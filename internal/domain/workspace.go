package domain

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"path/filepath"
	"strings"
	"time"

	"github.com/yubi233/agent-sessions/internal/id"
	"github.com/yubi233/agent-sessions/internal/store"
	"github.com/yubi233/agent-sessions/internal/workspacesafe"
	"github.com/yubi233/agent-sessions/packages/protocol"
)

// WorkspaceCreateInput 是 Android owner/write 设备发起的会话内新建工作区请求。
// terminal_id 可选；为空时由 Relay 选择账号下声明 workspace_create 的在线 Terminal。
type WorkspaceCreateInput struct {
	AccountID  string
	DeviceID   string
	Role       string
	Name       string
	TerminalID string
}

// WorkspaceCreateState 是客户端轮询 create-with-folder 的脱敏状态。
// canonical_root 永远不在该投影中出现。
type WorkspaceCreateState struct {
	Status      string
	CommandID   string
	WorkspaceID string
	ErrorCode   string
	Workspace   *store.WorkspaceRow
}

// WorkspaceSyncDSHInput 是 owner/write 端发起 DSH 工作区同步的请求。
// 只选择在线且声明 dsh_workspace_sync 能力的 Terminal；Daemon 不持 owner bearer。
type WorkspaceSyncDSHInput struct {
	AccountID  string
	DeviceID   string
	Role       string
	TerminalID string
}

// WorkspaceSyncDSHState 是客户端轮询 workspace.sync_dsh 的脱敏状态。
// canonical root 永远不在该投影中出现。
type WorkspaceSyncDSHState struct {
	Status       string
	CommandID    string
	ErrorCode    string
	WorkspaceIDs []string
}

// WorkspaceImportDSHInput 是 owner/write 端发起 DSH 会话按需导入的请求。
// 只允许导入该账号 home Terminal 所属 Workspace 下的 JSONL 元数据。
type WorkspaceImportDSHInput struct {
	AccountID   string
	DeviceID    string
	Role        string
	WorkspaceID string
	TerminalID  string
	// Discover 必须由用户显式选择；缺省只同步当前受管会话，不发现外部历史。
	Discover bool
	// IncludeAll 仅在 Discover=true 时绕过活跃窗口。
	IncludeAll bool
}

// WorkspaceImportDSHState 是客户端轮询 session.import_dsh 的脱敏状态。
type WorkspaceImportDSHState struct {
	Status     string
	CommandID  string
	ErrorCode  string
	SessionIDs []string
}

// WorkspaceService 编排命令创建和 daemon 回执后的状态读取；目录本身只能由 daemon 创建。
type WorkspaceService struct {
	repo store.Repository
	now  func() time.Time
	// Presence 是 Workspace/DSH 写命令 freshness 门控的阈值来源（v0.9.1 C2）。
	// 与 DaemonService、SessionService 共用同一份 PresencePolicy。
	Presence PresencePolicy
}

func NewWorkspaceService(repo store.Repository) *WorkspaceService {
	return &WorkspaceService{repo: repo, now: time.Now, Presence: DefaultPresencePolicy()}
}

