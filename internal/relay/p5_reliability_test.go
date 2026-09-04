package relay

import (
	"context"
	"encoding/json"
	"fmt"
	"path/filepath"
	"sort"
	"sync"
	"testing"
	"time"

	"github.com/yubi233/agent-sessions/internal/domain"
	"github.com/yubi233/agent-sessions/internal/store"
)

// SYNC-02：outbox 与 Relay 重启恢复——事件不丢、幂等键不重复 Provider 动作。
func TestOutboxReplayAcrossRestart(t *testing.T) {
	path := filepath.Join(t.TempDir(), "relay.db")
	db, err := store.Open(path)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	repo := store.NewRepository(db)
	svc := domain.NewSessionService(repo)
	ctx := context.Background()

	// 构造会话 + lease。
	_ = repo.CreateAccount(ctx, "acct", "r@t", []byte("h"), time.Now())
	_ = repo.CreateProject(ctx, store.ProjectRow{ID: "proj", AccountID: "acct", Fingerprint: "f"})
	_ = repo.CreateWorkspace(ctx, store.WorkspaceRow{ID: "ws", ProjectID: "proj", CanonicalRoot: "/ws", Status: "active"})
	sess, err := svc.CreateSession(ctx, "acct", "ws", "mock")
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	epoch, err := svc.AcquireLease(ctx, sess.ID, "dev", "")
	if err != nil {
		t.Fatalf("lease: %v", err)
	}
	// 提交命令，写入 outbox。
	cmd, err := svc.SubmitCommand(ctx, domain.CommandInput{
		AccountID: "acct", DeviceID: "dev", Role: "android_owner", SessionID: sess.ID,
		Kind: "session.abort", IdempotencyKey: "ik-restart", LeaseEpoch: epoch,
	})
	if err != nil {
		t.Fatalf("submit: %v", err)
	}
	_ = db.Close()

	// 模拟重启：重新打开库，worker 应能重放 pending outbox。
	db2, err := store.Open(path)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	defer db2.Close()
	repo2 := store.NewRepository(db2)
	worker := domain.NewOutboxWorker(repo2)
	done, err := worker.Drain(ctx, 10)
	if err != nil {
		t.Fatalf("drain: %v", err)
	}
	if done < 1 {
		t.Fatalf("want >=1 outbox replayed after restart, got %d", done)
	}
	// 幂等：同一 idempotency key 返回原命令。
	svc2 := domain.NewSessionService(repo2)
	again, err := svc2.SubmitCommand(ctx, domain.CommandInput{
		AccountID: "acct", DeviceID: "dev", Role: "android_owner", SessionID: sess.ID,
		Kind: "session.abort", IdempotencyKey: "ik-restart", LeaseEpoch: epoch,
	})
	if err != nil {
		t.Fatalf("resubmit: %v", err)
	}
	if again.ID != cmd.ID {
		t.Fatalf("idempotency violated after restart: %s != %s", again.ID, cmd.ID)
	}
}

// PERF-03：lease 竞争负载——并发抢租约只有一个写端胜出。
func TestLeaseCompetitionLoad(t *testing.T) {
	env := newTestEnv(t)
	pair := env.registerAs(t, "perf@test.dev")
	sessID, _ := env.createSession(t, pair.AccessToken, pair.AccountID)

	// 同设备并发抢是幂等续期（epoch 不变）；跨设备竞争才递增。
	// 两个 android 设备并发抢租约：epoch 只能前进，最终唯一写端由 fencing 保证。
	second := env.pairAndroidOwner(t, pair, "perf-second-android")
	var wg sync.WaitGroup
	epochs := make([]int64, 0, 16)
	var mu sync.Mutex
	for i := 0; i < 8; i++ {
		wg.Add(2)
		go func(token string) {
			defer wg.Done()
			resp := env.do(t, "POST", "/v1/sessions/"+sessID+"/lease", nil, token)
			if resp.Code == 200 {
				var lr struct {
					LeaseEpoch int64 `json:"lease_epoch"`
				}
				_ = json.Unmarshal([]byte(resp.Body.String()), &lr)
				mu.Lock()
				epochs = append(epochs, lr.LeaseEpoch)
				mu.Unlock()
			}
		}(pair.AccessToken)
		go func(token string) {
			defer wg.Done()
			resp := env.do(t, "POST", "/v1/sessions/"+sessID+"/lease", nil, token)
			if resp.Code == 200 {
				var lr struct {
					LeaseEpoch int64 `json:"lease_epoch"`
				}
				_ = json.Unmarshal([]byte(resp.Body.String()), &lr)
				mu.Lock()
				epochs = append(epochs, lr.LeaseEpoch)
				mu.Unlock()
			}
		}(second.AccessToken)
	}
	wg.Wait()
	if len(epochs) == 0 {
		t.Fatalf("no successful lease acquisition")
	}
	// 至少出现一次递增（epoch > 1），证明 fencing 生效。
	seenGT1 := false
	for _, e := range epochs {
		if e > 1 {
			seenGT1 = true
		}
	}
	if !seenGT1 {
		t.Fatalf("expected epoch escalation under competition, got %v", epochs)
	}
}

