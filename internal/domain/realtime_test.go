package domain

import (
	"context"
	"path/filepath"
	"testing"
	"time"

	"github.com/yubi233/agent-sessions/internal/store"
)

// helper 打开隔离 SQLite 仓储。
func newRepo(t *testing.T) store.Repository {
	t.Helper()
	db, err := store.Open(filepath.Join(t.TempDir(), "relay.db"))
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	return store.NewRepository(db)
}

func newSession(t *testing.T, repo store.Repository) string {
	t.Helper()
	ctx := context.Background()
	// 创建 account + project + workspace，满足外键约束链。
	_ = repo.CreateAccount(ctx, "acct", "t@t", []byte("h"), time.Now())
	_ = repo.CreateProject(ctx, store.ProjectRow{ID: "proj", AccountID: "acct", Fingerprint: "fp"})
	_ = repo.CreateWorkspace(ctx, store.WorkspaceRow{ID: "ws", ProjectID: "proj", CanonicalRoot: "/ws", Status: "active"})
	svc := NewSessionService(repo)
	sess, err := svc.CreateSession(ctx, "acct", "ws", "mock")
	if err != nil {
		t.Fatalf("create session: %v", err)
	}
	return sess.ID
}

// 事件 seq 单调且并发写入不重复。
func TestAppendEventMonotonicSeq(t *testing.T) {
	repo := newRepo(t)
	svc := NewSessionService(repo)
	sessID := newSession(t, repo)

	const n = 20
	seqs := make([]int64, 0, n)
	for i := 0; i < n; i++ {
		seq, err := svc.AppendEvent(context.Background(), sessID, "test.event", `{"i":`+string(rune('0'+i))+`}`)
		if err != nil {
			t.Fatalf("append %d: %v", i, err)
		}
		seqs = append(seqs, seq)
	}
	seen := map[int64]bool{}
	for i, s := range seqs {
		if seen[s] {
			t.Fatalf("duplicate seq %d at index %d", s, i)
		}
		seen[s] = true
		if i > 0 && s != seqs[i-1]+1 {
			t.Fatalf("seq not monotonic: %d then %d", seqs[i-1], s)
		}
	}
	// 游标恢复只补齐缺口：after_seq=10 → 返回 seq 11..21 共 11 条。
	events, err := svc.ListEventsAfter(context.Background(), sessID, int64(n/2))
	if err != nil {
		t.Fatalf("list after: %v", err)
	}
	want := n + 1 - n/2
	if len(events) != want {
		t.Fatalf("want %d events after cursor, got %d", want, len(events))
	}
}

// lease 竞态：每次抢租约 epoch 递增；旧 epoch 被 fencing。
func TestAcquireLeaseFencing(t *testing.T) {
	repo := newRepo(t)
	svc := NewSessionService(repo)
	sessID := newSession(t, repo)

	e1, err := svc.AcquireLease(context.Background(), sessID, "android-1", "")
	if err != nil {
		t.Fatalf("acquire 1: %v", err)
	}
	if e1 != 1 {
		t.Fatalf("epoch 1 = %d", e1)
	}
	e2, err := svc.AcquireLease(context.Background(), sessID, "android-1", "")
	if err != nil {
		t.Fatalf("acquire 2: %v", err)
	}
	if e2 != 2 {
		t.Fatalf("epoch 2 = %d", e2)
	}
	// 其他 Android 抢租约应被拒（只保留一个写端）。
	if _, err := svc.AcquireLease(context.Background(), sessID, "android-2", ""); err != ErrLeaseConflict {
		t.Fatalf("want ErrLeaseConflict for other writer, got %v", err)
	}
}

// 非 Android 写命令被拒绝。
func TestSubmitCommandReadOnly(t *testing.T) {
	repo := newRepo(t)
	svc := NewSessionService(repo)
	sessID := newSession(t, repo)
	_, _ = svc.AcquireLease(context.Background(), sessID, "dev", "")

	_, err := svc.SubmitCommand(context.Background(), CommandInput{
		AccountID: "acct", DeviceID: "dev", Role: "web",
		SessionID: sessID, Kind: "session.abort", IdempotencyKey: "ik", LeaseEpoch: 1,
	})
	if err != ErrReadOnlyDevice {
		t.Fatalf("want ErrReadOnlyDevice, got %v", err)
	}
}