// CreateWithFolder 创建 workspace.create command，或返回同名已有命令/Workspace。
// 幂等键绑定 account + name，避免重复点击导致多个 daemon mkdir。
func (s *WorkspaceService) CreateWithFolder(ctx context.Context, in WorkspaceCreateInput) (WorkspaceCreateState, error) {
	if !protocol.DeviceRoleCanWrite(in.Role) {
		return WorkspaceCreateState{}, ErrReadOnlyDevice
	}
	if strings.TrimSpace(in.AccountID) == "" || strings.TrimSpace(in.DeviceID) == "" {
		return WorkspaceCreateState{}, ErrScopeDenied
	}
	if err := workspacesafe.ValidateWorkspaceName(in.Name); err != nil {
		return WorkspaceCreateState{}, err
	}
	name := in.Name
	workspaceID, projectID := stableWorkspaceIDs(in.AccountID, name)
	// macOS 默认大小写不敏感；幂等键与稳定 Workspace ID 使用同一小写口径，
	// 防止 Demo/demo 两次点击在同一授权根竞争出两个命令。
	canonicalName := strings.ToLower(name)
	scopeHash := hashScope(in.AccountID, "workspace.create:"+canonicalName)
	idempotencyKey := "workspace.create:" + canonicalName

	var state WorkspaceCreateState
	err := s.repo.WithTx(ctx, func(ctx context.Context, tx store.Repository) error {
		// 已登记成功的 Workspace 先返回，允许 Terminal 暂时离线时重复打开页面。
		if workspace, lookupErr := tx.WorkspaceByID(ctx, workspaceID); lookupErr == nil {
			projects, projectErr := tx.ListProjects(ctx, in.AccountID)
			if projectErr != nil {
				return projectErr
			}
			for _, project := range projects {
				if project.ID == workspace.ProjectID && project.AccountID == in.AccountID {
					state = WorkspaceCreateState{Status: CommandSucceeded, WorkspaceID: workspaceID, Workspace: &workspace}
					return nil
				}
			}
			return ErrScopeDenied
		} else if !errors.Is(lookupErr, sql.ErrNoRows) {
			return lookupErr
		}

		if existing, lookupErr := tx.CommandByScopeKey(ctx, scopeHash, idempotencyKey); lookupErr == nil {
			if existing.AccountID != in.AccountID || existing.Kind != "workspace.create" {
				return ErrScopeDenied
			}
			state = workspaceStateFromCommand(ctx, tx, existing, workspaceID)
			return nil
		} else if !errors.Is(lookupErr, sql.ErrNoRows) {
			return lookupErr
		}

		terminal, err := s.selectWorkspaceTerminal(ctx, tx, in.AccountID, in.TerminalID)
		if err != nil {
			return err
		}
		payload, err := json.Marshal(struct {
			WorkspaceID string `json:"workspace_id"`
			ProjectID   string `json:"project_id"`
			Name        string `json:"name"`
		}{WorkspaceID: workspaceID, ProjectID: projectID, Name: name})
		if err != nil {
			return err
		}
		command := store.CommandRow{
			ID: id.New("cmd"), AccountID: in.AccountID, SessionID: "", Kind: "workspace.create",
			Status: CommandAccepted, ScopeHash: scopeHash, IdempotencyKey: idempotencyKey,
			LeaseEpoch: 0, TargetTerminalID: terminal.ID, CiphertextJSON: string(payload),
		}
		if err := tx.CreateCommand(ctx, command); err != nil {
			return err
		}
		if _, err := tx.CreateDaemonDelivery(ctx, store.DaemonDeliveryRow{
			TerminalID: terminal.ID, CommandID: command.ID, CreatedAtUnixMS: s.now().UnixMilli(),
		}); err != nil {
			return err
		}
		if err := tx.EnqueueOutbox(ctx, store.OutboxRow{Kind: "command.updated", PayloadJSON: `{"command_id":"` + command.ID + `"}`, Status: "pending"}); err != nil {
			return err
		}
		state = WorkspaceCreateState{Status: "pending", CommandID: command.ID, WorkspaceID: workspaceID}
		return nil
	})
	if err != nil {
		// 并发同名提交以已落盘的唯一命令为准；其它错误保持原始稳定边界。
		if existing, lookupErr := s.repo.CommandByScopeKey(ctx, scopeHash, idempotencyKey); lookupErr == nil && existing.Kind == "workspace.create" {
			return workspaceStateFromCommand(ctx, s.repo, existing, workspaceID), nil
		}
		return WorkspaceCreateState{}, err
	}
	return state, nil
}

// GetCreateWithFolder 返回命令结果或 pending 状态；调用方必须属于同一账号。
func (s *WorkspaceService) GetCreateWithFolder(ctx context.Context, accountID, commandID string) (WorkspaceCreateState, error) {
	command, err := s.repo.CommandByID(ctx, strings.TrimSpace(commandID))
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return WorkspaceCreateState{}, store.ErrNotFound
		}
		return WorkspaceCreateState{}, err
	}
	if command.AccountID != accountID || command.Kind != "workspace.create" {
		return WorkspaceCreateState{}, ErrScopeDenied
	}
	var workspaceID string
	var payload struct {
		WorkspaceID string `json:"workspace_id"`
	}
	if json.Unmarshal([]byte(command.CiphertextJSON), &payload) == nil {
		workspaceID = strings.TrimSpace(payload.WorkspaceID)
	}
	return workspaceStateFromCommand(ctx, s.repo, command, workspaceID), nil
}

