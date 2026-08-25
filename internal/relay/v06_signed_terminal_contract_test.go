package relay

import (
	"bytes"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/yubi233/agent-sessions/internal/authz"
	"github.com/yubi233/agent-sessions/internal/domain"
)

// v06SignedTerminal 是纵向签名回归的客户端侧 fixture：
// 持有 Terminal Ed25519 私钥，按 ADR-012 canonical bytes 对任意 POST 路径签名。
type v06SignedTerminal struct {
	priv     ed25519.PrivateKey
	deviceID string
	keyID    string
}

// sign 构造对指定路径与 body 的完整签名字段。nonce 必须由调用方提供：
// hello 使用 Relay 预签发的一次性 challenge，其余端点使用随机 nonce。
// body hash 覆盖未注入 signature 字段的原始字节，与 Relay 的剥离规则一致。
func (s *v06SignedTerminal) sign(t *testing.T, method, path string, body []byte, nonce string) authz.TerminalSignature {
	t.Helper()
	sig := authz.TerminalSignature{
		ProtocolVersion: 1,
		KeyID:           s.keyID,
		TimestampMS:     time.Now().UnixMilli(),
		Nonce:           nonce,
		BodyHash:        authz.HashBody(body),
	}
	signature, err := authz.SignTerminalRequest(s.priv, sig, s.deviceID, method, path)
	if err != nil {
		t.Fatalf("sign %s: %v", path, err)
	}
	sig.Signature = signature
	return sig
}

// postSigned 发送携带 v0.6 签名的 POST 请求，返回原始响应。
func (e *testEnv) postSigned(t *testing.T, terminal *v06SignedTerminal, token, path string, payload map[string]any, nonce string) *httptest.ResponseRecorder {
	t.Helper()
	raw, err := json.Marshal(payload)
	if err != nil {
		t.Fatalf("marshal payload: %v", err)
	}
	sig := terminal.sign(t, http.MethodPost, path, raw, nonce)
	var envelope map[string]json.RawMessage
	if err := json.Unmarshal(raw, &envelope); err != nil {
		t.Fatalf("unmarshal payload: %v", err)
	}
	encoded, err := json.Marshal(sig)
	if err != nil {
		t.Fatalf("marshal signature: %v", err)
	}
	envelope["signature"] = encoded
	return e.doRawJSON(t, http.MethodPost, path, envelope, token)
}

// doRawJSON 发送调用方构造好的 JSON body。
func (e *testEnv) doRawJSON(t *testing.T, method, path string, body any, token string) *httptest.ResponseRecorder {
	t.Helper()
	raw, err := json.Marshal(body)
	if err != nil {
		t.Fatalf("marshal body: %v", err)
	}
	req := httptest.NewRequest(method, path, bytes.NewReader(raw))
	req.Header.Set("Content-Type", "application/json")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	rec := httptest.NewRecorder()
	e.router.ServeHTTP(rec, req)
	return rec
}

