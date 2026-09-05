package domain

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/yubi233/agent-sessions/internal/id"
	"github.com/yubi233/agent-sessions/internal/store"
	"github.com/yubi233/agent-sessions/internal/workspacesafe"
	"github.com/yubi233/agent-sessions/packages/protocol"
)

// P2 只支持当前版本及其前一个主版本。当前为首个 Daemon REST+SSE 版本，
// 因而兼容窗口暂时为 1；后续升到 2 时应把 minProtocolVersion 降为 1。
const (
	currentDaemonProtocolVersion = 1
	minDaemonProtocolVersion     = 1
	daemonHeartbeatInterval      = 15 * time.Second
)

var (
	ErrTerminalRequired        = errors.New("terminal device required")
	ErrProtocolUpgradeRequired = errors.New("daemon protocol upgrade required")
	ErrProtocolUnsupported     = errors.New("daemon protocol unsupported")
	ErrDaemonCommandState      = errors.New("daemon command state conflict")
)

// DaemonHelloInput 是已配对 Terminal 声明的最小元数据。Workspace 根、Provider 正文和凭据
// 均不属于此协议，避免 Relay 变成工作区内容副本。
type DaemonHelloInput struct {
	AccountID       string
	DeviceID        string
	Role            string
	ProtocolVersion int
	DaemonVersion   string
	Hostname        string
	Platform        string
	Capabilities    []string
}

type DaemonHelloResult struct {
	Terminal                 store.TerminalRow
	ProtocolVersion          int
	MinProtocolVersion       int
	HeartbeatIntervalSeconds int
	AfterDeliverySeq         int64
	// AuthModes 是 Relay 当前接受的 Terminal 认证方式（ADR-012 能力协商）。
	// optional 窗口为 ["bearer","signature_v1"]；required 窗口只剩 ["signature_v1"]。
	AuthModes []string
	// RelayGeneration 是当前 Relay DB 实例代际（v0.8.9 P1 / V089-02，additive）。
	// Daemon 以 hello 为启动权威记录该值，运行期以 heartbeat 发现变化；
	// 旧 Relay 未登记时为空串，客户端按 legacy 兼容策略处理。
	RelayGeneration string
}

// terminalAuthModes 按兼容窗口进度返回 additive auth_modes 投影。
func (s *DaemonService) terminalAuthModes() []string {
	if s.signatureRequired {
		return []string{"signature_v1"}
	}
	return []string{"bearer", "signature_v1"}
}

type DaemonHeartbeatResult struct {
	TerminalID       string
	ServerTimeUnixMS int64
	// RelayGeneration 是运行期世代发现通道（v0.8.9 P1 / V089-02，additive）。
	// Daemon 每次心跳比较该值：变化说明 Relay DB 已被重建，必须停止命令处理并收口。
	RelayGeneration string
}

type DaemonCommandReceipt struct {
	CommandID   string
	DeliverySeq int64
	AckKind     string
	Status      string
	ErrorCode   string
}

// WorkspaceCommandResult 是 workspace.create 专用回执。canonical_root 只在 Relay 内部使用，
// HTTP 层必须通过不含路径的 workspaceCreateView 投影给 Android。
type WorkspaceCommandResult struct {
	CommandID    string
	DeliverySeq  int64
	WorkspaceID  string
	Status       string
	ErrorCode    string
	Workspace    store.WorkspaceRow
	HasWorkspace bool
}

// WorkspaceDSHSyncResult 是 workspace.sync_dsh 的专用回执。canonical roots 只在 Relay
// 内部用于登记 Workspace，普通 command result 不会携带路径。
type WorkspaceDSHSyncResult struct {
	CommandID    string
	DeliverySeq  int64
	Status       string
	ErrorCode    string
	WorkspaceIDs []string
}

// WorkspaceDSHSyncCandidate 是 Daemon 扫描结果的私有回执字段。CanonicalRoot 只用于 Relay
// 计算稳定 identity；DisplayName 已在 Daemon 从 basename 派生，Relay 仅做边界校验。
type WorkspaceDSHSyncCandidate struct {
	CanonicalRoot string `json:"canonical_root"`
	DisplayName   string `json:"display_name"`
}

// WorkspaceDSHImportResult 是 session.import_dsh 的专用回执。只返回 Relay opaque session ids。
type WorkspaceDSHImportResult struct {
	CommandID   string
	DeliverySeq int64
	Status      string
	ErrorCode   string
	SessionIDs  []string
}

type DaemonEventInput struct {
	AccountID       string
	DeviceID        string
	Role            string
	ProtocolVersion int
	EventID         string
	CommandID       string
	SessionID       string
	EventType       string
	// TerminalStatus 是 turn.completed 的非敏感生命周期投影。Relay 不解密
	// envelope，因此由 Daemon 明确声明正常 idle 或异常 stopped；空值保留
	// v0.5 旧客户端兼容语义（turn.completed 默认 idle）。
	TerminalStatus string
	EnvelopeJSON   string
	// CreatedAtUnixMS 由 Daemon 生成；0 表示旧客户端或历史事件，Relay 不补伪造时间。
	CreatedAtUnixMS int64
}

type DaemonEventResult struct {
	EventID    string
	EventSeq   int64
	Idempotent bool
}

// DaemonService 管理 Terminal 专用协议状态。SessionService 继续拥有 Android 命令创建与
// lease/fencing 语义；DaemonService 只确认目标 Terminal 的接收、执行、结果和事件上传。
type DaemonService struct {
	repo store.Repository
	now  func() time.Time
	// signatureRequired 是 ADR-012 N/N-1 兼容窗口开关：
	// false 为 optional（bearer + 签名双轨），true 为 required（bearer 一律 UPGRADE_REQUIRED）。
	signatureRequired bool
}

func NewDaemonService(repo store.Repository) *DaemonService {
	return &DaemonService{repo: repo, now: time.Now}
}

// Hello 登记或恢复同一 device_id 的 Terminal。device bearer 已由 HTTP 中间件校验活动状态；
// 此处再次锁定 role/account，防止把 Web/Admin token 当作 Daemon 身份使用。
func (s *DaemonService) Hello(ctx context.Context, in DaemonHelloInput) (DaemonHelloResult, error) {
	if in.Role != RoleTerminal || strings.TrimSpace(in.DeviceID) == "" || strings.TrimSpace(in.AccountID) == "" {
		return DaemonHelloResult{}, ErrTerminalRequired
	}
	if err := validateDaemonProtocol(in.ProtocolVersion); err != nil {
		return DaemonHelloResult{}, err
	}
	if err := validateHelloMetadata(in); err != nil {
		return DaemonHelloResult{}, err
	}

	capabilities, err := json.Marshal(uniqueCapabilityNames(in.Capabilities))
	if err != nil {
		return DaemonHelloResult{}, err
	}
	now := s.now().UnixMilli()
	terminal, err := s.repo.TerminalByDeviceID(ctx, in.DeviceID)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return DaemonHelloResult{}, err
	}
	if errors.Is(err, sql.ErrNoRows) {
		terminal = store.TerminalRow{ID: id.New("term"), DeviceID: in.DeviceID, AccountID: in.AccountID}
	} else if terminal.AccountID != in.AccountID {
		return DaemonHelloResult{}, ErrScopeDenied
	}
	terminal.Hostname = strings.TrimSpace(in.Hostname)
	terminal.Platform = strings.TrimSpace(in.Platform)
	terminal.Status = "online"
	terminal.LastSeenUnixMS = now
	terminal.ProtocolVersion = in.ProtocolVersion
	terminal.DaemonVersion = strings.TrimSpace(in.DaemonVersion)
	terminal.CapabilitiesJSON = string(capabilities)
	terminal.LastHeartbeatUnixMS = now
	if err := s.repo.UpsertDaemonTerminal(ctx, terminal); err != nil {
		return DaemonHelloResult{}, err
	}
	if err := s.repo.TouchDeviceLastSeen(ctx, in.DeviceID, now); err != nil {
		return DaemonHelloResult{}, err
	}
	// relay_generation 是 additive 字段（v0.8.9 P1）：读取失败等同于 hello 失败，
	// 不能静默降级为空值让 Daemon 误判为 legacy Relay。
	generation, err := s.repo.RelayGeneration(ctx)
	if err != nil {
		return DaemonHelloResult{}, err
	}
	return DaemonHelloResult{
		Terminal:                 terminal,
		ProtocolVersion:          currentDaemonProtocolVersion,
		MinProtocolVersion:       minDaemonProtocolVersion,
		HeartbeatIntervalSeconds: int(daemonHeartbeatInterval.Seconds()),
		AfterDeliverySeq:         0,
		AuthModes:                s.terminalAuthModes(),
		RelayGeneration:          generation,
	}, nil
}

