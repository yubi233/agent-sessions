package daemon

import (
	"crypto/ecdh"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/yubi233/agent-sessions/packages/protocol"
)

// WEB-07 根因回归：浏览器侧临时私钥与 Daemon 静态私钥必须能互解同一请求，但 AAD 中任一
// 会话、Terminal 或 kind 被 Relay 调包时都必须 fail-closed。
func TestWebReadTransportRoundTripAndAADBinding(t *testing.T) {
	curve := ecdh.X25519()
	terminalPrivate, err := curve.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	transport, err := NewWebReadTransport(terminalPrivate.Bytes())
	if err != nil {
		t.Fatal(err)
	}
	clientPrivate, err := curve.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	command := RelayCommand{
		CommandID:        "webread_0123456789abcdef0123456789abcdef",
		SessionID:        "sess-web-read",
		WorkspaceID:      "ws-web-read",
		TargetTerminalID: "term-web-read",
		Kind:             "code.read",
	}
	command.PayloadJSON = sealWebReadRequestForTest(t, command, clientPrivate, terminalPrivate.PublicKey(), WebReadRequest{Path: "src/main.go"})

	request, clientPublic, err := transport.OpenRequest(command)
	if err != nil {
		t.Fatalf("open request: %v", err)
	}
	if request.Path != "src/main.go" || !clientPublic.Equal(clientPrivate.PublicKey()) {
		t.Fatalf("unexpected opened request: %+v", request)
	}
	envelope, err := transport.SealResponse(command, clientPublic, map[string]any{"path": request.Path, "content": "private source"})
	if err != nil {
		t.Fatalf("seal response: %v", err)
	}
	shared, err := clientPrivate.ECDH(terminalPrivate.PublicKey())
	if err != nil {
		t.Fatal(err)
	}
	plaintext, err := openWebReadPayload(shared, "response", webReadAAD(command, "response"), envelope.Nonce, envelope.Ciphertext, envelope.AADHash)
	if err != nil {
		t.Fatalf("client opens response: %v", err)
	}
	var payload webReadResponsePayload
	if err := json.Unmarshal(plaintext, &payload); err != nil {
		t.Fatal(err)
	}
	if payload.Kind != "code.read" || payload.Version != 1 {
		t.Fatalf("unexpected response payload: %+v", payload)
	}

	tampered := command
	tampered.SessionID = "sess-other"
	if _, _, err := transport.OpenRequest(tampered); err == nil {
		t.Fatal("tampered session AAD must be rejected")
	}
	tampered = command
	tampered.TargetTerminalID = "term-other"
	if _, _, err := transport.OpenRequest(tampered); err == nil {
		t.Fatal("tampered terminal AAD must be rejected")
	}
	tampered = command
	tampered.Kind = "git.status"
	if _, _, err := transport.OpenRequest(tampered); err == nil {
		t.Fatal("tampered kind AAD must be rejected")
	}
}

