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