// CTRL-02 根因：lease/instance 在写事务内复核，旧 epoch 或旧 instance 都不能留下命令/outbox。
func TestSubmitCommandFencesLeaseAndTargetInstanceInTransaction(t *testing.T) {
	repo := newRepo(t)
	svc := NewSessionService(repo)
	sessID := newSession(t, repo)
	ctx := context.Background()
	if err := repo.SetSessionInstance(ctx, sessID, "inst-current"); err != nil {
		t.Fatalf("set current instance: %v", err)
	}
	if _, err := svc.AcquireLease(ctx, sessID, "dev", "inst-current"); err != nil {
		t.Fatalf("acquire current lease: %v", err)
	}

	if _, err := svc.SubmitCommand(ctx, CommandInput{
		AccountID: "acct", DeviceID: "dev", Role: RoleAndroidOwner,
		SessionID: sessID, Kind: "session.abort", IdempotencyKey: "old-instance", LeaseEpoch: 1, TargetInstanceID: "inst-old",
	}); err != ErrTargetStale {
		t.Fatalf("old instance error=%v want target stale", err)
	}
	// 同一设备续租使 epoch 递增，模拟客户端在检查后才提交的旧命令。
	if _, err := svc.AcquireLease(ctx, sessID, "dev", "inst-current"); err != nil {
		t.Fatalf("renew lease: %v", err)
	}
	if _, err := svc.SubmitCommand(ctx, CommandInput{
		AccountID: "acct", DeviceID: "dev", Role: RoleAndroidOwner,
		SessionID: sessID, Kind: "session.abort", IdempotencyKey: "old-epoch", LeaseEpoch: 1, TargetInstanceID: "inst-current",
	}); err != ErrTargetStale {
		t.Fatalf("old epoch error=%v want target stale", err)
	}
	accepted, err := svc.SubmitCommand(ctx, CommandInput{
		AccountID: "acct", DeviceID: "dev", Role: RoleAndroidOwner,
		SessionID: sessID, Kind: "session.abort", IdempotencyKey: "current", LeaseEpoch: 2, TargetInstanceID: "inst-current",
	})
	if err != nil || accepted.ID == "" {
		t.Fatalf("current command=%+v err=%v", accepted, err)
	}
	commands, err := repo.ListCommands(ctx, sessID)
	if err != nil || len(commands) != 1 {
		t.Fatalf("only current command may persist; commands=%d err=%v", len(commands), err)
	}
}

// outbox worker 重放 pending 条目。
func TestOutboxDrain(t *testing.T) {
	repo := newRepo(t)
	svc := NewSessionService(repo)
	sessID := newSession(t, repo)
	_, _ = svc.AcquireLease(context.Background(), sessID, "dev", "")
	if _, err := svc.SubmitCommand(context.Background(), CommandInput{
		AccountID: "acct", DeviceID: "dev", Role: "android_owner",
		SessionID: sessID, Kind: "session.abort", IdempotencyKey: "ik1", LeaseEpoch: 1,
	}); err != nil {
		t.Fatalf("submit: %v", err)
	}
	worker := NewOutboxWorker(repo)
	done, err := worker.Drain(context.Background(), 10)
	if err != nil {
		t.Fatalf("drain: %v", err)
	}
	if done < 1 {
		t.Fatalf("want >=1 drained, got %d", done)
	}
	// 二次 drain 无 pending。
	again, _ := worker.Drain(context.Background(), 10)
	if again != 0 {
		t.Fatalf("want 0 pending on second drain, got %d", again)
	}
}