func (s *DaemonService) Heartbeat(ctx context.Context, accountID, deviceID, role string, protocolVersion int) (DaemonHeartbeatResult, error) {
	if role != RoleTerminal || deviceID == "" {
		return DaemonHeartbeatResult{}, ErrTerminalRequired
	}
	if err := validateDaemonProtocol(protocolVersion); err != nil {
		return DaemonHeartbeatResult{}, err
	}
	terminal, err := s.terminalForDevice(ctx, accountID, deviceID)
	if err != nil {
		return DaemonHeartbeatResult{}, err
	}
	now := s.now().UnixMilli()
	if err := s.repo.TouchTerminal(ctx, terminal.ID, now); err != nil {
		return DaemonHeartbeatResult{}, err
	}
	if err := s.repo.TouchDeviceLastSeen(ctx, deviceID, now); err != nil {
		return DaemonHeartbeatResult{}, err
	}
	generation, err := s.repo.RelayGeneration(ctx)
	if err != nil {
		return DaemonHeartbeatResult{}, err
	}
	return DaemonHeartbeatResult{TerminalID: terminal.ID, ServerTimeUnixMS: now, RelayGeneration: generation}, nil
}

func (s *DaemonService) TerminalForDevice(ctx context.Context, accountID, deviceID, role string) (store.TerminalRow, error) {
	if role != RoleTerminal || deviceID == "" {
		return store.TerminalRow{}, ErrTerminalRequired
	}
	return s.terminalForDevice(ctx, accountID, deviceID)
}

// RecoverTerminalSessions 校验 Terminal 身份与协议窗口后执行进程启动清扫。
// 只有已配对 Terminal 可以声明进程重启——这是新 Daemon 进程的 ground truth 断言，
// Relay 据此收口该 Terminal 工作区遗留的 running 会话（收口语义见
// recoverStaleSessionsForTerminal：不要求心跳失联，但命令/事件证据缺一不可，
// 绝不 archive）。
func (s *DaemonService) RecoverTerminalSessions(ctx context.Context, accountID, deviceID, role string, protocolVersion int) (SessionRecoverySummary, error) {
	if role != RoleTerminal || deviceID == "" {
		return SessionRecoverySummary{}, ErrTerminalRequired
	}
	if err := validateDaemonProtocol(protocolVersion); err != nil {
		return SessionRecoverySummary{}, err
	}
	terminal, err := s.terminalForDevice(ctx, accountID, deviceID)
	if err != nil {
		return SessionRecoverySummary{}, err
	}
	return recoverStaleSessionsForTerminal(ctx, s.repo, accountID, terminal.ID)
}

func (s *DaemonService) terminalForDevice(ctx context.Context, accountID, deviceID string) (store.TerminalRow, error) {
	terminal, err := s.repo.TerminalByDeviceID(ctx, deviceID)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return store.TerminalRow{}, ErrTerminalOffline
		}
		return store.TerminalRow{}, err
	}
	if terminal.AccountID != accountID {
		return store.TerminalRow{}, ErrScopeDenied
	}
	return terminal, nil
}

func (s *DaemonService) ListDeliveries(ctx context.Context, accountID, deviceID, role string, afterDeliverySeq int64) (store.TerminalRow, []store.DaemonDeliveryRow, error) {
	if afterDeliverySeq < 0 {
		return store.TerminalRow{}, nil, protocol.NewError(protocol.ErrInvalidRequest, "after_delivery_seq must be a non-negative integer")
	}
	terminal, err := s.TerminalForDevice(ctx, accountID, deviceID, role)
	if err != nil {
		return store.TerminalRow{}, nil, err
	}
	deliveries, err := s.repo.ListDaemonDeliveriesAfter(ctx, terminal.ID, afterDeliverySeq)
	if err != nil {
		return store.TerminalRow{}, nil, err
	}
	return terminal, deliveries, nil
}

// DeliveryCommandForTerminal 将已持久化的 delivery 投影为 Daemon 可执行的最小命令。这里再次验证
// Session -> Workspace -> Terminal 关系，避免历史/损坏记录或错误 Hub 投递让 Terminal 获得别的
// Workspace 的 opaque payload；canonical_root 永远不离开 Relay。
func (s *DaemonService) DeliveryCommandForTerminal(ctx context.Context, terminal store.TerminalRow, delivery store.DaemonDeliveryRow) (store.CommandRow, string, error) {
	if terminal.ID == "" || delivery.TerminalID != terminal.ID || delivery.CommandID == "" {
		return store.CommandRow{}, "", ErrScopeDenied
	}
	command, err := s.repo.CommandByID(ctx, delivery.CommandID)
	if err != nil {
		return store.CommandRow{}, "", err
	}
	if command.AccountID != terminal.AccountID || command.TargetTerminalID != terminal.ID {
		return store.CommandRow{}, "", ErrScopeDenied
	}
	if isWorkspaceCreateCommand(command) {
		// workspace.create 没有 Session，Workspace ID 从命令的非敏感 payload 复核，
		// 不允许把缺失/伪造的 ID 投影给 daemon。
		var payload struct {
			WorkspaceID string `json:"workspace_id"`
		}
		if err := json.Unmarshal([]byte(command.CiphertextJSON), &payload); err != nil || strings.TrimSpace(payload.WorkspaceID) == "" {
			return store.CommandRow{}, "", ErrScopeDenied
		}
		return command, strings.TrimSpace(payload.WorkspaceID), nil
	}
	if isDSHSyncCommand(command) {
		// workspace.sync_dsh 没有 Session，也不绑定具体 Workspace ID；Daemon 在授权根内
		// 扫描后再通过专用 dsh-workspace-result 回传多个候选，因此这里 workspace_id 为空。
		return command, "", nil
	}
	if isDSHImportCommand(command) {
		// session.import_dsh 没有 Session，但绑定 Workspace；Workspace ID 从 payload 复核。
		var payload struct {
			WorkspaceID string `json:"workspace_id"`
		}
		if err := json.Unmarshal([]byte(command.CiphertextJSON), &payload); err != nil || strings.TrimSpace(payload.WorkspaceID) == "" {
			return store.CommandRow{}, "", ErrScopeDenied
		}
		return command, strings.TrimSpace(payload.WorkspaceID), nil
	}
	session, err := s.repo.SessionByID(ctx, command.SessionID)
	if err != nil {
		return store.CommandRow{}, "", err
	}
	if session.AccountID != terminal.AccountID || session.WorkspaceID == "" {
		return store.CommandRow{}, "", ErrScopeDenied
	}
	workspace, err := s.repo.WorkspaceByID(ctx, session.WorkspaceID)
	if err != nil {
		return store.CommandRow{}, "", err
	}
	if workspace.TerminalID != terminal.ID {
		return store.CommandRow{}, "", ErrScopeDenied
	}
	return command, workspace.ID, nil
}

