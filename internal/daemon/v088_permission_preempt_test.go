package daemon

// v0.8.8 P3b（V088-15b 真实栈首曝回归）：审批应答抢占性——ask 档下 session.send
// 回合在等待审批期间持有 executionMu（h.request 阻塞在 session/prompt），审批应答
// 若走同一把锁会永远排队（回合等审批、审批等回合 = 死锁）。修复后 approve/reject
// 与 abort 同为抢占类：不取 executionMu 直接走 respondPermission（handle 侧
// one-shot 校验自带并发安全）。本测试用 sendGate 占住执行锁，断言 approve 在
// send 未返回时完成决策回写。

import (
	"context"
	"testing"
	"time"
)

func TestV088PermissionApprovePreemptsInFlightSend(t *testing.T) {
	s, runner, fake := newRunnerFixture(t, "dsh")
	defer func() { _ = s.Close() }()
	start := Command{
		Kind: "session.start",
		PayloadJSON: `{"session_id":"preempt","workspace_root":"/tmp/ws","provider":"dsh",` +
			`"ciphertext":{"fixture_payload":{"prompt":"开始"}}}`,
	}
	if err := runner.ConsumeCommand(context.Background(), start); err != nil {
		t.Fatalf("consume start: %v", err)
	}
	h := fake.handles[0]

	// 桥的 session/prompt 挂起不响应：模拟回合等待审批（Send 长时间阻塞）。
	gate := make(chan struct{})
	h.mu.Lock()
	h.sendGate = gate
	h.mu.Unlock()

	sendDone := make(chan error, 1)
	go func() {
		sendDone <- runner.ConsumeCommand(context.Background(), Command{
			Kind: "session.send",
			PayloadJSON: `{"session_id":"preempt","ciphertext":{"fixture_payload":` +
				`{"message":"等审批的消息"}}}`,
		})
	}()

	// 等 Send 进入阻塞（已持有执行锁）。
	deadline := time.Now().Add(3 * time.Second)
	for {
		h.mu.Lock()
		waiting := h.sendGateWaiters
		h.mu.Unlock()
		if waiting > 0 || time.Now().After(deadline) {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	h.mu.Lock()
	waiting := h.sendGateWaiters
	h.mu.Unlock()
	if waiting == 0 {
		t.Fatalf("Send 未进入阻塞")
	}

	// approve 必须在 send 阻塞期间完成（不取 executionMu）。
	approveDone := make(chan error, 1)
	go func() {
		approveDone <- runner.ConsumeCommand(context.Background(), Command{
			Kind: "permission.approve",
			PayloadJSON: `{"session_id":"preempt","ciphertext":{"fixture_payload":` +
				`{"request_id":"call-test-1"}}}`,
		})
	}()
	select {
	case err := <-approveDone:
		// 未知 request_id 走决策语义失败（fail-closed 正常路径）；关键是不能死锁。
		if err != nil {
			t.Logf("approve 决策语义失败（预期：未知请求）: %v", err)
		}
	case <-time.After(3 * time.Second):
		t.Fatalf("approve 被 send 的 executionMu 阻塞（抢占修复未生效）")
	}

	// 放行 send 收尾，确认无死锁残留。
	close(gate)
	if err := <-sendDone; err != nil {
		t.Fatalf("send 完成: %v", err)
	}
}
