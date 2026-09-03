package dsh

import (
	"strings"
)

// TurnPhase 是 v0.8.4 冻结的回合级阶段（ADR-015 §2）。
// 它与 session 级状态（idle/active/stopped/errored/offline）正交：
// session 状态描述会话生命周期，TurnPhase 描述当前回合内的可观察活动。
type TurnPhase string

// TurnPhase 全部合法取值。completed/cancelled/failed 是不可继续增长的回合终态。
const (
	TurnPhaseQueued            TurnPhase = "queued"
	TurnPhasePreparing         TurnPhase = "preparing"
	TurnPhaseThinking          TurnPhase = "thinking"
	TurnPhaseStreaming         TurnPhase = "streaming"
	TurnPhaseToolRunning       TurnPhase = "tool_running"
	TurnPhaseWaitingPermission TurnPhase = "waiting_permission"
	TurnPhaseWaitingQuestion   TurnPhase = "waiting_question"
	TurnPhaseFinishing         TurnPhase = "finishing"
	TurnPhaseCancelling        TurnPhase = "cancelling"
	TurnPhaseCompleted         TurnPhase = "completed"
	TurnPhaseCancelled         TurnPhase = "cancelled"
	TurnPhaseFailed            TurnPhase = "failed"
)

// turnPhaseTransitions 是 ADR-015 §2.1 冻结的合法转换表（源 → 合法目标集合）。
// 关键裁决：
//   - 首个文本 chunk 之后 phase 进入 streaming，后续 thought delta 不回退 thinking
//     （thinking → streaming 是单向的，解决 raw 模式下 thought/text 交错的歧义）；
//   - waiting_permission/waiting_question 可从任意 active phase 进入，解除后由
//     后续事件自然驱动回 active phase，不记录"前一相位"；
//   - finishing → streaming 允许回退（迟到的文本 chunk 说明模型并未结束）；
//   - cancelling 的终态可以是 cancelled，也可能是 completed（取消竞态中回合先完成）；
//   - 终态（completed/cancelled/failed）没有出边（terminal fence）。
var turnPhaseTransitions = map[TurnPhase]map[TurnPhase]bool{
	TurnPhaseQueued: {
		TurnPhasePreparing: true, TurnPhaseCancelling: true,
		// queued → completed：旧桥没有 phase 投影时，adapter 直接以 prompt 响应
		// 合成权威终态（兜底路径），不允许客户端停留在生成中。
		TurnPhaseCompleted: true, TurnPhaseFailed: true,
	},
	TurnPhasePreparing: {
		TurnPhaseThinking: true, TurnPhaseStreaming: true, TurnPhaseToolRunning: true,
		TurnPhaseWaitingPermission: true, TurnPhaseWaitingQuestion: true,
		TurnPhaseFinishing: true, TurnPhaseCancelling: true,
		TurnPhaseCompleted: true, TurnPhaseCancelled: true, TurnPhaseFailed: true,
	},
	TurnPhaseThinking: {
		TurnPhaseStreaming: true, TurnPhaseToolRunning: true,
		TurnPhaseWaitingPermission: true, TurnPhaseWaitingQuestion: true,
		TurnPhaseFinishing: true, TurnPhaseCancelling: true,
		TurnPhaseCompleted: true, TurnPhaseCancelled: true, TurnPhaseFailed: true,
	},
	TurnPhaseStreaming: {
		TurnPhaseToolRunning:       true,
		TurnPhaseWaitingPermission: true, TurnPhaseWaitingQuestion: true,
		TurnPhaseFinishing: true, TurnPhaseCancelling: true,
		TurnPhaseCompleted: true, TurnPhaseCancelled: true, TurnPhaseFailed: true,
	},
	TurnPhaseToolRunning: {
		TurnPhaseThinking: true, TurnPhaseStreaming: true, TurnPhaseToolRunning: true,
		TurnPhaseWaitingPermission: true, TurnPhaseWaitingQuestion: true,
		TurnPhaseFinishing: true, TurnPhaseCancelling: true,
		TurnPhaseCompleted: true, TurnPhaseCancelled: true, TurnPhaseFailed: true,
	},
	TurnPhaseWaitingPermission: {
		TurnPhaseThinking: true, TurnPhaseStreaming: true, TurnPhaseToolRunning: true,
		TurnPhaseFinishing: true, TurnPhaseCancelling: true,
		TurnPhaseCompleted: true, TurnPhaseCancelled: true, TurnPhaseFailed: true,
	},
	TurnPhaseWaitingQuestion: {
		TurnPhaseThinking: true, TurnPhaseStreaming: true, TurnPhaseToolRunning: true,
		TurnPhaseFinishing: true, TurnPhaseCancelling: true,
		TurnPhaseCompleted: true, TurnPhaseCancelled: true, TurnPhaseFailed: true,
	},
	TurnPhaseFinishing: {
		TurnPhaseStreaming: true, TurnPhaseCompleted: true, TurnPhaseFailed: true, TurnPhaseCancelling: true,
	},
	TurnPhaseCancelling: {
		TurnPhaseCompleted: true, TurnPhaseCancelled: true, TurnPhaseFailed: true,
	},
	// 终态：terminal fence，无出边。
	TurnPhaseCompleted: {},
	TurnPhaseCancelled: {},
	TurnPhaseFailed:    {},
}

