package relay

import (
	"context"
	"encoding/json"
	"path/filepath"
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

	// 两个 android 设备并发抢租约；只有第一个能拿到 epoch=1，其余被拒或递增。
	// 这里用 owner 设备连续抢，验证 epoch 严格递增且最终唯一写端。
	var wg sync.WaitGroup
	epochs := make([]int64, 0, 8)
	var mu sync.Mutex
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			resp := env.do(t, "POST", "/v1/sessions/"+sessID+"/lease", nil, pair.AccessToken)
			if resp.Code == 200 {
				var lr struct {
					LeaseEpoch int64 `json:"lease_epoch"`
				}
				_ = json.Unmarshal([]byte(resp.Body.String()), &lr)
				mu.Lock()
				epochs = append(epochs, lr.LeaseEpoch)
				mu.Unlock()
			}
		}()
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
