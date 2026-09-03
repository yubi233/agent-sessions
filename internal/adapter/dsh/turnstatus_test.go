package dsh

import (
	"testing"
	"time"

	"github.com/yubi233/agent-sessions/internal/adapter"
)

// V084-07（adapter 侧）：dsh/turn/status 通知的结构校验、冻结转换表执行与
// turn.phase/session.activity 双事件投影（ADR-015 §3）。

// pushTurnStatus 向句柄注入一条 dsh/turn/status 通知帧。
func pushTurnStatus(t *testing.T, h *handle, payload string) {
	t.Helper()
	h.handleNotification(rpcMessage{
		Method: NotifyDshTurnStatus,
		Params: []byte(payload),
	})
}

// collectEvents 排空句柄事件通道（带超时）。
func collectEvents(t *testing.T, h *handle) []adapter.Event {
	t.Helper()
	var events []adapter.Event
	deadline := time.After(500 * time.Millisecond)
	for {
		select {
		case ev := <-h.Events():
			events = append(events, ev)
		case <-deadline:
			return events
		}
	}
}

func newTestHandle(t *testing.T) *handle {
	t.Helper()
	h := newHandle(newFakeBridge())
	h.setSessionID("sess-phase")
	return h
}

// TestTurnStatusValidFramesProjectCanonicalEvents 合法 phase 帧按冻结转换表
// 投影为 turn.phase + session.activity 双事件，revision 单调。
func TestTurnStatusValidFramesProjectCanonicalEvents(t *testing.T) {
	h := newTestHandle(t)
	pushTurnStatus(t, h, `{"protocolVersion":1,"sessionId":"sess-phase","turnId":"1","step":1,"phase":"preparing","revision":1,"reason":"turn_start"}`)
	pushTurnStatus(t, h, `{"protocolVersion":1,"sessionId":"sess-phase","turnId":"1","step":2,"phase":"streaming","revision":2,"reason":"first_text_delta"}`)
	pushTurnStatus(t, h, `{"protocolVersion":1,"sessionId":"sess-phase","turnId":"1","step":2,"phase":"finishing","revision":3,"reason":"model_output_end"}`)
	pushTurnStatus(t, h, `{"protocolVersion":1,"sessionId":"sess-phase","turnId":"1","step":2,"phase":"completed","revision":4,"reason":"turn_end"}`)

	var phases, activities []adapter.Event
	for _, ev := range collectEvents(t, h) {
		switch ev.Type {
		case adapter.EventTurnPhase:
			phases = append(phases, ev)
		case adapter.EventSessionActivity:
			activities = append(activities, ev)
		default:
			t.Fatalf("意外事件类型 %q", ev.Type)
		}
	}
	if len(phases) != 4 || len(activities) != 4 {
		t.Fatalf("phases=%d activities=%d, want 4/4", len(phases), len(activities))
	}
	wantRevisions := []int64{1, 2, 3, 4}
	for index, ev := range phases {
		if ev.Payload["revision"] != wantRevisions[index] {
			t.Fatalf("phase[%d].revision = %v, want %d", index, ev.Payload["revision"], wantRevisions[index])
		}
		if ev.Payload["reason"] == "" || ev.Payload["turn_id"] != "1" {
			t.Fatalf("phase[%d] payload = %+v", index, ev.Payload)
		}
	}
}