// SyncDSHWorkspaces 创建 workspace.sync_dsh 命令，或返回同账号进行中的同步命令。
// 同步是可重复的刷新操作：已终态命令释放幂等键，下一次点击会创建新的扫描。
// 幂等键绑定 account + "dsh_sync"（单 Terminal 场景）；只允许 write 角色发起。
func (s *WorkspaceService) SyncDSHWorkspaces(ctx context.Context, in WorkspaceSyncDSHInput) (WorkspaceSyncDSHState, error) {
	if !protocol.DeviceRoleCanWrite(in.Role) {
		return WorkspaceSyncDSHState{}, ErrReadOnlyDevice
	}
	if strings.TrimSpace(in.AccountID) == "" || strings.TrimSpace(in.DeviceID) == "" {
		return WorkspaceSyncDSHState{}, ErrScopeDenied
	}
	scopeHash := hashScope(in.AccountID, "dsh_sync")
	idempotencyKey := "workspace.sync_dsh:" + in.AccountID
	var state WorkspaceSyncDSHState
	err := s.repo.WithTx(ctx, func(ctx context.Context, tx store.Repository) error {
		if existing, lookupErr := tx.CommandByScopeKey(ctx, scopeHash, idempotencyKey); lookupErr == nil {
			if existing.AccountID != in.AccountID || existing.Kind != "workspace.sync_dsh" {
				return ErrScopeDenied
			}
			if !isTerminal(existing.Status) {
				state = dshSyncStateFromCommand(ctx, tx, existing)
				return nil
			}
			if err := tx.ReleaseCommandIdempotencyKey(ctx, existing.ID, releasedWorkspaceCommandIdempotencyKey(idempotencyKey, existing.ID)); err != nil {
				return err
			}
		} else if !errors.Is(lookupErr, sql.ErrNoRows) {
			return lookupErr
		}
		terminal, err := s.selectDSHSyncTerminal(ctx, tx, in.AccountID, in.TerminalID)
		if err != nil {
			return err
		}
		payload, err := json.Marshal(struct{}{})
		if err != nil {
			return err
		}
		command := store.CommandRow{
			ID: id.New("cmd"), AccountID: in.AccountID, SessionID: "", Kind: "workspace.sync_dsh",
			Status: CommandAccepted, ScopeHash: scopeHash, IdempotencyKey: idempotencyKey,
			LeaseEpoch: 0, TargetTerminalID: terminal.ID, CiphertextJSON: string(payload),
		}
		if err := tx.CreateCommand(ctx, command); err != nil {
			return err
		}
		if _, err := tx.CreateDaemonDelivery(ctx, store.DaemonDeliveryRow{
			TerminalID: terminal.ID, CommandID: command.ID, CreatedAtUnixMS: s.now().UnixMilli(),
		}); err != nil {
			return err
		}
		if err := tx.EnqueueOutbox(ctx, store.OutboxRow{Kind: "command.updated", PayloadJSON: `{"command_id":"` + command.ID + `"}`, Status: "pending"}); err != nil {
			return err
		}
		state = WorkspaceSyncDSHState{Status: "pending", CommandID: command.ID}
		return nil
	})
	if err != nil {
		if existing, lookupErr := s.repo.CommandByScopeKey(ctx, scopeHash, idempotencyKey); lookupErr == nil && existing.Kind == "workspace.sync_dsh" {
			return dshSyncStateFromCommand(ctx, s.repo, existing), nil
		}
		return WorkspaceSyncDSHState{}, err
	}
	return state, nil
}

// GetSyncDSHWorkspaces 返回同账号 workspace.sync_dsh 的脱敏状态。
func (s *WorkspaceService) GetSyncDSHWorkspaces(ctx context.Context, accountID, commandID string) (WorkspaceSyncDSHState, error) {
	command, err := s.repo.CommandByID(ctx, strings.TrimSpace(commandID))
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return WorkspaceSyncDSHState{}, store.ErrNotFound
		}
		return WorkspaceSyncDSHState{}, err
	}
	if command.AccountID != accountID || command.Kind != "workspace.sync_dsh" {
		return WorkspaceSyncDSHState{}, ErrScopeDenied
	}
	return dshSyncStateFromCommand(ctx, s.repo, command), nil
}

// dshImportCommandPayload 的 discover 永远显式下发；缺省旧命令按空白名单同步处理。
type dshImportCommandPayload struct {
	WorkspaceID string   `json:"workspace_id"`
	Discover    bool     `json:"discover"`
	IncludeAll  bool     `json:"include_all,omitempty"`
	SessionIDs  []string `json:"session_ids"`
}

