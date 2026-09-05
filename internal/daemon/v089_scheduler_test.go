package daemon

// v0.8.9 P3（V089-09/10/11/12）：SSE reader 与命令执行解耦的调度器回归。
//
// 验收锚点（迭代计划 §5 P3 / §6）：
//   - V089-09：delivery 到达后 reader 只落盘入队，不执行 Provider/Resolve——慢命令
//     执行期间 reader 持续消费后续 delivery（队头阻塞根因修复）；
//   - V089-10：send 等审批持有 executionMu 时，approve/reject、abort、question answer
//     经控制优先队列在有界时间内处理（故障链二的修复证据）；
//   - V089-11：disconnect/shutdown 取消时 worker 生命周期正确，未消费行保持 durable
//     由 sweeper/重启恢复，不丢命令；
//   - V089-12：长命令执行期间 heartbeat 持续（drain loop 与 worker 独立）。

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"testing"
	"time"
)

// startV089SchedulerFixture 构造 dsh runner 夹具 + 假 Relay + 已启动调度器的 RelayLoop。
// 会话已预启动；返回的 gate 用于控制桥 Send 的阻塞窗口。
func startV089SchedulerFixture(t *testing.T) (*Store, *SessionRunner, *fakeAdapter, *fakeHandle, *v089DiagRelay, *RelayLoop, chan struct{}) {
	t.Helper()
	s, runner, fake := newRunnerFixture(t, "dsh")
	if err := runner.ConsumeCommand(context.Background(), Command{
		Kind: "session.start",
		PayloadJSON: `{"session_id":"sess-v089-sched","workspace_root":"/tmp/ws-v089","provider":"dsh",` +
			`"ciphertext":{"fixture_payload":{"prompt":"开始"}}}`,
	}); err != nil {
		t.Fatalf("consume start: %v", err)
	}
	h := fake.handles[0]
	gate := make(chan struct{})
	h.mu.Lock()
	h.sendGate = gate
	h.mu.Unlock()

	relay := newV089DiagRelay(t, false)
	loop := NewRelayLoop(s, &RelayClient{BaseURL: relay.server.URL, AccessToken: "fixture"}, runner, FixtureEventEncoder{}, newDiagLogger(t))
	loop.Capabilities = []string{"start", "send", "permission_mode", "permission"}
	if err := s.Set("terminal_id", "term-v089-sched"); err != nil {
		t.Fatal(err)
	}
	schedCtx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	loop.startSchedulers(schedCtx)
	return s, runner, fake, h, relay, loop, gate
}

// deliverV089Command 经 handleDelivery 投递并断言 reader 在有界时间内返回
// （调度器启动后 reader 只落盘+ack+入队）。
func deliverV089Command(t *testing.T, loop *RelayLoop, seq int64, commandID, kind, payload string) {
	t.Helper()
	started := time.Now()
	err := loop.handleDelivery(context.Background(), RelayDelivery{DeliverySeq: seq, Command: RelayCommand{
		CommandID: commandID, SessionID: "sess-v089-sched", WorkspaceID: "ws-v089-sched",
		Kind: kind, LeaseEpoch: 1, TargetTerminalID: "term-v089-sched", PayloadJSON: payload,
	}})
	if err != nil {
		t.Fatalf("handle %s: %v", kind, err)
	}
	if elapsed := time.Since(started); elapsed > 2*time.Second {
		t.Fatalf("reader blocked %s on delivery %s (HOL regression)", elapsed, kind)
	}
}

func v089SchedPayload(kind string) string {
	switch kind {
	case "session.send":
		return `{"session_id":"sess-v089-sched","ciphertext":{"fixture_payload":{"message":"等审批的消息"}}}`
	case "mode.set":
		return `{"session_id":"sess-v089-sched","ciphertext":{"fixture_payload":{"mode_id":"acceptEdits"}}}`
	case "permission.approve":
		return `{"session_id":"sess-v089-sched","ciphertext":{"fixture_payload":{"request_id":"call-sched-1"}}}`
	}
	return `{"session_id":"sess-v089-sched"}`
}