// Acknowledge 把收到/开始/拒绝写为可重放状态。received 不改变 command 状态；started 重新检查
// 当前 lease/instance，防止旧控制权在网络重连后继续启动 Provider。
func (s *DaemonService) Acknowledge(ctx context.Context, accountID, deviceID, role, commandID string, deliverySeq int64, protocolVersion int, ackKind, errorCode string) (DaemonCommandReceipt, error) {
	if err := validateDaemonProtocol(protocolVersion); err != nil {
		return DaemonCommandReceipt{}, err
	}
	if !validAckKind(ackKind) || deliverySeq <= 0 {
		return DaemonCommandReceipt{}, protocol.NewError(protocol.ErrInvalidRequest, "invalid daemon command acknowledgement")
	}
	terminal, err := s.TerminalForDevice(ctx, accountID, deviceID, role)
	if err != nil {
		return DaemonCommandReceipt{}, err
	}
	var result DaemonCommandReceipt
	err = s.repo.WithTx(ctx, func(ctx context.Context, tx store.Repository) error {
		cmd, delivery, err := daemonCommandForTerminal(ctx, tx, terminal, commandID, deliverySeq)
		if err != nil {
			return err
		}
		if delivery.AckKind == ackKind {
			result = daemonReceipt(cmd, delivery)
			return nil
		}
		if delivery.ResultStatus != "" || isTerminal(cmd.Status) {
			result = daemonReceipt(cmd, delivery)
			return nil
		}
		switch ackKind {
		case "received":
			// 不用 received 覆盖 started/rejected；重试只返回已有更强状态。
			if delivery.AckKind != "" {
				result = daemonReceipt(cmd, delivery)
				return nil
			}
		case "started":
			// browser 只读请求和 workspace 专用命令没有 Android session lease；只有
			// lease_epoch=0 且固定 kind 的命令可走该分支，其他命令仍必须经过既有
			// owner/instance fencing。
			if !isWebReadCommand(cmd) && !isWorkspaceCreateCommand(cmd) && !isDSHSyncCommand(cmd) && !isDSHImportCommand(cmd) {
				if err := validateCommandFence(ctx, tx, cmd); err != nil {
					return err
				}
			}
			if cmd.Status == CommandAccepted {
				if err := tx.UpdateCommandStatus(ctx, cmd.ID, CommandRunning); err != nil {
					return err
				}
				cmd.Status = CommandRunning
			}
		case "rejected":
			if err := tx.UpdateCommandStatus(ctx, cmd.ID, CommandRejected); err != nil {
				return err
			}
			cmd.Status = CommandRejected
		}
		delivery.AckKind = ackKind
		delivery.ErrorCode = safeErrorCode(errorCode)
		delivery.UpdatedAtUnixMS = s.now().UnixMilli()
		if err := tx.UpdateDaemonDelivery(ctx, delivery); err != nil {
			return err
		}
		result = daemonReceipt(cmd, delivery)
		return nil
	})
	if err != nil {
		return DaemonCommandReceipt{}, err
	}
	return result, nil
}

// Resolve 把 Terminal 的终态写回命令。详细输出不能塞入 result API，必须走 event_id 幂等的
// 密文 event 上传；这样 status 轮询不会扩大 Provider 文本可见范围。
func (s *DaemonService) Resolve(ctx context.Context, accountID, deviceID, role, commandID string, deliverySeq int64, protocolVersion int, status, errorCode string) (DaemonCommandReceipt, error) {
	if err := validateDaemonProtocol(protocolVersion); err != nil {
		return DaemonCommandReceipt{}, err
	}
	if deliverySeq <= 0 || !validDaemonResultStatus(status) {
		return DaemonCommandReceipt{}, protocol.NewError(protocol.ErrInvalidRequest, "invalid daemon command result")
	}
	terminal, err := s.TerminalForDevice(ctx, accountID, deviceID, role)
	if err != nil {
		return DaemonCommandReceipt{}, err
	}
	var result DaemonCommandReceipt
	err = s.repo.WithTx(ctx, func(ctx context.Context, tx store.Repository) error {
		cmd, delivery, err := daemonCommandForTerminal(ctx, tx, terminal, commandID, deliverySeq)
		if err != nil {
			return err
		}
		if delivery.ResultStatus != "" || isTerminal(cmd.Status) {
			result = daemonReceipt(cmd, delivery)
			return nil
		}
		if isWorkspaceCreateCommand(cmd) {
			// workspace.create 必须通过专用 result endpoint 携带受控回执，
			// 防止普通 command result 漏出或丢失 canonical_root 绑定。
			return ErrDaemonCommandState
		}
		if !isWebReadCommand(cmd) {
			if err := validateCommandFence(ctx, tx, cmd); err != nil {
				return err
			}
		}
		if cmd.Status != CommandRunning && cmd.Status != CommandAccepted {
			return ErrDaemonCommandState
		}
		if err := tx.UpdateCommandStatus(ctx, cmd.ID, status); err != nil {
			return err
		}
		cmd.Status = status
		delivery.ResultStatus = status
		delivery.ErrorCode = safeErrorCode(errorCode)
		delivery.UpdatedAtUnixMS = s.now().UnixMilli()
		if err := tx.UpdateDaemonDelivery(ctx, delivery); err != nil {
			return err
		}
		if err := tx.AppendAudit(ctx, cmd.AccountID, "daemon.command_resolved", `{"command_id":"`+cmd.ID+`","status":"`+status+`"}`); err != nil {
			return err
		}
		result = daemonReceipt(cmd, delivery)
		return nil
	})
	if err != nil {
		return DaemonCommandReceipt{}, err
	}
	return result, nil
}