// ImportDSHSessions 保留 session.import_dsh 动作名，但同步和显式发现使用独立幂等域。
// 默认只同步本工作区未归档且默认可见的 DSH 会话；空集合不唤醒 Daemon。
func (s *WorkspaceService) ImportDSHSessions(ctx context.Context, in WorkspaceImportDSHInput) (WorkspaceImportDSHState, error) {
	if !protocol.DeviceRoleCanWrite(in.Role) {
		return WorkspaceImportDSHState{}, ErrReadOnlyDevice
	}
	if strings.TrimSpace(in.AccountID) == "" || strings.TrimSpace(in.DeviceID) == "" || strings.TrimSpace(in.WorkspaceID) == "" {
		return WorkspaceImportDSHState{}, ErrScopeDenied
	}
	mode := "sync"
	if in.Discover {
		mode = "discover"
		if in.IncludeAll {
			mode = "discover_all"
		}
	}
	scopeHash := hashScope(in.AccountID, in.WorkspaceID+"|dsh_import|"+mode)
	idempotencyKey := "session.import_dsh:" + in.AccountID + ":" + in.WorkspaceID + ":" + mode
	var state WorkspaceImportDSHState
	err := s.repo.WithTx(ctx, func(ctx context.Context, tx store.Repository) error {
		workspace, err := tx.WorkspaceByID(ctx, in.WorkspaceID)
		if err != nil {
			if errors.Is(err, sql.ErrNoRows) {
				return ErrWorkspaceNotFound
			}
			return err
		}
		if !workspaceBelongsToAccount(ctx, tx, in.AccountID, in.WorkspaceID) {
			return ErrScopeDenied
		}
		terminalID := workspace.TerminalID
		if in.TerminalID != "" && in.TerminalID != terminalID {
			return ErrScopeDenied
		}
		payload := dshImportCommandPayload{
			WorkspaceID: in.WorkspaceID, Discover: in.Discover,
			IncludeAll: in.Discover && in.IncludeAll, SessionIDs: []string{},
		}
		if !in.Discover {
			sessions, err := tx.ListSessions(ctx, in.AccountID)
			if err != nil {
				return err
			}
			for _, session := range sessions {
				if session.WorkspaceID == in.WorkspaceID && session.Provider == "dsh" {
					payload.SessionIDs = append(payload.SessionIDs, session.ID)
				}
			}
			if len(payload.SessionIDs) == 0 {
				state = WorkspaceImportDSHState{Status: CommandSucceeded, SessionIDs: []string{}}
				return nil
			}
		}
		if existing, lookupErr := tx.CommandByScopeKey(ctx, scopeHash, idempotencyKey); lookupErr == nil {
			if existing.AccountID != in.AccountID || existing.Kind != "session.import_dsh" {
				return ErrScopeDenied
			}
			if !isTerminal(existing.Status) {
				state = dshImportStateFromCommand(ctx, tx, existing)
				return nil
			}
			if err := tx.ReleaseCommandIdempotencyKey(ctx, existing.ID, releasedWorkspaceCommandIdempotencyKey(idempotencyKey, existing.ID)); err != nil {
				return err
			}
		} else if !errors.Is(lookupErr, sql.ErrNoRows) {
			return lookupErr
		}
		terminal, err := tx.TerminalByID(ctx, terminalID)
		if err != nil {
			return ErrTerminalOffline
		}
		if terminal.AccountID != in.AccountID {
			return ErrScopeDenied
		}
		if err := s.Presence.RefreshGate(terminal, s.now().UnixMilli()); err != nil {
			return err
		}
		encodedPayload, err := json.Marshal(payload)
		if err != nil {
			return err
		}
		command := store.CommandRow{
			ID: id.New("cmd"), AccountID: in.AccountID, SessionID: "", Kind: "session.import_dsh",
			Status: CommandAccepted, ScopeHash: scopeHash, IdempotencyKey: idempotencyKey,
			LeaseEpoch: 0, TargetTerminalID: terminal.ID, CiphertextJSON: string(encodedPayload),
		}
		if err := tx.CreateCommand(ctx, command); err != nil {
			return err
		}
		if _, err := tx.CreateDaemonDelivery(ctx, store.DaemonDeliveryRow{
			TerminalID: terminal.ID, CommandID: command.ID, CreatedAtUnixMS: s.now().UnixMilli(),
		}); err != nil {
			return err
		}
		if err := tx.EnqueueOutbox(ctx, store.OutboxRow{Kind: "command.updated", PayloadJSON: `{"command_id":"` + command.ID + `"}`, Status: "pending"}); err != nil {
			return err
		}
		state = WorkspaceImportDSHState{Status: "pending", CommandID: command.ID}
		return nil
	})
	if err != nil {
		return WorkspaceImportDSHState{}, err
	}
	return state, nil
}

