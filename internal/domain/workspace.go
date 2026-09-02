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
}

func NewWorkspaceService(repo store.Repository) *WorkspaceService {
	return &WorkspaceService{repo: repo, now: time.Now}
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

		terminal, err := selectWorkspaceTerminal(ctx, tx, in.AccountID, in.TerminalID)
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
		terminal, err := selectDSHSyncTerminal(ctx, tx, in.AccountID, in.TerminalID)
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

// ImportDSHSessions 创建 session.import_dsh 命令，或返回同账号已存在的导入命令。
// 幂等键绑定 account + workspace；只允许 write 角色发起，且目标必须是 Workspace 的 home Terminal。
func (s *WorkspaceService) ImportDSHSessions(ctx context.Context, in WorkspaceImportDSHInput) (WorkspaceImportDSHState, error) {
	if !protocol.DeviceRoleCanWrite(in.Role) {
		return WorkspaceImportDSHState{}, ErrReadOnlyDevice
	}
	if strings.TrimSpace(in.AccountID) == "" || strings.TrimSpace(in.DeviceID) == "" || strings.TrimSpace(in.WorkspaceID) == "" {
		return WorkspaceImportDSHState{}, ErrScopeDenied
	}
	scopeHash := hashScope(in.AccountID, in.WorkspaceID+"|dsh_import")
	idempotencyKey := "session.import_dsh:" + in.AccountID + ":" + in.WorkspaceID
	var state WorkspaceImportDSHState
	err := s.repo.WithTx(ctx, func(ctx context.Context, tx store.Repository) error {
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
		// 导入只允许 home Terminal 自己发起；目标 Terminal 必须与 Workspace 归属一致。
		terminalID := workspace.TerminalID
		if in.TerminalID != "" && in.TerminalID != terminalID {
			return ErrScopeDenied
		}
		terminal, err := tx.TerminalByID(ctx, terminalID)
		if err != nil {
			return ErrTerminalOffline
		}
		if terminal.AccountID != in.AccountID || terminal.Status != "online" {
			return ErrTerminalOffline
		}
		payload, err := json.Marshal(struct {
			WorkspaceID string `json:"workspace_id"`
		}{WorkspaceID: in.WorkspaceID})
		if err != nil {
			return err
		}
		command := store.CommandRow{
			ID: id.New("cmd"), AccountID: in.AccountID, SessionID: "", Kind: "session.import_dsh",
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
		state = WorkspaceImportDSHState{Status: "pending", CommandID: command.ID}
		return nil
	})
	if err != nil {
		if existing, lookupErr := s.repo.CommandByScopeKey(ctx, scopeHash, idempotencyKey); lookupErr == nil && existing.Kind == "session.import_dsh" {
			return dshImportStateFromCommand(ctx, s.repo, existing), nil
		}
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

func selectDSHSyncTerminal(ctx context.Context, repo store.Repository, accountID, requestedID string) (store.TerminalRow, error) {
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
		if !terminalCanSyncDSH(terminal) {
			return store.TerminalRow{}, ErrTerminalOffline
		}
		return terminal, nil
	}
	terminals, err := repo.ListTerminals(ctx, accountID)
	if err != nil {
		return store.TerminalRow{}, err
	}
	for _, terminal := range terminals {
		if terminalCanSyncDSH(terminal) {
			return terminal, nil
		}
	}
	return store.TerminalRow{}, ErrTerminalOffline
}

func terminalCanSyncDSH(terminal store.TerminalRow) bool {
	if terminal.Status != "online" {
		return false
	}
	var capabilities []string
	if json.Unmarshal([]byte(terminal.CapabilitiesJSON), &capabilities) != nil {
		return false
	}
	for _, capability := range capabilities {
		if strings.TrimSpace(capability) == "dsh_workspace_sync" {
			return true
		}
	}
	return false
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

func selectWorkspaceTerminal(ctx context.Context, repo store.Repository, accountID, requestedID string) (store.TerminalRow, error) {
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
		if !terminalCanCreateWorkspace(terminal) {
			return store.TerminalRow{}, ErrTerminalOffline
		}
		return terminal, nil
	}
	terminals, err := repo.ListTerminals(ctx, accountID)
	if err != nil {
		return store.TerminalRow{}, err
	}
	for _, terminal := range terminals {
		if terminalCanCreateWorkspace(terminal) {
			return terminal, nil
		}
	}
	return store.TerminalRow{}, ErrTerminalOffline
}

func terminalCanCreateWorkspace(terminal store.TerminalRow) bool {
	if terminal.Status != "online" {
		return false
	}
	var capabilities []string
	if json.Unmarshal([]byte(terminal.CapabilitiesJSON), &capabilities) != nil {
		return false
	}
	for _, capability := range capabilities {
		if strings.TrimSpace(capability) == "workspace_create" {
			return true
		}
	}
	return false
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
