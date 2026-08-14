package domain

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"strings"
	"time"

	"github.com/yubi233/agent-sessions/internal/id"
	"github.com/yubi233/agent-sessions/internal/store"
	"github.com/yubi233/agent-sessions/packages/protocol"
)

// Delegation 状态属于产品层父子 Session 图，不复用 Provider 私有 sub-agent 状态。
const (
	DelegationProposed  = "proposed"
	DelegationApproved  = "approved"
	DelegationRunning   = "running"
	DelegationCompleted = "completed"
	DelegationFailed    = "failed"
	DelegationCancelled = "cancelled"
	DelegationRejected  = "rejected"
)

var (
	ErrDelegationNotFound     = errors.New("delegation not found")
	ErrDelegationUnsupported  = errors.New("delegation capability unsupported")
	ErrDelegationInvalidState = errors.New("delegation invalid state")
	ErrDelegationBoundary     = errors.New("delegation workspace or terminal boundary denied")
)

// DelegationDispatchRequest 是 Relay 写入索引后交给 Daemon 的最小执行输入。
// TaskEnvelope 保持为密文，不在日志、审计或事件中展开。
type DelegationDispatchRequest struct {
	DelegationID    string
	ChildSessionID  string
	ParentSessionID string
	WorkspaceID     string
	TargetProvider  string
	TaskEnvelope    []byte
}

// DelegationDispatchResult 是 Daemon 启动 child 后回传的最小实例信息。
type DelegationDispatchResult struct {
	InstanceID string
}

// DelegationDispatcher 隔离产品层状态机和 Provider 私有启动协议。
// 真实 Provider 未获得授权时不得由此接口伪造成功；本轮只注入 deterministic mock。
type DelegationDispatcher interface {
	ValidateTarget(ctx context.Context, parentProvider, targetProvider string) error
	Start(ctx context.Context, request DelegationDispatchRequest) (DelegationDispatchResult, error)
	Stop(ctx context.Context, delegationID string) error
}

// DelegationCreateInput 只接受客户端已经加密的任务书与摘要。Relay 不接收任务正文、文件路径或子会话内容。
type DelegationCreateInput struct {
	AccountID         string
	DeviceID          string
	Role              string
	ParentSessionID   string
	TargetWorkspaceID string
	TargetTerminalID  string
	TargetProvider    string
	TaskEnvelope      []byte
	SummaryEnvelope   []byte
	IdempotencyKey    string
	LeaseEpoch        int64
}

// DelegationDecisionInput 是 Android 对 proposed/running 节点的显式确认、拒绝或取消。
// 每次决策仍使用父 Session 的当前 lease，child 的后续写操作则由 child lease 单独保护。
type DelegationDecisionInput struct {
	AccountID        string
	DeviceID         string
	Role             string
	DelegationID     string
	Decision         string
	IdempotencyKey   string
	ParentLeaseEpoch int64
}

// DelegationService 管理父子 Session 图、确认状态机和密文摘要事件。
type DelegationService struct {
	repo       store.Repository
	dispatcher DelegationDispatcher
	now        func() time.Time
}

// NewDelegationService 构造产品层派发服务。dispatcher 可为 nil，此时所有派发显式 unsupported。
func NewDelegationService(repo store.Repository, dispatcher DelegationDispatcher) *DelegationService {
	return &DelegationService{repo: repo, dispatcher: dispatcher, now: time.Now}
}