// GetImportDSHSessions 返回同账号 session.import_dsh 的脱敏状态。
func (s *WorkspaceService) GetImportDSHSessions(ctx context.Context, accountID, commandID string) (WorkspaceImportDSHState, error) {
	command, err := s.repo.CommandByID(ctx, strings.TrimSpace(commandID))
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return WorkspaceImportDSHState{}, store.ErrNotFound
		}
		return WorkspaceImportDSHState{}, err
	}
	if command.AccountID != accountID || command.Kind != "session.import_dsh" {
		return WorkspaceImportDSHState{}, ErrScopeDenied
	}
	return dshImportStateFromCommand(ctx, s.repo, command), nil
}

func dshImportStateFromCommand(ctx context.Context, repo store.Repository, command store.CommandRow) WorkspaceImportDSHState {
	state := WorkspaceImportDSHState{Status: "pending", CommandID: command.ID}
	if result, err := repo.WorkspaceCommandResultByCommandID(ctx, command.ID); err == nil {
		state.Status, state.ErrorCode = result.Status, result.ErrorCode
		var payload struct {
			SessionIDs []string `json:"session_ids"`
		}
		if result.Status == CommandSucceeded {
			_ = json.Unmarshal([]byte(result.CanonicalRoot), &payload)
			state.SessionIDs = payload.SessionIDs
		}
		return state
	}
	if command.Status == CommandFailed || command.Status == CommandRejected || command.Status == CommandCancelled || command.Status == CommandExpired {
		state.Status = command.Status
	}
	return state
}

func dshSyncStateFromCommand(ctx context.Context, repo store.Repository, command store.CommandRow) WorkspaceSyncDSHState {
	state := WorkspaceSyncDSHState{Status: "pending", CommandID: command.ID}
	if result, err := repo.WorkspaceCommandResultByCommandID(ctx, command.ID); err == nil {
		state.Status, state.ErrorCode = result.Status, result.ErrorCode
		var payload struct {
			WorkspaceIDs []string `json:"workspace_ids"`
		}
		if result.Status == CommandSucceeded {
			_ = json.Unmarshal([]byte(result.CanonicalRoot), &payload)
			state.WorkspaceIDs = payload.WorkspaceIDs
		}
		return state
	}
	if command.Status == CommandFailed || command.Status == CommandRejected || command.Status == CommandCancelled || command.Status == CommandExpired {
		state.Status = command.Status
	}
	return state
}

// releasedWorkspaceCommandIdempotencyKey 保留终态命令的审计可读性，同时让基础幂等键
// 只代表当前可合并的同步/导入操作。command ID 全局唯一，故同一 scope 内也保持唯一。
func releasedWorkspaceCommandIdempotencyKey(baseKey, commandID string) string {
	return baseKey + ":resolved:" + commandID
}

// selectDSHSyncTerminal 为 workspace.sync_dsh 选择目标 Terminal（v0.9.1 C2 统一门控）。
// 显式 requestedID 与自动选择都走同一 Presence freshness predicate：
// 只有 availability == online 且具备 dsh_workspace_sync 能力的目标可新建投递；
// unknown 目标返回 ErrTerminalUnreachable，offline/不支持目标返回 ErrTerminalOffline。
func (s *WorkspaceService) selectDSHSyncTerminal(ctx context.Context, repo store.Repository, accountID, requestedID string) (store.TerminalRow, error) {
	nowMS := s.now().UnixMilli()
	if requestedID != "" {
		terminal, err := repo.TerminalByID(ctx, requestedID)
		if err != nil {
			if errors.Is(err, sql.ErrNoRows) {
				return store.TerminalRow{}, ErrTerminalOffline
			}
			return store.TerminalRow{}, err
		}
		if terminal.AccountID != accountID {
			return store.TerminalRow{}, ErrScopeDenied
		}
		if err := s.Presence.TerminalWriteGate(terminal, nowMS, "dsh_workspace_sync"); err != nil {
			return store.TerminalRow{}, err
		}
		return terminal, nil
	}
	terminals, err := repo.ListTerminals(ctx, accountID)
	if err != nil {
		return store.TerminalRow{}, err
	}
	// 自动选择：first-fit 命中即返回；全部不可用时按最接近可用的失败分类上报
	// （存在 offline 候选时优先报 offline，只有 unknown 候选时报 unreachable）。
	return selectEligibleTerminal(terminals, nowMS, s.Presence, "dsh_workspace_sync")
}