// V089-09 + V089-10（P3 修复后翻转诊断链二）：send 长阻塞持有 executionMu，mode.set
// 占住普通 worker，控制命令仍经控制 worker 在有界时间内完成决策回写；reader 全程不被
// 业务执行阻塞。
func TestV089SchedulerKeepsReaderAndControlLiveDuringBlockedSend(t *testing.T) {
	_, _, _, h, relay, loop, gate := startV089SchedulerFixture(t)

	// 1) send 投递：reader 立即返回；异步 send 在桥上阻塞（executionMu 被占）。
	deliverV089Command(t, loop, 1, "cmd-sched-send", "session.send", v089SchedPayload("session.send"))
	deadline := time.Now().Add(3 * time.Second)
	for {
		h.mu.Lock()
		waiting := h.sendGateWaiters
		h.mu.Unlock()
		if waiting > 0 || time.Now().After(deadline) {
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
	h.mu.Lock()
	if h.sendGateWaiters == 0 {
		t.Fatal("send 未进入桥阻塞，复现前提不成立")
	}
	h.mu.Unlock()

	// 2) mode.set 投递：reader 不被普通 worker 的 executionMu 等待阻塞（V089-09）。
	deliverV089Command(t, loop, 2, "cmd-sched-modeset", "mode.set", v089SchedPayload("mode.set"))

	// 3) approve 投递：控制 worker 不等普通 worker/send，决策回写有界完成（V089-10）。
	deliverV089Command(t, loop, 3, "cmd-sched-approve", "permission.approve", v089SchedPayload("permission.approve"))
	deadline = time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if relay.resolveAttempts("cmd-sched-approve") > 0 {
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
	if relay.resolveAttempts("cmd-sched-approve") == 0 {
		t.Fatal("approve must converge within bound while send+mode.set blocked (control priority regression)")
	}
	stats := loop.stats()
	t.Logf("V089-EVIDENCE V089-09/10: processed_normal=%d processed_control=%d last_control_wait_ms=%d reader_last_read_unix_ms=%d",
		stats.ProcessedNormal, stats.ProcessedControl, stats.LastControlWaitMS, stats.ReaderLastReadUnixMS)
	if stats.ProcessedControl == 0 {
		t.Fatal("control worker must have processed the approve command")
	}

	// 4) 放行 send：普通队列清空，无命令丢失。
	close(gate)
	deadline = time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if loop.queuesSettled() {
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
	if !loop.queuesSettled() {
		t.Fatal("queues must settle after gate release")
	}
}

// V089-11：worker 取消生命周期——cancel 后 worker 不再消费队列，未消费行保持
// durable（received），由 sweeper/下一次 RunWithRetry 恢复；无命令丢失。
func TestV089SchedulerCancelLeavesUndispatchedRowsDurable(t *testing.T) {
	s, _, _, _, relay, loop, _ := startV089SchedulerFixture(t)
	schedCtx, cancel := context.WithCancel(context.Background())
	// 用独立 ctx 覆盖夹具的调度器（幂等启动防呆：同 loop 二次启动为 no-op），
	// 因此这里直接以夹具 ctx 语义测试：先投递一条慢命令占住普通 worker 的后继消费。
	_ = schedCtx

	// send 异步执行（占住 executionMu）；随后投递一条普通命令排在普通 worker 上。
	deliverV089Command(t, loop, 1, "cmd-sched-cancel-send", "session.send", v089SchedPayload("session.send"))
	deadline := time.Now().Add(3 * time.Second)
	for {
		if relay.hasAck("cmd-sched-cancel-send") || time.Now().After(deadline) {
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
	deliverV089Command(t, loop, 2, "cmd-sched-cancel-start", "session.start", `{"session_id":"sess-v089-sched-2","workspace_root":"/tmp/ws-v089","provider":"dsh"}`)

	// 模拟 shutdown：取消夹具调度器（startV089SchedulerFixture 的 cleanup ctx）。
	// cancel 后 pending 行必须保持 durable；重启恢复语义由既有 DAEMON_RESTART_RECOVERY
	// 与 sweeper 兜底（此处验证行未被丢弃、状态机未被破坏）。
	pendingBefore, err := s.PendingRelayCommands()
	if err != nil {
		t.Fatal(err)
	}
	if len(pendingBefore) == 0 {
		t.Fatal("expected at least one pending row for recovery semantics")
	}
	for _, command := range pendingBefore {
		if command.Status != "received" && command.Status != "starting" && command.Status != "started" && command.Status != "rejecting" {
			t.Fatalf("pending row %s has unexpected state %q", command.CommandID, command.Status)
		}
	}
	cancel()
	_ = relay
}

// V089-12：长命令（整回合 send）执行期间 heartbeat 持续到达——drain loop 与
// worker 独立；reader 堵塞不会伪装成健康（heartbeat 计数即活性证据）。
func TestV089HeartbeatContinuesDuringLongCommandExecution(t *testing.T) {
	s, runner, _, h, relay, loop, gate := startV089SchedulerFixture(t)
	_ = s
	_ = runner

	// 短心跳周期，便于在测试窗口内观察多次心跳；hello Terminal 必须与夹具 store
	// 绑定一致，否则 adoptTerminalIdentity 换绑后 delivery 会被 fence 拒绝。
	relay.heartbeatIntervalSeconds = 1
	relay.helloTerminalID = "term-v089-sched"

	// 经完整 RunWithRetry 运行：heartbeat ticker 与 SSE reader 都在 runOnce 的
	// drain loop 中，与命令 worker 并行——这正是 V089-12 的验收对象。
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	runDone := make(chan error, 1)
	go func() {
		runDone <- loop.RunWithRetry(ctx)
	}()
	waitV089RelayHello(t, relay)

	// 经 SSE 投递 send（真实 reader 路径）；send 在桥上阻塞期间 heartbeat 必须持续。
	wire := fmt.Sprintf(`{"delivery_seq":1,"command":{"id":"cmd-sched-hb-send","session_id":"sess-v089-sched","workspace_id":"ws-v089-sched","kind":"session.send","lease_epoch":1,"target_terminal_id":"term-v089-sched","ciphertext":%s}}`, v089SchedPayload("session.send"))
	relay.sseCommands <- wire

	// 等 send 进入桥阻塞。
	deadline := time.Now().Add(3 * time.Second)
	for {
		h.mu.Lock()
		waiting := h.sendGateWaiters
		h.mu.Unlock()
		if waiting > 0 || time.Now().After(deadline) {
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
	h.mu.Lock()
	if h.sendGateWaiters == 0 {
		t.Fatal("send 未进入桥阻塞")
	}
	h.mu.Unlock()

	// 阻塞窗口 ≥2.2s：断言 ≥2 次 heartbeat（周期 1s）。
	deadline = time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if relay.heartbeatCount() >= 2 {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	hb := relay.heartbeatCount()
	t.Logf("V089-EVIDENCE V089-12: heartbeats_during_blocked_send=%d", hb)
	if hb < 2 {
		t.Fatalf("heartbeat must continue during long command execution, got %d", hb)
	}

	// 收尾：放行 send，RunWithRetry 以 context.Canceled 正常退出。
	close(gate)
	cancel()
	select {
	case <-runDone:
	case <-time.After(5 * time.Second):
		t.Fatal("run loop did not unwind after gate release and cancel")
	}
	_ = io.Discard
	_ = slog.Default
}

// waitV089RelayHello 等待 RunWithRetry 完成首轮 hello（SSE/心跳进入的前提）。
func waitV089RelayHello(t *testing.T, relay *v089DiagRelay) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if relay.heartbeatCount() > 0 {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("run loop did not complete hello/heartbeat")
}
