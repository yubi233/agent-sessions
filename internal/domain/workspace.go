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
