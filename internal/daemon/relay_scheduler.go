package daemon

// v0.8.9 P3（迭代计划 §3.4）：SSE reader 与命令执行解耦的调度器。
//
// 职责边界（§5 P3 验收）：
//   - scanner（Stream 的 consume=handleDelivery）只做「解码 → 落盘 relay_commands →
//     推进已落盘 cursor → received 回执 → 入队」；不调用 Provider、Resolve、事件上传，
//     不长时间持锁——SSE reader 不再被业务执行队头阻塞（故障链二根因）。
//   - 普通 worker 串行消费普通命令（保持既有"同一 Daemon 命令兑现串行化"语义）；
//     session.send 仍走 executeSendAsync（一个回合可占用 Provider 整个世代）。
//   - 控制 worker 独立消费控制优先队列：permission.approve/reject、session.abort、
//     question.answer 与 rejecting 重放——不等待普通 worker 的 executionMu（V089-10）。
//   - processMu 只保护状态扫描与去重标记，不覆盖网络请求或 Provider 执行。
//   - worker 生命周期绑定 RunWithRetry：返回（含 ErrRelayGenerationChanged 终态与
//     shutdown）时统一取消；断线重连不影响已入队命令（行已落盘，幂等去重兜底）。

import (
	"context"
	"log/slog"
	"sync"
	"sync/atomic"
	"time"
)

// dispatchItem 是队列中的最小调度单元；enqueuedAt 只用于控制等待时延指标（脱敏）。
type dispatchItem struct {
	command    RelayCommand
	enqueuedAt time.Time
}

// isControlCommandKind 判定控制优先队列成员（§3.4）。
// rejecting 状态行（rejected 回执重放）也走控制队列：它是快速协议重放，
// 不应排在慢 Provider 命令之后。
func isControlCommandKind(kind string) bool {
	switch kind {
	case "permission.approve", "permission.reject", "session.abort", "question.answer":
		return true
	}
	return false
}

// dispatchCommand 把一条命令加入调度队列（去重 + 非阻塞）。
// 已在队/处理中的命令直接跳过（command ID 是执行去重键，与 durable 行一致）。
func (l *RelayLoop) dispatchCommand(command RelayCommand) {
	l.schedMu.Lock()
	if l.dispatched == nil {
		l.dispatched = make(map[string]time.Time)
	}
	if _, exists := l.dispatched[command.CommandID]; exists {
		l.schedMu.Unlock()
		return
	}
	item := dispatchItem{command: command, enqueuedAt: time.Now()}
	if isControlCommandKind(command.Kind) || command.Status == "rejecting" {
		l.controlQueue = append(l.controlQueue, item)
		l.schedMu.Unlock()
		// 每队列独立唤醒通道（缓冲 1）：避免共享令牌被另一 worker 抢走造成
		// 丢失唤醒、命令滞留队列。非阻塞投递；已有多枚待处理令牌时丢弃本次。
		select {
		case l.controlWake <- struct{}{}:
		default:
		}
	} else {
		l.normalQueue = append(l.normalQueue, item)
		l.schedMu.Unlock()
		select {
		case l.normalWake <- struct{}{}:
		default:
		}
	}
}

// popCommand 从指定队列弹出队头；control=true 优先弹控制队列。
// 控制命令的等待时延在弹出时记录（脱敏毫秒值）。
func (l *RelayLoop) popCommand(control bool) (dispatchItem, bool) {
	l.schedMu.Lock()
	defer l.schedMu.Unlock()
	var queue *[]dispatchItem
	if control {
		queue = &l.controlQueue
	} else {
		queue = &l.normalQueue
	}
	if len(*queue) == 0 {
		return dispatchItem{}, false
	}
	item := (*queue)[0]
	*queue = (*queue)[1:]
	delete(l.dispatched, item.command.CommandID)
	if control {
		waitMS := time.Since(item.enqueuedAt).Milliseconds()
		l.lastControlWaitMS.Store(waitMS)
		l.processedControl.Add(1)
	} else {
		l.processedNormal.Add(1)
	}
	return item, true
}

// queuesSettled 报告队列与在队标记是否全部清空（processPending 兼容等待用；
// 不含 in-flight async send——既有语义不等待整回合 send 完成）。
func (l *RelayLoop) queuesSettled() bool {
	l.schedMu.Lock()
	defer l.schedMu.Unlock()
	return len(l.normalQueue) == 0 && len(l.controlQueue) == 0 && len(l.dispatched) == 0
}

// schedulersRunning 报告 worker 是否已由 RunWithRetry 启动。
func (l *RelayLoop) schedulersRunning() bool {
	l.schedMu.Lock()
	defer l.schedMu.Unlock()
	return l.schedulersStarted
}