// TestTurnStatusIllegalAndStaleFramesDropped 非法转换、revision 回退、跨 session、
// 未知字段、终态 fence 全部丢弃计数，不产生事件。
func TestTurnStatusIllegalAndStaleFramesDropped(t *testing.T) {
	h := newTestHandle(t)
	pushTurnStatus(t, h, `{"protocolVersion":1,"sessionId":"sess-phase","turnId":"1","step":1,"phase":"streaming","revision":1,"reason":"first_text_delta"}`)
	// streaming → thinking 非法（首个文本 chunk 之后不回退）。
	pushTurnStatus(t, h, `{"protocolVersion":1,"sessionId":"sess-phase","turnId":"1","step":1,"phase":"thinking","revision":2,"reason":"first_thought_delta"}`)
	// revision 回退。
	pushTurnStatus(t, h, `{"protocolVersion":1,"sessionId":"sess-phase","turnId":"1","step":1,"phase":"finishing","revision":1,"reason":"model_output_end"}`)
	// 跨 session。
	pushTurnStatus(t, h, `{"protocolVersion":1,"sessionId":"sess-other","turnId":"1","step":1,"phase":"finishing","revision":3,"reason":"model_output_end"}`)
	// 未知字段（严格 schema）。
	pushTurnStatus(t, h, `{"protocolVersion":1,"sessionId":"sess-phase","turnId":"1","step":1,"phase":"finishing","revision":3,"reason":"model_output_end","extra":1}`)
	// 终态进入（streaming→completed 合法），随后一切转换被 fence 拒绝。
	pushTurnStatus(t, h, `{"protocolVersion":1,"sessionId":"sess-phase","turnId":"1","step":1,"phase":"completed","revision":4,"reason":"turn_end"}`)
	pushTurnStatus(t, h, `{"protocolVersion":1,"sessionId":"sess-phase","turnId":"1","step":1,"phase":"streaming","revision":5,"reason":"first_text_delta"}`)

	events := collectEvents(t, h)
	for _, ev := range events {
		if ev.Type != adapter.EventTurnPhase && ev.Type != adapter.EventSessionActivity {
			t.Fatalf("意外事件类型 %q", ev.Type)
		}
	}
	// 合法事件：streaming（帧1）与 completed（帧6）各产生 phase+activity 两条。
	if got := len(events); got != 4 {
		t.Fatalf("合法事件应只有 streaming/completed 的 4 条，实际 %d", got)
	}
	phases := []string{}
	for _, ev := range events {
		if ev.Type == adapter.EventTurnPhase {
			phases = append(phases, ev.Payload["phase"].(string))
		}
	}
	if len(phases) != 2 || phases[0] != "streaming" || phases[1] != "completed" {
		t.Fatalf("phase 投影 = %v, want [streaming completed]", phases)
	}
	if h.dropped["turn_phase_illegal_transition"] == 0 || h.dropped["turn_phase_stale_revision"] == 0 ||
		h.dropped["turn_status_invalid_payload"] == 0 || h.dropped["turn_status_unknown_field"] == 0 {
		t.Fatalf("丢弃计数缺失: %+v", h.dropped)
	}
}

// TestSynthesizeTerminalPhaseDedupedByFence 覆盖终态兜底合成：旧桥无投影时
// 合成 completed；桥已投影终态时 fence 静默去重（不产生第二条）。
func TestSynthesizeTerminalPhaseDedupedByFence(t *testing.T) {
	h := newTestHandle(t)
	// 无任何桥投影：合成合法（queued → completed），产生 phase+activity 双事件。
	h.synthesizeTerminalPhase("end_turn")
	events := collectEvents(t, h)
	if len(events) != 2 {
		t.Fatalf("合成终态应产生 2 条事件，实际 %d", len(events))
	}
	if events[0].Type != adapter.EventTurnPhase || events[0].Payload["phase"] != "completed" {
		t.Fatalf("合成终态事件 = %+v", events[0])
	}

	// 桥已投影 completed：再合成 completed 被自环去重（无事件）；换 streaming
	// 则被 terminal fence 拒绝并计数——两种情况都不产生第二条终态事件。
	h2 := newTestHandle(t)
	pushTurnStatus(t, h2, `{"protocolVersion":1,"sessionId":"sess-phase","turnId":"1","step":1,"phase":"completed","revision":1,"reason":"turn_end"}`)
	initial := collectEvents(t, h2)
	if len(initial) != 2 {
		t.Fatalf("桥终态投影应产生 2 条事件，实际 %d", len(initial))
	}
	h2.phaseApply(h2.turnPhases.latestTurnID(), 0, TurnPhaseStreaming, TurnReasonFirstText, 0)
	events2 := collectEvents(t, h2)
	if len(events2) != 0 {
		t.Fatalf("终态去重/fence 后不应产生事件，实际 %v", events2)
	}
	if h2.dropped["turn_phase_illegal_transition"] == 0 {
		t.Fatalf("fence 拒绝应计数: %+v", h2.dropped)
	}
}
