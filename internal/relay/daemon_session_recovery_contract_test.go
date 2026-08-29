package relay

import (
	"encoding/json"
	"net/http"
	"testing"
	"time"

	"github.com/yubi233/agent-sessions/internal/domain"
	"github.com/yubi233/agent-sessions/internal/store"
)

// DAEMON-RPC-03：Daemon 进程启动清扫契约。只有已配对 Terminal 能声明「上一进程已
// 死亡」；Relay 收口只覆盖该 Terminal 的工作区——完成证据齐备 → idle，回合被打断或
// 带死亡 instance → stopped 并清空 instance；其他 Terminal 会话不受影响，重复调用
// 幂等，owner 设备不可调用。
func TestDaemonSessionRecoverySweep(t *testing.T) {
	env := newTestEnv(t)
	owner := env.registerAs(t, "daemon-recovery@test.dev")
	ctx := t.Context()

	closeStuck := func(t *testing.T, terminalID, name, lastEvent string, withInstance bool) string {
		t.Helper()
		sessionID, _ := env.createBoundSession(t, owner, terminalID, "daemon-recovery-"+name)
		if err := env.repo.SetSessionStatusAt(ctx, sessionID, domain.SessionRunning, time.Now().Add(-time.Hour).UnixMilli()); err != nil {
			t.Fatalf("mark running: %v", err)
		}
		if lastEvent != "" {
			if _, err := env.repo.AppendEvent(ctx, store.SessionEventRow{SessionID: sessionID, EventType: lastEvent, EnvelopeJSON: "{}"}); err != nil {
				t.Fatalf("append %s event: %v", lastEvent, err)
			}
		}
		if withInstance {
			if err := env.repo.SetSessionInstance(ctx, sessionID, "inst-dead-"+name); err != nil {
				t.Fatalf("set instance: %v", err)
			}
		}
		return sessionID
	}

	terminalA := env.pairTerminal(t, owner, "daemon-recovery-a")
	terminalAID := daemonHello(t, env, terminalA.AccessToken)
	terminalB := env.pairTerminal(t, owner, "daemon-recovery-b")
	terminalBID := daemonHello(t, env, terminalB.AccessToken)

	completedID := closeStuck(t, terminalAID, "completed", "message.completed", false)
	interruptedID := closeStuck(t, terminalAID, "interrupted", "user.message", false)
	liveInstanceID := closeStuck(t, terminalAID, "instance", "message.completed", true)
	otherTerminalID := closeStuck(t, terminalBID, "other", "message.completed", false)

	response := env.do(t, http.MethodPost, "/v1/daemon/sessions/recover", map[string]any{"protocol_version": 1}, terminalA.AccessToken)
	if response.Code != http.StatusOK {
		t.Fatalf("recover status=%d body=%s", response.Code, response.Body.String())
	}
	var summary struct {
		RecoveredIdle    int `json:"recovered_idle"`
		RecoveredStopped int `json:"recovered_stopped"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &summary); err != nil {
		t.Fatalf("decode summary: %v body=%s", err, response.Body.String())
	}
	if summary.RecoveredIdle != 1 || summary.RecoveredStopped != 2 {
		t.Fatalf("summary=%+v, want idle=1 stopped=2", summary)
	}
	wantStatus := map[string]string{
		completedID:     domain.SessionIdle,
		interruptedID:   domain.SessionStopped,
		liveInstanceID:  domain.SessionStopped,
		otherTerminalID: domain.SessionRunning,
	}
	for sessionID, want := range wantStatus {
		sess, err := env.repo.SessionByID(ctx, sessionID)
		if err != nil {
			t.Fatalf("read session: %v", err)
		}
		if sess.Status != want {
			t.Fatalf("session status=%q, want %q", sess.Status, want)
		}
		if sess.ArchivedAtUnixMS != 0 {
			t.Fatalf("session archived_at_unix_ms=%d, want 0 (never archive)", sess.ArchivedAtUnixMS)
		}
	}
	sess, err := env.repo.SessionByID(ctx, liveInstanceID)
	if err != nil {
		t.Fatalf("read instance session: %v", err)
	}
	if sess.CurrentInstanceID != "" {
		t.Fatalf("current_instance_id=%q, want cleared", sess.CurrentInstanceID)
	}

	// 幂等：已收口会话不再是 running，第二次调用必须空转。
	second := env.do(t, http.MethodPost, "/v1/daemon/sessions/recover", map[string]any{"protocol_version": 1}, terminalA.AccessToken)
	if second.Code != http.StatusOK {
		t.Fatalf("second recover status=%d body=%s", second.Code, second.Body.String())
	}
	var secondSummary struct {
		RecoveredIdle    int `json:"recovered_idle"`
		RecoveredStopped int `json:"recovered_stopped"`
	}
	if err := json.Unmarshal(second.Body.Bytes(), &secondSummary); err != nil {
		t.Fatalf("decode second summary: %v", err)
	}
	if secondSummary.RecoveredIdle+secondSummary.RecoveredStopped != 0 {
		t.Fatalf("second summary=%+v, want no-op", secondSummary)
	}

	// owner token 不是 Terminal，不能声明进程重启。
	if denied := env.do(t, http.MethodPost, "/v1/daemon/sessions/recover", map[string]any{"protocol_version": 1}, owner.AccessToken); denied.Code == http.StatusOK {
		t.Fatalf("owner token unexpectedly allowed to sweep: %s", denied.Body.String())
	}
}
