package domain

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"time"

	"github.com/yubi233/agent-sessions/internal/id"
	"github.com/yubi233/agent-sessions/internal/store"
	"github.com/yubi233/agent-sessions/packages/protocol"
)

// 命令状态常量。accepted 之后才允许 running。
const (
	CommandAccepted  = "accepted"
	CommandRunning   = "running"
	CommandSucceeded = "succeeded"
	CommandFailed    = "failed"
	CommandCancelled = "cancelled"
	CommandRejected  = "rejected"
	CommandExpired   = "expired"
)

// 会话状态常量。
const (
	SessionIdle    = "idle"
	SessionRunning = "running"
	SessionStopped = "stopped"
)

// 领域实时同步错误，映射到协议稳定错误码。
var (
	ErrSessionNotFound   = errors.New("session not found")
	ErrLeaseConflict     = errors.New("lease conflict")
	ErrTargetStale       = errors.New("target instance stale")
	ErrIdempotencyUsed   = errors.New("idempotency key already used")
	ErrTerminalOffline   = errors.New("terminal offline")
	ErrWorkspaceNotFound = errors.New("workspace not found")
	ErrScopeDenied       = errors.New("scope denied")
	ErrAlreadyResolved   = errors.New("command already resolved")
)

// CommandInput 是一次异步控制请求的规范化输入。
type CommandInput struct {
	AccountID        string
	DeviceID         string
	Role             string
	SessionID        string
	Kind             string
	IdempotencyKey   string
	LeaseEpoch       int64
	TargetInstanceID string
	TargetTerminalID string
	CiphertextJSON   string
}

// DaemonCommandObservation 是 Android 只读观察面的最小命令投影。
// 它刻意不包含 command/terminal/instance 标识、lease、幂等键或密文，避免观察页演化成控制面。
type DaemonCommandObservation struct {
	Kind          string
	Status        string
	DeliveryState string
	ErrorCode     string
}

// SessionService 管理 Session 生命周期、事件追加与命令状态机。
type SessionService struct {
	repo store.Repository
	now  func() time.Time
}

// NewSessionService 构造会话服务。
func NewSessionService(repo store.Repository) *SessionService {
	return &SessionService{repo: repo, now: time.Now}
}

// CreateSession 创建逻辑会话并写初始事件。
func (s *SessionService) CreateSession(ctx context.Context, accountID, workspaceID, provider string) (store.SessionRow, error) {
	workspaces, err := s.repo.ListWorkspaces(ctx, accountID)
	if err != nil {
		return store.SessionRow{}, err
	}
	owned := false
	for _, workspace := range workspaces {
		if workspace.ID == workspaceID {
			owned = true
			break
		}
	}
	if !owned {
		return store.SessionRow{}, ErrWorkspaceNotFound
	}
	sess := store.SessionRow{
		ID: id.New("sess"), WorkspaceID: workspaceID, AccountID: accountID,
		Status: SessionIdle, Provider: provider,
	}
	var initialSeq int64
	err = s.repo.WithTx(ctx, func(ctx context.Context, tx store.Repository) error {
		if err := tx.CreateSession(ctx, sess); err != nil {
			return err
		}
		seq, err := tx.AppendEvent(ctx, store.SessionEventRow{
			SessionID: sess.ID, EventType: "session.created", EnvelopeJSON: `{"session_id":"` + sess.ID + `"}`,
		})
		if err != nil {
			return err
		}
		initialSeq = seq
		return tx.SetSessionLastSeq(ctx, sess.ID, seq)
	})
	if err != nil {
		return store.SessionRow{}, err
	}
	sess.LastSeq = initialSeq
	return sess, nil
}

// GetSession 读取会话；不存在返回 ErrSessionNotFound。
func (s *SessionService) GetSession(ctx context.Context, id string) (store.SessionRow, error) {
	sess, err := s.repo.SessionByID(ctx, id)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return store.SessionRow{}, ErrSessionNotFound
		}
		return store.SessionRow{}, err
	}
	return sess, nil
}

// ListSessions 列出账号下会话。
func (s *SessionService) ListSessions(ctx context.Context, accountID string) ([]store.SessionRow, error) {
	return s.repo.ListSessions(ctx, accountID)
}

// ListWorkspaces 列出账号下工作区。
func (s *SessionService) ListWorkspaces(ctx context.Context, accountID string) ([]store.WorkspaceRow, error) {
	return s.repo.ListWorkspaces(ctx, accountID)
}

