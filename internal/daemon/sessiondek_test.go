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
	"testing"

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