// selectEligibleTerminal 在候选列表中 first-fit 选择通过统一写门控的 Terminal。
// 全部不可用时按最接近可用的失败分类上报：存在 offline/unsupported 候选时报
// ErrTerminalOffline，只有 unknown 候选时报 ErrTerminalUnreachable；
// 空列表等价于没有可投递目标，报 ErrTerminalOffline。
func selectEligibleTerminal(terminals []store.TerminalRow, nowMS int64, policy PresencePolicy, capability string) (store.TerminalRow, error) {
	onlyUnreachable := true
	for _, terminal := range terminals {
		err := policy.TerminalWriteGate(terminal, nowMS, capability)
		switch {
		case err == nil:
			return terminal, nil
		case errors.Is(err, ErrTerminalOffline):
			onlyUnreachable = false
		}
	}
	if len(terminals) > 0 && onlyUnreachable {
		return store.TerminalRow{}, ErrTerminalUnreachable
	}
	return store.TerminalRow{}, ErrTerminalOffline
}

func workspaceStateFromCommand(ctx context.Context, repo store.Repository, command store.CommandRow, workspaceID string) WorkspaceCreateState {
	state := WorkspaceCreateState{Status: "pending", CommandID: command.ID, WorkspaceID: workspaceID}
	if result, err := repo.WorkspaceCommandResultByCommandID(ctx, command.ID); err == nil {
		state.Status, state.ErrorCode, state.WorkspaceID = result.Status, result.ErrorCode, result.WorkspaceID
		if result.Status == CommandSucceeded {
			if workspace, lookupErr := repo.WorkspaceByID(ctx, result.WorkspaceID); lookupErr == nil {
				state.Workspace = &workspace
			}
		}
		return state
	}
	if command.Status == CommandFailed || command.Status == CommandRejected || command.Status == CommandCancelled || command.Status == CommandExpired {
		state.Status = command.Status
	}
	return state
}

// selectWorkspaceTerminal 为 workspace.create 选择目标 Terminal（v0.9.1 C2 统一门控）。
// 显式 requestedID 与自动选择都走同一 Presence freshness predicate：
// 只有 availability == online 且具备 workspace_create 能力的目标可新建投递。
func (s *WorkspaceService) selectWorkspaceTerminal(ctx context.Context, repo store.Repository, accountID, requestedID string) (store.TerminalRow, error) {
	nowMS := s.now().UnixMilli()
	if requestedID != "" {
		terminal, err := repo.TerminalByID(ctx, requestedID)
		if err != nil {
			if errors.Is(err, sql.ErrNoRows) {
				return store.TerminalRow{}, ErrTerminalOffline
			}
			return store.TerminalRow{}, err
		}
		if terminal.AccountID != accountID {
			return store.TerminalRow{}, ErrScopeDenied
		}
		if err := s.Presence.TerminalWriteGate(terminal, nowMS, "workspace_create"); err != nil {
			return store.TerminalRow{}, err
		}
		return terminal, nil
	}
	terminals, err := repo.ListTerminals(ctx, accountID)
	if err != nil {
		return store.TerminalRow{}, err
	}
	return selectEligibleTerminal(terminals, nowMS, s.Presence, "workspace_create")
}

func stableWorkspaceIDs(accountID, name string) (workspaceID, projectID string) {
	sum := sha256.Sum256([]byte("workspace-v07\x00" + accountID + "\x00" + strings.ToLower(name)))
	digest := hex.EncodeToString(sum[:16])
	return "ws_v07_" + digest, "proj_v07_" + digest
}

// stableDSHWorkspaceIDs 以 account + terminal + canonical root 生成稳定 Workspace/Project ID。
// canonical root 不进入 Relay 普通响应；该哈希只用于幂等映射，不暴露路径。
func stableDSHWorkspaceIDs(accountID, terminalID, canonicalRoot string) (workspaceID, projectID string) {
	sum := sha256.Sum256([]byte("workspace-v08-dsh\x00" + accountID + "\x00" + terminalID + "\x00" + filepath.Clean(canonicalRoot)))
	digest := hex.EncodeToString(sum[:16])
	return "ws_v08_" + digest, "proj_v08_" + digest
}
