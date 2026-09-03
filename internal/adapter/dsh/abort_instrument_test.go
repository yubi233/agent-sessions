package dsh

import (
	"context"
	"encoding/json"
	"sync"
	"testing"
	"time"

	"github.com/yubi233/agent-sessions/internal/adapter"
)

// V084-08 补强（真实中断验证 + 埋点）：Abort 必须真正打断 DSH 模型回合，
// 而不只是客户端改状态。三层证据：
//  1. 线缆层：client 向桥发出 session/cancel 通知帧（且位于 session/prompt 之后）；
//  2. 回合层：prompt 以 stopReason=cancelled 结算，handle 广播
//     turn_completed(stop_reason=cancelled)，中断后不再有新的模型增量；
//  3. 埋点层：abort_requested 与 turn_cancelled 计数各 +1。

// TestAbortInterruptsModelTurnWithInstrumentation 覆盖中断全链路。
func TestAbortInterruptsModelTurnWithInstrumentation(t *testing.T) {
	const sessionID = "sess-abort-live"
	fb := newFakeBridge()

	// prompt 挂起点：脚本在 prompt 请求到达时先推两条流式 delta（模拟模型输出），
	// 然后挂起应答，直到 client 的 session/cancel 帧到达才以 cancelled 结算。
	// 注意 WriteFrame 持有假桥锁执行脚本，脚本内绝不阻塞——应答由 goroutine 推送。
	release := newReleaseGate()
	fb.script = func(fb *fakeBridge, msg map[string]any) {
		switch methodOf(msg) {
		case "initialize", "session/new":
			respondByMethod(t, sessionID)(fb, msg)
		case "session/prompt":
			id := frameID(msg)
			fb.push(t, map[string]any{
				"jsonrpc": "2.0",
				"method":  "session/update",
				"params": map[string]any{
					"sessionId": sessionID,
					"_meta": map[string]any{
						"com.deepseek.dsh/chunk": map[string]any{
							"kind": "text-delta", "turn": 1, "step": 1, "seq": 1,
						},
					},
					"update": map[string]any{
						"sessionUpdate": "agent_message_chunk",
						"content":       map[string]any{"type": "text", "text": "第一段"},
					},
				},
			})
			fb.push(t, map[string]any{
				"jsonrpc": "2.0",
				"method":  "session/update",
				"params": map[string]any{
					"sessionId": sessionID,
					"_meta": map[string]any{
						"com.deepseek.dsh/chunk": map[string]any{
							"kind": "text-delta", "turn": 1, "step": 1, "seq": 2,
						},
					},
					"update": map[string]any{
						"sessionUpdate": "agent_message_chunk",
						"content":       map[string]any{"type": "text", "text": "第二段"},
					},
				},
			})
			go func() {
				release.wait()
				fb.pushRaw(mustJSON(map[string]any{
					"jsonrpc": "2.0", "id": id,
					"result": map[string]any{"stopReason": "cancelled"},
				}))
			}()
		case "session/cancel":
			// 埋点：桥侧收到中断通知（真实桥由此打断模型流）。
			release.fire()
		}
	}

	h := startWithFake(t, fb)

	sendDone := make(chan error, 1)
	go func() {
		sendDone <- h.Send(context.Background(), "讲个长故事")
	}()

	// 等两条流式 delta 进入 canonical 事件流（中断前的模型输出）。
	deadline := time.After(5 * time.Second)
	deltaCount := 0
	var abortIndex, promptIndex = -1, -1
	for deltaCount < 2 {
		select {
		case ev := <-h.Events():
			if ev.Type == adapter.EventMessageDelta {
				deltaCount++
			}
		case <-deadline:
			t.Fatalf("等待流式 delta 超时，已收到 %d 条", deltaCount)
		}
	}

	// 中断：发出 session/cancel，回合以 cancelled 结算。
	if err := h.Abort(context.Background()); err != nil {
		t.Fatalf("Abort: %v", err)
	}
	if err := <-sendDone; err != nil {
		t.Fatalf("Send 应以 cancelled 正常结算，实际报错: %v", err)
	}

	// 回合层证据：turn_completed(stop_reason=cancelled)。
	// phase 投影是旁路事件（合成兜底终态会先广播 turn.phase），需跳过。
	ev := nextNonPhaseEvent(t, h.Events())
	if ev.Type != adapter.EventTurnCompleted {
		t.Fatalf("事件类型 = %q, want turn_completed", ev.Type)
	}
	if ev.Payload["stop_reason"] != "cancelled" {
		t.Fatalf("stop_reason = %v, want cancelled", ev.Payload["stop_reason"])
	}

	// 线缆层证据：cancel 帧存在且位于 session/prompt 之后（先有回合才谈中断）。
	written := fb.written()
	for index, frame := range written {
		switch methodOf(frame) {
		case "session/prompt":
			if promptIndex == -1 {
				promptIndex = index
			}
		case "session/cancel":
			if abortIndex == -1 {
				abortIndex = index
			}
		}
	}
	if promptIndex == -1 || abortIndex == -1 {
		t.Fatalf("线缆帧缺失: promptIndex=%d abortIndex=%d", promptIndex, abortIndex)
	}
	if abortIndex < promptIndex {
		t.Fatalf("cancel 帧必须晚于 prompt 帧: abort=%d prompt=%d", abortIndex, promptIndex)
	}

	// 中断后不再有新的模型增量（模型输出确实停止）。
	select {
	case ev := <-h.Events():
		if ev.Type == adapter.EventMessageDelta {
			t.Fatalf("中断后仍收到模型增量: %+v", ev.Payload)
		}
	case <-time.After(300 * time.Millisecond):
	}

	// 埋点层证据：一次中断请求，一次真实取消。
	instrument := h.(*handle).instrumentSnapshot()
	if instrument["abort_requested"] != 1 || instrument["turn_cancelled"] != 1 {
		t.Fatalf("埋点计数 = %v, want abort_requested=1 turn_cancelled=1", instrument)
	}
	_ = deltaCount
}

// releaseGate 是一次性放行门：session/cancel 到达前阻塞 prompt 应答。
type releaseGate struct {
	ch   chan struct{}
	once sync.Once
}

func newReleaseGate() *releaseGate {
	return &releaseGate{ch: make(chan struct{})}
}

func (g *releaseGate) wait() { <-g.ch }
func (g *releaseGate) fire() { g.once.Do(func() { close(g.ch) }) }

func mustJSON(value map[string]any) []byte {
	raw, err := json.Marshal(value)
	if err != nil {
		panic(err)
	}
	return raw
}