// AppendEvent 追加一条事件，seq 由存储单调分配，并更新会话 last_seq。
func (s *SessionService) AppendEvent(ctx context.Context, sessionID, eventType, envelopeJSON string) (int64, error) {
	var seq int64
	err := s.repo.WithTx(ctx, func(ctx context.Context, tx store.Repository) error {
		var err error
		seq, err = tx.AppendEvent(ctx, store.SessionEventRow{SessionID: sessionID, EventType: eventType, EnvelopeJSON: envelopeJSON})
		if err != nil {
			return err
		}
		// last_seq 是客户端快照游标的权威值，必须和事件追加处于同一事务。
		if err := tx.SetSessionLastSeq(ctx, sessionID, seq); err != nil {
			return err
		}
		return tx.SetSessionStatus(ctx, sessionID, SessionRunning)
	})
	if err != nil {
		return 0, err
	}
	return seq, nil
}

// SubmitCommand 提交异步命令：幂等键去重 + lease/fencing 校验 + 写入 outbox。
// 非 Android 写端、缺失/旧 epoch、撤销设备均被拒绝。重复幂等键返回原命令。
func (s *SessionService) SubmitCommand(ctx context.Context, in CommandInput) (store.CommandRow, error) {
	if !protocol.DeviceRoleCanWrite(in.Role) {
		return store.CommandRow{}, ErrReadOnlyDevice
	}
	scopeHash := hashScope(in.AccountID, in.SessionID)
	cmd := store.CommandRow{
		ID: id.New("cmd"), AccountID: in.AccountID, SessionID: in.SessionID, Kind: in.Kind,
		Status: CommandAccepted, ScopeHash: scopeHash, IdempotencyKey: in.IdempotencyKey,
		LeaseEpoch: in.LeaseEpoch, TargetInstanceID: in.TargetInstanceID, TargetTerminalID: in.TargetTerminalID,
		CiphertextJSON: in.CiphertextJSON,
	}
	var out store.CommandRow
	err := s.repo.WithTx(ctx, func(ctx context.Context, tx store.Repository) error {
		// 幂等读取、会话/lease 校验、命令与 outbox 必须在同一事务，避免旧 epoch 在检查后插入。
		if existing, lookupErr := tx.CommandByScopeKey(ctx, scopeHash, in.IdempotencyKey); lookupErr == nil {
			out = existing
			return nil
		} else if !errors.Is(lookupErr, sql.ErrNoRows) {
			return lookupErr
		}
		if in.SessionID != "" {
			session, sessionErr := tx.SessionByID(ctx, in.SessionID)
			if sessionErr != nil {
				if errors.Is(sessionErr, sql.ErrNoRows) {
					return ErrSessionNotFound
				}
				return sessionErr
			}
			if session.AccountID != in.AccountID {
				return ErrScopeDenied
			}
			if err := checkLeaseWithRepo(ctx, tx, in.SessionID, in.DeviceID, in.LeaseEpoch); err != nil {
				return err
			}
			// 存在运行实例时，所有写命令必须明确绑定当前 instance；旧实例不能接收命令。
			if session.CurrentInstanceID != "" && in.TargetInstanceID != session.CurrentInstanceID {
				return ErrTargetStale
			}
			lease, leaseErr := tx.LeaseBySession(ctx, in.SessionID)
			if leaseErr != nil {
				return leaseErr
			}
			if lease.InstanceID != "" && in.TargetInstanceID != lease.InstanceID {
				return ErrTargetStale
			}
			// Daemon 命令的唯一目标来自会话所属 Workspace，不能由 Android 客户端自由指定。
			// 历史未绑定 Workspace 仍保留原有 accepted/outbox 语义，但不会进入专用 Daemon 流。
			workspace, workspaceErr := tx.WorkspaceByID(ctx, session.WorkspaceID)
			if workspaceErr != nil {
				if errors.Is(workspaceErr, sql.ErrNoRows) {
					return ErrWorkspaceNotFound
				}
				return workspaceErr
			}
			if !workspaceBelongsToAccount(ctx, tx, in.AccountID, workspace.ID) {
				return ErrScopeDenied
			}
			if workspace.TerminalID == "" {
				if in.TargetTerminalID != "" {
					return ErrScopeDenied
				}
				cmd.TargetTerminalID = ""
			} else {
				if in.TargetTerminalID != "" && in.TargetTerminalID != workspace.TerminalID {
					return ErrScopeDenied
				}
				terminal, terminalErr := tx.TerminalByID(ctx, workspace.TerminalID)
				if terminalErr != nil {
					if errors.Is(terminalErr, sql.ErrNoRows) {
						return ErrTerminalOffline
					}
					return terminalErr
				}
				if terminal.AccountID != in.AccountID {
					return ErrScopeDenied
				}
				cmd.TargetTerminalID = terminal.ID
			}
		}
		if err := tx.CreateCommand(ctx, cmd); err != nil {
			return err
		}
		if cmd.TargetTerminalID != "" {
			if _, err := tx.CreateDaemonDelivery(ctx, store.DaemonDeliveryRow{
				TerminalID: cmd.TargetTerminalID, CommandID: cmd.ID, CreatedAtUnixMS: s.now().UnixMilli(),
			}); err != nil {
				return err
			}
		}
		return tx.EnqueueOutbox(ctx, store.OutboxRow{Kind: "command.updated", PayloadJSON: `{"command_id":"` + cmd.ID + `"}`, Status: "pending"})
	})
	if err != nil {
		// 并发同键插入会命中唯一索引；提交者的原命令才是可重试结果。
		if existing, lookupErr := s.repo.CommandByScopeKey(ctx, scopeHash, in.IdempotencyKey); lookupErr == nil {
			return existing, nil
		}
		return store.CommandRow{}, err
	}
	if out.ID == "" {
		out = cmd
	}
	return out, nil
}