// presence hub：在线判定与发布订阅。
func TestPresenceHub(t *testing.T) {
	hub := NewPresenceHub(2 * time.Second)
	now := time.Now()
	hub.Touch("dev-1", now)
	if !hub.Online("dev-1", now) {
		t.Fatalf("dev-1 should be online")
	}
	if hub.Online("dev-1", now.Add(3*time.Second)) {
		t.Fatalf("dev-1 should be offline after TTL")
	}

	ch, cancel := hub.Subscribe("sess-1")
	defer cancel()
	go func() {
		hub.Publish("sess-1", store.SessionEventRow{SessionID: "sess-1", EventSeq: 1, EventType: "x", EnvelopeJSON: "{}"})
	}()
	select {
	case ev := <-ch:
		if ev.EventSeq != 1 {
			t.Fatalf("seq = %d", ev.EventSeq)
		}
	case <-time.After(time.Second):
		t.Fatalf("no event delivered")
	}
}

// 唤醒结果只接受已知集合。
func TestNewWakeResult(t *testing.T) {
	repo := newRepo(t)
	svc := NewSessionService(repo)
	sessID := newSession(t, repo)
	if err := svc.NewWakeResult(context.Background(), sessID, "resumed"); err != nil {
		t.Fatalf("valid wake: %v", err)
	}
	if err := svc.NewWakeResult(context.Background(), sessID, "not-a-wake"); err == nil {
		t.Fatalf("invalid wake should error")
	}
}

// 归档是本地元数据操作：默认列表隐藏、数据仍可读取，取消归档恢复列表。
func TestArchiveSessionHidesFromDefaultListAndRestores(t *testing.T) {
	ctx := context.Background()
	repo := newRepo(t)
	svc := NewSessionService(repo)
	sessID := newSession(t, repo)

	if _, err := svc.ArchiveSession(ctx, "acct", "web", sessID); err != ErrReadOnlyDevice {
		t.Fatalf("readonly archive error=%v want ErrReadOnlyDevice", err)
	}

	archived, err := svc.ArchiveSession(ctx, "acct", RoleAndroidOwner, sessID)
	if err != nil {
		t.Fatalf("archive: %v", err)
	}
	if archived.ArchivedAtUnixMS <= 0 {
		t.Fatalf("archived at <= 0: %+v", archived)
	}
	active, err := repo.ListSessions(ctx, "acct")
	if err != nil || len(active) != 0 {
		t.Fatalf("active sessions should hide archived; got %d err=%v", len(active), err)
	}
	archivedList, err := repo.ListArchivedSessions(ctx, "acct")
	if err != nil || len(archivedList) != 1 || archivedList[0].ID != sessID {
		t.Fatalf("archived list=%+v err=%v", archivedList, err)
	}
	direct, err := repo.SessionByID(ctx, sessID)
	if err != nil || direct.ArchivedAtUnixMS <= 0 {
		t.Fatalf("direct session should still be readable: %+v err=%v", direct, err)
	}

	restored, err := svc.UnarchiveSession(ctx, "acct", RoleAndroidOwner, sessID)
	if err != nil {
		t.Fatalf("unarchive: %v", err)
	}
	if restored.ArchivedAtUnixMS != 0 {
		t.Fatalf("restored archived time = %d", restored.ArchivedAtUnixMS)
	}
	active, err = repo.ListSessions(ctx, "acct")
	if err != nil || len(active) != 1 || active[0].ID != sessID {
		t.Fatalf("active sessions after restore=%+v err=%v", active, err)
	}
}