// ResolveWorkspace 收口 workspace.create 的 daemon 回执，并在同一事务内登记 Relay Workspace。
// ResolveDSHWorkspace 收口 workspace.sync_dsh 的 daemon 回执，并在同一事务内登记多个 DSH Workspace。
// candidate 的 root 只用于 Relay 内部登记，客户端和普通 result 均不返回路径。
func (s *DaemonService) ResolveDSHWorkspace(ctx context.Context, accountID, deviceID, role, commandID string, deliverySeq int64, protocolVersion int, candidates []WorkspaceDSHSyncCandidate, status, errorCode string) (WorkspaceDSHSyncResult, error) {
	if err := validateDaemonProtocol(protocolVersion); err != nil {
		return WorkspaceDSHSyncResult{}, err
	}
	if deliverySeq <= 0 || !validWorkspaceResultStatus(status) {
		return WorkspaceDSHSyncResult{}, protocol.NewError(protocol.ErrInvalidRequest, "invalid dsh sync result")
	}
	for _, candidate := range candidates {
		if status == CommandSucceeded && (!filepath.IsAbs(candidate.CanonicalRoot) || hasControlCharacter(candidate.CanonicalRoot) || !validDSHWorkspaceDisplayName(candidate.DisplayName)) {
			return WorkspaceDSHSyncResult{}, protocol.NewError(protocol.ErrInvalidRequest, "dsh sync path is invalid")
		}
	}
	terminal, err := s.TerminalForDevice(ctx, accountID, deviceID, role)
	if err != nil {
		return WorkspaceDSHSyncResult{}, err
	}
	var result WorkspaceDSHSyncResult
	err = s.repo.WithTx(ctx, func(ctx context.Context, tx store.Repository) error {
		cmd, delivery, err := daemonCommandForTerminal(ctx, tx, terminal, commandID, deliverySeq)
		if err != nil {
			return err
		}
		if !isDSHSyncCommand(cmd) {
			return ErrScopeDenied
		}
		if existing, lookupErr := tx.WorkspaceCommandResultByCommandID(ctx, cmd.ID); lookupErr == nil {
			if existing.AccountID != accountID {
				return ErrScopeDenied
			}
			result = dshSyncResultFromRow(ctx, tx, existing)
			result.DeliverySeq = delivery.DeliverySeq
			return nil
		} else if !errors.Is(lookupErr, sql.ErrNoRows) {
			return lookupErr
		}
		if delivery.ResultStatus != "" || isTerminal(cmd.Status) {
			return ErrDaemonCommandState
		}
		var workspaceIDs []string
		if status == CommandSucceeded {
			// 同一 Terminal 的每个 canonical root 都生成稳定 Workspace/Project ID。
			// 已有 Workspace 只确认归属，不覆盖 TerminalID/CanonicalRoot。
			seenRoots := map[string]struct{}{}
			for _, candidate := range candidates {
				root := candidate.CanonicalRoot
				if root == "" {
					return ErrScopeDenied
				}
				if _, exists := seenRoots[root]; exists {
					// Daemon 重试或故障重复候选不能制造重复 Workspace，也不能改变结果计数。
					continue
				}
				seenRoots[root] = struct{}{}
				workspaceID, projectID := stableDSHWorkspaceIDs(accountID, terminal.ID, root)
				projects, projErr := tx.ListProjects(ctx, accountID)
				if projErr != nil {
					return projErr
				}
				projectOwned := false
				for _, project := range projects {
					if project.ID == projectID && project.AccountID == accountID {
						projectOwned = true
						break
					}
				}
				if !projectOwned {
					if err := tx.CreateProject(ctx, store.ProjectRow{ID: projectID, AccountID: accountID, Fingerprint: "fp_" + projectID}); err != nil {
						return err
					}
				}
				workspace, lookupErr := tx.WorkspaceByID(ctx, workspaceID)
				if lookupErr == nil {
					if workspace.ProjectID != projectID || workspace.TerminalID != terminal.ID || workspace.CanonicalRoot != root {
						return ErrScopeDenied
					}
					if err := tx.UpdateWorkspaceDSHMetadata(ctx, workspaceID, candidate.DisplayName); err != nil {
						return err
					}
				} else if errors.Is(lookupErr, sql.ErrNoRows) {
					workspace = store.WorkspaceRow{
						ID: workspaceID, ProjectID: projectID, TerminalID: terminal.ID, CanonicalRoot: root, Status: "active",
						Origin: store.WorkspaceOriginDSH, DisplayName: candidate.DisplayName,
					}
					if err := tx.CreateWorkspace(ctx, workspace); err != nil {
						return err
					}
				} else {
					return lookupErr
				}
				workspaceIDs = append(workspaceIDs, workspaceID)
			}
		}
		if err := tx.UpdateCommandStatus(ctx, cmd.ID, status); err != nil {
			return err
		}
		cmd.Status = status
		delivery.ResultStatus = status
		delivery.ErrorCode = safeErrorCode(errorCode)
		delivery.UpdatedAtUnixMS = s.now().UnixMilli()
		if err := tx.UpdateDaemonDelivery(ctx, delivery); err != nil {
			return err
		}
		workspaceIDsJSON, _ := json.Marshal(struct {
			WorkspaceIDs []string `json:"workspace_ids"`
		}{WorkspaceIDs: workspaceIDs})
		if err := tx.UpsertWorkspaceCommandResult(ctx, store.WorkspaceCommandResultRow{
			CommandID: cmd.ID, AccountID: accountID, WorkspaceID: "", CanonicalRoot: string(workspaceIDsJSON),
			Status: status, ErrorCode: safeErrorCode(errorCode), CreatedAtUnixMS: s.now().UnixMilli(),
		}); err != nil {
			return err
		}
		if err := tx.AppendAudit(ctx, accountID, "workspace.sync_dsh.resolved", `{"command_id":"`+cmd.ID+`","status":"`+status+`","count":`+fmt.Sprint(len(workspaceIDs))+`}`); err != nil {
			return err
		}
		if err := tx.EnqueueOutbox(ctx, store.OutboxRow{Kind: "command.updated", PayloadJSON: `{"command_id":"` + cmd.ID + `"}`, Status: "pending"}); err != nil {
			return err
		}
		result = WorkspaceDSHSyncResult{CommandID: cmd.ID, DeliverySeq: delivery.DeliverySeq, Status: status, ErrorCode: safeErrorCode(errorCode), WorkspaceIDs: workspaceIDs}
		return nil
	})
	if err != nil {
		return WorkspaceDSHSyncResult{}, err
	}
	return result, nil
}

// validDSHWorkspaceDisplayName 是 Relay 的 fail-closed 校验，不从 root 重新推导显示名。
// 这样即使私有 Daemon 请求被伪造，也不会把路径片段放进公开 Workspace view。
func validDSHWorkspaceDisplayName(value string) bool {
	value = strings.TrimSpace(value)
	if value == "" || value == "." || value == ".." || len(value) > 128 || !utf8.ValidString(value) ||
		strings.ContainsAny(value, `/\\`) || filepath.IsAbs(value) || filepath.VolumeName(value) != "" {
		return false
	}
	if len(value) >= 2 && value[1] == ':' && ((value[0] >= 'A' && value[0] <= 'Z') || (value[0] >= 'a' && value[0] <= 'z')) {
		return false
	}
	for _, r := range value {
		if r < 0x20 || r == 0x7f {
			return false
		}
	}
	return true
}

func dshSyncResultFromRow(ctx context.Context, repo store.Repository, row store.WorkspaceCommandResultRow) WorkspaceDSHSyncResult {
	result := WorkspaceDSHSyncResult{CommandID: row.CommandID, Status: row.Status, ErrorCode: row.ErrorCode}
	if row.Status == CommandSucceeded {
		var payload struct {
			WorkspaceIDs []string `json:"workspace_ids"`
		}
		_ = json.Unmarshal([]byte(row.CanonicalRoot), &payload)
		result.WorkspaceIDs = payload.WorkspaceIDs
	}
	return result
}

