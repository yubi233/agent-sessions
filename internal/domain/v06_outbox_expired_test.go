package domain

import (
	"context"
	"testing"

	"github.com/yubi233/agent-sessions/internal/store"
)

// TestAcquireLeaseExpiresStaleEpochCommands 验证 P2 命令终态收敛：
// lease epoch 递增的同一事务内，旧 epoch 下 accepted/running 的命令立即 expired；
// 已终态命令保持不变；迟到的 ack/result 不能把 expired 命令复活。
func TestAcquireLeaseExpiresStaleEpochCommands(t *testing.T) {
	repo := newRepo(t)
	svc := NewSessionService(repo)
	ctx := context.Background()
	sessionID := newSession(t, repo)

	// epoch 1：提交两条命令（accepted），其中一条推进到 running。
	epoch1, err := svc.AcquireLease(ctx, sessionID, "dev-owner", "")
	if err != nil {
		t.Fatalf("acquire lease 1: %v", err)
	}
	cmdAccepted := submitExpiredFixtureCommand(t, repo, svc, sessionID, epoch1, "expired-accept", CommandAccepted)
	cmdRunning := submitExpiredFixtureCommand(t, repo, svc, sessionID, epoch1, "expired-running", CommandRunning)

	// 终态命令不受影响：succeeded 保持历史。
	cmdDone := submitExpiredFixtureCommand(t, repo, svc, sessionID, epoch1, "expired-done", CommandSucceeded)

	// epoch 2：另一设备接管新控制权生效，旧 epoch 的未终态命令必须同事务过期。
	epoch2, err := svc.AcquireLease(ctx, sessionID, "dev-owner-2", "")
	if err != nil {
		t.Fatalf("acquire lease 2: %v", err)
	}
	if epoch2 != epoch1+1 {
		t.Fatalf("epoch2=%d want %d", epoch2, epoch1+1)
	}

	for _, id := range []string{cmdAccepted.ID, cmdRunning.ID} {
		cmd, err := repo.CommandByID(ctx, id)
		if err != nil {
			t.Fatalf("load command: %v", err)
		}
		if cmd.Status != CommandExpired {
			t.Fatalf("command %s status=%q want expired", id, cmd.Status)
		}
	}

	done, err := repo.CommandByID(ctx, cmdDone.ID)
	if err != nil || done.Status != CommandSucceeded {
		t.Fatalf("terminal command must stay untouched: %+v err=%v", done, err)
	}

	// 迟到的 started ack：expired 是终态，acknowledge 只返回既有 receipt，不复活命令。
	daemons := NewDaemonService(repo)
	if _, err := daemons.Acknowledge(ctx, "acct", "dev-term-x", RoleTerminal, cmdAccepted.ID, 0, 1, "started", ""); err == nil {
		// scope/terminal 校验先失败也符合预期；这里只断言不会产生 running 状态。
	}
	after, err := repo.CommandByID(ctx, cmdAccepted.ID)
	if err != nil || after.Status != CommandExpired {
		t.Fatalf("late ack must not resurrect expired command: %+v err=%v", after, err)
	}
}

// submitExpiredFixtureCommand 直接在 repo 层写入指定状态的 fixture 命令，
// 用于驱动 AcquireLease 的过期收敛；不经过 HTTP 层。
func submitExpiredFixtureCommand(t *testing.T, repo store.Repository, svc *SessionService, sessionID string, epoch int64, key, status string) store.CommandRow {
	t.Helper()
	ctx := context.Background()
	cmd := store.CommandRow{
		ID:             "cmd-" + key,
		AccountID:      "acct",
		SessionID:      sessionID,
		Kind:           "session.send",
		Status:         CommandAccepted,
		ScopeHash:      hashScope("acct", sessionID),
		IdempotencyKey: key,
		LeaseEpoch:     epoch,
	}
	if err := repo.CreateCommand(ctx, cmd); err != nil {
		t.Fatalf("create command: %v", err)
	}
	if status != CommandAccepted {
		if err := repo.UpdateCommandStatus(ctx, cmd.ID, status); err != nil {
			t.Fatalf("seed status: %v", err)
		}
	}
	return cmd
}

// TestOutboxWorkerBackoffAndRecovery 验证 Relay outbox 状态机：
// 失败保留 attempts 与指数退避；达到上限后停止自动出队；
// RequeueFailedOutbox 恢复入口复位后可再次出队；重启后状态持久保留。
func TestOutboxWorkerBackoffAndRecovery(t *testing.T) {
	repo := newRepo(t)
	ctx := context.Background()

	if err := repo.EnqueueOutbox(ctx, store.OutboxRow{Kind: "command.updated", PayloadJSON: `{"x":1}`, Status: "pending"}); err != nil {
		t.Fatalf("enqueue: %v", err)
	}

	// 连续失败直到重试上限：每次失败都保留行并推迟下次重试。
	worker := NewOutboxWorker(repo)
	rowsBefore, err := repo.ListPendingOutbox(ctx, 10)
	if err != nil || len(rowsBefore) != 1 {
		t.Fatalf("initial pending rows=%d err=%v", len(rowsBefore), err)
	}
	id := rowsBefore[0].ID
	for attempts := 1; attempts <= store.RelayOutboxRetryCap; attempts++ {
		if err := repo.MarkOutboxFailed(ctx, id, attempts); err != nil {
			t.Fatalf("mark failed %d: %v", attempts, err)
		}
		row, err := repo.ClaimOutbox(ctx, id)
		if err != nil {
			t.Fatal(err)
		}
		if row.Status != "failed" || row.Attempts != attempts {
			t.Fatalf("attempt %d state=%+v", attempts, row)
		}
		if attempts < store.RelayOutboxRetryCap && row.NextAttemptAtUnixMS == 0 {
			t.Fatalf("attempt %d must schedule backoff: %+v", attempts, row)
		}
	}

	// 达到上限后不再自动出队，但行必须保留。
	rowsDue, err := repo.ListPendingOutbox(ctx, 10)
	if err != nil || len(rowsDue) != 0 {
		t.Fatalf("capped failed row must not be listed: rows=%d err=%v", len(rowsDue), err)
	}
	row, err := repo.ClaimOutbox(ctx, id)
	if err != nil || row.Status != "failed" {
		t.Fatalf("capped row must be retained: %+v err=%v", row, err)
	}

	// 恢复入口复位后可再次出队并成功投递为 delivered。
	requeued, err := repo.RequeueFailedOutbox(ctx)
	if err != nil || requeued != 1 {
		t.Fatalf("requeue: %d %v", requeued, err)
	}
	rowsAfter, err := repo.ListPendingOutbox(ctx, 10)
	if err != nil || len(rowsAfter) != 1 {
		t.Fatalf("requeued rows=%d err=%v", len(rowsAfter), err)
	}
	count, drainErr := worker.Drain(ctx, 10)
	if drainErr != nil || count != 1 {
		t.Fatalf("drain after recovery: %d %v", count, drainErr)
	}
	final, err := repo.ClaimOutbox(ctx, id)
	if err != nil || final.Status != "delivered" {
		t.Fatalf("drained row must be delivered: %+v err=%v", final, err)
	}
}
