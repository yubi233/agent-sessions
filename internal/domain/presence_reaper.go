package domain

import (
	"context"
	"log/slog"
	"sync"
	"time"

	"github.com/yubi233/agent-sessions/internal/store"
)

// PresenceReaper 是有界的 presence 过期投影器（v0.9.1 P1，计划 §3.3 / §4 P1）。
//
// 职责边界（裁决冻结）：
//   - read path / command path 已经按服务端时间即时投影 availability，reaper 不承担
//     安全正确性：它只负责「过期转换的通知与持久投影」，让 invalidation 及早到达、
//     让 legacy status 列及时翻转（V091-03 证明了没有 reaper 读取也正确）；
//   - 单次扫描有界（BatchLimit），超出部分留到下一 tick，避免大规模失联时打爆 DB；
//   - 丢唤醒可自愈：每个 tick 都以「服务端时间 vs last_heartbeat」重算，错过某次
//     边界的转换会在后续 tick 或读取路径补齐，最终事实不丢；
//   - 多 Terminal 隔离：单个 Terminal 投影/发布失败不影响同批其他 Terminal。
//
// 资源生命周期：Run 阻塞在 ticker 与 stop 之间；Stop 幂等并等待 goroutine 退出，
// 保证停止后无 ticker/goroutine 泄漏（V091-07）。
type PresenceReaper struct {
	repo store.Repository
	hub  *PresenceHub
	// Presence 是过期判定阈值（与列表投影/命令门控同源；测试可注入收缩值）。
	Presence PresencePolicy
	// now 支持测试注入服务端时钟。
	now func() time.Time
	// Interval 是扫描周期；BatchLimit 是单次扫描最大 Terminal 数（有界扫描）。
	Interval   time.Duration
	BatchLimit int

	logger *slog.Logger

	stopOnce sync.Once
	stop     chan struct{}
	done     chan struct{}
}

// NewPresenceReaper 构造 presence reaper。hub 可为 nil（只做持久投影，不发布通知）。
func NewPresenceReaper(repo store.Repository, hub *PresenceHub, logger *slog.Logger) *PresenceReaper {
	if logger == nil {
		logger = slog.Default()
	}
	return &PresenceReaper{
		repo:       repo,
		hub:        hub,
		Presence:   DefaultPresencePolicy(),
		now:        time.Now,
		Interval:   10 * time.Second,
		BatchLimit: 200,
		logger:     logger,
		stop:       make(chan struct{}),
		done:       make(chan struct{}),
	}
}

// PresenceSweepSummary 是单次扫描的脱敏计数摘要（不含 Terminal ID / 路径 / 正文）。
type PresenceSweepSummary struct {
	Scanned      int // 本批检查的候选数
	Transitioned int // 发生投影转换并持久化的数量
	Published    int // 成功发布 invalidation 的数量
}

// Run 阻塞运行扫描循环；每个 tick 执行一次有界 SweepOnce。Stop 后返回。
func (r *PresenceReaper) Run() {
	defer close(r.done)
	ticker := time.NewTicker(r.Interval)
	defer ticker.Stop()
	for {
		select {
		case <-r.stop:
			return
		case <-ticker.C:
			ctx, cancel := context.WithTimeout(context.Background(), r.Interval)
			summary, err := r.SweepOnce(ctx)
			cancel()
			if err != nil {
				// 扫描失败不中断循环：下一 tick 重算即可自愈。
				r.logger.Warn("presence reaper sweep failed", "error", err)
			} else if summary.Transitioned > 0 {
				r.logger.Info("presence reaper sweep",
					"scanned", summary.Scanned, "transitioned", summary.Transitioned)
			}
		}
	}
}

// Stop 幂等停止扫描循环并等待 goroutine 退出（资源释放契约，V091-07）。
func (r *PresenceReaper) Stop() {
	r.stopOnce.Do(func() {
		close(r.stop)
	})
	<-r.done
}

// SweepOnce 执行一次有界扫描：候选 -> 以服务端时间重算投影 -> 与持久投影不同则
// 持久化（offline 同步 legacy status；unknown 不降级）并发布 invalidation。
// 单个 Terminal 失败记日志并继续下一个（多 Terminal 隔离）。
func (r *PresenceReaper) SweepOnce(ctx context.Context) (PresenceSweepSummary, error) {
	summary := PresenceSweepSummary{}
	nowMS := r.now().UnixMilli()
	candidates, err := r.repo.ListPresenceSweepCandidates(
		ctx,
		nowMS-r.Presence.SuspectWindow.Milliseconds(),
		nowMS-r.Presence.OfflineDeadline.Milliseconds(),
		r.BatchLimit)
	if err != nil {
		return summary, err
	}
	summary.Scanned = len(candidates)
	for _, row := range candidates {
		derived := r.Presence.Project(row, nowMS)
		// unsupported/online 不是时间驱动的过期转换：unsupported 属协议事实，
		// online 说明活性已恢复（心跳必然先到达并写回投影），均跳过。
		if derived != PresenceUnknown && derived != PresenceOffline {
			continue
		}
		setStatus := ""
		if derived == PresenceOffline {
			setStatus = "offline"
		}
		revision, changed, err := r.repo.PersistPresenceProjection(ctx, row.ID, string(derived), setStatus)
		if err != nil {
			r.logger.Warn("presence reaper persist projection failed", "error", err)
			continue
		}
		if !changed {
			continue
		}
		summary.Transitioned++
		if r.hub != nil {
			r.hub.PublishPresenceInvalidation(row.AccountID, PresenceInvalidation{
				TerminalID: row.ID, Availability: string(derived), PresenceRevision: revision,
			})
			summary.Published++
		}
	}
	return summary, nil
}
