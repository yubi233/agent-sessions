package relay

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdh"
	"crypto/hkdf"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/yubi233/agent-sessions/internal/adapter"
	"github.com/yubi233/agent-sessions/internal/daemon"
	"github.com/yubi233/agent-sessions/internal/domain"
)

// WEB-07：真实本机 Daemon + 临时 Git Workspace 的 Web 只读 request/response 闭环。浏览器端
// 的 X25519 实现由下方独立 helper 模拟，Relay 只能观察两个 opaque envelope 和 command 状态。
func TestP4WebReadTransportRoundTripStaysOpaqueAtRelay(t *testing.T) {
	root := t.TempDir()
	initP4GitWorkspace(t, root)
	if err := os.MkdirAll(filepath.Join(root, "src"), 0o755); err != nil {
		t.Fatal(err)
	}
	const source = "package privatefixture\nconst localOnly = true\n"
	if err := os.WriteFile(filepath.Join(root, "src", "private.go"), []byte(source), 0o600); err != nil {
		t.Fatal(err)
	}

	env := newTestEnv(t)
	owner := env.registerAs(t, "p4-web-read@test.dev")
	curve := ecdh.X25519()
	terminalPrivate, err := curve.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	terminal := pairP4Terminal(t, env, owner, base64.RawStdEncoding.EncodeToString(terminalPrivate.PublicKey().Bytes()))
	terminalID := daemonHelloWithCapabilities(t, env, terminal.AccessToken, []string{"file_read", "git_read", "web_read_transport"})
	sessionID, workspaceID := env.createBoundSessionAtRoot(t, owner, terminalID, "p4-web-read", root)
	webToken := loginP4Web(t, env, "p4-web-read@test.dev")

	// 普通 owner token 不能借这个 endpoint 获取 public transport 或绕过 Android/write 边界。
	if response := env.do(t, http.MethodGet, "/v1/sessions/"+sessionID+"/readonly-transport", nil, owner.AccessToken); response.Code != http.StatusForbidden {
		t.Fatalf("owner transport status=%d want 403 body=%s", response.Code, response.Body.String())
	}
	transportResponse := env.do(t, http.MethodGet, "/v1/sessions/"+sessionID+"/readonly-transport", nil, webToken)
	if transportResponse.Code != http.StatusOK {
		t.Fatalf("web transport status=%d body=%s", transportResponse.Code, transportResponse.Body.String())
	}
	var transportInfo struct {
		TerminalID          string `json:"terminal_id"`
		WorkspaceID         string `json:"workspace_id"`
		EncryptionPublicKey string `json:"encryption_public_key"`
		Algorithm           string `json:"algorithm"`
	}
	decodeW1(t, transportResponse.Body.Bytes(), &transportInfo)
	if transportInfo.TerminalID != terminalID || transportInfo.WorkspaceID != workspaceID || transportInfo.Algorithm != domain.WebReadEnvelopeAlgorithm {
		t.Fatalf("unexpected web transport: %+v", transportInfo)
	}

	clientPrivate, err := curve.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	requestID := "webread_0123456789abcdef0123456789abcdef"
	envelope := sealP4WebRequest(t, p4WebAAD{
		RequestID: requestID, SessionID: sessionID, WorkspaceID: workspaceID, TerminalID: terminalID, Kind: "code.read", Direction: "request",
	}, clientPrivate, terminalPrivate.PublicKey(), map[string]any{"path": "src/private.go"})
	request := env.do(t, http.MethodPost, "/v1/sessions/"+sessionID+"/readonly-requests", map[string]any{
		"request_id": requestID, "kind": "code.read", "envelope": envelope,
	}, webToken)
	if request.Code != http.StatusAccepted {
		t.Fatalf("submit web read status=%d body=%s", request.Code, request.Body.String())
	}

	server := httptest.NewServer(env.router)
	defer server.Close()
	local, err := daemon.OpenStore(filepath.Join(t.TempDir(), "daemon.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer local.Close()
	if _, err := local.ConfirmWorkspace(workspaceID, root); err != nil {
		t.Fatal(err)
	}
	webRead, err := daemon.NewWebReadTransport(terminalPrivate.Bytes())
	if err != nil {
		t.Fatal(err)
	}
	defer webRead.Destroy()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	runner := daemon.NewSessionRunner(local, map[string]adapter.Adapter{}, logger)
	defer runner.Close(context.Background())
	loop := daemon.NewRelayLoop(local, &daemon.RelayClient{BaseURL: server.URL, AccessToken: terminal.AccessToken}, runner, daemon.FixtureEventEncoder{}, logger)
	loop.DaemonVersion = "p4-web-read-fixture"
	loop.Hostname = "p4-web-read-host"
	loop.Platform = "test"
	loop.Capabilities = []string{"file_read", "git_read", "web_read_transport"}
	loop.WebRead = webRead
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- loop.RunWithRetry(ctx) }()

	var result struct {
		Status   string                `json:"status"`
		Envelope p4WebResponseEnvelope `json:"envelope"`
	}
	deadline := time.Now().Add(4 * time.Second)
	for time.Now().Before(deadline) {
		response := env.do(t, http.MethodGet, "/v1/sessions/"+sessionID+"/readonly-requests/"+requestID, nil, webToken)
		if response.Code == http.StatusOK {
			decodeW1(t, response.Body.Bytes(), &result)
			if result.Status == domain.CommandSucceeded && result.Envelope.Ciphertext != "" {
				break
			}
		}
		time.Sleep(20 * time.Millisecond)
	}
	if result.Status != domain.CommandSucceeded || result.Envelope.Ciphertext == "" {
		t.Fatalf("web read did not converge: %+v", result)
	}
	plaintext := openP4WebResponse(t, p4WebAAD{
		RequestID: requestID, SessionID: sessionID, WorkspaceID: workspaceID, TerminalID: terminalID, Kind: "code.read", Direction: "response",
	}, clientPrivate, terminalPrivate.PublicKey(), result.Envelope)
	var opened struct {
		Version int    `json:"version"`
		Kind    string `json:"kind"`
		Result  struct {
			Path    string `json:"path"`
			Content string `json:"content"`
		} `json:"result"`
	}
	if err := json.Unmarshal(plaintext, &opened); err != nil {
		t.Fatalf("decode browser response: %v", err)
	}
	if opened.Version != 1 || opened.Kind != "code.read" || opened.Result.Path != "src/private.go" || opened.Result.Content != source {
		t.Fatalf("browser response mismatch: %+v", opened)
	}

	// 第一个请求在 Daemon 连接前写入，用于验证 SQLite 初始回放。它已收敛意味着 loop 的 SSE
	// 订阅已建立；第二个请求必须由提交 handler 实时发布到 Hub，不能等下一次 reconnect 才被消费。
	liveRequestID := "webread_live0123456789abcdef0123456789"
	liveEnvelope := sealP4WebRequest(t, p4WebAAD{
		RequestID: liveRequestID, SessionID: sessionID, WorkspaceID: workspaceID, TerminalID: terminalID, Kind: "code.read", Direction: "request",
	}, clientPrivate, terminalPrivate.PublicKey(), map[string]any{"path": "src/private.go"})
	liveRequest := env.do(t, http.MethodPost, "/v1/sessions/"+sessionID+"/readonly-requests", map[string]any{
		"request_id": liveRequestID, "kind": "code.read", "envelope": liveEnvelope,
	}, webToken)
	if liveRequest.Code != http.StatusAccepted {
		t.Fatalf("submit live web read status=%d body=%s", liveRequest.Code, liveRequest.Body.String())
	}
	var liveResult struct {
		Status   string                `json:"status"`
		Envelope p4WebResponseEnvelope `json:"envelope"`
	}
	liveDeadline := time.Now().Add(4 * time.Second)
	for time.Now().Before(liveDeadline) {
		response := env.do(t, http.MethodGet, "/v1/sessions/"+sessionID+"/readonly-requests/"+liveRequestID, nil, webToken)
		if response.Code == http.StatusOK {
			decodeW1(t, response.Body.Bytes(), &liveResult)
			if liveResult.Status == domain.CommandSucceeded && liveResult.Envelope.Ciphertext != "" {
				break
			}
		}
		time.Sleep(20 * time.Millisecond)
	}
	if liveResult.Status != domain.CommandSucceeded || liveResult.Envelope.Ciphertext == "" {
		t.Fatalf("live web read was not delivered through daemon hub: %+v", liveResult)
	}
	cancel()
	if runErr := <-done; runErr != context.Canceled {
		t.Fatalf("web read daemon loop result=%v want context.Canceled", runErr)
	}
	command, err := env.repo.CommandByID(t.Context(), requestID)
	if err != nil {
		t.Fatal(err)
	}
	for _, persisted := range []string{command.CiphertextJSON, command.ReadResponseEnvelopeJSON} {
		if strings.Contains(persisted, source) || strings.Contains(persisted, "src/private.go") || strings.Contains(persisted, root) {
			t.Fatal("Relay persisted protected read plaintext or path")
		}
	}
	events, err := env.repo.ListEventsAfter(t.Context(), sessionID, 0)
	if err != nil {
		t.Fatal(err)
	}
	for _, event := range events {
		if strings.Contains(event.EnvelopeJSON, source) || strings.Contains(event.EnvelopeJSON, "src/private.go") {
			t.Fatal("web read result leaked into account event stream")
		}
	}
}

// WEB-07 负向契约：仅 web 角色可创建/读取限定请求；Terminal 必须先 ack started，才可以保存
// response envelope。这样 response API 既不能绕过账号范围，也不能抢在本机安全边界前改变状态。
func TestP4WebReadRequestScopeAndResponseStateFence(t *testing.T) {
	env := newTestEnv(t)
	owner := env.registerAs(t, "p4-web-fence@test.dev")
	curve := ecdh.X25519()
	terminalPrivate, err := curve.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	terminal := pairP4Terminal(t, env, owner, base64.RawStdEncoding.EncodeToString(terminalPrivate.PublicKey().Bytes()))
	terminalID := daemonHelloWithCapabilities(t, env, terminal.AccessToken, []string{"file_read", "git_read", "web_read_transport"})
	sessionID, workspaceID := env.createBoundSession(t, owner, terminalID, "p4-web-fence")
	webToken := loginP4Web(t, env, "p4-web-fence@test.dev")
	clientPrivate, err := curve.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	requestID := "webread_abcdef0123456789abcdef0123456789"
	envelope := sealP4WebRequest(t, p4WebAAD{
		RequestID: requestID, SessionID: sessionID, WorkspaceID: workspaceID, TerminalID: terminalID, Kind: "git.status", Direction: "request",
	}, clientPrivate, terminalPrivate.PublicKey(), map[string]any{})

	// Owner 仍是 Android 写控制身份，不能创建或读取 Web 专用请求。
	if response := env.do(t, http.MethodPost, "/v1/sessions/"+sessionID+"/readonly-requests", map[string]any{
		"request_id": requestID, "kind": "git.status", "envelope": envelope,
	}, owner.AccessToken); response.Code != http.StatusForbidden {
		t.Fatalf("owner web request status=%d want 403 body=%s", response.Code, response.Body.String())
	}
	if response := env.do(t, http.MethodPost, "/v1/sessions/"+sessionID+"/readonly-requests", map[string]any{
		"request_id": requestID, "kind": "git.status", "envelope": envelope,
	}, webToken); response.Code != http.StatusAccepted {
		t.Fatalf("web request status=%d want 202 body=%s", response.Code, response.Body.String())
	}
	if response := env.do(t, http.MethodGet, "/v1/sessions/"+sessionID+"/readonly-requests/webread_missing0123456789abcdef", nil, webToken); response.Code != http.StatusNotFound {
		t.Fatalf("missing web request status=%d want 404 body=%s", response.Code, response.Body.String())
	}

	responseEnvelope := validP4WebResponseEnvelope()
	plaintextEnvelope := map[string]any{
		"alg": responseEnvelope.Alg, "payload_version": responseEnvelope.PayloadVersion,
		"nonce": responseEnvelope.Nonce, "ciphertext": responseEnvelope.Ciphertext, "aad_hash": responseEnvelope.AADHash,
		// Relay 不能仅因值最终不会被浏览器解封而保存此字段；它本身已是受保护内容泄漏。
		"content": "must-not-persist-web-read-plaintext",
	}
	if response := env.do(t, http.MethodPost, "/v1/sessions/"+sessionID+"/readonly-requests", map[string]any{
		"request_id": "webread_plaintext0123456789abcdef0123456789", "kind": "git.status", "envelope": map[string]any{
			"alg": envelope["alg"], "payload_version": envelope["payload_version"], "ephemeral_public_key": envelope["ephemeral_public_key"],
			"nonce": envelope["nonce"], "ciphertext": envelope["ciphertext"], "aad_hash": envelope["aad_hash"], "path": "must-not-persist-web-read-path",
		},
	}, webToken); response.Code != http.StatusBadRequest {
		t.Fatalf("plaintext request envelope status=%d want 400 body=%s", response.Code, response.Body.String())
	}
	if response := env.do(t, http.MethodPost, "/v1/daemon/commands/"+requestID+"/readonly-response", map[string]any{
		"protocol_version": 1, "delivery_seq": 1, "envelope": responseEnvelope,
	}, terminal.AccessToken); response.Code != http.StatusConflict {
		t.Fatalf("response before started status=%d want 409 body=%s", response.Code, response.Body.String())
	}
	if response := env.do(t, http.MethodPost, "/v1/daemon/commands/"+requestID+"/ack", map[string]any{
		"protocol_version": 1, "delivery_seq": 1, "ack_kind": "started",
	}, terminal.AccessToken); response.Code != http.StatusOK {
		t.Fatalf("started web request status=%d body=%s", response.Code, response.Body.String())
	}
	if response := env.do(t, http.MethodPost, "/v1/daemon/commands/"+requestID+"/readonly-response", map[string]any{
		"protocol_version": 1, "delivery_seq": 1, "envelope": plaintextEnvelope,
	}, terminal.AccessToken); response.Code != http.StatusBadRequest {
		t.Fatalf("plaintext response envelope status=%d want 400 body=%s", response.Code, response.Body.String())
	}
	if response := env.do(t, http.MethodPost, "/v1/daemon/commands/"+requestID+"/readonly-response", map[string]any{
		"protocol_version": 1, "delivery_seq": 1, "envelope": responseEnvelope,
	}, terminal.AccessToken); response.Code != http.StatusOK {
		t.Fatalf("response after started status=%d body=%s", response.Code, response.Body.String())
	}

	env.provisionAdditionalAccount(t, "p4-web-other@test.dev")
	otherWebToken := loginP4Web(t, env, "p4-web-other@test.dev")
	if response := env.do(t, http.MethodGet, "/v1/sessions/"+sessionID+"/readonly-requests/"+requestID, nil, otherWebToken); response.Code != http.StatusForbidden {
		t.Fatalf("cross-account web request status=%d want 403 body=%s", response.Code, response.Body.String())
	}
}

func validP4WebResponseEnvelope() p4WebResponseEnvelope {
	return p4WebResponseEnvelope{
		Alg:            domain.WebReadEnvelopeAlgorithm,
		PayloadVersion: 1,
		Nonce:          base64.RawStdEncoding.EncodeToString(make([]byte, 12)),
		Ciphertext:     base64.RawStdEncoding.EncodeToString(make([]byte, 16)),
		AADHash:        strings.Repeat("0", 64),
	}
}

func initP4GitWorkspace(t *testing.T, root string) {
	t.Helper()
	for _, args := range [][]string{{"init", "-q"}, {"config", "user.email", "fixture@example.test"}, {"config", "user.name", "Fixture"}, {"commit", "--allow-empty", "-qm", "initial"}} {
		command := exec.Command("git", args...)
		command.Dir = root
		if output, err := command.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v %s", args, err, output)
		}
	}
}