// newV06SignedTerminal 通过配对流程创建带真实 Ed25519 身份公钥的 Terminal 设备并签发 bearer。
// identity_public_key 与签名私钥同源，模拟"配对时生成本机身份密钥"的生产形态（ADR-002/ADR-012）。
func (e *testEnv) newV06SignedTerminal(t *testing.T, owner authPair, name string) (*v06SignedTerminal, string) {
	t.Helper()
	seed := bytes.Repeat([]byte{0x61}, ed25519.SeedSize)
	priv := ed25519.NewKeyFromSeed(seed)
	pubEncoded := base64.RawURLEncoding.EncodeToString(priv.Public().(ed25519.PublicKey))

	pending := e.do(t, http.MethodPost, "/v1/pairing/requests", map[string]any{
		"role": "terminal", "display_name": name, "platform": "test",
		"identity_public_key": pubEncoded, "encryption_public_key": "ekk-" + name,
	}, owner.AccessToken)
	if pending.Code != http.StatusCreated {
		t.Fatalf("create signed terminal pairing status=%d body=%s", pending.Code, pending.Body.String())
	}
	var pairing struct {
		ID string `json:"id"`
	}
	decodeW1(t, pending.Body.Bytes(), &pairing)
	approved := e.do(t, http.MethodPost, "/v1/pairing/requests/"+pairing.ID+"/approve", nil, owner.AccessToken)
	if approved.Code != http.StatusOK {
		t.Fatalf("approve signed terminal pairing status=%d body=%s", approved.Code, approved.Body.String())
	}
	var device struct {
		ID string `json:"id"`
	}
	decodeW1(t, approved.Body.Bytes(), &device)
	tokens, err := domain.NewAuthService(e.repo).IssueForDevice(t.Context(), owner.AccountID, device.ID)
	if err != nil {
		t.Fatalf("issue signed terminal bearer: %v", err)
	}
	terminal := &v06SignedTerminal{priv: priv, deviceID: device.ID, keyID: device.ID}
	return terminal, tokens.AccessToken
}

// v06Challenge 获取一次性 hello challenge。
func (e *testEnv) v06Challenge(t *testing.T, token string) string {
	t.Helper()
	response := e.v06ChallengeRequest(t, token)
	if response.Code != http.StatusOK {
		t.Fatalf("challenge status=%d body=%s", response.Code, response.Body.String())
	}
	var payload struct {
		Challenge string `json:"challenge"`
	}
	decodeW1(t, response.Body.Bytes(), &payload)
	if payload.Challenge == "" {
		t.Fatalf("empty challenge: %s", response.Body.String())
	}
	return payload.Challenge
}

// v06ChallengeRequest 返回获取 challenge 的原始响应，供撤销场景断言非 200。
func (e *testEnv) v06ChallengeRequest(t *testing.T, token string) *httptest.ResponseRecorder {
	t.Helper()
	return e.do(t, http.MethodGet, "/v1/daemon/challenge", nil, token)
}