// prepareStaleRunningSession creates the exact persisted shape that can be
// reconciled: running, no Provider instance, old activity, and a final
// message.completed event. The event is appended directly through the store so
// the test can set an old activity timestamp after all writes.
func prepareStaleRunningSession(t *testing.T, withTerminal bool) (store.Repository, *SessionService, string, time.Time) {
	t.Helper()
	repo := newRepo(t)
	ctx := context.Background()
	accountID, projectID, workspaceID := "acct", "proj", "ws"
	if !withTerminal {
		// Reuse the normal fixture for the common no-terminal case.
		sessID := newSession(t, repo)
		now := time.UnixMilli(2_000_000_000_000)
		svc := NewSessionService(repo)
		svc.now = func() time.Time { return now }
		return finishStaleSession(t, repo, svc, sessID, now)
	}
	// A terminal-linked workspace is needed to exercise the heartbeat guard.
	if err := repo.CreateAccount(ctx, accountID, "stale@test.dev", []byte("h"), time.Now()); err != nil {
		t.Fatalf("create account: %v", err)
	}
	if err := repo.CreateProject(ctx, store.ProjectRow{ID: projectID, AccountID: accountID, Fingerprint: "fp"}); err != nil {
		t.Fatalf("create project: %v", err)
	}
	if err := repo.CreateDevice(ctx, store.DeviceRow{ID: "dev", AccountID: accountID, Role: "terminal", Status: "online", DisplayName: "fixture"}); err != nil {
		t.Fatalf("create device: %v", err)
	}
	if err := repo.CreateTerminal(ctx, store.TerminalRow{ID: "term", DeviceID: "dev", AccountID: accountID, Status: "online"}); err != nil {
		t.Fatalf("create terminal: %v", err)
	}
	if err := repo.CreateWorkspace(ctx, store.WorkspaceRow{ID: workspaceID, ProjectID: projectID, TerminalID: "term", CanonicalRoot: "/ws", Status: "active"}); err != nil {
		t.Fatalf("create workspace: %v", err)
	}
	svc := NewSessionService(repo)
	sess, err := svc.CreateSession(ctx, accountID, workspaceID, "mock")
	if err != nil {
		t.Fatalf("create session: %v", err)
	}
	now := time.UnixMilli(2_000_000_000_000)
	svc.now = func() time.Time { return now }
	return finishStaleSession(t, repo, svc, sess.ID, now)
}

func finishStaleSession(t *testing.T, repo store.Repository, svc *SessionService, sessID string, now time.Time) (store.Repository, *SessionService, string, time.Time) {
	t.Helper()
	ctx := context.Background()
	seq, err := repo.AppendEvent(ctx, store.SessionEventRow{
		SessionID: sessID, EventType: "message.completed", EnvelopeJSON: "{}",
	})
	if err != nil {
		t.Fatalf("append completed event: %v", err)
	}
	if err := repo.SetSessionLastSeq(ctx, sessID, seq); err != nil {
		t.Fatalf("set last seq: %v", err)
	}
	// SetSessionLastSeq uses wall clock time; overwrite it with deterministic old
	// activity after all event/sequence writes are complete.
	if err := repo.SetSessionStatusAt(ctx, sessID, SessionRunning, now.Add(-5*time.Minute).UnixMilli()); err != nil {
		t.Fatalf("set stale status: %v", err)
	}
	return repo, svc, sessID, now
}