// CreateProposal 写入 Android 确认前的 proposed 节点。此步骤绝不创建 child Session 或启动 Provider。
func (s *DelegationService) CreateProposal(ctx context.Context, in DelegationCreateInput) (store.DelegationRow, error) {
	if !protocol.DeviceRoleCanWrite(in.Role) {
		return store.DelegationRow{}, ErrReadOnlyDevice
	}
	if strings.TrimSpace(in.ParentSessionID) == "" ||
		strings.TrimSpace(in.TargetWorkspaceID) == "" ||
		strings.TrimSpace(in.TargetProvider) == "" ||
		strings.TrimSpace(in.IdempotencyKey) == "" || in.LeaseEpoch <= 0 {
		return store.DelegationRow{}, protocol.NewError(protocol.ErrInvalidRequest, "delegation request is incomplete")
	}
	taskEnvelope, taskHash, err := normalizeCipherEnvelope(in.TaskEnvelope)
	if err != nil {
		return store.DelegationRow{}, err
	}
	summaryEnvelope, summaryHash, err := normalizeCipherEnvelope(in.SummaryEnvelope)
	if err != nil {
		return store.DelegationRow{}, err
	}

	nowUnixMS := s.now().UTC().UnixMilli()
	delegation := store.DelegationRow{
		ID:                    id.New("deleg"),
		AccountID:             in.AccountID,
		ParentSessionID:       in.ParentSessionID,
		TargetProvider:        strings.TrimSpace(in.TargetProvider),
		Status:                DelegationProposed,
		TaskEnvelopeJSON:      taskEnvelope,
		TaskEnvelopeSHA256:    taskHash,
		SummaryEnvelopeJSON:   summaryEnvelope,
		SummaryEnvelopeSHA256: summaryHash,
		IdempotencyKey:        in.IdempotencyKey,
		ParentLeaseEpoch:      in.LeaseEpoch,
		CreatedByDeviceID:     in.DeviceID,
		CreatedAtUnixMS:       nowUnixMS,
		UpdatedAtUnixMS:       nowUnixMS,
	}
	var out store.DelegationRow
	err = s.repo.WithTx(ctx, func(ctx context.Context, tx store.Repository) error {
		// Delegation 与普通命令共用 parent scope 的幂等空间，避免同一点击既创建 command 又创建 child 图。
		if existing, lookupErr := tx.DelegationByParentKey(ctx, in.ParentSessionID, in.IdempotencyKey); lookupErr == nil {
			out = existing
			return nil
		} else if !errors.Is(lookupErr, sql.ErrNoRows) {
			return lookupErr
		}
		if existingCommand, lookupErr := tx.CommandByScopeKey(ctx, hashScope(in.AccountID, in.ParentSessionID), in.IdempotencyKey); lookupErr == nil {
			_ = existingCommand
			return ErrIdempotencyUsed
		} else if !errors.Is(lookupErr, sql.ErrNoRows) {
			return lookupErr
		}

		parent, err := delegationParentWithLease(ctx, tx, in.AccountID, in.ParentSessionID, in.DeviceID, in.LeaseEpoch)
		if err != nil {
			return err
		}
		if parent.WorkspaceID != in.TargetWorkspaceID {
			return ErrDelegationBoundary
		}
		workspace, err := tx.WorkspaceByID(ctx, parent.WorkspaceID)
		if err != nil {
			return err
		}
		if in.TargetTerminalID != "" && in.TargetTerminalID != workspace.TerminalID {
			return ErrDelegationBoundary
		}
		if s.dispatcher == nil {
			return ErrDelegationUnsupported
		}
		if err := s.dispatcher.ValidateTarget(ctx, parent.Provider, delegation.TargetProvider); err != nil {
			return err
		}
		if err := tx.CreateDelegation(ctx, delegation); err != nil {
			return err
		}
		if err := createDelegationCommand(ctx, tx, delegation, "delegation.create", in.IdempotencyKey, in.LeaseEpoch); err != nil {
			return err
		}
		if err := appendDelegationChanged(ctx, tx, delegation); err != nil {
			return err
		}
		if err := tx.AppendAudit(ctx, in.AccountID, "delegation.proposed", delegationAuditJSON(delegation)); err != nil {
			return err
		}
		out = delegation
		return nil
	})
	if err != nil {
		// SQLite 唯一键的并发冲突仍按原节点返回，保证重试不会制造第二个 child。
		if existing, lookupErr := s.repo.DelegationByParentKey(ctx, in.ParentSessionID, in.IdempotencyKey); lookupErr == nil {
			return existing, nil
		}
		return store.DelegationRow{}, err
	}
	return out, nil
}

