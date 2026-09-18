package relay

import (
	"net/http"
	"strings"
	"testing"
)

// 本地开发/fixture 路径下，session.model_select 被 Relay 受理后必须同步到会话元数据，
// 否则 App 里“已切换模型”只停留在乐观更新，重新拉取会话/controls 仍显示旧模型。
func TestModelSelectUpdatesRelaySessionModel(t *testing.T) {
	env := newTestEnv(t)
	owner := env.registerAs(t, "model-display@test.dev")
	terminal := env.pairTerminal(t, owner, "model-display-terminal")
	terminalID := daemonHello(t, env, terminal.AccessToken)
	sessionID, _ := env.createBoundSession(t, owner, terminalID, "model-display")
	epoch := p2SessionLeaseEpoch(t, env, owner.AccessToken, sessionID)

	submit := env.do(t, http.MethodPost, "/v1/sessions/"+sessionID+"/commands", map[string]any{
		"kind":            "session.model_select",
		"idempotency_key": "model-switch-1",
		"lease_epoch":     epoch,
		"ciphertext": map[string]any{
			"session_id": sessionID,
			"ciphertext": map[string]any{
				"fixture_payload": map[string]any{"model": "opencode/mimo-v2.5-free"},
			},
		},
	}, owner.AccessToken)
	if submit.Code != http.StatusAccepted {
		t.Fatalf("model_select status=%d body=%s", submit.Code, submit.Body.String())
	}
	var submitted struct {
		ID string `json:"id"`
	}
	decodeW1(t, submit.Body.Bytes(), &submitted)
	if submitted.ID == "" {
		t.Fatalf("command projection missing id")
	}

	// V094-24：受理阶段不得把请求值冒充生效值——controls 仍显示旧（权威）模型。
	controlsBefore := env.do(t, http.MethodGet, "/v1/sessions/"+sessionID+"/controls", nil, owner.AccessToken)
	if controlsBefore.Code != http.StatusOK {
		t.Fatalf("controls before result status=%d", controlsBefore.Code)
	}
	if strings.Contains(controlsBefore.Body.String(), "opencode/mimo-v2.5-free") {
		t.Fatalf("受理阶段 controls 泄漏请求值冒充生效值: %s", controlsBefore.Body.String())
	}

	// Daemon 生命周期：投递 → received/started ack → result succeeded。
	streamBody := streamDaemonOnce(t, env, terminal.AccessToken, 0)
	if !strings.Contains(streamBody, submitted.ID) {
		t.Fatalf("daemon stream missing delivery: %s", streamBody)
	}
	for _, kind := range []string{"received", "started"} {
		ack := env.do(t, http.MethodPost, "/v1/daemon/commands/"+submitted.ID+"/ack", map[string]any{
			"protocol_version": 1, "delivery_seq": 1, "ack_kind": kind,
		}, terminal.AccessToken)
		if ack.Code != http.StatusOK {
			t.Fatalf("ack %s status=%d body=%s", kind, ack.Code, ack.Body.String())
		}
	}
	result := env.do(t, http.MethodPost, "/v1/daemon/commands/"+submitted.ID+"/result", map[string]any{
		"protocol_version": 1, "delivery_seq": 1, "status": "succeeded",
	}, terminal.AccessToken)
	if result.Code != http.StatusOK {
		t.Fatalf("result status=%d body=%s", result.Code, result.Body.String())
	}

	// 执行端确认成功后，权威投影才更新模型（V094-24 冻结契约）。
	controls := env.do(t, http.MethodGet, "/v1/sessions/"+sessionID+"/controls", nil, owner.AccessToken)
	if controls.Code != http.StatusOK {
		t.Fatalf("controls status=%d body=%s", controls.Code, controls.Body.String())
	}
	var body struct {
		Model string `json:"model"`
	}
	decodeW1(t, controls.Body.Bytes(), &body)
	if body.Model != "opencode/mimo-v2.5-free" {
		t.Fatalf("controls model = %q, want opencode/mimo-v2.5-free", body.Model)
	}

	list := env.do(t, http.MethodGet, "/v1/sessions", nil, owner.AccessToken)
	if list.Code != http.StatusOK {
		t.Fatalf("sessions status=%d body=%s", list.Code, list.Body.String())
	}
	var sessions struct {
		Items []struct {
			ID    string `json:"id"`
			Model string `json:"model"`
		} `json:"sessions"`
	}
	decodeW1(t, list.Body.Bytes(), &sessions)
	found := false
	for _, item := range sessions.Items {
		if item.ID == sessionID {
			found = true
			if item.Model != "opencode/mimo-v2.5-free" {
				t.Fatalf("session model = %q, want opencode/mimo-v2.5-free", item.Model)
			}
		}
	}
	if !found {
		t.Fatalf("session %q not found in list", sessionID)
	}
}