// TestPERF04RelayCommandEventBackpressureBaseline 固定本地样本量，验证命令入队、
// 事件持久化和账号 Hub 的有界背压。该基线只约束 deterministic SQLite/进程内链路，
// 不代表真实 Provider、网络、浏览器渲染或移动设备性能。
func TestPERF04RelayCommandEventBackpressureBaseline(t *testing.T) {
	const (
		fixtureSeed       = 404
		commandSamples    = 128
		eventSamples      = 256
		p95Budget         = 250 * time.Millisecond
		subscriberBacklog = 64
	)

	env := newTestEnv(t)
	owner := env.registerAs(t, "perf-04@fixture.test")
	sessionID, _ := env.createSessionForProject(t, owner.AccessToken, owner.AccountID, "perf-04-project")
	service := domain.NewSessionService(env.repo)
	epoch, err := service.AcquireLease(t.Context(), sessionID, "perf-04-device", "")
	if err != nil {
		t.Fatalf("acquire PERF-04 lease: %v", err)
	}

	commandLatencies := make([]time.Duration, 0, commandSamples)
	for i := 0; i < commandSamples; i++ {
		started := time.Now()
		_, err := service.SubmitCommand(t.Context(), domain.CommandInput{
			AccountID: owner.AccountID, DeviceID: "perf-04-device", Role: "android_owner",
			SessionID: sessionID, Kind: "session.abort", LeaseEpoch: epoch,
			IdempotencyKey: fmt.Sprintf("perf-04-%d-%03d", fixtureSeed, i),
		})
		if err != nil {
			t.Fatalf("enqueue command %d: %v", i, err)
		}
		commandLatencies = append(commandLatencies, time.Since(started))
	}

	hub := domain.NewPresenceHub(time.Minute)
	slowSubscriber, cancelSlow := hub.SubscribeAccount(owner.AccountID)
	defer cancelSlow()
	fastSubscriber, cancelFast := hub.SubscribeAccount(owner.AccountID)
	defer cancelFast()
	fastReceived := 0

	existing, err := env.repo.ListEventsAfter(t.Context(), sessionID, 0)
	if err != nil {
		t.Fatalf("list initial session events: %v", err)
	}
	lastEventSeq := int64(0)
	if len(existing) > 0 {
		lastEventSeq = existing[len(existing)-1].EventSeq
	}
	eventLatencies := make([]time.Duration, 0, eventSamples)
	for i := 0; i < eventSamples; i++ {
		started := time.Now()
		seq, err := env.repo.AppendEvent(t.Context(), store.SessionEventRow{
			SessionID: sessionID, EventSeq: lastEventSeq + 1, EventType: "perf.fixture", EnvelopeJSON: `{}`,
		})
		if err != nil {
			t.Fatalf("append event %d: %v", i, err)
		}
		persisted, err := env.repo.ListEventsAfter(t.Context(), sessionID, lastEventSeq)
		if err != nil || len(persisted) != 1 {
			t.Fatalf("reload event %d: count=%d err=%v", i, len(persisted), err)
		}
		lastEventSeq = seq
		hub.PublishAccount(owner.AccountID, persisted[0])
		select {
		case received := <-fastSubscriber:
			if received.EventSeq != seq {
				t.Fatalf("fast subscriber event_seq=%d, want %d", received.EventSeq, seq)
			}
			fastReceived++
		case <-time.After(100 * time.Millisecond):
			t.Fatal("fast subscriber was blocked by slow subscriber")
		}
		eventLatencies = append(eventLatencies, time.Since(started))
	}

	if fastReceived != eventSamples {
		t.Fatalf("fast subscriber count=%d, want %d", fastReceived, eventSamples)
	}
	if depth := len(slowSubscriber); depth != subscriberBacklog {
		t.Fatalf("slow subscriber backlog=%d, want bounded depth %d", depth, subscriberBacklog)
	}
	accountEvents, err := env.repo.ListAccountEventsAfter(t.Context(), owner.AccountID, 0)
	if err != nil {
		t.Fatalf("list account cursor log: %v", err)
	}
	for i := 1; i < len(accountEvents); i++ {
		if accountEvents[i].AccountEventCursor <= accountEvents[i-1].AccountEventCursor {
			t.Fatalf("account cursor is not strictly increasing at %d", i)
		}
	}

	commandP95 := percentile95(commandLatencies)
	eventP95 := percentile95(eventLatencies)
	if commandP95 > p95Budget || eventP95 > p95Budget {
		t.Fatalf("PERF-04 budget exceeded: command_p95=%s event_p95=%s budget=%s", commandP95, eventP95, p95Budget)
	}
	metrics := map[string]any{
		"fixture_seed": fixtureSeed, "command_samples": commandSamples, "event_samples": eventSamples,
		"subscriber_backlog_limit": subscriberBacklog, "account_event_count": len(accountEvents),
		"command_p50_us": percentile50(commandLatencies).Microseconds(), "command_p95_us": commandP95.Microseconds(),
		"event_p50_us": percentile50(eventLatencies).Microseconds(), "event_p95_us": eventP95.Microseconds(),
		"p95_budget_us": p95Budget.Microseconds(),
	}
	encoded, err := json.Marshal(metrics)
	if err != nil {
		t.Fatalf("encode PERF-04 metrics: %v", err)
	}
	t.Logf("PERF04_METRICS=%s", encoded)
}

func percentile50(samples []time.Duration) time.Duration { return percentile(samples, 50) }
func percentile95(samples []time.Duration) time.Duration { return percentile(samples, 95) }

func percentile(samples []time.Duration, value int) time.Duration {
	ordered := append([]time.Duration(nil), samples...)
	sort.Slice(ordered, func(i, j int) bool { return ordered[i] < ordered[j] })
	index := (len(ordered)*value + 99) / 100
	if index <= 0 {
		index = 1
	}
	return ordered[index-1]
}