// startSchedulers 启动普通/控制 worker（幂等）。ctx 取消时 worker 退出；
// 正在执行中的命令自然收尾（其行状态已落盘，重启后由既有恢复语义兜底）。
func (l *RelayLoop) startSchedulers(ctx context.Context) {
	l.schedMu.Lock()
	if l.schedulersStarted {
		l.schedMu.Unlock()
		return
	}
	l.schedulersStarted = true
	l.schedMu.Unlock()
	go l.workerLoop(ctx, false)
	go l.workerLoop(ctx, true)
	if l.Logger != nil {
		l.Logger.Info("relay command scheduler started", "normal_workers", 1, "control_workers", 1)
	}
}

// workerLoop 是单个 worker 的主循环：唤醒后排空自己的队列。
// 执行上下文用 commandExecutionContext（优先 commandCtx）——与既有 async send 一致，
// 已接受命令在 SSE 短暂重连期间继续执行，不脱离当前 loop context（§5 P3-4）。
func (l *RelayLoop) workerLoop(ctx context.Context, control bool) {
	var wake chan struct{}
	if control {
		wake = l.controlWake
	} else {
		wake = l.normalWake
	}
	for {
		select {
		case <-ctx.Done():
			return
		case <-wake:
		}
		for {
			if ctx.Err() != nil {
				return
			}
			item, ok := l.popCommand(control)
			if !ok {
				break
			}
			execCtx := l.commandExecutionContext(ctx)
			if err := l.processOneCommand(execCtx, item.command); err != nil {
				if l.Logger != nil {
					l.Logger.Warn("daemon command scheduling pass failed; row stays durable for sweeper retry",
						"command", item.command.CommandID, "kind", item.command.Kind, "queue", queueName(control), "error", err)
				}
			}
			// 处理完即触发 outbox 冲刷（事件/usage 上行不被 heartbeat 周期阻塞）。
			select {
			case l.eventWake <- struct{}{}:
			default:
			}
		}
	}
}

func queueName(control bool) string {
	if control {
		return "control"
	}
	return "normal"
}

// drainQueuesInline 是调度器未启动时（测试/手工构造 RelayLoop）的同步执行路径：
// 控制队列优先、普通队列随后，循环排空为止，保持与旧 processPending 相同的
// 逐条串行语义。生产路径不进入本函数。
func (l *RelayLoop) drainQueuesInline(ctx context.Context) error {
	for {
		item, ok := l.popCommand(true)
		if !ok {
			item, ok = l.popCommand(false)
		}
		if !ok {
			break
		}
		if err := ctx.Err(); err != nil {
			return err
		}
		if err := l.processOneCommand(l.commandExecutionContext(ctx), item.command); err != nil {
			return err
		}
	}
	return l.flushOutboxes(ctx)
}

// RelaySchedulerStats 是调度器的脱敏可观测性投影：只含深度/计数/时延，
// 不含命令正文、payload、路径或密钥（V089-15 口径）。
type RelaySchedulerStats struct {
	NormalQueueDepth     int   `json:"normal_queue_depth"`
	ControlQueueDepth    int   `json:"control_queue_depth"`
	DispatchedCount      int   `json:"dispatched"`
	InFlightSends        int   `json:"in_flight_sends"`
	ReaderLastReadUnixMS int64 `json:"reader_last_read_unix_ms"`
	ProcessedNormal      int64 `json:"processed_normal"`
	ProcessedControl     int64 `json:"processed_control"`
	LastControlWaitMS    int64 `json:"last_control_wait_ms"`
}

// stats 汇总当前调度器指标。
func (l *RelayLoop) stats() RelaySchedulerStats {
	l.schedMu.Lock()
	normal, control, dispatched := len(l.normalQueue), len(l.controlQueue), len(l.dispatched)
	l.schedMu.Unlock()
	l.inFlightMu.Lock()
	inFlight := len(l.inFlightSends)
	l.inFlightMu.Unlock()
	return RelaySchedulerStats{
		NormalQueueDepth:     normal,
		ControlQueueDepth:    control,
		DispatchedCount:      dispatched,
		InFlightSends:        inFlight,
		ReaderLastReadUnixMS: l.readerLastRead.Load(),
		ProcessedNormal:      l.processedNormal.Load(),
		ProcessedControl:     l.processedControl.Load(),
		LastControlWaitMS:    l.lastControlWaitMS.Load(),
	}
}

// logSchedulerStats 输出脱敏调度器指标（heartbeat 周期调用；Debug 级别避免噪音）。
func (l *RelayLoop) logSchedulerStats(logger *slog.Logger) {
	stats := l.stats()
	logger.Debug("relay scheduler stats",
		"normal_queue_depth", stats.NormalQueueDepth,
		"control_queue_depth", stats.ControlQueueDepth,
		"in_flight_sends", stats.InFlightSends,
		"reader_last_read_unix_ms", stats.ReaderLastReadUnixMS,
		"processed_normal", stats.ProcessedNormal,
		"processed_control", stats.ProcessedControl,
		"last_control_wait_ms", stats.LastControlWaitMS)
}

// 编译期防呆：确保调度器字段与 RelayLoop 同包同型。
var _ = sync.Mutex{}
var _ = atomic.Int64{}
