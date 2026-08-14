package daemon

import (
	"context"
	"log/slog"
	"time"
)

// Transport 抽象 Daemon 与 Relay 的命令投递通道，便于测试替换。
type Transport interface {
	// Deliver 投递一条命令；返回 error 表示离线/失败。
	Deliver(ctx context.Context, cmd Command) error
}

// Supervisor 负责离线 outbox 重放：只在收到投递成功后才标记 delivered。
// 幂等由 request_id 保证，重连后不重复远端命令（SYNC-03）。
type Supervisor struct {
	store     *Store
	transport Transport
	logger    *slog.Logger
	interval  time.Duration
}

// NewSupervisor 构造 outbox 监督器。
func NewSupervisor(store *Store, transport Transport, logger *slog.Logger) *Supervisor {
	if logger == nil {
		logger = slog.Default()
	}
	return &Supervisor{store: store, transport: transport, logger: logger, interval: time.Second}
}

// Run 周期扫描 pending 并投递，直到 ctx 取消。
func (s *Supervisor) Run(ctx context.Context) {
	ticker := time.NewTicker(s.interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			s.replayOnce(ctx)
		}
	}
}

// ReplayOnce 执行一次重放，返回投递成功条数（测试可单次调用）。
func (s *Supervisor) ReplayOnce(ctx context.Context) int {
	return s.replayOnce(ctx)
}

func (s *Supervisor) replayOnce(ctx context.Context) int {
	pending, err := s.store.PendingCommands()
	if err != nil {
		s.logger.Error("daemon pending", "error", err)
		return 0
	}
	done := 0
	for _, cmd := range pending {
		if err := s.transport.Deliver(ctx, cmd); err != nil {
			// 离线/失败：保留 pending，等待下次重试，不标记失败以保持可重放。
			s.logger.Warn("daemon deliver deferred", "command", cmd.ID, "error", err)
			continue
		}
		if err := s.store.MarkDelivered(cmd.ID); err != nil {
			s.logger.Error("daemon mark delivered", "command", cmd.ID, "error", err)
			continue
		}
		done++
	}
	return done
}