// TestV06SignedTerminalFullLoop 是 AUTH-05 的跨层回归：
// challenge → signed hello → signed heartbeat → 命令投递 → signed ack/result/event，
// 覆盖挑战重放拒绝、nonce 重放拒绝、篡改拒绝、幂等重试、公钥登记双读和撤销即时生效。
// 口径：local_test=true、fixture_data=true、real_browser=false、real_model=false、real_upstream=false、headless=false。
func TestV06SignedTerminalFullLoop(t *testing.T) {
	env := newTestEnv(t)
	owner := env.registerAs(t, "v06-signed@test.dev")
	terminal, token := env.newV06SignedTerminal(t, owner, "v06-signed-terminal")
	helloPayload := map[string]any{
		"protocol_version": 1, "daemon_version": "fixture-signed",
		"hostname": "v06-fixture", "platform": "test",
		"capabilities": []string{"start", "git_read"},
	}

	// 1) signed hello：nonce 必须是预签发的一次性 challenge；响应声明双轨 auth_modes。
	challenge := env.v06Challenge(t, token)
	helloResponse := env.postSigned(t, terminal, token, "/v1/daemon/hello", helloPayload, challenge)
	if helloResponse.Code != http.StatusOK {
		t.Fatalf("signed hello status=%d body=%s", helloResponse.Code, helloResponse.Body.String())
	}
	var hello struct {
		TerminalID         string   `json:"terminal_id"`
		ProtocolVersion    int      `json:"protocol_version"`
		HeartbeatInSeconds int      `json:"heartbeat_interval_seconds"`
		AuthModes          []string `json:"auth_modes"`
	}
	decodeW1(t, helloResponse.Body.Bytes(), &hello)
	if hello.TerminalID == "" || hello.ProtocolVersion != 1 || hello.HeartbeatInSeconds <= 0 {
		t.Fatalf("signed hello projection incomplete: %+v", hello)
	}
	hasBearer, hasSignatureV1 := false, false
	for _, mode := range hello.AuthModes {
		switch mode {
		case "bearer":
			hasBearer = true
		case "signature_v1":
			hasSignatureV1 = true
		}
	}
	if !hasBearer || !hasSignatureV1 {
		t.Fatalf("optional window must advertise both auth modes: %v", hello.AuthModes)
	}

	// 2) 同一挑战重放必须被拒：hello 已消费 challenge，重复请求返回 NONCE_REUSED。
	replay := env.postSigned(t, terminal, token, "/v1/daemon/hello", helloPayload, challenge)
	if !strings.Contains(replay.Body.String(), "NONCE_REUSED") {
		t.Fatalf("challenge replay must be NONCE_REUSED: %d %s", replay.Code, replay.Body.String())
	}

	// 3) signed heartbeat：随机 nonce 成功后，同 nonce 重放被拒。
	hbPath := "/v1/daemon/heartbeat"
	hbPayload := map[string]any{"protocol_version": 1}
	if hb := env.postSigned(t, terminal, token, hbPath, hbPayload, "v06-hb-nonce-1"); hb.Code != http.StatusOK {
		t.Fatalf("signed heartbeat status=%d body=%s", hb.Code, hb.Body.String())
	}
	hbReplay := env.postSigned(t, terminal, token, hbPath, hbPayload, "v06-hb-nonce-1")
	if !strings.Contains(hbReplay.Body.String(), "NONCE_REUSED") {
		t.Fatalf("heartbeat nonce replay must fail: %d %s", hbReplay.Code, hbReplay.Body.String())
	}

	// 4) owner 提交命令，Terminal 用 bearer SSE 接收（SSE 只读投递不在签名面内）。
	terminalID := hello.TerminalID
	sessionID, _ := env.createBoundSession(t, owner, terminalID, "v06-signed-project")
	epoch := p2SessionLeaseEpoch(t, env, owner.AccessToken, sessionID)
	command := env.do(t, http.MethodPost, "/v1/sessions/"+sessionID+"/commands", map[string]any{
		"kind": "session.start", "idempotency_key": "v06-signed-1", "lease_epoch": epoch,
		"target_terminal_id": terminalID,
		"ciphertext": map[string]any{
			"kind": "session.start", "session_id": sessionID,
			"ciphertext": map[string]any{"fixture_payload": map[string]any{"provider": "fixture"}},
		},
	}, owner.AccessToken)
	if command.Code != http.StatusAccepted {
		t.Fatalf("submit signed-loop command status=%d body=%s", command.Code, command.Body.String())
	}
	var submitted struct {
		ID string `json:"id"`
	}
	decodeW1(t, command.Body.Bytes(), &submitted)
	streamBody := streamDaemonOnce(t, env, token, 0)
	if !strings.Contains(streamBody, submitted.ID) || !strings.Contains(streamBody, "id: 1") {
		t.Fatalf("signed loop stream missing delivery: %s", streamBody)
	}

	// 5) signed ack：received → started；同 nonce 重放拒绝；换 nonce 幂等重试返回既有状态。
	ackPath := "/v1/daemon/commands/" + submitted.ID + "/ack"
	ackPayload := func(kind string) map[string]any {
		return map[string]any{"protocol_version": 1, "delivery_seq": int64(1), "ack_kind": kind, "error_code": ""}
	}
	if ack := env.postSigned(t, terminal, token, ackPath, ackPayload("received"), "v06-ack-received-1"); ack.Code != http.StatusOK {
		t.Fatalf("signed received ack status=%d body=%s", ack.Code, ack.Body.String())
	}
	if ack := env.postSigned(t, terminal, token, ackPath, ackPayload("started"), "v06-ack-started-1"); ack.Code != http.StatusOK {
		t.Fatalf("signed started ack status=%d body=%s", ack.Code, ack.Body.String())
	}
	startedReplay := env.postSigned(t, terminal, token, ackPath, ackPayload("started"), "v06-ack-started-1")
	if !strings.Contains(startedReplay.Body.String(), "NONCE_REUSED") {
		t.Fatalf("acked nonce replay must fail: %d %s", startedReplay.Code, startedReplay.Body.String())
	}
	idempotentAck := env.postSigned(t, terminal, token, ackPath, ackPayload("started"), "v06-ack-started-2")
	if idempotentAck.Code != http.StatusOK {
		t.Fatalf("idempotent retry with fresh nonce status=%d body=%s", idempotentAck.Code, idempotentAck.Body.String())
	}

	// 6) 篡改 body hash 必须拒绝：签名对应的不是实际请求体。
	eventPath := "/v1/daemon/events"
	eventPayload := map[string]any{
		"protocol_version": 1, "event_id": "evt-v06-tampered", "command_id": submitted.ID,
		"session_id": sessionID, "event_type": "turn.started",
		"envelope": opaqueFixtureEnvelope("v06-tampered"),
	}
	rawEvent, _ := json.Marshal(eventPayload)
	badSig := terminal.sign(t, http.MethodPost, eventPath, []byte(`{"different":"body"}`), "v06-tampered-nonce-1")
	var tamperedEnvelope map[string]json.RawMessage
	_ = json.Unmarshal(rawEvent, &tamperedEnvelope)
	badSigEncoded, _ := json.Marshal(badSig)
	tamperedEnvelope["signature"] = badSigEncoded
	tamperedResponse := env.doRawJSON(t, http.MethodPost, eventPath, tamperedEnvelope, token)
	if !strings.Contains(tamperedResponse.Body.String(), "SIGNATURE_INVALID") {
		t.Fatalf("body hash mismatch must be SIGNATURE_INVALID: %d %s", tamperedResponse.Code, tamperedResponse.Body.String())
	}

	// 7) signed event 上传成功；重复 event_id（新 nonce）返回幂等 receipt，不重复追加事件。
	validEventPayload := map[string]any{
		"protocol_version": 1, "event_id": "evt-v06-1", "command_id": submitted.ID,
		"session_id": sessionID, "event_type": "turn.started",
		"envelope": opaqueFixtureEnvelope("v06-opaque-event"),
	}
	if event := env.postSigned(t, terminal, token, eventPath, validEventPayload, "v06-event-1"); event.Code != http.StatusOK {
		t.Fatalf("signed event upload status=%d body=%s", event.Code, event.Body.String())
	}
	duplicateEvent := env.postSigned(t, terminal, token, eventPath, validEventPayload, "v06-event-2")
	if duplicateEvent.Code != http.StatusOK || !strings.Contains(duplicateEvent.Body.String(), `"idempotent":true`) {
		t.Fatalf("duplicate event_id must be idempotent: %d %s", duplicateEvent.Code, duplicateEvent.Body.String())
	}

	// 8) signed result 收口命令，receipt 投影稳定终态。
	resultPath := "/v1/daemon/commands/" + submitted.ID + "/result"
	resultPayload := map[string]any{"protocol_version": 1, "delivery_seq": int64(1), "status": "succeeded", "error_code": ""}
	if result := env.postSigned(t, terminal, token, resultPath, resultPayload, "v06-result-1"); result.Code != http.StatusOK {
		t.Fatalf("signed result status=%d body=%s", result.Code, result.Body.String())
	} else if !strings.Contains(result.Body.String(), `"status":"succeeded"`) {
		t.Fatalf("result receipt incomplete: %s", result.Body.String())
	}

	// 9) 公钥登记 + 轮换双读：owner 登记第二把 Ed25519 key 后，
	// 新 key 签名立即可用（双读）；Terminal 自己不能登记密钥（owner 边界）。
	rotatePriv := ed25519.NewKeyFromSeed(bytes.Repeat([]byte{0x62}, ed25519.SeedSize))
	registerKey := env.do(t, http.MethodPost, "/v1/devices/"+terminal.deviceID+"/identity-keys", map[string]any{
		"identity_public_key": base64.RawURLEncoding.EncodeToString(rotatePriv.Public().(ed25519.PublicKey)),
	}, owner.AccessToken)
	if registerKey.Code != http.StatusCreated {
		t.Fatalf("register identity key status=%d body=%s", registerKey.Code, registerKey.Body.String())
	}
	var registered struct {
		KeyID   string `json:"key_id"`
		Status  string `json:"status"`
		Device  string `json:"device_id"`
		Retired int64  `json:"retired_at_unix_ms"`
	}
	decodeW1(t, registerKey.Body.Bytes(), &registered)
	if registered.KeyID == "" || registered.Status != "active" || registered.Device != terminal.deviceID {
		t.Fatalf("registered key projection incomplete: %+v", registered)
	}
	rotatedTerminal := &v06SignedTerminal{priv: rotatePriv, deviceID: terminal.deviceID, keyID: registered.KeyID}
	if hb := env.postSigned(t, rotatedTerminal, token, hbPath, hbPayload, "v06-hb-newkey-1"); hb.Code != http.StatusOK {
		t.Fatalf("registered key dual-read signature rejected: %d %s", hb.Code, hb.Body.String())
	}
	selfRegister := env.do(t, http.MethodPost, "/v1/devices/"+terminal.deviceID+"/identity-keys", map[string]any{
		"identity_public_key": base64.RawURLEncoding.EncodeToString(ed25519.NewKeyFromSeed(bytes.Repeat([]byte{0x63}, ed25519.SeedSize)).Public().(ed25519.PublicKey)),
	}, token)
	if selfRegister.Code != http.StatusForbidden {
		t.Fatalf("terminal self-registration status=%d want 403 body=%s", selfRegister.Code, selfRegister.Body.String())
	}

	// 10) owner 立即撤销登记密钥：新 key 签名随即 fail-closed（KEY_UNKNOWN_OR_REVOKED）。
	if revoke := env.do(t, http.MethodDelete, "/v1/devices/"+terminal.deviceID+"/identity-keys/"+registered.KeyID, nil, owner.AccessToken); revoke.Code != http.StatusNoContent {
		t.Fatalf("revoke identity key status=%d body=%s", revoke.Code, revoke.Body.String())
	}
	if hb := env.postSigned(t, rotatedTerminal, token, hbPath, hbPayload, "v06-hb-revoked-key-1"); strings.Contains(hb.Body.String(), `"code":"OK"`) || hb.Code == http.StatusOK {
		t.Fatalf("revoked identity key must be rejected: %d %s", hb.Code, hb.Body.String())
	} else if !strings.Contains(hb.Body.String(), "KEY_UNKNOWN_OR_REVOKED") {
		t.Fatalf("revoked key code mismatch: %d %s", hb.Code, hb.Body.String())
	}
}