// ResolveDSHImport 收口 session.import_dsh 的 daemon 回执，并在同一事务内登记 Relay Session。
// sessionIDs 是 Relay opaque session id 白名单；cwd、DSH id、路径和正文都不进入该回执。
func (s *DaemonService) ResolveDSHImport(ctx context.Context, accountID, deviceID, role, commandID string, deliverySeq int64, protocolVersion int, sessionIDs []string, status, errorCode string) (WorkspaceDSHImportResult, error) {
	if err := validateDaemonProtocol(protocolVersion); err != nil {
		return WorkspaceDSHImportResult{}, err
	}
	if deliverySeq <= 0 || !validWorkspaceResultStatus(status) {
		return WorkspaceDSHImportResult{}, protocol.NewError(protocol.ErrInvalidRequest, "invalid dsh import result")
	}
	terminal, err := s.TerminalForDevice(ctx, accountID, deviceID, role)
	if err != nil {
		return WorkspaceDSHImportResult{}, err
	}
	var result WorkspaceDSHImportResult
	err = s.repo.WithTx(ctx, func(ctx context.Context, tx store.Repository) error {
		cmd, delivery, err := daemonCommandForTerminal(ctx, tx, terminal, commandID, deliverySeq)
		if err != nil {
			return err
		}
		if !isDSHImportCommand(cmd) {
			return ErrScopeDenied
		}
		if existing, lookupErr := tx.WorkspaceCommandResultByCommandID(ctx, cmd.ID); lookupErr == nil {
			if existing.AccountID != accountID {
				return ErrScopeDenied
			}
			result = dshImportResultFromRow(ctx, tx, existing)
			result.DeliverySeq = delivery.DeliverySeq
			return nil
		} else if !errors.Is(lookupErr, sql.ErrNoRows) {
			return lookupErr
		}
		if delivery.ResultStatus != "" || isTerminal(cmd.Status) {
			return ErrDaemonCommandState
		}
		var payload struct {
			WorkspaceID string `json:"workspace_id"`
		}
		if err := json.Unmarshal([]byte(cmd.CiphertextJSON), &payload); err != nil || strings.TrimSpace(payload.WorkspaceID) == "" {
			return ErrScopeDenied
		}
		if status == CommandSucceeded {
			for _, sessionID := range sessionIDs {
				if strings.TrimSpace(sessionID) == "" {
					return ErrScopeDenied
				}
				if err := tx.CreateSession(ctx, store.SessionRow{
					ID: sessionID, WorkspaceID: payload.WorkspaceID, AccountID: accountID,
					Status: SessionIdle, Provider: "dsh",
				}); err != nil {
					// 已存在的同 id 会话视为幂等确认，不覆盖归属。
					if !strings.Contains(err.Error(), "UNIQUE") && !strings.Contains(err.Error(), "constraint") {
						return err
					}
				}
				// 导入成功是可审计的会话状态写入，记录其真实写入时间以便列表排序。
				if err := tx.SetSessionStatusAt(ctx, sessionID, SessionIdle, s.now().UnixMilli()); err != nil {
					return err
				}
			}
		}
		if err := tx.UpdateCommandStatus(ctx, cmd.ID, status); err != nil {
			return err
		}
		cmd.Status = status
		delivery.ResultStatus = status
		delivery.ErrorCode = safeErrorCode(errorCode)
		delivery.UpdatedAtUnixMS = s.now().UnixMilli()
		if err := tx.UpdateDaemonDelivery(ctx, delivery); err != nil {
			return err
		}
		sessionIDsJSON, _ := json.Marshal(struct {
			SessionIDs []string `json:"session_ids"`
		}{SessionIDs: sessionIDs})
		if err := tx.UpsertWorkspaceCommandResult(ctx, store.WorkspaceCommandResultRow{
			CommandID: cmd.ID, AccountID: accountID, WorkspaceID: payload.WorkspaceID, CanonicalRoot: string(sessionIDsJSON),
			Status: status, ErrorCode: safeErrorCode(errorCode), CreatedAtUnixMS: s.now().UnixMilli(),
		}); err != nil {
			return err
		}
		if err := tx.AppendAudit(ctx, accountID, "session.import_dsh.resolved", `{"command_id":"`+cmd.ID+`","status":"`+status+`","count":`+fmt.Sprint(len(sessionIDs))+`}`); err != nil {
			return err
		}
		if err := tx.EnqueueOutbox(ctx, store.OutboxRow{Kind: "command.updated", PayloadJSON: `{"command_id":"` + cmd.ID + `"}`, Status: "pending"}); err != nil {
			return err
		}
		result = WorkspaceDSHImportResult{CommandID: cmd.ID, DeliverySeq: delivery.DeliverySeq, Status: status, ErrorCode: safeErrorCode(errorCode), SessionIDs: sessionIDs}
		return nil
	})
	if err != nil {
		return WorkspaceDSHImportResult{}, err
	}
	return result, nil
}

func dshImportResultFromRow(ctx context.Context, repo store.Repository, row store.WorkspaceCommandResultRow) WorkspaceDSHImportResult {
	result := WorkspaceDSHImportResult{CommandID: row.CommandID, Status: row.Status, ErrorCode: row.ErrorCode}
	if row.Status == CommandSucceeded {
		var payload struct {
			SessionIDs []string `json:"session_ids"`
		}
		_ = json.Unmarshal([]byte(row.CanonicalRoot), &payload)
		result.SessionIDs = payload.SessionIDs
	}
	return result
}

func isDSHSyncCommand(command store.CommandRow) bool {
	return command.Kind == "workspace.sync_dsh" && command.SessionID == ""
}

func isDSHImportCommand(command store.CommandRow) bool {
	return command.Kind == "session.import_dsh" && command.SessionID == ""
}

// canonicalRoot 仅写入 workspace_command_results/workspaces，普通 command receipt 不会携带它。
func (s *DaemonService) ResolveWorkspace(ctx context.Context, accountID, deviceID, role, commandID string, deliverySeq int64, protocolVersion int, workspaceID, canonicalRoot, status, errorCode string) (WorkspaceCommandResult, error) {
	if err := validateDaemonProtocol(protocolVersion); err != nil {
		return WorkspaceCommandResult{}, err
	}
	if deliverySeq <= 0 || !validWorkspaceResultStatus(status) || strings.TrimSpace(workspaceID) == "" {
		return WorkspaceCommandResult{}, protocol.NewError(protocol.ErrInvalidRequest, "invalid workspace command result")
	}
	canonicalRoot = strings.TrimSpace(canonicalRoot)
	if status == CommandSucceeded && (!filepath.IsAbs(canonicalRoot) || hasControlCharacter(canonicalRoot)) {
		return WorkspaceCommandResult{}, protocol.NewError(protocol.ErrInvalidRequest, "workspace result path is invalid")
	}
	terminal, err := s.TerminalForDevice(ctx, accountID, deviceID, role)
	if err != nil {
		return WorkspaceCommandResult{}, err
	}
	var result WorkspaceCommandResult
	err = s.repo.WithTx(ctx, func(ctx context.Context, tx store.Repository) error {
		cmd, delivery, err := daemonCommandForTerminal(ctx, tx, terminal, commandID, deliverySeq)
		if err != nil {
			return err
		}
		if !isWorkspaceCreateCommand(cmd) {
			return ErrScopeDenied
		}
		var payload struct {
			WorkspaceID string `json:"workspace_id"`
			ProjectID   string `json:"project_id"`
			Name        string `json:"name"`
		}
		if err := json.Unmarshal([]byte(cmd.CiphertextJSON), &payload); err != nil ||
			strings.TrimSpace(payload.WorkspaceID) != strings.TrimSpace(workspaceID) ||
			strings.TrimSpace(payload.ProjectID) == "" {
			return ErrScopeDenied
		}
		if existing, lookupErr := tx.WorkspaceCommandResultByCommandID(ctx, cmd.ID); lookupErr == nil {
			if existing.AccountID != accountID || existing.WorkspaceID != workspaceID {
				return ErrScopeDenied
			}
			result = workspaceCommandResultFromRow(ctx, tx, existing)
			result.DeliverySeq = delivery.DeliverySeq
			return nil
		} else if !errors.Is(lookupErr, sql.ErrNoRows) {
			return lookupErr
		}
		if delivery.ResultStatus != "" || isTerminal(cmd.Status) {
			return ErrDaemonCommandState
		}

		if status == CommandSucceeded {
			// 名称仍在 Relay 根因层复核，避免被伪造 payload 写入奇怪的 project 索引。
			if err := validateWorkspaceCreateName(payload.Name); err != nil {
				return err
			}
			projects, err := tx.ListProjects(ctx, accountID)
			if err != nil {
				return err
			}
			projectOwned := false
			for _, project := range projects {
				if project.ID == payload.ProjectID {
					projectOwned = project.AccountID == accountID
					break
				}
			}
			if !projectOwned {
				if err := tx.CreateProject(ctx, store.ProjectRow{ID: payload.ProjectID, AccountID: accountID, Fingerprint: "fp_" + payload.ProjectID}); err != nil {
					return err
				}
			}
			workspace, lookupErr := tx.WorkspaceByID(ctx, workspaceID)
			if lookupErr == nil {
				if workspace.ProjectID != payload.ProjectID || workspace.TerminalID != terminal.ID {
					return ErrScopeDenied
				}
				result.Workspace = workspace
			} else if !errors.Is(lookupErr, sql.ErrNoRows) {
				return lookupErr
			} else {
				workspace = store.WorkspaceRow{ID: workspaceID, ProjectID: payload.ProjectID, TerminalID: terminal.ID, CanonicalRoot: canonicalRoot, Status: "active"}
				if err := tx.CreateWorkspace(ctx, workspace); err != nil {
					return err
				}
				result.Workspace = workspace
			}
			result.HasWorkspace = true
		}
		if err := tx.UpdateCommandStatus(ctx, cmd.ID, status); err != nil {
			return err
		}
		cmd.Status = status
		delivery.ResultStatus = status
		delivery.ErrorCode = safeErrorCode(errorCode)
		delivery.UpdatedAtUnixMS = s.now().UnixMilli()
		if err := tx.UpdateDaemonDelivery(ctx, delivery); err != nil {
			return err
		}
		if err := tx.UpsertWorkspaceCommandResult(ctx, store.WorkspaceCommandResultRow{
			CommandID: cmd.ID, AccountID: accountID, WorkspaceID: workspaceID,
			CanonicalRoot: canonicalRoot, Status: status, ErrorCode: safeErrorCode(errorCode),
			CreatedAtUnixMS: s.now().UnixMilli(),
		}); err != nil {
			return err
		}
		if err := tx.AppendAudit(ctx, accountID, "workspace.create.resolved", `{"command_id":"`+cmd.ID+`","workspace_id":"`+workspaceID+`","status":"`+status+`"}`); err != nil {
			return err
		}
		if err := tx.EnqueueOutbox(ctx, store.OutboxRow{Kind: "command.updated", PayloadJSON: `{"command_id":"` + cmd.ID + `"}`, Status: "pending"}); err != nil {
			return err
		}
		result.CommandID, result.DeliverySeq, result.WorkspaceID, result.Status, result.ErrorCode = cmd.ID, delivery.DeliverySeq, workspaceID, status, safeErrorCode(errorCode)
		return nil
	})
	if err != nil {
		return WorkspaceCommandResult{}, err
	}
	return result, nil
}

