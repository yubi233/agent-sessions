package relay

import (
	"net/http"
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
