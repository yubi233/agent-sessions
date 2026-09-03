package dsh

import "testing"

// V084-01：TurnPhase 状态转换、非法转换、terminal fence、reason 白名单与
// 未知值 fail-closed（ADR-015 §2 冻结表的守护回归）。

// TestTurnPhaseHappyPath 覆盖一条完整回合的主干转换链：
// queued → preparing → thinking → streaming → tool_running → streaming → finishing → completed。
func TestTurnPhaseHappyPath(t *testing.T) {
	m := NewTurnPhaseMachine()
	path := []TurnPhase{
		TurnPhasePreparing, TurnPhaseThinking, TurnPhaseStreaming,
		TurnPhaseToolRunning, TurnPhaseStreaming, TurnPhaseFinishing, TurnPhaseCompleted,
	}
	revision := int64(0)
	for _, next := range path {
		got, ok := m.Apply(next)
		if !ok || got != next {
			t.Fatalf("transition to %q rejected: got=%q ok=%v", next, got, ok)
		}
		revision++
		if _, rev := m.Current(); rev != revision {
			t.Fatalf("revision = %d, want %d", rev, revision)
		}
	}
}

// TestTurnPhaseIllegalTransitions 覆盖冻结表中明确禁止的回退与跳跃转换。
func TestTurnPhaseIllegalTransitions(t *testing.T) {
	cases := []struct {
		name string
		path []TurnPhase // 前缀建立源相位，最后一个元素必须被拒绝
	}{
		{"queued 不能直接 streaming", []TurnPhase{TurnPhaseStreaming}},
		{"thinking 不能回退 preparing", []TurnPhase{TurnPhasePreparing, TurnPhaseThinking, TurnPhasePreparing}},
		{"streaming 不能回退 thinking（首文本后 thought 不回退相位）", []TurnPhase{TurnPhasePreparing, TurnPhaseThinking, TurnPhaseStreaming, TurnPhaseThinking}},
		{"streaming 不能回退 preparing", []TurnPhase{TurnPhasePreparing, TurnPhaseStreaming, TurnPhasePreparing}},
		{"cancelling 不能回到 streaming", []TurnPhase{TurnPhasePreparing, TurnPhaseCancelling, TurnPhaseStreaming}},
		{"finishing 不能进入 tool_running", []TurnPhase{TurnPhasePreparing, TurnPhaseFinishing, TurnPhaseToolRunning}},
		{"queued 不能直接 tool_running", []TurnPhase{TurnPhaseToolRunning}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			m := NewTurnPhaseMachine()
			for _, next := range tc.path[:len(tc.path)-1] {
				if _, ok := m.Apply(next); !ok {
					t.Fatalf("prefix transition to %q should be legal", next)
				}
			}
			source, _ := m.Current()
			got, ok := m.Apply(tc.path[len(tc.path)-1])
			if ok {
				t.Fatalf("illegal transition %q → %q was accepted", source, tc.path[len(tc.path)-1])
			}
			if got != source {
				t.Fatalf("rejected transition mutated phase: %q → %q", source, got)
			}
		})
	}
}

// TestTurnPhaseTerminalFence 覆盖终态后的一切转换都被拒绝（terminal fence）。
func TestTurnPhaseTerminalFence(t *testing.T) {
	terminals := []TurnPhase{TurnPhaseCompleted, TurnPhaseCancelled, TurnPhaseFailed}
	attempts := []TurnPhase{
		TurnPhasePreparing, TurnPhaseThinking, TurnPhaseStreaming, TurnPhaseToolRunning,
		TurnPhaseWaitingPermission, TurnPhaseWaitingQuestion, TurnPhaseFinishing,
		TurnPhaseCancelling, TurnPhaseCompleted, TurnPhaseCancelled, TurnPhaseFailed,
	}
	for _, terminal := range terminals {
		for _, attempt := range attempts {
			m := NewTurnPhaseMachine()
			// preparing → terminal 是合法进入终态的路径。
			if _, ok := m.Apply(TurnPhasePreparing); !ok {
				t.Fatalf("entering preparing should be legal")
			}
			if _, ok := m.Apply(terminal); !ok {
				t.Fatalf("entering terminal %q should be legal", terminal)
			}
			_, revBefore := m.Current()
			got, ok := m.Apply(attempt)
			if ok || got != terminal {
				t.Fatalf("terminal fence broken: %q → %q accepted=%v", terminal, attempt, ok)
			}
			if _, rev := m.Current(); rev != revBefore {
				t.Fatalf("terminal fence advanced revision: %d → %d", revBefore, rev)
			}
		}
	}
}

