package daemon

import (
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"

	"github.com/yubi233/agent-sessions/internal/adapter"
	"github.com/yubi233/agent-sessions/internal/authz"
)

// 本文件是 v0.6 残余项收口（生产 Daemon 签名私钥接线）的根因层回归：
// 环境契约解析、密钥文件格式、fail-closed 语义与签名数学正确性都在最低可证明层级钉住。
// 口径：local_test=true、fixture_data=true、real_browser=false、real_model=false。

func testLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

// writeSeedFile 在临时目录写一个符合生产格式的种子文件（一行 base64url seed，0600）。
func writeSeedFile(t *testing.T, content string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "terminal_signing_seed.b64")
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatalf("write seed file: %v", err)
	}
	return path
}

func testGetenv(values map[string]string) func(string) string {
	return func(key string) string { return values[key] }
}

// TestV06LoadTerminalSignerUnsetKeepsBearerBehavior：未配置任何来源时必须返回 (nil, nil)，
// 保证既有 bearer 桥接路径零行为变化（计划 §8.2 回滚安全要求）。
func TestV06LoadTerminalSignerUnsetKeepsBearerBehavior(t *testing.T) {
	signer, err := LoadTerminalSignerFromEnv(testGetenv(map[string]string{}), "dev-1")
	if err != nil || signer != nil {
		t.Fatalf("unset env must yield (nil,nil), got (%v,%v)", signer, err)
	}
}

// TestV06LoadTerminalSignerRejectsAmbiguousSources：文件与内联双来源互斥，
// 意图不明必须拒绝启动，不允许猜测优先级。
func TestV06LoadTerminalSignerRejectsAmbiguousSources(t *testing.T) {
	seed, _, err := GenerateTerminalSigningSeed()
	if err != nil {
		t.Fatalf("generate seed: %v", err)
	}
	path := writeSeedFile(t, seed+"\n")
	signer, err := LoadTerminalSignerFromEnv(testGetenv(map[string]string{
		TerminalSigningKeyFileEnvironment: path,
		TerminalSigningKeyEnvironment:     seed,
	}), "dev-1")
	if err == nil || signer != nil {
		t.Fatalf("ambiguous sources must fail-closed, got (%v,%v)", signer, err)
	}
}

// TestV06LoadTerminalSignerRequiresPairedDevice：配置了私钥但缺 device id 时不能启动；
// 否则进程只会在每次 hello 处失败且难以归因。
func TestV06LoadTerminalSignerRequiresPairedDevice(t *testing.T) {
	seed, _, err := GenerateTerminalSigningSeed()
	if err != nil {
		t.Fatalf("generate seed: %v", err)
	}
	signer, err := LoadTerminalSignerFromEnv(testGetenv(map[string]string{
		TerminalSigningKeyEnvironment: seed,
	}), "")
	if err == nil || signer != nil {
		t.Fatalf("missing device id must fail-closed, got (%v,%v)", signer, err)
	}
}

// TestV06LoadTerminalSignerFileAndInlineRoundtrip：文件与内联两条供给路径都必须产出
// 可通过 Relay 验签的签名者；签名数学用 authz.VerifyTerminalRequest 原语直接复核。
func TestV06LoadTerminalSignerFileAndInlineRoundtrip(t *testing.T) {
	seed, pubB64, err := GenerateTerminalSigningSeed()
	if err != nil {
		t.Fatalf("generate seed: %v", err)
	}
	pubRaw, err := base64.RawURLEncoding.DecodeString(pubB64)
	if err != nil {
		t.Fatalf("decode generated pub: %v", err)
	}
	pub := ed25519.PublicKey(pubRaw)

	cases := map[string]map[string]string{
		"inline": {TerminalSigningKeyEnvironment: seed},
		"file":   {TerminalSigningKeyFileEnvironment: writeSeedFile(t, seed+"\n")},
	}
	for name, values := range cases {
		signer, err := LoadTerminalSignerFromEnv(testGetenv(values), "dev-roundtrip")
		if err != nil || signer == nil {
			t.Fatalf("%s: loader returned (%v,%v)", name, signer, err)
		}
		// 桥接期契约：KeyID 必须等于 DeviceID，Relay 才会走配对内置公钥验签
		// （internal/domain/signed_terminal.go 的 key_id==device_id 分支）。
		if signer.DeviceID != "dev-roundtrip" || signer.KeyID != "dev-roundtrip" {
			t.Fatalf("%s: unexpected identity binding: %+v", name, signer)
		}
		body := []byte(`{"probe":true}`)
		sig, err := signer.sign(http.MethodPost, "/v1/daemon/hello", body, "nonce-1")
		if err != nil {
			t.Fatalf("%s: sign: %v", name, err)
		}
		if sig.BodyHash != authz.HashBody(body) {
			t.Fatalf("%s: body hash mismatch", name)
		}
		if err := authz.VerifyTerminalRequest(pub, sig, "dev-roundtrip", http.MethodPost, "/v1/daemon/hello"); err != nil {
			t.Fatalf("%s: relay-side verification failed: %v", name, err)
		}
	}
}