// ListForParent 返回父会话拥有的图节点。调用方只能读取同账号 parent，任务书不会出现在 REST 投影中。
func (s *DelegationService) ListForParent(ctx context.Context, accountID, parentSessionID string) ([]store.DelegationRow, error) {
	parent, err := s.repo.SessionByID(ctx, parentSessionID)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, ErrSessionNotFound
		}
		return nil, err
	}
	if parent.AccountID != accountID {
		return nil, ErrScopeDenied
	}
	return s.repo.ListDelegationsByParent(ctx, parentSessionID)
}

// Decide 执行 Android 的 approve/reject/cancel。批准在同一事务中创建 child Session 和 child lease，
// 再把启动动作交给 Daemon；任何失败都会映射为明确状态，不能伪装 completed。
func (s *DelegationService) Decide(ctx context.Context, in DelegationDecisionInput) (store.DelegationRow, error) {
	if !protocol.DeviceRoleCanWrite(in.Role) {
		return store.DelegationRow{}, ErrReadOnlyDevice
	}
	if strings.TrimSpace(in.DelegationID) == "" || strings.TrimSpace(in.IdempotencyKey) == "" || in.ParentLeaseEpoch <= 0 {
		return store.DelegationRow{}, protocol.NewError(protocol.ErrInvalidRequest, "delegation decision is incomplete")
	}
	decision := strings.TrimSpace(in.Decision)
	if decision != "approve" && decision != "reject" && decision != "cancel" {
		return store.DelegationRow{}, protocol.NewError(protocol.ErrInvalidRequest, "unknown delegation decision")
	}

	var out store.DelegationRow
	start := false
	stop := false
	var dispatch DelegationDispatchRequest
	err := s.repo.WithTx(ctx, func(ctx context.Context, tx store.Repository) error {
		delegation, err := tx.DelegationByID(ctx, in.DelegationID)
		if err != nil {
			if errors.Is(err, sql.ErrNoRows) {
				return ErrDelegationNotFound
			}
			return err
		}
		if delegation.AccountID != in.AccountID {
			return ErrScopeDenied
		}
		parent, err := delegationParentWithLease(ctx, tx, in.AccountID, delegation.ParentSessionID, in.DeviceID, in.ParentLeaseEpoch)
		if err != nil {
			return err
		}
		scopeHash := hashScope(in.AccountID, delegation.ParentSessionID)
		if existing, lookupErr := tx.CommandByScopeKey(ctx, scopeHash, in.IdempotencyKey); lookupErr == nil {
			if existing.Kind != "delegation.resolve" {
				return ErrIdempotencyUsed
			}
			out = delegation
			return nil
		} else if !errors.Is(lookupErr, sql.ErrNoRows) {
			return lookupErr
		}

		switch decision {
		case "reject":
			if delegation.Status != DelegationProposed {
				return ErrDelegationInvalidState
			}
			delegation.Status = DelegationRejected
		case "approve":
			if delegation.Status != DelegationProposed {
				return ErrDelegationInvalidState
			}
			if s.dispatcher == nil {
				return ErrDelegationUnsupported
			}
			if err := s.dispatcher.ValidateTarget(ctx, parent.Provider, delegation.TargetProvider); err != nil {
				return err
			}
			child, err := createDelegatedChildSession(ctx, tx, delegation, in.DeviceID)
			if err != nil {
				return err
			}
			delegation.ChildSessionID = child.ID
			delegation.Status = DelegationApproved
			start = true
			dispatch = DelegationDispatchRequest{
				DelegationID: delegation.ID, ChildSessionID: child.ID, ParentSessionID: delegation.ParentSessionID,
				WorkspaceID: parent.WorkspaceID, TargetProvider: delegation.TargetProvider,
				TaskEnvelope: []byte(delegation.TaskEnvelopeJSON),
			}
		case "cancel":
			if delegation.Status != DelegationApproved && delegation.Status != DelegationRunning {
				return ErrDelegationInvalidState
			}
			delegation.Status = DelegationCancelled
			stop = true
		}

		delegation.UpdatedAtUnixMS = s.now().UTC().UnixMilli()
		if err := tx.UpdateDelegation(ctx, delegation.ID, delegation.Status, delegation.ChildSessionID, delegation.UpdatedAtUnixMS); err != nil {
			return err
		}
		if stop && delegation.ChildSessionID != "" {
			if err := tx.SetSessionStatus(ctx, delegation.ChildSessionID, SessionStopped); err != nil {
				return err
			}
		}
		if err := createDelegationCommand(ctx, tx, delegation, "delegation.resolve", in.IdempotencyKey, in.ParentLeaseEpoch); err != nil {
			return err
		}
		if err := appendDelegationChanged(ctx, tx, delegation); err != nil {
			return err
		}
		if err := tx.AppendAudit(ctx, in.AccountID, "delegation."+delegation.Status, delegationAuditJSON(delegation)); err != nil {
			return err
		}
		out = delegation
		return nil
	})
	if err != nil {
		return store.DelegationRow{}, err
	}
	if stop && s.dispatcher != nil {
		// child 已被持久化为 cancelled；Daemon 回收失败不会把它回滚成 running。
		_ = s.dispatcher.Stop(ctx, out.ID)
	}
	if !start {
		return out, nil
	}
	result, dispatchErr := s.dispatcher.Start(ctx, dispatch)
	if dispatchErr != nil {
		return s.markTerminal(ctx, out.ID, DelegationFailed)
	}
	return s.markRunning(ctx, out.ID, result.InstanceID)
}