func workspaceCommandResultFromRow(ctx context.Context, repo store.Repository, row store.WorkspaceCommandResultRow) WorkspaceCommandResult {
	result := WorkspaceCommandResult{CommandID: row.CommandID, WorkspaceID: row.WorkspaceID, Status: row.Status, ErrorCode: row.ErrorCode}
	if row.Status == CommandSucceeded {
		if workspace, err := repo.WorkspaceByID(ctx, row.WorkspaceID); err == nil {
			result.Workspace, result.HasWorkspace = workspace, true
		}
	}
	return result
}

func validWorkspaceResultStatus(status string) bool {
	switch status {
	case CommandSucceeded, CommandFailed, CommandCancelled:
		return true
	default:
		return false
	}
}

func isWorkspaceCreateCommand(command store.CommandRow) bool {
	return command.Kind == "workspace.create" && command.SessionID == ""
}

func validateWorkspaceCreateName(name string) error {
	// 领域层复用 workspacesafe 的名称规则，避免 HTTP 与 daemon 两套口径漂移。
	return workspacesafe.ValidateWorkspaceName(name)
}

func hasControlCharacter(value string) bool {
	for _, r := range value {
		if r == 0 || r < 0x20 {
			return true
		}
	}
	return false
}

// StoreWebReadResponse 保存 Daemon 对浏览器临时公钥回封的结果。该 endpoint 不接受普通 event，
// 因此文件、代码和 diff 不会流入 account SSE 或 session_events；Relay 只保留 opaque envelope。
func (s *DaemonService) StoreWebReadResponse(ctx context.Context, accountID, deviceID, role, commandID string, deliverySeq int64, protocolVersion int, envelopeJSON string) (DaemonCommandReceipt, error) {
	if err := validateDaemonProtocol(protocolVersion); err != nil {
		return DaemonCommandReceipt{}, err
	}
	if deliverySeq <= 0 || len(envelopeJSON) == 0 || len(envelopeJSON) > maxWebReadEnvelopeBytes || !validWebReadResponseEnvelope(envelopeJSON) {
		return DaemonCommandReceipt{}, protocol.NewError(protocol.ErrInvalidRequest, "invalid web read response envelope")
	}
	terminal, err := s.TerminalForDevice(ctx, accountID, deviceID, role)
	if err != nil {
		return DaemonCommandReceipt{}, err
	}
	var result DaemonCommandReceipt
	err = s.repo.WithTx(ctx, func(ctx context.Context, tx store.Repository) error {
		cmd, delivery, err := daemonCommandForTerminal(ctx, tx, terminal, commandID, deliverySeq)
		if err != nil {
			return err
		}
		if !isWebReadCommand(cmd) {
			return ErrScopeDenied
		}
		// 只有 Terminal 已确认开始处理的 delivery 才能回填响应。否则任意持有 Terminal token 的
		// 调用方都可能抢在本机 fence/解密前写入伪造 envelope，破坏 command 状态机。
		if delivery.AckKind != "started" {
			return ErrDaemonCommandState
		}
		if cmd.ReadResponseEnvelopeJSON != "" && cmd.ReadResponseEnvelopeJSON != envelopeJSON {
			return ErrDaemonCommandState
		}
		if cmd.Status != CommandRunning && cmd.Status != CommandSucceeded {
			return ErrDaemonCommandState
		}
		if cmd.Status == CommandSucceeded && cmd.ReadResponseEnvelopeJSON == "" {
			return ErrDaemonCommandState
		}
		if cmd.ReadResponseEnvelopeJSON == "" {
			if err := tx.SetCommandReadResponse(ctx, cmd.ID, envelopeJSON); err != nil {
				return err
			}
		}
		result = daemonReceipt(cmd, delivery)
		return nil
	})
	if err != nil {
		return DaemonCommandReceipt{}, err
	}
	return result, nil
}

// UploadEvent 写入与 command 绑定的 canonical event。Relay 不解密 event envelope，且 event_id
// 先在同一事务占位，避免失联重试时重复追加 session_events。
// SyncSessionPermissionModes 保存 Daemon 上行同步的会话级运行期元数据快照
// (v0.8.5 §3.4/§3.8)：permission mode 目录 + agent preset。校验：设备必须是已
// 登记 Terminal，会话必须属于该账号，且会话 workspace 的 home Terminal 必须就是
// 当前 Terminal——这些事实来自运行期 handle，只有拥有该会话的 Daemon 可以写，
// 其它 Terminal/账号一律 fail-closed。modesJSON 只允许合法 JSON 数组文本 (<= 64 条)，
// Relay 不解释 mode/preset 语义。
func (s *DaemonService) SyncSessionPermissionModes(ctx context.Context, accountID, deviceID, role, sessionID, modeID, modesJSON, agentPresetID string) error {
	if strings.TrimSpace(sessionID) == "" {
		return protocol.NewError(protocol.ErrInvalidRequest, "session_id required")
	}
	terminal, err := s.TerminalForDevice(ctx, accountID, deviceID, role)
	if err != nil {
		return err
	}
	session, err := s.repo.SessionByID(ctx, sessionID)
	if err != nil {
		return err
	}
	if session.AccountID != accountID {
		return ErrScopeDenied
	}
	workspace, err := s.repo.WorkspaceByID(ctx, session.WorkspaceID)
	if err != nil {
		return err
	}
	if workspace.TerminalID != terminal.ID {
		return ErrScopeDenied
	}
	if modesJSON != "" {
		var raw []json.RawMessage
		if err := json.Unmarshal([]byte(modesJSON), &raw); err != nil || len(raw) > 64 {
			return protocol.NewError(protocol.ErrInvalidRequest, "available_permission_modes must be a JSON array (<=64)")
		}
	}
	// agent_preset_id 是同一会话元数据上行的可选字段（v0.8.5 §3.8）：空串清空快照。
	if err := s.repo.SetSessionPermissionModes(ctx, session.ID, modeID, modesJSON); err != nil {
		return err
	}
	return s.repo.SetSessionAgentPreset(ctx, session.ID, strings.TrimSpace(agentPresetID))
}

// AttachmentReadProjection 是 Daemon 附件读取的最小密文投影（v0.8.5 §3.3）：
// Relay 只回传存储中的密文块与元数据密文，不回显任何可识别元数据（文件名/
// 明文正文/大小之外的白名单字段由 Daemon 端解密 metadata 后自行获得）。
type AttachmentReadProjection struct {
	AttachmentID       string
	SessionID          string
	MimeType           string
	ByteSize           int64
	TotalChunks        int
	MetadataCiphertext []byte
	Chunks             [][]byte
	ChunkSHA256        []string
	Status             string
}

