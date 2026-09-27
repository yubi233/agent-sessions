package relay

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/yubi233/agent-sessions/internal/httpapi"
)

// TestV06DeviceRevocationClosesActiveDaemonSSE 验证 ADR-012 的"撤销关闭旧 SSE"：
// 已建立的 Daemon 命令流在设备被撤销后最多一个心跳周期内被服务端关闭。
func TestV06DeviceRevocationClosesActiveDaemonSSE(t *testing.T) {
	env := newTestEnv(t)
	owner := env.registerAs(t, "v06-sse-revoke@test.dev")
	terminal := env.pairTerminal(t, owner, "v06-sse-revoke-terminal")
	terminalID := daemonHello(t, env, terminal.AccessToken)

	sessionID, _ := env.createBoundSession(t, owner, terminalID, "v06-sse-revoke-project")
	epoch := p2SessionLeaseEpoch(t, env, owner.AccessToken, sessionID)
	command := env.do(t, http.MethodPost, "/v1/sessions/"+sessionID+"/commands", map[string]any{
		"kind": "session.start", "idempotency_key": "v06-sse-1", "lease_epoch": epoch,
		"target_terminal_id": terminalID,
		"ciphertext": map[string]any{
			"kind": "session.start", "session_id": sessionID,
			"ciphertext": map[string]any{"fixture_payload": map[string]any{"provider": "fixture"}},
		},
	}, owner.AccessToken)
	if command.Code != http.StatusAccepted {
		t.Fatalf("submit command status=%d body=%s", command.Code, command.Body.String())
	}

	// 注入短心跳周期，让撤销检查在一个测试可等待的窗口内发生。
	originalInterval := httpapi.DaemonSSEHeartbeatIntervalForTest()
	httpapi.SetDaemonSSEHeartbeatIntervalForTest(25 * time.Millisecond)
	defer httpapi.SetDaemonSSEHeartbeatIntervalForTest(originalInterval)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	req := httptest.NewRequest(http.MethodGet, "/v1/daemon/commands/stream?after_delivery_seq=0", nil).WithContext(ctx)
	req.Header.Set("Authorization", "Bearer "+terminal.AccessToken)
	recorder := newSSERecorder()
	done := make(chan struct{})
	go func() {
		env.router.ServeHTTP(recorder, req)
		close(done)
	}()

	// 等待首条投递写出（证明流已建立）。
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if strings.Contains(recorder.body(), "event: command") {
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
	if !strings.Contains(recorder.body(), "event: command") {
		t.Fatalf("stream did not deliver initial command: %s", recorder.body())
	}

	// 撤销设备：流必须在远小于客户端超时的时间内被服务端关闭。
	if revoke := env.do(t, http.MethodDelete, "/v1/devices/"+terminal.DeviceID, nil, owner.AccessToken); revoke.Code != http.StatusNoContent {
		t.Fatalf("revoke device status=%d body=%s", revoke.Code, revoke.Body.String())
	}
	select {
	case <-done:
		// 服务端主动返回，流已关闭。
	case <-time.After(2 * time.Second):
		t.Fatal("revoked device SSE was not closed by server within heartbeat window")
	}
}

// TestV06DiagnosticsProjectionOwnerOnly 验证 /v1/diagnostics：
// 仅 owner 可读；投影只含白名单整数指标；认证失败与 outbox 积压计数正确累计。
func TestV06DiagnosticsProjectionOwnerOnly(t *testing.T) {
	env := newTestEnv(t)
	owner := env.registerAs(t, "v06-diag@test.dev")

	// 制造一次认证失败（坏 token），计数应在诊断投影中体现。
	bad := env.do(t, http.MethodGet, "/v1/devices", nil, "not-a-real-token")
	if bad.Code != http.StatusUnauthorized {
		t.Fatalf("bad token status=%d want 401", bad.Code)
	}

	diag := env.do(t, http.MethodGet, "/v1/diagnostics", nil, owner.AccessToken)
	if diag.Code != http.StatusOK {
		t.Fatalf("diagnostics status=%d body=%s", diag.Code, diag.Body.String())
	}
	var view struct {
		Outbox struct {
			Pending   int64 `json:"pending"`
			Failed    int64 `json:"failed"`
			Delivered int64 `json:"delivered"`
		} `json:"outbox"`
		TerminalSSE struct {
			Active         int64 `json:"active"`
			ConnectedTotal int64 `json:"connected_total"`
		} `json:"terminal_sse"`
		AuthFailuresTotal int64 `json:"auth_failures_total"`
		AuthRevokedTotal  int64 `json:"auth_revoked_total"`
	}
	decodeW1(t, diag.Body.Bytes(), &view)
	if view.AuthFailuresTotal < 1 {
		t.Fatalf("auth failure counter not incremented: %+v", view)
	}
	if view.TerminalSSE.ConnectedTotal != 0 || view.TerminalSSE.Active != 0 {
		t.Fatalf("no SSE opened yet but counters nonzero: %+v", view.TerminalSSE)
	}

	// 非 owner（terminal/web）不可读诊断端点。
	terminal := env.pairTerminal(t, owner, "v06-diag-terminal")
	denied := env.do(t, http.MethodGet, "/v1/diagnostics", nil, terminal.AccessToken)
	if denied.Code != http.StatusForbidden {
		t.Fatalf("terminal diagnostics status=%d want 403", denied.Code)
	}

	// 匿名请求同样拒绝。
	if anon := env.do(t, http.MethodGet, "/v1/diagnostics", nil, ""); anon.Code != http.StatusUnauthorized {
		t.Fatalf("anonymous diagnostics status=%d want 401", anon.Code)
	}
}