// MarkCompleted 仅供 Daemon 监督器在 child 完成后调用；父事件仍只携带摘要和状态。
func (s *DelegationService) MarkCompleted(ctx context.Context, delegationID string) (store.DelegationRow, error) {
	return s.markTerminal(ctx, delegationID, DelegationCompleted)
}

func (s *DelegationService) markRunning(ctx context.Context, delegationID, instanceID string) (store.DelegationRow, error) {
	var out store.DelegationRow
	err := s.repo.WithTx(ctx, func(ctx context.Context, tx store.Repository) error {
		delegation, err := tx.DelegationByID(ctx, delegationID)
		if err != nil {
			return err
		}
		if delegation.Status != DelegationApproved {
			return ErrDelegationInvalidState
		}
		if strings.TrimSpace(instanceID) == "" {
			return protocol.NewError(protocol.ErrInvalidRequest, "daemon did not return child instance")
		}
		delegation.Status = DelegationRunning
		delegation.UpdatedAtUnixMS = s.now().UTC().UnixMilli()
		if err := tx.CreateInstance(ctx, store.InstanceRow{ID: instanceID, SessionID: delegation.ChildSessionID, LeaseEpoch: 1, Status: SessionRunning}); err != nil {
			return err
		}
		if err := tx.SetSessionInstance(ctx, delegation.ChildSessionID, instanceID); err != nil {
			return err
		}
		if err := tx.SetSessionStatus(ctx, delegation.ChildSessionID, SessionRunning); err != nil {
			return err
		}
		if err := tx.UpdateDelegation(ctx, delegation.ID, delegation.Status, delegation.ChildSessionID, delegation.UpdatedAtUnixMS); err != nil {
			return err
		}
		if err := appendDelegationChanged(ctx, tx, delegation); err != nil {
			return err
		}
		if err := tx.AppendAudit(ctx, delegation.AccountID, "delegation.running", delegationAuditJSON(delegation)); err != nil {
			return err
		}
		out = delegation
		return nil
	})
	return out, err
}