// ReadAttachmentForDaemon 让拥有该会话的 home Terminal 读取附件密文（§3.3）。
// 归属链：attachment.session -> session.workspace -> workspace.home terminal；
// 其它 Terminal/账号 fail-closed。只读操作不做 lease 检查（附件状态已完成才可读），
// 未完成附件返回 ErrAttachmentIncomplete。
func (s *DaemonService) ReadAttachmentForDaemon(ctx context.Context, accountID, deviceID, role, attachmentID string) (AttachmentReadProjection, error) {
	if strings.TrimSpace(attachmentID) == "" {
		return AttachmentReadProjection{}, protocol.NewError(protocol.ErrInvalidRequest, "attachment_id required")
	}
	terminal, err := s.TerminalForDevice(ctx, accountID, deviceID, role)
	if err != nil {
		return AttachmentReadProjection{}, err
	}
	attachment, err := s.repo.AttachmentByID(ctx, attachmentID)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return AttachmentReadProjection{}, ErrAttachmentNotFound
		}
		return AttachmentReadProjection{}, err
	}
	if attachment.AccountID != accountID {
		return AttachmentReadProjection{}, ErrScopeDenied
	}
	session, err := s.repo.SessionByID(ctx, attachment.SessionID)
	if err != nil {
		return AttachmentReadProjection{}, err
	}
	workspace, err := s.repo.WorkspaceByID(ctx, session.WorkspaceID)
	if err != nil {
		return AttachmentReadProjection{}, err
	}
	if workspace.TerminalID != terminal.ID {
		return AttachmentReadProjection{}, ErrScopeDenied
	}
	if attachment.Status != AttachmentCompleted {
		return AttachmentReadProjection{}, ErrAttachmentIncomplete
	}
	chunks, err := s.repo.ListAttachmentChunks(ctx, attachment.ID)
	if err != nil {
		return AttachmentReadProjection{}, err
	}
	out := AttachmentReadProjection{
		AttachmentID: attachment.ID, SessionID: attachment.SessionID, MimeType: attachment.MimeType,
		ByteSize: attachment.ByteSize, TotalChunks: attachment.TotalChunks,
		MetadataCiphertext: attachment.MetadataCiphertext, Status: attachment.Status,
	}
	for _, chunk := range chunks {
		out.Chunks = append(out.Chunks, chunk.Ciphertext)
		out.ChunkSHA256 = append(out.ChunkSHA256, chunk.CiphertextSHA256)
	}
	return out, nil
}

func (s *DaemonService) UploadEvent(ctx context.Context, in DaemonEventInput) (DaemonEventResult, error) {
	if err := validateDaemonProtocol(in.ProtocolVersion); err != nil {
		return DaemonEventResult{}, err
	}
	if strings.TrimSpace(in.EventID) == "" || strings.TrimSpace(in.CommandID) == "" || strings.TrimSpace(in.SessionID) == "" || !validDaemonEventType(in.EventType) {
		return DaemonEventResult{}, protocol.NewError(protocol.ErrInvalidRequest, "invalid daemon event metadata")
	}
	if err := validateDaemonTerminalStatus(in.EventType, in.TerminalStatus); err != nil {
		return DaemonEventResult{}, err
	}
	envelope, err := normalizeDaemonCipherEnvelope(in.EnvelopeJSON)
	if err != nil {
		return DaemonEventResult{}, err
	}
	terminal, err := s.TerminalForDevice(ctx, in.AccountID, in.DeviceID, in.Role)
	if err != nil {
		return DaemonEventResult{}, err
	}
	var result DaemonEventResult
	err = s.repo.WithTx(ctx, func(ctx context.Context, tx store.Repository) error {
		if existing, lookupErr := tx.DaemonEventReceiptByID(ctx, in.EventID); lookupErr == nil {
			if existing.TerminalID != terminal.ID || existing.CommandID != in.CommandID || existing.SessionID != in.SessionID {
				return ErrScopeDenied
			}
			if existing.EventSeq <= 0 {
				return ErrDaemonCommandState
			}
			result = DaemonEventResult{EventID: existing.EventID, EventSeq: existing.EventSeq, Idempotent: true}
			return nil
		} else if !errors.Is(lookupErr, sql.ErrNoRows) {
			return lookupErr
		}

		cmd, _, commandErr := daemonCommandForTerminal(ctx, tx, terminal, in.CommandID, 0)
		if commandErr != nil {
			return commandErr
		}
		if cmd.SessionID != in.SessionID {
			return ErrScopeDenied
		}
		// 事件上传只校验命令存在性与终端归属，不做 lease epoch fence：
		// 回合是会话所有的后台任务，epoch 翻转（含在飞命令被接管作废）不得把
		// 已发生的事实性事件打成死信——客户端必须最终收到 turn 终态
		// （ADR-009 决策 5 的 fence 范围仅限命令 ack/执行，不含事件上传）。
		if err := tx.CreateDaemonEventReceipt(ctx, store.DaemonEventReceiptRow{
			EventID: in.EventID, TerminalID: terminal.ID, CommandID: in.CommandID, SessionID: in.SessionID,
			CreatedAtUnixMS: s.now().UnixMilli(),
		}); err != nil {
			return err
		}
		seq, appendErr := tx.AppendEvent(ctx, store.SessionEventRow{
			SessionID: in.SessionID, EventType: in.EventType, TerminalStatus: in.TerminalStatus, EnvelopeJSON: envelope,
			CreatedAtUnixMS: in.CreatedAtUnixMS,
		})
		if appendErr != nil {
			return appendErr
		}
		if err := tx.SetSessionLastSeq(ctx, in.SessionID, seq); err != nil {
			return err
		}
		status := sessionStatusForDaemonEvent(in.EventType, in.TerminalStatus)
		if status != "" {
			if err := tx.SetSessionStatus(ctx, in.SessionID, status); err != nil {
				return err
			}
		}
		if err := tx.SetDaemonEventReceiptSeq(ctx, in.EventID, seq); err != nil {
			return err
		}
		result = DaemonEventResult{EventID: in.EventID, EventSeq: seq}
		return nil
	})
	if err != nil {
		return DaemonEventResult{}, err
	}
	return result, nil
}

func daemonCommandForTerminal(ctx context.Context, repo store.Repository, terminal store.TerminalRow, commandID string, deliverySeq int64) (store.CommandRow, store.DaemonDeliveryRow, error) {
	cmd, err := repo.CommandByID(ctx, commandID)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return store.CommandRow{}, store.DaemonDeliveryRow{}, store.ErrNotFound
		}
		return store.CommandRow{}, store.DaemonDeliveryRow{}, err
	}
	if cmd.AccountID != terminal.AccountID || cmd.TargetTerminalID != terminal.ID {
		return store.CommandRow{}, store.DaemonDeliveryRow{}, ErrScopeDenied
	}
	delivery, err := repo.DaemonDeliveryByCommandID(ctx, commandID)
	if err != nil {
		return store.CommandRow{}, store.DaemonDeliveryRow{}, err
	}
	if delivery.TerminalID != terminal.ID || (deliverySeq > 0 && delivery.DeliverySeq != deliverySeq) {
		return store.CommandRow{}, store.DaemonDeliveryRow{}, ErrScopeDenied
	}
	return cmd, delivery, nil
}

func validateCommandFence(ctx context.Context, repo store.Repository, cmd store.CommandRow) error {
	if cmd.SessionID == "" || cmd.LeaseEpoch <= 0 {
		return ErrTargetStale
	}
	session, err := repo.SessionByID(ctx, cmd.SessionID)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return ErrSessionNotFound
		}
		return err
	}
	lease, err := repo.LeaseBySession(ctx, cmd.SessionID)
	if err != nil {
		return ErrTargetStale
	}
	if lease.Epoch != cmd.LeaseEpoch {
		return ErrTargetStale
	}
	if session.CurrentInstanceID != "" && cmd.TargetInstanceID != session.CurrentInstanceID {
		return ErrTargetStale
	}
	if lease.InstanceID != "" && cmd.TargetInstanceID != lease.InstanceID {
		return ErrTargetStale
	}
	return nil
}