func pairP4Terminal(t *testing.T, env *testEnv, owner authPair, encryptionPublicKey string) authPair {
	t.Helper()
	pending := env.do(t, http.MethodPost, "/v1/pairing/requests", map[string]any{
		"role": "terminal", "display_name": "p4-web-terminal", "platform": "test",
		"identity_public_key": "p4-web-identity", "encryption_public_key": encryptionPublicKey,
	}, owner.AccessToken)
	if pending.Code != http.StatusCreated {
		t.Fatalf("pair terminal status=%d body=%s", pending.Code, pending.Body.String())
	}
	var pairing struct {
		ID string `json:"id"`
	}
	decodeW1(t, pending.Body.Bytes(), &pairing)
	approved := env.do(t, http.MethodPost, "/v1/pairing/requests/"+pairing.ID+"/approve", nil, owner.AccessToken)
	if approved.Code != http.StatusOK {
		t.Fatalf("approve terminal status=%d body=%s", approved.Code, approved.Body.String())
	}
	var device struct {
		ID string `json:"id"`
	}
	decodeW1(t, approved.Body.Bytes(), &device)
	tokens, err := domain.NewAuthService(env.repo).IssueForDevice(t.Context(), owner.AccountID, device.ID)
	if err != nil {
		t.Fatal(err)
	}
	return authPair{AccountID: owner.AccountID, DeviceID: device.ID, AccessToken: tokens.AccessToken, RefreshToken: tokens.RefreshToken}
}

