package daemon

import (
	"context"
	"crypto/ecdh"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/yubi233/agent-sessions/packages/crypto"
)

// V085-01（ADR-016）：SessionDEKManager 首启会话时生成本机 DEK 并 wrap 上行；
// 载荷 = sender_pub(32)||nonce(12)||gcm，owner 私钥可解开还原本机 DEK；幂等不重发。
func TestSessionDEKManagerEnsuresAndPublishes(t *testing.T) {
	// 模拟 owner 设备密钥对（Relay 侧只有公钥，私钥在“设备”上）。
	ownerPrivate, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	ownerPublic := ownerPrivate.PublicKey()
	var putBodies []map[string]any
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
		switch {
		case request.Method == http.MethodGet && request.URL.Path == "/v1/daemon/sessions/sess-dek-1/owner-key":
			w.Header().Set("Content-Type", "application/json")
			_, _ = io.WriteString(w, `{"encryption_public_key":"`+base64.RawStdEncoding.EncodeToString(ownerPublic.Bytes())+`","device_id":"dev-owner-1"}`)
		case request.Method == http.MethodPut && request.URL.Path == "/v1/daemon/sessions/sess-dek-1/content-dek":
			var body map[string]any
			_ = json.NewDecoder(request.Body).Decode(&body)
			putBodies = append(putBodies, body)
			w.Header().Set("Content-Type", "application/json")
			_, _ = io.WriteString(w, `{"status":"stored"}`)
		default:
			http.NotFound(w, request)
		}
	}))
	defer server.Close()

	state, err := OpenStore(filepath.Join(t.TempDir(), "dek.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer state.Close()
	client := &RelayClient{BaseURL: server.URL, AccessToken: "fixture"}
	manager := NewSessionDEKManager(state, client)

	if err := manager.EnsureAndPublishDEK(context.Background(), "sess-dek-1"); err != nil {
		t.Fatalf("ensure: %v", err)
	}
	// 幂等：第二次调用不重复上行。
	if err := manager.EnsureAndPublishDEK(context.Background(), "sess-dek-1"); err != nil {
		t.Fatalf("ensure again: %v", err)
	}
	if len(putBodies) != 1 {
		t.Fatalf("want 1 content-dek put, got %d", len(putBodies))
	}
	body := putBodies[0]
	if body["dek_id"] != "dek-sess-dek-1" || body["recipient_device_id"] != "dev-owner-1" {
		t.Fatalf("unexpected put body: %v", body)
	}
	// 本机 DEK 已持久化。
	localB64, err := state.Get("session-dek:sess-dek-1")
	if err != nil || len(localB64) == 0 {
		t.Fatalf("local dek missing: %v", err)
	}
	localDEK, err := base64.RawStdEncoding.DecodeString(localB64)
	if err != nil || len(localDEK) != 32 {
		t.Fatalf("local dek decode: %v", err)
	}
	// wrapped 载荷解包：sender_pub(32)||nonce(12)||gcm，用 owner 私钥 + sender 公钥解开。
	wrappedRaw, _ := body["wrapped_dek"].(string)
	payload, err := base64.StdEncoding.DecodeString(wrappedRaw)
	if err != nil || len(payload) < 44 {
		t.Fatalf("wrapped payload decode: %v len=%d", err, len(payload))
	}
	senderPub, err := ecdh.X25519().NewPublicKey(payload[:32])
	if err != nil {
		t.Fatal(err)
	}
	unwrapped, err := crypto.UnwrapDEK(ownerPrivate, senderPub, payload[32:44], payload[44:])
	if err != nil {
		t.Fatalf("unwrap: %v", err)
	}
	if string(unwrapped) != string(localDEK) {
		t.Fatalf("unwrapped dek mismatch: got %x want %x", unwrapped, localDEK)
	}
}

// V010（ADR-017 §6）：ReconcileOwnerDEKWraps 拉取待补清单并为缺失组合补 wrap。
// 三类行为一次钉死：
//   1) 本机持有 DEK 的会话 → 为 recipient 补 wrap，recipient 私钥可解且等于本机 DEK；
//   2) 本机无 DEK 的会话（daemon 未处理过）→ 跳过，不伪造；
//   3) 清单 DEK id 与本机派生口径不一致 → fail-closed 跳过；
// 且对账幂等：清单收敛为空后不再产生上行。
func TestSessionDEKManagerReconcileOwnerDEKWraps(t *testing.T) {
	recipientPrivate, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	recipientPubB64 := base64.RawStdEncoding.EncodeToString(recipientPrivate.PublicKey().Bytes())
	pendingRows := []map[string]string{
		{"session_id": "sess-recon-1", "device_id": "dev-joiner", "encryption_public_key": recipientPubB64, "dek_id": "dek-sess-recon-1"},
		{"session_id": "sess-recon-2", "device_id": "dev-joiner", "encryption_public_key": recipientPubB64, "dek_id": "dek-sess-recon-2"},
		{"session_id": "sess-recon-3", "device_id": "dev-joiner", "encryption_public_key": recipientPubB64, "dek_id": "mismatched-id"},
	}
	var putBodies []map[string]any
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
		switch {
		case request.Method == http.MethodGet && request.URL.Path == "/v1/daemon/dek-wraps/pending":
			w.Header().Set("Content-Type", "application/json")
			rows := "[]"
			if len(pendingRows) > 0 {
				var sb strings.Builder
				_ = sb.WriteByte('[')
				for i, row := range pendingRows {
					if i > 0 {
						_ = sb.WriteByte(',')
					}
					_ = json.NewEncoder(&sb).Encode(map[string]string{
						"session_id": row["session_id"], "device_id": row["device_id"],
						"encryption_public_key": row["encryption_public_key"], "dek_id": row["dek_id"],
					})
				}
				_ = sb.WriteByte(']')
				rows = sb.String()
			}
			_, _ = io.WriteString(w, `{"pending":`+rows+`}`)
		case request.Method == http.MethodPut &&
			strings.HasPrefix(request.URL.Path, "/v1/daemon/sessions/") &&
			strings.HasSuffix(request.URL.Path, "/content-dek"):
			var body map[string]any
			_ = json.NewDecoder(request.Body).Decode(&body)
			putBodies = append(putBodies, body)
			w.Header().Set("Content-Type", "application/json")
			_, _ = io.WriteString(w, `{"status":"stored"}`)
		default:
			http.NotFound(w, request)
		}
	}))
	defer server.Close()

	state, err := OpenStore(filepath.Join(t.TempDir(), "dek-recon.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer state.Close()
	// 只有 sess-recon-1 有本机 DEK；recon-2（无 DEK）与 recon-3（id 不一致）都应跳过。
	dek, err := crypto.RandomDEK()
	if err != nil {
		t.Fatal(err)
	}
	if err := state.Set("session-dek:sess-recon-1", base64.RawStdEncoding.EncodeToString(dek)); err != nil {
		t.Fatal(err)
	}
	client := &RelayClient{BaseURL: server.URL, AccessToken: "fixture"}
	manager := NewSessionDEKManager(state, client)

	published, err := manager.ReconcileOwnerDEKWraps(context.Background())
	if err != nil {
		t.Fatalf("reconcile: %v", err)
	}
	if published != 1 || len(putBodies) != 1 {
		t.Fatalf("want 1 published put, got published=%d puts=%d", published, len(putBodies))
	}
	body := putBodies[0]
	if body["dek_id"] != "dek-sess-recon-1" || body["recipient_device_id"] != "dev-joiner" {
		t.Fatalf("unexpected reconcile put body: %v", body)
	}
	wrappedRaw, _ := body["wrapped_dek"].(string)
	payload, err := base64.StdEncoding.DecodeString(wrappedRaw)
	if err != nil || len(payload) < 44 {
		t.Fatalf("wrapped payload decode: %v len=%d", err, len(payload))
	}
	senderPub, err := ecdh.X25519().NewPublicKey(payload[:32])
	if err != nil {
		t.Fatal(err)
	}
	unwrapped, err := crypto.UnwrapDEK(recipientPrivate, senderPub, payload[32:44], payload[44:])
	if err != nil {
		t.Fatalf("unwrap by recipient: %v", err)
	}
	if string(unwrapped) != string(dek) {
		t.Fatalf("recipient unwrapped dek mismatch")
	}

	// 幂等收敛：清单为空后零上行。
	pendingRows = nil
	publishedAgain, err := manager.ReconcileOwnerDEKWraps(context.Background())
	if err != nil || publishedAgain != 0 || len(putBodies) != 1 {
		t.Fatalf("second reconcile should be a no-op: published=%d puts=%d err=%v", publishedAgain, len(putBodies), err)
	}
}

// V010：对账周期缺省 1 分钟；env 覆盖生效；非法值回退缺省（不因配置错误崩溃）。
func TestDEKWrapReconcileIntervalFromEnv(t *testing.T) {
	if got := dekWrapReconcileInterval(); got != time.Minute {
		t.Fatalf("default interval = %v", got)
	}
	t.Setenv("AGENT_SESSIONS_DEK_WRAP_RECONCILE_MS", "25")
	if got := dekWrapReconcileInterval(); got != 25*time.Millisecond {
		t.Fatalf("env override = %v", got)
	}
	t.Setenv("AGENT_SESSIONS_DEK_WRAP_RECONCILE_MS", "not-a-number")
	if got := dekWrapReconcileInterval(); got != time.Minute {
		t.Fatalf("invalid env should fall back, got %v", got)
	}
}