// WEB-07 根因回归：Web envelope 必须在真实本机 dispatcher 中接受与 fixture 完全相同的
// Workspace 安全边界。这里只验证结果的稳定错误码，绝不把路径或文件正文输出到测试日志。
func TestWebReadDispatcherFailsClosedForUnsafeWorkspaceInputs(t *testing.T) {
	root := t.TempDir()
	runGit(t, root, "init")
	runGit(t, root, "config", "user.email", "fixture@example.test")
	runGit(t, root, "config", "user.name", "Fixture")
	if err := os.MkdirAll(filepath.Join(root, "dir"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "safe.txt"), []byte("safe\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "binary.bin"), []byte{0x00, 0x01, 0x02}, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "large.txt"), []byte(strings.Repeat("x", maxReadOnlyFileBytes+1)), 0o600); err != nil {
		t.Fatal(err)
	}
	runGit(t, root, "add", "safe.txt", "binary.bin", "large.txt")
	runGit(t, root, "commit", "-m", "initial")
	// 在创建仓外 symlink 前取得 snapshot；Git 读取器会主动拒绝不安全链接，因此不能把该链接
	// 混入产生 snapshot 的受信 Workspace 状态。
	reader := NewWorkspaceReader(root, "git")
	staleStatus, err := reader.GitStatus(t.Context())
	if err != nil || staleStatus.SnapshotToken == "" {
		t.Fatalf("create stale snapshot: status=%+v err=%v", staleStatus, err)
	}

	outside := t.TempDir()
	if err := os.WriteFile(filepath.Join(outside, "secret.txt"), []byte("outside\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(root, "outside-link")); err != nil {
		t.Fatalf("create test symlink: %v", err)
	}

	store, err := OpenStore(filepath.Join(t.TempDir(), "daemon.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if _, err := store.ConfirmWorkspace("ws-web-safe", root); err != nil {
		t.Fatal(err)
	}
	if err := store.Set("terminal_id", "term-web-safe"); err != nil {
		t.Fatal(err)
	}
	dispatcher := NewReadOnlyDispatcher(store, "git")
	curve := ecdh.X25519()
	terminalPrivate, err := curve.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	transport, err := NewWebReadTransport(terminalPrivate.Bytes())
	if err != nil {
		t.Fatal(err)
	}
	defer transport.Destroy()

	attemptCount := 0
	attempt := func(kind, path, snapshot string, wantCode string) {
		t.Helper()
		attemptCount++
		clientPrivate, err := curve.GenerateKey(rand.Reader)
		if err != nil {
			t.Fatal(err)
		}
		command := RelayCommand{
			CommandID:        fmt.Sprintf("webread_safety_case_%02d_abcdefghijkl", attemptCount),
			SessionID:        "sess-web-safe",
			WorkspaceID:      "ws-web-safe",
			TargetTerminalID: "term-web-safe",
			Kind:             kind,
		}
		command.PayloadJSON = sealWebReadRequestForTest(t, command, clientPrivate, terminalPrivate.PublicKey(), WebReadRequest{
			Path: path, SnapshotToken: snapshot, Limit: 100,
		})
		_, err = dispatcher.ExecuteWeb(t.Context(), command, transport)
		if got := CommandErrorCode(err); got != wantCode {
			t.Fatalf("kind=%s path=%q code=%s want=%s err=%v", kind, path, got, wantCode, err)
		}
	}

	attempt("code.read", "../outside.txt", "", protocol.ErrWorkspacePathDenied)
	attempt("code.read", filepath.Join(root, "safe.txt"), "", protocol.ErrWorkspacePathDenied)
	attempt("code.read", "outside-link/secret.txt", "", protocol.ErrWorkspacePathDenied)
	attempt("code.read", "dir", "", protocol.ErrContentUnavailable)
	attempt("code.read", "binary.bin", "", protocol.ErrContentUnavailable)
	attempt("code.read", "large.txt", "", protocol.ErrPayloadTooLarge)

	// GitDiff 会再次验证整个 Git 根。删除仅用于 symlink 拒绝的夹具后，确保接下来的失败根因
	// 是 snapshot 过期而不是仍在的仓外链接。
	if err := os.Remove(filepath.Join(root, "outside-link")); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "safe.txt"), []byte("changed after snapshot\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	attempt("git.diff", "safe.txt", staleStatus.SnapshotToken, protocol.ErrSnapshotStale)
}

func sealWebReadRequestForTest(t *testing.T, command RelayCommand, clientPrivate *ecdh.PrivateKey, terminalPublic *ecdh.PublicKey, request WebReadRequest) string {
	t.Helper()
	shared, err := clientPrivate.ECDH(terminalPublic)
	if err != nil {
		t.Fatal(err)
	}
	plaintext, err := json.Marshal(request)
	if err != nil {
		t.Fatal(err)
	}
	envelope, err := sealWebReadPayload(shared, "request", webReadAAD(command, "request"), []byte("123456789012"), plaintext)
	if err != nil {
		t.Fatal(err)
	}
	raw, err := json.Marshal(webReadRequestEnvelope{
		Alg: webReadAlgorithm, PayloadVersion: webReadPayloadVersion,
		EphemeralPublicKey: base64.RawStdEncoding.EncodeToString(clientPrivate.PublicKey().Bytes()),
		Nonce:              envelope.Nonce, Ciphertext: envelope.Ciphertext, AADHash: envelope.AADHash,
	})
	if err != nil {
		t.Fatal(err)
	}
	return string(raw)
}