// TestV06RequiredModeRejectsLegacyBearer 验证 N/N-1 窗口结束后的发布形态：
// required 模式下旧 bearer Daemon 的签名端点一律 426 UPGRADE_REQUIRED，合法签名仍可用。
func TestV06RequiredModeRejectsLegacyBearer(t *testing.T) {
	env := newTestEnvWithSignatureRequired(t)
	owner := env.registerAs(t, "v06-required@test.dev")
	terminal, token := env.newV06SignedTerminal(t, owner, "v06-required-terminal")

	legacyHello := env.do(t, http.MethodPost, "/v1/daemon/hello", map[string]any{
		"protocol_version": 1, "daemon_version": "legacy-bearer", "hostname": "legacy", "platform": "test",
		"capabilities": []string{"start"},
	}, token)
	if legacyHello.Code != http.StatusUpgradeRequired {
		t.Fatalf("legacy bearer in required mode status=%d want 426 body=%s", legacyHello.Code, legacyHello.Body.String())
	}
	if !strings.Contains(legacyHello.Body.String(), "UPGRADE_REQUIRED") {
		t.Fatalf("required rejection must use stable UPGRADE_REQUIRED code: %s", legacyHello.Body.String())
	}
	if legacyHeartbeat := env.do(t, http.MethodPost, "/v1/daemon/heartbeat", map[string]any{"protocol_version": 1}, token); legacyHeartbeat.Code != http.StatusUpgradeRequired {
		t.Fatalf("legacy heartbeat status=%d want 426", legacyHeartbeat.Code)
	}
	// required 模式下 usage 上传同样不再接受旧 bearer。
	usagePayload := map[string]any{
		"usage_key": "v06-required-usage", "provider": "fixture", "utc_day": "2026-08-25",
		"input_tokens": int64(1), "output_tokens": int64(2),
	}
	if usage := env.do(t, http.MethodPost, "/v1/daemon/usage/events", usagePayload, token); usage.Code != http.StatusUpgradeRequired {
		t.Fatalf("legacy usage upload status=%d want 426 body=%s", usage.Code, usage.Body.String())
	}

	// required 模式下 signed hello 正常工作，且只声明 signature_v1。
	challenge := env.v06Challenge(t, token)
	signedHello := env.postSigned(t, terminal, token, "/v1/daemon/hello", map[string]any{
		"protocol_version": 1, "daemon_version": "fixture-required", "hostname": "required", "platform": "test",
		"capabilities": []string{"start"},
	}, challenge)
	if signedHello.Code != http.StatusOK {
		t.Fatalf("required-mode signed hello status=%d body=%s", signedHello.Code, signedHello.Body.String())
	}
	if !strings.Contains(signedHello.Body.String(), `"auth_modes":["signature_v1"]`) {
		t.Fatalf("required mode must advertise only signature_v1: %s", signedHello.Body.String())
	}
}