func daemonHelloWithCapabilities(t *testing.T, env *testEnv, token string, capabilities []string) string {
	t.Helper()
	response := env.do(t, http.MethodPost, "/v1/daemon/hello", map[string]any{
		"protocol_version": 1, "daemon_version": "p4-fixture", "hostname": "p4-fixture", "platform": "test", "capabilities": capabilities,
	}, token)
	if response.Code != http.StatusOK {
		t.Fatalf("daemon hello status=%d body=%s", response.Code, response.Body.String())
	}
	var hello struct {
		TerminalID string `json:"terminal_id"`
	}
	decodeW1(t, response.Body.Bytes(), &hello)
	return hello.TerminalID
}

func loginP4Web(t *testing.T, env *testEnv, email string) string {
	t.Helper()
	response := env.do(t, http.MethodPost, "/v1/auth/login", map[string]any{"email": email, "password": "test-pass-123", "device_role": "web"}, "")
	if response.Code != http.StatusOK {
		t.Fatalf("web login status=%d body=%s", response.Code, response.Body.String())
	}
	var tokens struct {
		AccessToken string `json:"access_token"`
	}
	decodeW1(t, response.Body.Bytes(), &tokens)
	return tokens.AccessToken
}

type p4WebAAD struct {
	RequestID, SessionID, WorkspaceID, TerminalID, Kind, Direction string
}