func (s *DelegationService) markTerminal(ctx context.Context, delegationID, status string) (store.DelegationRow, error) {
	if status != DelegationCompleted && status != DelegationFailed && status != DelegationCancelled {
		return store.DelegationRow{}, ErrDelegationInvalidState
	}
	var out store.DelegationRow
	err := s.repo.WithTx(ctx, func(ctx context.Context, tx store.Repository) error {
		delegation, err := tx.DelegationByID(ctx, delegationID)
		if err != nil {
			if errors.Is(err, sql.ErrNoRows) {
				return ErrDelegationNotFound
			}
			return err
		}
		if delegation.Status == status {
			out = delegation
			return nil
		}
		if delegation.Status != DelegationApproved && delegation.Status != DelegationRunning {
			return ErrDelegationInvalidState
		}
		delegation.Status = status
		delegation.UpdatedAtUnixMS = s.now().UTC().UnixMilli()
		if delegation.ChildSessionID != "" {
			if err := tx.SetSessionStatus(ctx, delegation.ChildSessionID, SessionStopped); err != nil {
				return err
			}
		}
		if err := tx.UpdateDelegation(ctx, delegation.ID, delegation.Status, delegation.ChildSessionID, delegation.UpdatedAtUnixMS); err != nil {
			return err
		}
		if err := appendDelegationChanged(ctx, tx, delegation); err != nil {
			return err
		}
		if err := tx.AppendAudit(ctx, delegation.AccountID, "delegation."+status, delegationAuditJSON(delegation)); err != nil {
			return err
		}
		out = delegation
		return nil
	})
	if err == nil && (status == DelegationCompleted || status == DelegationFailed || status == DelegationCancelled) && s.dispatcher != nil {
		_ = s.dispatcher.Stop(ctx, delegationID)
	}
	return out, err
}

func delegationParentWithLease(ctx context.Context, repo store.Repository, accountID, sessionID, deviceID string, epoch int64) (store.SessionRow, error) {
	parent, err := repo.SessionByID(ctx, sessionID)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return store.SessionRow{}, ErrSessionNotFound
		}
		return store.SessionRow{}, err
	}
	if parent.AccountID != accountID {
		return store.SessionRow{}, ErrScopeDenied
	}
	if err := checkLeaseWithRepo(ctx, repo, sessionID, deviceID, epoch); err != nil {
		return store.SessionRow{}, err
	}
	return parent, nil
}

// createDelegatedChildSession 在批准事务内一次性创建 child、初始事件和独立 lease，禁止继承 parent epoch。
func createDelegatedChildSession(ctx context.Context, tx store.Repository, delegation store.DelegationRow, deviceID string) (store.SessionRow, error) {
	parent, err := tx.SessionByID(ctx, delegation.ParentSessionID)
	if err != nil {
		return store.SessionRow{}, err
	}
	child := store.SessionRow{
		ID: id.New("sess"), WorkspaceID: parent.WorkspaceID, AccountID: parent.AccountID,
		Status: SessionIdle, Provider: delegation.TargetProvider,
	}
	if err := tx.CreateSession(ctx, child); err != nil {
		return store.SessionRow{}, err
	}
	seq, err := tx.AppendEvent(ctx, store.SessionEventRow{
		SessionID: child.ID, EventType: "session.created", EnvelopeJSON: `{"session_id":"` + child.ID + `"}`,
	})
	if err != nil {
		return store.SessionRow{}, err
	}
	if err := tx.SetSessionLastSeq(ctx, child.ID, seq); err != nil {
		return store.SessionRow{}, err
	}
	// child 使用自己的 lease 表行和 epoch=1；绝不复制 parent lease epoch。
	if err := tx.AcquireLease(ctx, store.LeaseRow{SessionID: child.ID, DeviceID: deviceID, Epoch: 1}); err != nil {
		return store.SessionRow{}, err
	}
	child.LastSeq = seq
	return child, nil
}

func createDelegationCommand(ctx context.Context, tx store.Repository, delegation store.DelegationRow, kind, idempotencyKey string, epoch int64) error {
	command := store.CommandRow{
		ID: id.New("cmd"), AccountID: delegation.AccountID, SessionID: delegation.ParentSessionID,
		Kind: kind, Status: CommandAccepted, ScopeHash: hashScope(delegation.AccountID, delegation.ParentSessionID),
		IdempotencyKey: idempotencyKey, LeaseEpoch: epoch,
		// command 表只保存 delegation id，任务书始终留在 delegation 的密文列中。
		CiphertextJSON: `{"delegation_id":"` + delegation.ID + `"}`,
	}
	if err := tx.CreateCommand(ctx, command); err != nil {
		return err
	}
	return tx.EnqueueOutbox(ctx, store.OutboxRow{
		Kind: "delegation.changed", PayloadJSON: `{"delegation_id":"` + delegation.ID + `"}`, Status: "pending",
	})
}