// IsTerminalTurnPhase 报告 phase 是否为回合终态。终态之后不再接受任何转换。
func IsTerminalTurnPhase(phase TurnPhase) bool {
	switch phase {
	case TurnPhaseCompleted, TurnPhaseCancelled, TurnPhaseFailed:
		return true
	default:
		return false
	}
}

// ParseTurnPhase 解析桥/协议侧的 phase 字符串。未知值 fail-closed 返回 false，
// 调用方必须丢弃计数，绝不映射为近似相位（ADR-015 §2.1）。
func ParseTurnPhase(value string) (TurnPhase, bool) {
	phase := TurnPhase(strings.TrimSpace(value))
	if phase == "" {
		return "", false
	}
	_, ok := turnPhaseTransitions[phase]
	return phase, ok
}

// TurnPhaseReason 是 dsh/turn/status 中 reason 字段的白名单取值（ADR-015 §3 冻结）。
// 白名单外的 reason 视为畸形帧丢弃计数，不进入 canonical 事件。
type TurnPhaseReason string

// reason 白名单。每条对应桥侧一个明确的观测事实。
const (
	TurnReasonQueued          TurnPhaseReason = "turn_queued"
	TurnReasonStart           TurnPhaseReason = "turn_start"
	TurnReasonFirstThought    TurnPhaseReason = "first_thought_delta"
	TurnReasonFirstText       TurnPhaseReason = "first_text_delta"
	TurnReasonToolOpen        TurnPhaseReason = "tool_open"
	TurnReasonToolClose       TurnPhaseReason = "tool_close"
	TurnReasonPermissionReq   TurnPhaseReason = "permission_request"
	TurnReasonPermissionDone  TurnPhaseReason = "permission_resolved"
	TurnReasonQuestionReq     TurnPhaseReason = "question_request"
	TurnReasonQuestionDone    TurnPhaseReason = "question_resolved"
	TurnReasonModelOutputEnd  TurnPhaseReason = "model_output_end"
	TurnReasonCancelRequested TurnPhaseReason = "cancel_requested"
	TurnReasonTurnEnd         TurnPhaseReason = "turn_end"
	TurnReasonTurnFailed      TurnPhaseReason = "turn_failed"
	TurnReasonTurnCancelled   TurnPhaseReason = "turn_cancelled"
)

// IsValidTurnPhaseReason 校验 reason 是否在冻结白名单内。
func IsValidTurnPhaseReason(value string) bool {
	switch TurnPhaseReason(strings.TrimSpace(value)) {
	case TurnReasonQueued, TurnReasonStart, TurnReasonFirstThought, TurnReasonFirstText,
		TurnReasonToolOpen, TurnReasonToolClose, TurnReasonPermissionReq, TurnReasonPermissionDone,
		TurnReasonQuestionReq, TurnReasonQuestionDone, TurnReasonModelOutputEnd,
		TurnReasonCancelRequested, TurnReasonTurnEnd, TurnReasonTurnFailed, TurnReasonTurnCancelled:
		return true
	default:
		return false
	}
}

// dshTurnStatusLimits 是 dsh/turn/status 帧的字段大小上限（ADR-015 §3 冻结）。
// 超限帧按畸形丢弃计数，防止桥侧异常数据挤占事件通道。
const (
	dshTurnStatusTurnIDLimit  = 128
	dshTurnStatusPhaseLimit   = 64
	dshTurnStatusReasonLimit  = 64
	dshTurnStatusSummaryLimit = 200
)

// TurnPhaseMachine 是单个回合的相位状态机：持有当前相位与单调 revision，
// 以冻结转换表校验每次变更。它被 mapper/读循环用于校验桥的 dsh/turn/status
// 投影，也可由 adapter 侧合成兜底终态；同一 session 的每个 turnId 一个实例。
// 非并发安全：调用方负责串行化（读循环单 goroutine 内使用）。
type TurnPhaseMachine struct {
	phase    TurnPhase
	revision int64
	seen     bool // 尚未收到任何合法帧时允许 queued/preparing 直接初始化
}

// NewTurnPhaseMachine 以隐式 queued 起点构造状态机；首个合法帧把回合带入活动态。
func NewTurnPhaseMachine() *TurnPhaseMachine {
	return &TurnPhaseMachine{phase: TurnPhaseQueued}
}

// Current 返回当前相位与已推进到的 revision。
func (m *TurnPhaseMachine) Current() (TurnPhase, int64) {
	return m.phase, m.revision
}

// Apply 校验一次相位变更：合法则推进 revision 并返回新相位（ok=true）；
// 非法转换 / terminal fence / 同相位自环返回 ok=false。同相位自环是 no-op 去重，
// 不推进 revision 也不算违规；terminal 后的一切变更都被 fence 拒绝。
func (m *TurnPhaseMachine) Apply(next TurnPhase) (TurnPhase, bool) {
	if IsTerminalTurnPhase(m.phase) {
		// terminal fence：终态后拒绝一切转换，revision 不再推进。
		return m.phase, false
	}
	if _, legal := turnPhaseTransitions[m.phase][next]; !legal {
		return m.phase, false
	}
	if next == m.phase {
		// 同相位自环：no-op 去重，revision 不变（ADR-015 §2.1）。
		return m.phase, false
	}
	m.phase = next
	m.revision++
	m.seen = true
	return m.phase, true
}