// TestTurnPhaseWaitingInteractions 覆盖权限/问题等待与解除后的相位驱动：
// 任意 active phase 可进入等待相位，解除后由后续事件回到 active phase。
func TestTurnPhaseWaitingInteractions(t *testing.T) {
	m := NewTurnPhaseMachine()
	for _, next := range []TurnPhase{TurnPhasePreparing, TurnPhaseStreaming, TurnPhaseWaitingPermission} {
		if _, ok := m.Apply(next); !ok {
			t.Fatalf("transition to %q should be legal", next)
		}
	}
	// 权限解除后工具继续执行。
	if _, ok := m.Apply(TurnPhaseToolRunning); !ok {
		t.Fatalf("waiting_permission → tool_running should be legal")
	}
	// 工具执行中弹出结构化问题。
	if _, ok := m.Apply(TurnPhaseWaitingQuestion); !ok {
		t.Fatalf("tool_running → waiting_question should be legal")
	}
	if _, ok := m.Apply(TurnPhaseFinishing); !ok {
		t.Fatalf("waiting_question → finishing should be legal")
	}
}

// TestTurnPhaseCancelRace 覆盖取消竞态：cancelling 之后回合可能以 cancelled
// 收口，也可能先完成（completed 是真实终态）。
func TestTurnPhaseCancelRace(t *testing.T) {
	m := NewTurnPhaseMachine()
	for _, next := range []TurnPhase{TurnPhasePreparing, TurnPhaseStreaming, TurnPhaseCancelling} {
		if _, ok := m.Apply(next); !ok {
			t.Fatalf("transition to %q should be legal", next)
		}
	}
	if _, ok := m.Apply(TurnPhaseCancelled); !ok {
		t.Fatalf("cancelling → cancelled should be legal")
	}

	m2 := NewTurnPhaseMachine()
	for _, next := range []TurnPhase{TurnPhasePreparing, TurnPhaseCancelling, TurnPhaseCompleted} {
		if _, ok := m2.Apply(next); !ok {
			t.Fatalf("transition to %q should be legal in cancel race", next)
		}
	}
}

// TestTurnPhaseSelfLoopDedup 覆盖同相位自环去重：不推进 revision、不算违规。
func TestTurnPhaseSelfLoopDedup(t *testing.T) {
	m := NewTurnPhaseMachine()
	if _, ok := m.Apply(TurnPhasePreparing); !ok {
		t.Fatalf("preparing should be legal")
	}
	_, revBefore := m.Current()
	got, ok := m.Apply(TurnPhasePreparing)
	if ok || got != TurnPhasePreparing {
		t.Fatalf("self loop should be a rejected no-op, got ok=%v phase=%q", ok, got)
	}
	if _, rev := m.Current(); rev != revBefore {
		t.Fatalf("self loop advanced revision: %d → %d", revBefore, rev)
	}
}

// TestParseTurnPhaseUnknownFailClosed 覆盖未知/空 phase 字符串 fail-closed。
func TestParseTurnPhaseUnknownFailClosed(t *testing.T) {
	for _, value := range []string{"", "  ", "running", "STREAMING", "generated", "unknown"} {
		if _, ok := ParseTurnPhase(value); ok {
			t.Fatalf("ParseTurnPhase(%q) should be rejected", value)
		}
	}
	for _, value := range []string{"queued", "preparing", "thinking", "streaming", "tool_running",
		"waiting_permission", "waiting_question", "finishing", "cancelling", "completed", "cancelled", "failed"} {
		if _, ok := ParseTurnPhase(value); !ok {
			t.Fatalf("ParseTurnPhase(%q) should be accepted", value)
		}
	}
}

// TestTurnPhaseReasonWhitelist 覆盖 reason 白名单：白名单外一律拒绝。
func TestTurnPhaseReasonWhitelist(t *testing.T) {
	for _, reason := range []string{"turn_queued", "turn_start", "first_thought_delta", "first_text_delta",
		"tool_open", "tool_close", "permission_request", "permission_resolved", "question_request",
		"question_resolved", "model_output_end", "cancel_requested", "turn_end", "turn_failed", "turn_cancelled"} {
		if !IsValidTurnPhaseReason(reason) {
			t.Fatalf("reason %q should be whitelisted", reason)
		}
	}
	for _, reason := range []string{"", "model_output", "secret", "思考中", "chunk", "unknown"} {
		if IsValidTurnPhaseReason(reason) {
			t.Fatalf("reason %q should NOT be whitelisted", reason)
		}
	}
}

// TestTurnPhaseLegacyFallback 覆盖旧客户端 fallback 语义的根因层：
// 状态机本身从不产生 phase 事件——只有协商后的 dsh/turn/status 帧才驱动它，
// 因此未协商的客户端天然收不到 phase 投影（fail-closed 的结构性保证）。
func TestTurnPhaseLegacyFallback(t *testing.T) {
	// 未收到任何帧的机器停留在隐式 queued，revision=0。
	m := NewTurnPhaseMachine()
	phase, revision := m.Current()
	if phase != TurnPhaseQueued || revision != 0 {
		t.Fatalf("fresh machine = %q rev=%d, want queued rev=0", phase, revision)
	}
	// 终态兜底合成（prompt 响应）允许从隐式起点直接进入，保证没有桥投影时
	// 客户端仍能收到权威终态，不会永远停留在生成中。
	if _, ok := m.Apply(TurnPhaseCompleted); !ok {
		t.Fatalf("synthesized terminal from implicit queued should be legal")
	}
}