// DaemonDeliveryForCommand 返回已绑定 Daemon 的专用投递记录。没有 target terminal 的历史命令
// 不能被任何 Daemon stream 取走，调用方应按 sql.ErrNoRows 区分而非猜测目标。
func (s *SessionService) DaemonDeliveryForCommand(ctx context.Context, commandID string) (store.DaemonDeliveryRow, error) {
	return s.repo.DaemonDeliveryByCommandID(ctx, commandID)
}

func workspaceBelongsToAccount(ctx context.Context, repo store.Repository, accountID, workspaceID string) bool {
	workspaces, err := repo.ListWorkspaces(ctx, accountID)
	if err != nil {
		return false
	}
	for _, workspace := range workspaces {
		if workspace.ID == workspaceID {
			return true
		}
	}
	return false
}

// checkLease 校验写端是否持有当前 lease 且 epoch 匹配（fencing）。
func (s *SessionService) checkLease(ctx context.Context, sessionID, deviceID string, epoch int64) error {
	return checkLeaseWithRepo(ctx, s.repo, sessionID, deviceID, epoch)
}

// checkLeaseWithRepo 允许 SubmitCommand 在既有事务连接中做 fencing，避免事务外 TOCTOU 窗口。
func checkLeaseWithRepo(ctx context.Context, repo store.Repository, sessionID, deviceID string, epoch int64) error {
	if epoch <= 0 {
		// 每次写命令都必须显式携带当前 fencing epoch，不能把 0 当作兼容通配符。
		return ErrTargetStale
	}
	lease, err := repo.LeaseBySession(ctx, sessionID)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return ErrLeaseConflict
		}
		return err
	}
	if lease.DeviceID != deviceID {
		return ErrLeaseConflict
	}
	if lease.Epoch != epoch {
		return ErrTargetStale
	}
	return nil
}

// AcquireLease 抢占写控制权；返回当前 epoch。竞态时只保留一个写端。
func (s *SessionService) AcquireLease(ctx context.Context, sessionID, deviceID, instanceID string) (int64, error) {
	var epoch int64
	err := s.repo.WithTx(ctx, func(ctx context.Context, tx store.Repository) error {
		lease, err := tx.LeaseBySession(ctx, sessionID)
		if err != nil && !errors.Is(err, sql.ErrNoRows) {
			return err
		}
		if err == nil && lease.DeviceID != "" && lease.DeviceID != deviceID {
			return ErrLeaseConflict
		}
		if err == nil {
			epoch = lease.Epoch + 1
		} else {
			epoch = 1
		}
		return tx.AcquireLease(ctx, store.LeaseRow{SessionID: sessionID, DeviceID: deviceID, Epoch: epoch, InstanceID: instanceID})
	})
	if err != nil {
		return 0, err
	}
	return epoch, nil
}

// GetCommand 读取命令详情。
func (s *SessionService) GetCommand(ctx context.Context, id string) (store.CommandRow, error) {
	cmd, err := s.repo.CommandByID(ctx, id)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return store.CommandRow{}, store.ErrNotFound
		}
		return store.CommandRow{}, err
	}
	return cmd, nil
}

