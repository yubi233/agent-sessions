// 回合看门狗（v0.8.6 A①，迭代计划 §3.6）：回合受理后若执行端长时间不产出任何
// 事件，客户端会永久停留在"生成中"且没有任何失败事实（实机事故：dsh 会话发送
// 后 8 小时无终态）。看门狗在"沉默窗口"内未观察到任何 handle 事件时，由 daemon
// 产出脱敏 session_error + turn_completed(stop_reason=watchdog_timeout) 两条
// canonical 事实事件，把回合收敛为可见失败。
//
// 语义冻结（迭代计划 v0.8.6 §3.6，重试责任 2026-09-05 用户裁决归 dsh 桥）：
//   - 计时按"无任何事件"计，不按回合总时长：每个 handle 事件都会重置窗口，
//     因此慢回合（持续产出）不会误报；桥侧重试若发出可见事件同样会续命。
//   - 只在 send 受理后布防（回合在途）；终态事件 / 会话终止即撤防，空闲会话
//     没有计时器，不产生任何后台唤醒。
//   - 时限可配置（AGENT_SESSIONS_TURN_WATCHDOG_MS，默认 120000，0 = 关闭，
//     关闭即回滚到无看门狗行为）。
package daemon

import (
	"os"
	"strconv"
	"time"

	"github.com/yubi233/agent-sessions/internal/adapter"
)

// DefaultTurnWatchdogWindow 是看门狗的默认沉默窗口。取值依据：Zen 免费池
// 慢回合常见 30-60s（v0.8.1 #5 的轮询窗口即为此扩到 60s），翻倍留裕量；
// 超过 120s 毫无产出基本可判定执行端失联。
const DefaultTurnWatchdogWindow = 120 * time.Second

// TurnWatchdogWindowEnv 是看门狗沉默窗口的环境变量名（毫秒；0 = 关闭）。
const TurnWatchdogWindowEnv = "AGENT_SESSIONS_TURN_WATCHDOG_MS"

// turnWatchdogWindowFromEnv 解析环境变量配置；非法值回退默认，0 显式关闭。
func turnWatchdogWindowFromEnv() time.Duration {
	raw := os.Getenv(TurnWatchdogWindowEnv)
	if raw == "" {
		return DefaultTurnWatchdogWindow
	}
	ms, err := strconv.Atoi(raw)
	if err != nil || ms < 0 {
		return DefaultTurnWatchdogWindow
	}
	return time.Duration(ms) * time.Millisecond
}

// armTurnWatchdog 在回合受理（send/SendContent 成功）后布防。重复布防 = 重置
// 窗口；window<=0（显式关闭）时为 no-op，不创建任何计时器。
func (r *SessionRunner) armTurnWatchdog(sessionID string) {
	if r == nil || r.turnWatchdogWindow <= 0 {
		return
	}
	r.watchdogMu.Lock()
	defer r.watchdogMu.Unlock()
	if r.watchdogs == nil {
		r.watchdogs = make(map[string]*time.Timer)
	}
	if timer, ok := r.watchdogs[sessionID]; ok {
		timer.Reset(r.turnWatchdogWindow)
		return
	}
	sid := sessionID
	r.watchdogs[sessionID] = time.AfterFunc(r.turnWatchdogWindow, func() {
		r.fireTurnWatchdog(sid)
	})
}

// resetTurnWatchdog 在 handle 产出任意事件后续命。未布防（空闲会话）时为
// no-op——空闲沉默是正常状态，不产生计时器也不触发失败。
func (r *SessionRunner) resetTurnWatchdog(sessionID string) {
	if r == nil {
		return
	}
	r.watchdogMu.Lock()
	defer r.watchdogMu.Unlock()
	if timer, ok := r.watchdogs[sessionID]; ok && r.turnWatchdogWindow > 0 {
		timer.Reset(r.turnWatchdogWindow)
	}
}

// disarmTurnWatchdog 在回合终态 / 会话终止后撤防。必须幂等：终态、abort、
// kill、事件流关闭、handle 回收多个路径都会调用。
func (r *SessionRunner) disarmTurnWatchdog(sessionID string) {
	if r == nil {
		return
	}
	r.watchdogMu.Lock()
	defer r.watchdogMu.Unlock()
	if timer, ok := r.watchdogs[sessionID]; ok {
		timer.Stop()
		delete(r.watchdogs, sessionID)
	}
}

// fireTurnWatchdog 是沉默窗口到期的收敛出口：补发脱敏 session_error +
// turn_completed(stop_reason=watchdog_timeout)，与事件流提前关闭的既有收口
// （forwardEventsWithReplay）同型。只补一次：触发即撤防，迟到的 Provider 事件
// 由时间线序号自然吸收，不会造成双终态（重复 turn.completed 对客户端幂等）。
func (r *SessionRunner) fireTurnWatchdog(sessionID string) {
	r.disarmTurnWatchdog(sessionID)
	if r.logger != nil {
		r.logger.Warn("回合看门狗触发：沉默窗口内无任何执行端事件", "session_id", sessionID)
	}
	r.emitEvent(sessionID, adapter.Event{
		Type: adapter.EventSessionError,
		Payload: map[string]any{
			"instance_id": sessionID,
			// 脱敏文案：不携带上游地址/错误原文，细节只保留在本机桥日志。
			"message": "回合超时：执行端长时间无响应，请检查终端后重试。",
		},
	})
	r.emitEvent(sessionID, adapter.Event{
		Type: adapter.EventTurnCompleted,
		Payload: map[string]any{
			"instance_id": sessionID,
			"stop_reason": "watchdog_timeout",
		},
	})
}