type p4WebResponseEnvelope struct {
	Alg            string `json:"alg"`
	PayloadVersion int    `json:"payload_version"`
	Nonce          string `json:"nonce"`
	Ciphertext     string `json:"ciphertext"`
	AADHash        string `json:"aad_hash"`
}

func p4WebAADBytes(value p4WebAAD) []byte {
	raw, _ := json.Marshal(struct {
		RequestID   string `json:"request_id"`
		SessionID   string `json:"session_id"`
		WorkspaceID string `json:"workspace_id"`
		TerminalID  string `json:"terminal_id"`
		Kind        string `json:"kind"`
		Direction   string `json:"direction"`
	}{value.RequestID, value.SessionID, value.WorkspaceID, value.TerminalID, value.Kind, value.Direction})
	return raw
}

func sealP4WebRequest(t *testing.T, aad p4WebAAD, clientPrivate *ecdh.PrivateKey, terminalPublic *ecdh.PublicKey, payload any) map[string]any {
	t.Helper()
	shared, err := clientPrivate.ECDH(terminalPublic)
	if err != nil {
		t.Fatal(err)
	}
	plaintext, err := json.Marshal(payload)
	if err != nil {
		t.Fatal(err)
	}
	nonce := []byte("123456789012")
	ciphertext := p4WebSeal(t, shared, "request", p4WebAADBytes(aad), nonce, plaintext)
	return map[string]any{
		"alg": domain.WebReadEnvelopeAlgorithm, "payload_version": 1,
		"ephemeral_public_key": base64.RawStdEncoding.EncodeToString(clientPrivate.PublicKey().Bytes()),
		"nonce":                base64.RawStdEncoding.EncodeToString(nonce), "ciphertext": base64.RawStdEncoding.EncodeToString(ciphertext),
		"aad_hash": p4WebAADHash(p4WebAADBytes(aad)),
	}
}

