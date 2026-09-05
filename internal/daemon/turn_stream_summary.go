// 回合流式摘要日志（v0.8.7 V087-10，迭代计划 §3.6）：门禁 2（日志证明流式逐步
// 到达）的服务端佐证面。移动端埋点是门禁 2 的唯一判定源；本摘要让 daemon 本机
// 日志也能回答"这一回合上游真实产出了多少增量、跨度多久"。
//
// 语义冻结（迭代计划 v0.8.7 §3.6）：
//   - 只做回合级一条 Info（delta 条数 / 字符数 / 产出跨度 / 终态类型），
//     绝不逐 delta 打日志（噪声与体量不可控）；
//   - 累计与收敛都在事件泵单点 recordEventResult 内完成（调用方持有
//     eventSeqMu），与本机 seq 分配天然串行，无额外并发面；
//   - turn_completed / session_aborted 视为回合终态：有产出则输出摘要并清零；
//     事件流被回收（fwdCtx 取消）等无终态路径静默丢弃——半途数据不构成
//     完整回合证据；
//   - 计数只含元数据（条数 / rune 字符数 / 时刻），绝不记录正文内容，
//     与 last_event 摘要同一脱敏口径；
//   - 开关 AGENT_SESSIONS_TURN_STREAM_SUMMARY=0 关闭（回滚开关），默认开启。
package daemon

import (
	"os"
	"time"
	"unicode/utf8"

	"github.com/yubi233/agent-sessions/internal/adapter"
)

// TurnStreamSummaryEnv 是回合流式摘要日志的开关环境变量（"0" = 关闭）。
const TurnStreamSummaryEnv = "AGENT_SESSIONS_TURN_STREAM_SUMMARY"

// turnStreamSummary 累计单个会话当前回合的流式输出规模。
type turnStreamSummary struct {
	deltas  int
	chars   int
	firstAt time.Time
	lastAt  time.Time
}

// turnStreamSummaryEnabled 读回滚开关；缺省开启，显式 "0" 关闭。
func turnStreamSummaryEnabled() bool {
	return os.Getenv(TurnStreamSummaryEnv) != "0"
}

// noteTurnStreamEventLocked 在事件泵单点内累计/收敛回合流式规模。
// 调用方（recordEventResult）持有 eventSeqMu；本函数不做二次加锁。
func (r *SessionRunner) noteTurnStreamEventLocked(sessionID string, ev adapter.Event) {
	if r == nil || !r.streamSummaryEnabled {
		return
	}
	switch ev.Type {
	case adapter.EventTurnStarted:
		// 回合边界：新回合开始即丢弃上一回合未收敛的残留计数（正常路径终态
		// 已清零；这里是桥不产终态直接开下一回合时的卫生防线）。
		delete(r.turnStreams, sessionID)
	case adapter.EventMessageDelta, adapter.EventThoughtDelta:
		text, _ := ev.Payload["text"].(string)
		if r.turnStreams == nil {
			r.turnStreams = make(map[string]*turnStreamSummary)
		}
		summary := r.turnStreams[sessionID]
		if summary == nil {
			summary = &turnStreamSummary{}
			r.turnStreams[sessionID] = summary
		}
		summary.deltas++
		summary.chars += utf8.RuneCountInString(text)
		now := time.Now()
		if summary.firstAt.IsZero() {
			summary.firstAt = now
		}
		summary.lastAt = now
	case adapter.EventTurnCompleted, adapter.EventSessionAborted:
		summary, ok := r.turnStreams[sessionID]
		if !ok {
			return
		}
		delete(r.turnStreams, sessionID)
		if summary.deltas == 0 || r.logger == nil {
			return
		}
		r.logger.Info("回合流式摘要",
			"session_id", sessionID,
			"delta_events", summary.deltas,
			"delta_chars", summary.chars,
			"stream_span_ms", summary.lastAt.Sub(summary.firstAt).Milliseconds(),
			"terminal", string(ev.Type),
		)
	}
}

// resetTurnStreamSummary 在无终态的会话回收路径上静默丢弃半途累计，
// 防止上一回合未收敛的计数串进下一回合。
func (r *SessionRunner) resetTurnStreamSummary(sessionID string) {
	if r == nil {
		return
	}
	r.eventSeqMu.Lock()
	defer r.eventSeqMu.Unlock()
	delete(r.turnStreams, sessionID)
}