// Reconciliation is deliberately conservative: only the fully-qualified
// historical shape is changed to idle. Every individual guard must prevent a
// false positive, and the operation is idempotent/non-archiving.
func TestReconcileStaleRunningSessions(t *testing.T) {
	tests := []struct {
		name     string
		mutate   func(t *testing.T, repo store.Repository, sessID string, now time.Time)
		wantIdle bool
	}{
		{name: "qualified completed history", wantIdle: true},
		{
			name: "terminal command",
			mutate: func(t *testing.T, repo store.Repository, sessID string, _ time.Time) {
				t.Helper()
				if err := repo.CreateCommand(context.Background(), store.CommandRow{
					ID: "cmd-done", AccountID: "acct", SessionID: sessID, Kind: "session.send",
					Status: CommandSucceeded, ScopeHash: "scope-done", IdempotencyKey: "done", LeaseEpoch: 1,
				}); err != nil {
					t.Fatalf("create terminal command: %v", err)
				}
			},
			wantIdle: true,
		},
		{
			name: "active instance",
			mutate: func(t *testing.T, repo store.Repository, sessID string, _ time.Time) {
				t.Helper()
				if err := repo.SetSessionInstance(context.Background(), sessID, "inst-live"); err != nil {
					t.Fatalf("set instance: %v", err)
				}
			},
		},
		{
			name: "active command",
			mutate: func(t *testing.T, repo store.Repository, sessID string, _ time.Time) {
				t.Helper()
				if err := repo.CreateCommand(context.Background(), store.CommandRow{
					ID: "cmd-active", AccountID: "acct", SessionID: sessID, Kind: "session.send",
					Status: CommandRunning, ScopeHash: "scope", IdempotencyKey: "active", LeaseEpoch: 1,
				}); err != nil {
					t.Fatalf("create active command: %v", err)
				}
			},
		},
		{
			name: "fresh activity",
			mutate: func(t *testing.T, repo store.Repository, sessID string, now time.Time) {
				t.Helper()
				if err := repo.SetSessionStatusAt(context.Background(), sessID, SessionRunning, now.Add(-30*time.Second).UnixMilli()); err != nil {
					t.Fatalf("set fresh activity: %v", err)
				}
			},
		},
		{
			name: "non-completed final event",
			mutate: func(t *testing.T, repo store.Repository, sessID string, now time.Time) {
				t.Helper()
				seq, err := repo.AppendEvent(context.Background(), store.SessionEventRow{SessionID: sessID, EventType: "usage.updated", EnvelopeJSON: "{}"})
				if err != nil {
					t.Fatalf("append trailing event: %v", err)
				}
				if err := repo.SetSessionLastSeq(context.Background(), sessID, seq); err != nil {
					t.Fatalf("set trailing seq: %v", err)
				}
				if err := repo.SetSessionStatusAt(context.Background(), sessID, SessionRunning, now.Add(-5*time.Minute).UnixMilli()); err != nil {
					t.Fatalf("restore stale status: %v", err)
				}
			},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			repo, svc, sessID, now := prepareStaleRunningSession(t, false)
			if tt.mutate != nil {
				tt.mutate(t, repo, sessID, now)
			}
			rows, err := svc.ListSessions(context.Background(), "acct")
			if err != nil {
				t.Fatalf("list sessions/reconcile: %v", err)
			}
			if len(rows) != 1 {
				t.Fatalf("rows=%d, want one visible session", len(rows))
			}
			if got := rows[0].Status == SessionIdle; got != tt.wantIdle {
				t.Fatalf("status=%q, idle=%v want %v", rows[0].Status, got, tt.wantIdle)
			}
			if rows[0].ArchivedAtUnixMS != 0 {
				t.Fatalf("reconcile must not archive session: %+v", rows[0])
			}
			// A second read must be stable and must not append another transition.
			rows2, err := svc.ListSessions(context.Background(), "acct")
			if err != nil || len(rows2) != 1 || rows2[0].Status != rows[0].Status {
				t.Fatalf("second reconciliation rows=%+v err=%v", rows2, err)
			}
		})
	}
}

// A fresh heartbeat on the workspace Terminal blocks reconciliation even when
// the persisted session activity itself is older than the TTL.
func TestReconcileStaleRunningSessionsSkipsFreshTerminal(t *testing.T) {
	repo, svc, sessID, now := prepareStaleRunningSession(t, true)
	if sessID == "" {
		t.Fatal("stale session id must not be empty")
	}
	if err := repo.TouchTerminal(context.Background(), "term", now.Add(-30*time.Second).UnixMilli()); err != nil {
		t.Fatalf("touch terminal: %v", err)
	}
	rows, err := svc.ListSessions(context.Background(), "acct")
	if err != nil {
		t.Fatalf("list sessions: %v", err)
	}
	if len(rows) != 1 || rows[0].Status != SessionRunning {
		t.Fatalf("fresh terminal must keep running session: %+v", rows)
	}
}

// A legacy row may have last_activity_at_unix_ms=0 because it predates the
// additive column.  That unknown timestamp must not bypass the Terminal
// heartbeat guard: a fresh linked Terminal still proves that the session may
// be active and therefore must remain running.
func TestReconcileLegacyActivityStillHonorsFreshTerminal(t *testing.T) {
	repo, svc, sessID, now := prepareStaleRunningSession(t, true)
	ctx := context.Background()
	if err := repo.SetSessionStatusAt(ctx, sessID, SessionRunning, 0); err != nil {
		t.Fatalf("clear legacy activity timestamp: %v", err)
	}
	if err := repo.TouchTerminal(ctx, "term", now.Add(-30*time.Second).UnixMilli()); err != nil {
		t.Fatalf("touch terminal: %v", err)
	}
	rows, err := svc.ListSessions(ctx, "acct")
	if err != nil {
		t.Fatalf("list sessions: %v", err)
	}
	if len(rows) != 1 || rows[0].Status != SessionRunning {
		t.Fatalf("fresh terminal must keep legacy running session: %+v", rows)
	}
}