func openP4WebResponse(t *testing.T, aad p4WebAAD, clientPrivate *ecdh.PrivateKey, terminalPublic *ecdh.PublicKey, envelope p4WebResponseEnvelope) []byte {
	t.Helper()
	if envelope.Alg != domain.WebReadEnvelopeAlgorithm || envelope.PayloadVersion != 1 || envelope.AADHash != p4WebAADHash(p4WebAADBytes(aad)) {
		t.Fatal("invalid response envelope")
	}
	shared, err := clientPrivate.ECDH(terminalPublic)
	if err != nil {
		t.Fatal(err)
	}
	nonce, err := base64.RawStdEncoding.DecodeString(envelope.Nonce)
	if err != nil {
		t.Fatal(err)
	}
	ciphertext, err := base64.RawStdEncoding.DecodeString(envelope.Ciphertext)
	if err != nil {
		t.Fatal(err)
	}
	return p4WebOpen(t, shared, "response", p4WebAADBytes(aad), nonce, ciphertext)
}

func p4WebSeal(t *testing.T, shared []byte, direction string, aad, nonce, plaintext []byte) []byte {
	t.Helper()
	key := p4WebKey(t, shared, direction)
	block, err := aes.NewCipher(key)
	if err != nil {
		t.Fatal(err)
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		t.Fatal(err)
	}
	return gcm.Seal(nil, nonce, plaintext, aad)
}

func p4WebOpen(t *testing.T, shared []byte, direction string, aad, nonce, ciphertext []byte) []byte {
	t.Helper()
	key := p4WebKey(t, shared, direction)
	block, err := aes.NewCipher(key)
	if err != nil {
		t.Fatal(err)
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		t.Fatal(err)
	}
	plaintext, err := gcm.Open(nil, nonce, ciphertext, aad)
	if err != nil {
		t.Fatal(err)
	}
	return plaintext
}

func p4WebKey(t *testing.T, shared []byte, direction string) []byte {
	t.Helper()
	key, err := hkdf.Key(sha256.New, shared, []byte("agent-sessions-web-read-v1"), direction, 32)
	if err != nil {
		t.Fatal(err)
	}
	return key
}

func p4WebAADHash(aad []byte) string {
	sum := sha256.Sum256(aad)
	return hex.EncodeToString(sum[:])
}
