package relay

import (
	"encoding/json"
	"net/http"
	"testing"

	"github.com/yubi233/agent-sessions/internal/domain"
)

// DAEMON-RPC-02：Terminal 上传 turn.completed 时，Relay 必须消费非敏感
// terminal_status 投影；正常 idle 与异常 stopped 不能在 HTTP 边界混淆。
func TestDaemonEventUploadProjectsTerminalStatus(t *testing.T) {
	env := newTestEnv(t)
	owner := env.registerAs(t, "daemon-terminal-status@test.dev")

	for _, tc := range []struct {
		name           string
		terminalStatus string
		wantStatus     string
	}{
		{name: "idle", terminalStatus: domain.SessionIdle, wantStatus: domain.SessionIdle},
		{name: "stopped", terminalStatus: domain.SessionStopped, wantStatus: domain.SessionStopped},
	} {
		t.Run(tc.name, func(t *testing.T) {
			terminal := env.pairTerminal(t, owner, "daemon-terminal-status-terminal-"+tc.name)
			terminalID := daemonHello(t, env, terminal.AccessToken)
			sessionID, _ := env.createBoundSession(t, owner, terminalID, "daemon-terminal-status-"+tc.name)
			epoch := p2SessionLeaseEpoch(t, env, owner.AccessToken, sessionID)
			commandResponse := env.do(t, http.MethodPost, "/v1/sessions/"+sessionID+"/commands", map[string]any{
				"kind": "session.start", "idempotency_key": "terminal-status-" + tc.name,
				"lease_epoch": epoch, "target_terminal_id": terminalID,
				"ciphertext": map[string]any{"kind": "session.start", "session_id": sessionID},
			}, owner.AccessToken)
			if commandResponse.Code != http.StatusAccepted {
				t.Fatalf("submit command status=%d body=%s", commandResponse.Code, commandResponse.Body.String())
			}
			var command struct{ ID string }
			if err := json.Unmarshal(commandResponse.Body.Bytes(), &command); err != nil || command.ID == "" {
				t.Fatalf("decode command=%+v err=%v body=%s", command, err, commandResponse.Body.String())
			}
			ack := env.do(t, http.MethodPost, "/v1/daemon/commands/"+command.ID+"/ack", map[string]any{
				"protocol_version": 1, "delivery_seq": 1, "ack_kind": "started",
			}, terminal.AccessToken)
			if ack.Code != http.StatusOK {
				t.Fatalf("started ack status=%d body=%s", ack.Code, ack.Body.String())
			}
			event := env.do(t, http.MethodPost, "/v1/daemon/events", map[string]any{
				"protocol_version": 1, "event_id": "terminal-status-event-" + tc.name,
				"command_id": command.ID, "session_id": sessionID, "event_type": "turn.completed",
				"terminal_status": tc.terminalStatus, "envelope": opaqueFixtureEnvelope("terminal-status-" + tc.name),
			}, terminal.AccessToken)
			if event.Code != http.StatusOK {
				t.Fatalf("upload event status=%d body=%s", event.Code, event.Body.String())
			}
			session, err := env.repo.SessionByID(t.Context(), sessionID)
			if err != nil {
				t.Fatalf("read session: %v", err)
			}
			if session.Status != tc.wantStatus {
				t.Fatalf("session status=%q, want %q", session.Status, tc.wantStatus)
			}
			events, err := env.repo.ListEventsAfter(t.Context(), sessionID, 0)
			if err != nil || len(events) != 2 || events[len(events)-1].TerminalStatus != tc.terminalStatus {
				t.Fatalf("stored terminal projection events=%+v err=%v, want %q", events, err, tc.terminalStatus)
			}
			observation := env.do(t, http.MethodGet, "/v1/sessions/"+sessionID+"/commands", nil, owner.AccessToken)
			if observation.Code != http.StatusOK {
				t.Fatalf("observation status=%d body=%s", observation.Code, observation.Body.String())
			}
			var view struct {
				Events []struct {
					EventType      string `json:"event_type"`
					TerminalStatus string `json:"terminal_status"`
				} `json:"events"`
			}
			decodeW1(t, observation.Body.Bytes(), &view)
			if len(view.Events) != 2 || view.Events[1].EventType != "turn.completed" || view.Events[1].TerminalStatus != tc.terminalStatus {
				t.Fatalf("observation terminal projection=%+v, want %q", view.Events, tc.terminalStatus)
			}
		})
	}
}

// terminal_status 只能附着于 turn.completed，且只能取 idle/stopped；HTTP
// handler 必须在签名/持久化前拒绝其它组合。
func TestDaemonEventUploadRejectsInvalidTerminalStatus(t *testing.T) {
	env := newTestEnv(t)
	owner := env.registerAs(t, "daemon-terminal-status-invalid@test.dev")
	terminal := env.pairTerminal(t, owner, "daemon-terminal-status-invalid-terminal")
	terminalID := daemonHello(t, env, terminal.AccessToken)
	sessionID, _ := env.createBoundSession(t, owner, terminalID, "daemon-terminal-status-invalid")
	epoch := p2SessionLeaseEpoch(t, env, owner.AccessToken, sessionID)
	commandResponse := env.do(t, http.MethodPost, "/v1/sessions/"+sessionID+"/commands", map[string]any{
		"kind": "session.start", "idempotency_key": "terminal-status-invalid",
		"lease_epoch": epoch, "target_terminal_id": terminalID,
		"ciphertext": map[string]any{"kind": "session.start", "session_id": sessionID},
	}, owner.AccessToken)
	if commandResponse.Code != http.StatusAccepted {
		t.Fatalf("submit command status=%d body=%s", commandResponse.Code, commandResponse.Body.String())
	}
	var command struct{ ID string }
	if err := json.Unmarshal(commandResponse.Body.Bytes(), &command); err != nil || command.ID == "" {
		t.Fatalf("decode command=%+v err=%v", command, err)
	}
	ack := env.do(t, http.MethodPost, "/v1/daemon/commands/"+command.ID+"/ack", map[string]any{
		"protocol_version": 1, "delivery_seq": 1, "ack_kind": "started",
	}, terminal.AccessToken)
	if ack.Code != http.StatusOK {
		t.Fatalf("started ack status=%d body=%s", ack.Code, ack.Body.String())
	}
	for _, tc := range []struct {
		name      string
		eventType string
		status    string
	}{
		{name: "unknown status", eventType: "turn.completed", status: "running"},
		{name: "nonterminal event", eventType: "message.completed", status: domain.SessionStopped},
	} {
		t.Run(tc.name, func(t *testing.T) {
			response := env.do(t, http.MethodPost, "/v1/daemon/events", map[string]any{
				"protocol_version": 1, "event_id": "terminal-status-invalid-" + tc.name,
				"command_id": command.ID, "session_id": sessionID, "event_type": tc.eventType,
				"terminal_status": tc.status, "envelope": opaqueFixtureEnvelope("invalid-" + tc.name),
			}, terminal.AccessToken)
			if response.Code != http.StatusBadRequest {
				t.Fatalf("invalid terminal status response=%d body=%s", response.Code, response.Body.String())
			}
		})
	}
}