// TestV06LoadTerminalSignerRejectsInvalidMaterial：缺失文件、空内容、坏编码、错长度
// 全部 fail-closed；错误信息只含环境变量名与格式分类，不回显密钥材料。
func TestV06LoadTerminalSignerRejectsInvalidMaterial(t *testing.T) {
	cases := map[string]map[string]string{
		"missing file": {TerminalSigningKeyFileEnvironment: filepath.Join(t.TempDir(), "nope.b64")},
		"empty file":   {TerminalSigningKeyFileEnvironment: writeSeedFile(t, "\n")},
		"bad base64":   {TerminalSigningKeyEnvironment: "not-base64!!"},
		"wrong length": {TerminalSigningKeyEnvironment: base64.RawURLEncoding.EncodeToString([]byte("short"))},
	}
	for name, values := range cases {
		signer, err := LoadTerminalSignerFromEnv(testGetenv(values), "dev-1")
		if err == nil || signer != nil {
			t.Fatalf("%s: expected fail-closed, got (%v,%v)", name, signer, err)
		}
	}
}

// TestGenerateTerminalSigningSeedProducesVerifiablePair：keygen 产物必须公私钥同源——
// 公钥写入配对请求后，运行期签名必须能被 Relay 用同一公钥验证。
func TestGenerateTerminalSigningSeedProducesVerifiablePair(t *testing.T) {
	seedB64, pubB64, err := GenerateTerminalSigningSeed()
	if err != nil {
		t.Fatalf("generate: %v", err)
	}
	seedRaw, err := base64.RawURLEncoding.DecodeString(seedB64)
	if err != nil || len(seedRaw) != ed25519.SeedSize {
		t.Fatalf("seed decode/length: err=%v len=%d", err, len(seedRaw))
	}
	priv := ed25519.NewKeyFromSeed(seedRaw)
	pubRaw, err := base64.RawURLEncoding.DecodeString(pubB64)
	if err != nil {
		t.Fatalf("pub decode: %v", err)
	}
	if !priv.Public().(ed25519.PublicKey).Equal(ed25519.PublicKey(pubRaw)) {
		t.Fatalf("generated keypair not homologous")
	}
}

// TestIsTerminalAuthErrorCodeClassifiesProtocolCodes：五类签名协议错误码必须被识别，
// 非签名类错误码不得误伤（否则会改变 bearer 模式的重试语义）。
func TestIsTerminalAuthErrorCodeClassifiesProtocolCodes(t *testing.T) {
	for _, code := range []string{"SIGNATURE_REQUIRED", "SIGNATURE_INVALID", "NONCE_REUSED", "TIMESTAMP_EXPIRED", "KEY_UNKNOWN_OR_REVOKED"} {
		if !IsTerminalAuthErrorCode(code) {
			t.Fatalf("expected %q to be terminal auth code", code)
		}
	}
	for _, code := range []string{"", "INVALID_REQUEST", "UNAUTHENTICATED", "LEASE_CONFLICT"} {
		if IsTerminalAuthErrorCode(code) {
			t.Fatalf("unexpected terminal auth classification for %q", code)
		}
	}
}

// newWiringTestLoop 组装真实 Store + Runner + httptest 服务器的 RelayLoop，
// 服务器对一切请求返回 400 SIGNATURE_INVALID（模拟签名配置故障）。
func newWiringTestLoop(t *testing.T, signer *TerminalRequestSigner, hits *atomic.Int64) *RelayLoop {
	t.Helper()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		hits.Add(1)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		_, _ = w.Write([]byte(`{"code":"SIGNATURE_INVALID"}`))
	}))
	t.Cleanup(server.Close)
	store, err := OpenStore(filepath.Join(t.TempDir(), "daemon.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	t.Cleanup(func() { _ = store.Close() })
	runner := NewSessionRunner(store, map[string]adapter.Adapter{}, testLogger())
	return NewRelayLoop(store, &RelayClient{BaseURL: server.URL, AccessToken: "t", Signer: signer}, runner, FixtureEventEncoder{}, testLogger())
}

// TestV06RunWithRetryFailsFastOnSignatureAuthErrors：配置签名后，hello 返回签名类
// 协议错误（Relay 以 400 + 稳定 code 表达）必须立即退出，不允许退避重试掩盖配置故障；
// 未配置签名的 bearer 客户端对同一错误保持原有重试语义（行为不变对照组）。
func TestV06RunWithRetryFailsFastOnSignatureAuthErrors(t *testing.T) {
	t.Run("signed_mode_fails_fast", func(t *testing.T) {
		var hits atomic.Int64
		loop := newWiringTestLoop(t, &TerminalRequestSigner{DeviceID: "dev", KeyID: "dev", Priv: ed25519.NewKeyFromSeed(make([]byte, ed25519.SeedSize))}, &hits)
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		err := loop.RunWithRetry(ctx)
		var httpErr *RelayHTTPError
		// 签名模式下必须以原始协议错误退出，而不是 ctx 超时或无限退避。
		if !errors.As(err, &httpErr) || httpErr.Code != "SIGNATURE_INVALID" {
			t.Fatalf("signed mode must fail fast with protocol error, got %v", err)
		}
		// challenge + hello 各一次即应退出；超过说明仍在退避重试。
		if hits.Load() > 2 {
			t.Fatalf("signed mode retried %d times instead of failing fast", hits.Load())
		}
	})

	t.Run("bearer_mode_keeps_retrying", func(t *testing.T) {
		var hits atomic.Int64
		loop := newWiringTestLoop(t, nil, &hits)
		ctx, cancel := context.WithTimeout(context.Background(), 700*time.Millisecond)
		defer cancel()
		_ = loop.RunWithRetry(ctx)
		// bearer 对照组：400 签名错误不在快速失败名单，窗口内必须发生多次尝试。
		if hits.Load() < 2 {
			t.Fatalf("bearer mode should keep retrying 400 signature errors, hits=%d", hits.Load())
		}
	})
}