// appendDelegationChanged 只向 parent 追加状态和密文摘要。任务书、child 事件和 child 内容绝不复制进 parent 流。
func appendDelegationChanged(ctx context.Context, tx store.Repository, delegation store.DelegationRow) error {
	envelope, err := json.Marshal(map[string]any{
		"delegation_id":           delegation.ID,
		"parent_session_id":       delegation.ParentSessionID,
		"child_session_id":        delegation.ChildSessionID,
		"target_provider":         delegation.TargetProvider,
		"status":                  delegation.Status,
		"summary_envelope":        json.RawMessage(delegation.SummaryEnvelopeJSON),
		"summary_envelope_sha256": delegation.SummaryEnvelopeSHA256,
	})
	if err != nil {
		return err
	}
	seq, err := tx.AppendEvent(ctx, store.SessionEventRow{
		SessionID: delegation.ParentSessionID, EventType: "delegation.changed", EnvelopeJSON: string(envelope),
	})
	if err != nil {
		return err
	}
	return tx.SetSessionLastSeq(ctx, delegation.ParentSessionID, seq)
}

func delegationAuditJSON(delegation store.DelegationRow) string {
	payload, _ := json.Marshal(map[string]string{
		"delegation_id": delegation.ID, "parent_session_id": delegation.ParentSessionID,
		"child_session_id": delegation.ChildSessionID, "target_provider": delegation.TargetProvider,
		"status": delegation.Status, "task_envelope_sha256": delegation.TaskEnvelopeSHA256,
		"summary_envelope_sha256": delegation.SummaryEnvelopeSHA256,
	})
	return string(payload)
}

// normalizeCipherEnvelope 只验证加密 envelope 的结构，不能解密或解析其业务内容。
func normalizeCipherEnvelope(raw []byte) (string, string, error) {
	if len(raw) == 0 || len(raw) > 64*1024 {
		return "", "", protocol.NewError(protocol.ErrInvalidRequest, "delegation ciphertext envelope is invalid")
	}
	var envelope map[string]json.RawMessage
	if err := json.Unmarshal(raw, &envelope); err != nil || len(envelope) == 0 {
		return "", "", protocol.NewError(protocol.ErrInvalidRequest, "delegation ciphertext envelope is invalid")
	}
	for _, forbidden := range []string{"plaintext", "text", "message", "prompt", "content", "task"} {
		if _, found := envelope[forbidden]; found {
			return "", "", protocol.NewError(protocol.ErrInvalidRequest, "delegation plaintext fields are forbidden")
		}
	}
	for _, key := range []string{"alg", "key_id", "nonce", "ciphertext", "aad_hash", "payload_version"} {
		if len(envelope[key]) == 0 {
			return "", "", protocol.NewError(protocol.ErrInvalidRequest, "delegation ciphertext envelope is incomplete")
		}
	}
	var alg, keyID, nonce, ciphertext, aadHash string
	var payloadVersion int
	if json.Unmarshal(envelope["alg"], &alg) != nil || strings.TrimSpace(alg) == "" ||
		json.Unmarshal(envelope["key_id"], &keyID) != nil || strings.TrimSpace(keyID) == "" ||
		json.Unmarshal(envelope["nonce"], &nonce) != nil || strings.TrimSpace(nonce) == "" ||
		json.Unmarshal(envelope["ciphertext"], &ciphertext) != nil || strings.TrimSpace(ciphertext) == "" ||
		json.Unmarshal(envelope["aad_hash"], &aadHash) != nil || strings.TrimSpace(aadHash) == "" ||
		json.Unmarshal(envelope["payload_version"], &payloadVersion) != nil || payloadVersion < 1 {
		return "", "", protocol.NewError(protocol.ErrInvalidRequest, "delegation ciphertext envelope is invalid")
	}
	normalized, err := json.Marshal(envelope)
	if err != nil {
		return "", "", err
	}
	hash := sha256.Sum256(normalized)
	return string(normalized), hex.EncodeToString(hash[:]), nil
}