// ListDaemonCommandObservations 返回账号内指定会话的 Daemon 命令安全投影。
// 命令状态和 delivery receipt 是不同事实：前者代表 Relay 命令生命周期，后者代表 Daemon
// 是否已接收/开始/完成。两者都不需要也不允许向 Android 返回执行 payload。
func (s *SessionService) ListDaemonCommandObservations(ctx context.Context, accountID, sessionID string) ([]DaemonCommandObservation, error) {
	session, err := s.GetSession(ctx, sessionID)
	if err != nil {
		return nil, err
	}
	if session.AccountID != accountID {
		return nil, ErrScopeDenied
	}
	commands, err := s.repo.ListCommands(ctx, sessionID)
	if err != nil {
		return nil, err
	}
	observations := make([]DaemonCommandObservation, 0, len(commands))
	for _, command := range commands {
		// 没有目标 Terminal 的历史控制记录不属于 Daemon 观察契约，不能借此暴露旧控制面。
		if command.TargetTerminalID == "" {
			continue
		}
		observation := DaemonCommandObservation{
			Kind:          command.Kind,
			Status:        command.Status,
			DeliveryState: "queued",
		}
		delivery, deliveryErr := s.repo.DaemonDeliveryByCommandID(ctx, command.ID)
		switch {
		case deliveryErr == nil:
			observation.DeliveryState = daemonObservationDeliveryState(delivery)
			observation.ErrorCode = safeErrorCode(delivery.ErrorCode)
		case errors.Is(deliveryErr, sql.ErrNoRows):
			// 旧库升级期间可能存在已投递标记尚未补齐的记录；只读端明确显示 queued，
			// 不推断 Terminal 已经执行，也不把该不一致转为可写修复动作。
		default:
			return nil, deliveryErr
		}
		observations = append(observations, observation)
	}
	return observations, nil
}

func daemonObservationDeliveryState(delivery store.DaemonDeliveryRow) string {
	if delivery.ResultStatus != "" {
		return "resolved"
	}
	switch delivery.AckKind {
	case "received", "started", "rejected":
		return delivery.AckKind
	default:
		return "queued"
	}
}

// ResolveCommand 更新命令状态并追加标准事件；已终态的命令幂等返回原状态。
func (s *SessionService) ResolveCommand(ctx context.Context, commandID, status string) (store.CommandRow, error) {
	cmd, err := s.repo.CommandByID(ctx, commandID)
	if err != nil {
		return store.CommandRow{}, store.ErrNotFound
	}
	if isTerminal(cmd.Status) {
		return cmd, nil
	}
	if err := s.repo.UpdateCommandStatus(ctx, commandID, status); err != nil {
		return store.CommandRow{}, err
	}
	cmd.Status = status
	_ = s.repo.AppendAudit(ctx, cmd.AccountID, "command.resolved", `{"command_id":"`+commandID+`","status":"`+status+`"}`)
	return cmd, nil
}

// OutboxWorker 消费 pending outbox；失败按次数标记 failed，可重放。
type OutboxWorker struct {
	repo store.Repository
}

// NewOutboxWorker 构造 outbox worker。
func NewOutboxWorker(repo store.Repository) *OutboxWorker {
	return &OutboxWorker{repo: repo}
}

// Drain 尝试投递最多 limit 条 pending outbox。返回成功条数。
func (w *OutboxWorker) Drain(ctx context.Context, limit int) (int, error) {
	rows, err := w.repo.ListPendingOutbox(ctx, limit)
	if err != nil {
		return 0, err
	}
	done := 0
	for _, row := range rows {
		// 投递逻辑：这里以“可送达”为语义，写入成功即标记 done。
		if err := w.repo.MarkOutboxDone(ctx, row.ID); err != nil {
			return done, err
		}
		done++
	}
	return done, nil
}

// hashScope 生成 scope_hash，绑定账号与会话。
func hashScope(accountID, sessionID string) string {
	sum := sha256.Sum256([]byte(accountID + "|" + sessionID))
	return hex.EncodeToString(sum[:])
}

// isTerminal 判断命令是否已进入终态。
func isTerminal(status string) bool {
	switch status {
	case CommandSucceeded, CommandFailed, CommandCancelled, CommandRejected, CommandExpired:
		return true
	}
	return false
}

// RecoverLease 从进程内 presence 丢失场景中重建当前 lease（SQLite 仍是权威）。
func (s *SessionService) RecoverLease(ctx context.Context, sessionID string) (int64, bool) {
	lease, err := s.repo.LeaseBySession(ctx, sessionID)
	if err != nil {
		return 0, false
	}
	return lease.Epoch, lease.DeviceID != ""
}

// ListEventsAfter 读取游标之后的事件（SSE/WS 恢复）。
func (s *SessionService) ListEventsAfter(ctx context.Context, sessionID string, afterSeq int64) ([]store.SessionEventRow, error) {
	return s.repo.ListEventsAfter(ctx, sessionID, afterSeq)
}

// NewWakeResult 生成唤醒结果事件（SESS-04）。
func (s *SessionService) NewWakeResult(ctx context.Context, sessionID, result string) error {
	if !validWake(result) {
		return protocol.NewError(protocol.ErrInvalidRequest, "invalid wake result")
	}
	_, err := s.AppendEvent(ctx, sessionID, "session.wake", `{"result":"`+result+`"}`)
	return err
}

func validWake(r string) bool {
	for _, k := range protocol.KnownWakeOutcomes() {
		if k == r {
			return true
		}
	}
	return false
}