func daemonReceipt(cmd store.CommandRow, delivery store.DaemonDeliveryRow) DaemonCommandReceipt {
	return DaemonCommandReceipt{
		CommandID: cmd.ID, DeliverySeq: delivery.DeliverySeq, AckKind: delivery.AckKind,
		Status: cmd.Status, ErrorCode: delivery.ErrorCode,
	}
}

func validateDaemonProtocol(version int) error {
	if version < minDaemonProtocolVersion {
		return ErrProtocolUpgradeRequired
	}
	if version > currentDaemonProtocolVersion {
		return ErrProtocolUnsupported
	}
	return nil
}

func validateHelloMetadata(in DaemonHelloInput) error {
	if strings.TrimSpace(in.DaemonVersion) == "" || strings.TrimSpace(in.Hostname) == "" || strings.TrimSpace(in.Platform) == "" || len(in.Capabilities) > 64 {
		return protocol.NewError(protocol.ErrInvalidRequest, "invalid daemon hello metadata")
	}
	for _, capability := range in.Capabilities {
		if value := strings.TrimSpace(capability); value == "" || len(value) > 96 {
			return protocol.NewError(protocol.ErrInvalidRequest, "invalid daemon capability")
		}
	}
	return nil
}

func uniqueCapabilityNames(values []string) []string {
	seen := make(map[string]struct{}, len(values))
	out := make([]string, 0, len(values))
	for _, raw := range values {
		value := strings.TrimSpace(raw)
		if _, ok := seen[value]; ok {
			continue
		}
		seen[value] = struct{}{}
		out = append(out, value)
	}
	return out
}

func validAckKind(value string) bool {
	switch value {
	case "received", "started", "rejected":
		return true
	}
	return false
}

func validDaemonResultStatus(value string) bool {
	switch value {
	case CommandSucceeded, CommandFailed, CommandCancelled:
		return true
	}
	return false
}

func validWebReadResponseEnvelope(raw string) bool {
	if !validWebReadEnvelopeObject(raw, "alg", "payload_version", "nonce", "ciphertext", "aad_hash") {
		return false
	}
	var envelope struct {
		Alg            string `json:"alg"`
		PayloadVersion int    `json:"payload_version"`
		Nonce          string `json:"nonce"`
		Ciphertext     string `json:"ciphertext"`
		AADHash        string `json:"aad_hash"`
	}
	return json.Unmarshal([]byte(raw), &envelope) == nil &&
		envelope.Alg == WebReadEnvelopeAlgorithm && envelope.PayloadVersion == 1 &&
		validWebReadCipherFields(envelope.Nonce, envelope.Ciphertext, envelope.AADHash)
}

func validDaemonEventType(value string) bool {
	// 与 packages/protocol/schema/events.json 的 event_type enum 保持一致
	// （单一真值）；缺了就会把合法事件打成 400 永久死信（V085-25：v0.8.4 的
	// message.thought_delta / turn.phase 从未进过白名单，真实流式回合的
	// reasoning/相位帧全部被拒收）。
	switch value {
	case "session.lifecycle", "session.aborted", "turn.started", "user.message",
		"message.delta", "message.thought_delta", "message.completed",
		"turn.completed", "turn.phase", "session.activity",
		"tool.call", "tool.result",
		"permission.request", "permission.decision", "user.question",
		"plan.changed", "goal.changed", "skill.catalog_changed",
		"usage.updated", "file.changed", "git.snapshot", "command.updated",
		"delegation.changed":
		return true
	}
	return false
}

// validateDaemonTerminalStatus 检查 Daemon 对终态事件提供的稳定状态投影。
// 该字段不能被用于把任意中间事件伪装成终态；未知值也必须拒绝，避免
// Relay/Flutter 在不同实现间产生不一致的 running/idle/stopped 解释。
// v0.8.5：session.aborted 是 Abort 成功的非敏感停止事实，允许其携带 stopped
// （Relay 无需解密 payload 即可把会话投影为 stopped；只接受 stopped，不接受 idle）。
func validateDaemonTerminalStatus(eventType, terminalStatus string) error {
	status := strings.TrimSpace(terminalStatus)
	if status == "" {
		return nil // 兼容旧 Daemon；turn.completed 缺省按 idle 处理。
	}
	switch eventType {
	case "turn.completed":
		if status == SessionIdle || status == SessionStopped {
			return nil
		}
	case "session.aborted":
		if status == SessionStopped {
			return nil
		}
	}
	return protocol.NewError(protocol.ErrInvalidRequest, "invalid daemon terminal status")
}

// sessionStatusForDaemonEvent 将公开生命周期投影收口为 Relay 会话状态。
// 只有真正开始回合的事件能进入 running，只有 turn.completed 能结束回合；消息、
// 用量和 command.updated 等旁路事件必须返回空值，保留先前的生命周期终态。
func sessionStatusForDaemonEvent(eventType, terminalStatus string) string {
	switch eventType {
	case "session.aborted":
		return SessionStopped
	case "user.message", "turn.started":
		return SessionRunning
	case "turn.completed":
		if strings.TrimSpace(terminalStatus) == SessionStopped {
			return SessionStopped
		}
		return SessionIdle
	default:
		return ""
	}
}

// normalizeDaemonCipherEnvelope 只检查可转发的加密外形，不解析业务 payload。任何像正文、路径
// 或 Provider 原始响应的顶层键都在入库前拒绝，减少测试 fixture 或调用方误传造成的泄漏面。
func normalizeDaemonCipherEnvelope(raw string) (string, error) {
	var envelope map[string]json.RawMessage
	if json.Unmarshal([]byte(raw), &envelope) != nil || len(envelope) == 0 {
		return "", protocol.NewError(protocol.ErrInvalidRequest, "daemon event envelope is invalid")
	}
	for _, forbidden := range []string{"content", "message", "text", "path", "prompt", "provider_response", "raw"} {
		if _, found := envelope[forbidden]; found {
			return "", protocol.NewError(protocol.ErrInvalidRequest, "daemon event envelope contains plaintext field")
		}
	}
	for _, key := range []string{"alg", "key_id", "nonce", "ciphertext", "aad_hash", "payload_version"} {
		if len(envelope[key]) == 0 {
			return "", protocol.NewError(protocol.ErrInvalidRequest, "daemon event envelope is incomplete")
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
		return "", protocol.NewError(protocol.ErrInvalidRequest, "daemon event envelope is invalid")
	}
	normalized, err := json.Marshal(envelope)
	if err != nil {
		return "", err
	}
	return string(normalized), nil
}

func safeErrorCode(value string) string {
	value = strings.TrimSpace(value)
	// Terminal 上报的错误码会投影给同账号只读端，因此只能保留协议已登记的稳定码。
	// 未知值统一归为执行失败，不能把 Adapter/系统自由文本写入 Relay 或客户端界面。
	switch value {
	case "":
		return ""
	case protocol.ErrCapabilityUnsupported,
		protocol.ErrContentUnavailable,
		protocol.ErrDaemonExecutionFailed,
		protocol.ErrDaemonRestartRecovery,
		protocol.ErrDeadlineExceeded,
		protocol.ErrInvalidRequest,
		protocol.ErrLocalStateMissing,
		protocol.ErrPayloadTooLarge,
		protocol.ErrProtocolUnsupported,
		protocol.ErrScopeDenied,
		protocol.ErrSnapshotStale,
		protocol.ErrTargetInstanceStale,
		protocol.ErrTerminalOffline,
		protocol.ErrUpgradeRequired,
		protocol.ErrWorkspaceMoved,
		protocol.ErrWorkspacePathDenied:
		return value
	default:
		return protocol.ErrDaemonExecutionFailed
	}
}