// newTestEnvWithSignatureRequired 以 required 签名模式装配隔离 Relay fixture。
func newTestEnvWithSignatureRequired(t *testing.T) *testEnv {
	t.Helper()
	env := newTestEnv(t)
	env.router = NewServerWithTerminalSignatureRequired(env.db, nil)
	return env
}

// TestV06SignedTerminalRevocationFailClosed 验证设备撤销即时生效：
// 撤销后的 Terminal 即使持有效 bearer 也无法继续获取 challenge 或调用任何 Terminal 端点。
func TestV06SignedTerminalRevocationFailClosed(t *testing.T) {
	env := newTestEnv(t)
	owner := env.registerAs(t, "v06-revoke@test.dev")
	terminal, token := env.newV06SignedTerminal(t, owner, "v06-revoke-terminal")

	challenge := env.v06Challenge(t, token)
	helloBody := map[string]any{
		"protocol_version": 1, "daemon_version": "fixture-revoke", "hostname": "revoke", "platform": "test",
		"capabilities": []string{"start"},
	}
	if hello := env.postSigned(t, terminal, token, "/v1/daemon/hello", helloBody, challenge); hello.Code != http.StatusOK {
		t.Fatalf("pre-revoke signed hello status=%d body=%s", hello.Code, hello.Body.String())
	}

	// owner 撤销设备后，challenge 立即不可获取。
	if revoke := env.do(t, http.MethodDelete, "/v1/devices/"+terminal.deviceID, nil, owner.AccessToken); revoke.Code != http.StatusNoContent {
		t.Fatalf("revoke device status=%d body=%s", revoke.Code, revoke.Body.String())
	}
	next := env.v06ChallengeRequest(t, token)
	if next.Code == http.StatusOK {
		t.Fatalf("revoked terminal must not obtain challenge: %s", next.Body.String())
	}
	if !strings.Contains(next.Body.String(), "DEVICE_REVOKED") && next.Code != http.StatusUnauthorized {
		t.Fatalf("revoked challenge response unexpected: %d %s", next.Code, next.Body.String())
	}
}
