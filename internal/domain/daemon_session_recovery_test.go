package domain

import (
	"context"
	"testing"
	"time"

	"github.com/yubi233/agent-sessions/internal/store"
)

// Daemon 进程启动清扫（POST /v1/daemon/sessions/recover）的根因回归。ground truth
// 来自新进程的「上一进程已死亡」声明，因此新鲜 Terminal 心跳不得阻止收口；但命令
// 终态与最后事件证据仍然缺一不可，且收口绝不 archive。
func TestRecoverStaleSessionsForTerminal(t *testing.T) {
	ctx := context.Background()
	now := time.UnixMilli(2_000_000_000_000)

	setup := func(t *testing.T) (store.Repository, *SessionService) {
		t.Helper()
		repo := newRepo(t)
		if err := repo.CreateAccount(ctx, "acct", "recovery@test.dev", []byte("h"), time.Now()); err != nil {
			t.Fatalf("create account: %v", err)
		}
		if err := repo.CreateProject(ctx, store.ProjectRow{ID: "proj", AccountID: "acct", Fingerprint: "fp-recovery"}); err != nil {
			t.Fatalf("create project: %v", err)
		}
		for _, terminalID := range []string{"term-a", "term-b"} {
			if err := repo.CreateDevice(ctx, store.DeviceRow{ID: "dev-" + terminalID, AccountID: "acct", Role: "terminal", Status: "online", DisplayName: terminalID}); err != nil {
				t.Fatalf("create device: %v", err)
			}
			if err := repo.CreateTerminal(ctx, store.TerminalRow{ID: terminalID, DeviceID: "dev-" + terminalID, AccountID: "acct", Status: "online"}); err != nil {
				t.Fatalf("create terminal: %v", err)
			}
			// 心跳刻意保持新鲜：启动清扫不依赖心跳失联。
			if err := repo.TouchTerminal(ctx, terminalID, now.UnixMilli()); err != nil {
				t.Fatalf("touch terminal: %v", err)
			}
			if err := repo.CreateWorkspace(ctx, store.WorkspaceRow{ID: "ws-" + terminalID, ProjectID: "proj", TerminalID: terminalID, CanonicalRoot: "/ws-" + terminalID, Status: "active"}); err != nil {
				t.Fatalf("create workspace: %v", err)
			}
		}
		svc := NewSessionService(repo)
		svc.now = func() time.Time { return now }
		return repo, svc
	}

	newRunningSession := func(t *testing.T, repo store.Repository, svc *SessionService, workspaceID string) string {
		t.Helper()
		sess, err := svc.CreateSession(ctx, "acct", workspaceID, "mock")
		if err != nil {
			t.Fatalf("create session: %v", err)
		}
		if err := repo.SetSessionStatusAt(ctx, sess.ID, SessionRunning, now.Add(-time.Hour).UnixMilli()); err != nil {
			t.Fatalf("mark running: %v", err)
		}
		return sess.ID
	}

	appendEvent := func(t *testing.T, repo store.Repository, sessionID, eventType string) {
		t.Helper()
		if _, err := repo.AppendEvent(ctx, store.SessionEventRow{SessionID: sessionID, EventType: eventType, EnvelopeJSON: "{}"}); err != nil {
			t.Fatalf("append %s event: %v", eventType, err)
		}
	}

	finishCommand := func(t *testing.T, repo store.Repository, sessionID, id, status string) {
		t.Helper()
		if err := repo.CreateCommand(ctx, store.CommandRow{
			ID: id, AccountID: "acct", SessionID: sessionID, Kind: "session.send",
			Status: status, ScopeHash: "scope-" + id, IdempotencyKey: id, LeaseEpoch: 1,
		}); err != nil {
			t.Fatalf("create command %s: %v", id, err)
		}
	}

	assertStatus := func(t *testing.T, repo store.Repository, sessionID, want string) {
		t.Helper()
		sess, err := repo.SessionByID(ctx, sessionID)
		if err != nil {
			t.Fatalf("read session: %v", err)
		}
		if sess.Status != want {
			t.Fatalf("session status=%q, want %q", sess.Status, want)
		}
	}

	t.Run("completed evidence closes to idle despite fresh heartbeat", func(t *testing.T) {
		repo, svc := setup(t)
		sessID := newRunningSession(t, repo, svc, "ws-term-a")
		finishCommand(t, repo, sessID, "cmd-ok", CommandSucceeded)
		appendEvent(t, repo, sessID, "message.completed")

		summary, err := svc.RecoverStaleSessionsForTerminal(ctx, "acct", "term-a")
		if err != nil {
			t.Fatalf("recover: %v", err)
		}
		if summary.RecoveredIdle != 1 || summary.RecoveredStopped != 0 {
			t.Fatalf("summary=%+v, want idle=1 stopped=0", summary)
		}
		assertStatus(t, repo, sessID, SessionIdle)
	})

	t.Run("interrupted turn closes to stopped", func(t *testing.T) {
		repo, svc := setup(t)
		sessID := newRunningSession(t, repo, svc, "ws-term-a")
		finishCommand(t, repo, sessID, "cmd-failed", CommandFailed)
		appendEvent(t, repo, sessID, "user.message")

		summary, err := svc.RecoverStaleSessionsForTerminal(ctx, "acct", "term-a")
		if err != nil {
			t.Fatalf("recover: %v", err)
		}
		if summary.RecoveredStopped != 1 {
			t.Fatalf("summary=%+v, want stopped=1", summary)
		}
		assertStatus(t, repo, sessID, SessionStopped)
	})

	t.Run("live instance closes to stopped and clears instance", func(t *testing.T) {
		repo, svc := setup(t)
		sessID := newRunningSession(t, repo, svc, "ws-term-a")
		if err := repo.SetSessionInstance(ctx, sessID, "inst-dead"); err != nil {
			t.Fatalf("set instance: %v", err)
		}
		appendEvent(t, repo, sessID, "message.completed")

		summary, err := svc.RecoverStaleSessionsForTerminal(ctx, "acct", "term-a")
		if err != nil {
			t.Fatalf("recover: %v", err)
		}
		if summary.RecoveredStopped != 1 {
			t.Fatalf("summary=%+v, want stopped=1", summary)
		}
		assertStatus(t, repo, sessID, SessionStopped)
		sess, err := repo.SessionByID(ctx, sessID)
		if err != nil {
			t.Fatalf("read session: %v", err)
		}
		if sess.CurrentInstanceID != "" {
			t.Fatalf("current_instance_id=%q, want cleared", sess.CurrentInstanceID)
		}
	})

	t.Run("open command and other-terminal sessions stay untouched", func(t *testing.T) {
		repo, svc := setup(t)
		openCmd := newRunningSession(t, repo, svc, "ws-term-a")
		finishCommand(t, repo, openCmd, "cmd-open", CommandRunning)
		otherTerminal := newRunningSession(t, repo, svc, "ws-term-b")
		finishCommand(t, repo, otherTerminal, "cmd-other", CommandSucceeded)
		appendEvent(t, repo, otherTerminal, "message.completed")

		summary, err := svc.RecoverStaleSessionsForTerminal(ctx, "acct", "term-a")
		if err != nil {
			t.Fatalf("recover: %v", err)
		}
		if summary.RecoveredIdle+summary.RecoveredStopped != 0 {
			t.Fatalf("summary=%+v, want no-op", summary)
		}
		assertStatus(t, repo, openCmd, SessionRunning)
		assertStatus(t, repo, otherTerminal, SessionRunning)
	})

	t.Run("idempotent and non-archiving", func(t *testing.T) {
		repo, svc := setup(t)
		sessID := newRunningSession(t, repo, svc, "ws-term-a")
		finishCommand(t, repo, sessID, "cmd-idem", CommandSucceeded)
		appendEvent(t, repo, sessID, "message.completed")

		if _, err := svc.RecoverStaleSessionsForTerminal(ctx, "acct", "term-a"); err != nil {
			t.Fatalf("first recover: %v", err)
		}
		second, err := svc.RecoverStaleSessionsForTerminal(ctx, "acct", "term-a")
		if err != nil {
			t.Fatalf("second recover: %v", err)
		}
		if second.RecoveredIdle+second.RecoveredStopped != 0 {
			t.Fatalf("second summary=%+v, want no-op", second)
		}
		assertStatus(t, repo, sessID, SessionIdle)
		sess, err := repo.SessionByID(ctx, sessID)
		if err != nil {
			t.Fatalf("read session: %v", err)
		}
		if sess.ArchivedAtUnixMS != 0 {
			t.Fatalf("archived_at_unix_ms=%d, want 0 (never archive)", sess.ArchivedAtUnixMS)
		}
		archived, err := svc.ListArchivedSessions(ctx, "acct")
		if err != nil {
			t.Fatalf("list archived: %v", err)
		}
		if len(archived) != 0 {
			t.Fatalf("archived list=%+v, want empty", archived)
		}
	})
}
