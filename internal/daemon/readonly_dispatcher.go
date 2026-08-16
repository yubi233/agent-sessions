package daemon

import (
	"context"
	"errors"
	"strings"

	"github.com/yubi233/agent-sessions/internal/adapter"
	"github.com/yubi233/agent-sessions/internal/gitread"
	"github.com/yubi233/agent-sessions/internal/workspacesafe"
	"github.com/yubi233/agent-sessions/packages/protocol"
)

// ReadOnlyDispatcher 是 Relay 下行只读命令的本机执行边界。它不接受绝对路径，也不从命令 payload
// 推导 Workspace 根；根只能来自用户此前在本机确认的 Workspace ID 映射。
type ReadOnlyDispatcher struct {
	store  *Store
	gitBin string
}

// CommandExecutionError 只向 Relay 暴露稳定错误码。内部 cause 保留给本机测试的 errors.Is，避免
// Git/文件系统错误文本（可能含绝对路径）进入 Relay 日志或 result API。
type CommandExecutionError struct {
	Code  string
	cause error
}

func (e *CommandExecutionError) Error() string { return e.Code }

func (e *CommandExecutionError) Unwrap() error { return e.cause }

// CommandErrorCode 把 Daemon 受限执行失败归一为公开稳定码。非本机边界错误不泄露细节，统一按
// DAEMON_EXECUTION_FAILED 处理；客户端不应解析自由文本。
func CommandErrorCode(err error) string {
	var commandErr *CommandExecutionError
	if errors.As(err, &commandErr) && commandErr.Code != "" {
		return commandErr.Code
	}
	// 非只读命令也必须用协议错误码收敛。Provider/能力缺失不能被看作可重试的内部故障，
	// 本地 instance 丢失则提示客户端创建新动作或走明确恢复流程。
	switch {
	case errors.Is(err, ErrUnsupportedCommand):
		return protocol.ErrCapabilityUnsupported
	case errors.Is(err, ErrSessionInstanceMissing):
		return protocol.ErrLocalStateMissing
	default:
		return protocol.ErrDaemonExecutionFailed
	}
}

func newCommandExecutionError(code string, cause error) error {
	return &CommandExecutionError{Code: code, cause: cause}
}

// NewReadOnlyDispatcher 创建只读 dispatcher。gitBin 为空时复用 gitread 的安全默认值；此对象不
// 缓存 WorkspaceReader，确保每个命令都会重新做 realpath 与 Git 根检查。
func NewReadOnlyDispatcher(store *Store, gitBin string) *ReadOnlyDispatcher {
	return &ReadOnlyDispatcher{store: store, gitBin: gitBin}
}

func isReadOnlyCommandKind(kind string) bool {
	switch kind {
	case "file.tree", "file.read", "code.read", "git.status", "git.changes", "git.diff":
		return true
	}
	return false
}

// Execute 只执行已登记的 file/code/Git 只读 kind。真实密文没有 fixture_payload 时拒绝执行，
// 防止 Daemon 把未解密或未经用户确认的请求误当成本机文件读取。
func (d *ReadOnlyDispatcher) Execute(ctx context.Context, command RelayCommand) (adapter.Event, error) {
	if d == nil || d.store == nil {
		return adapter.Event{}, newCommandExecutionError(protocol.ErrCapabilityUnsupported, errors.New("read-only dispatcher unavailable"))
	}
	if !isReadOnlyCommandKind(command.Kind) {
		return adapter.Event{}, newCommandExecutionError(protocol.ErrCapabilityUnsupported, errors.New("unsupported read-only command"))
	}
	if strings.TrimSpace(command.SessionID) == "" || strings.TrimSpace(command.WorkspaceID) == "" {
		return adapter.Event{}, newCommandExecutionError(protocol.ErrInvalidRequest, errors.New("missing session or workspace metadata"))
	}
	localTerminalID, err := d.store.Get("terminal_id")
	if err != nil || localTerminalID == "" || localTerminalID != command.TargetTerminalID {
		return adapter.Event{}, newCommandExecutionError(protocol.ErrScopeDenied, errors.New("terminal target mismatch"))
	}
	workspace, err := d.store.ConfirmedWorkspaceByID(command.WorkspaceID)
	if err != nil {
		return adapter.Event{}, newCommandExecutionError(readOnlyErrorCode(err), err)
	}
	request, err := parseFixtureReadOnlyRequest(command.PayloadJSON)
	if err != nil {
		return adapter.Event{}, newCommandExecutionError(protocol.ErrCapabilityUnsupported, err)
	}
	reader := NewWorkspaceReader(workspace.Root, d.gitBin)

	var result any
	switch command.Kind {
	case "file.tree":
		path := request.Path
		if path == "" {
			path = "."
		}
		result, err = reader.List(path)
	case "file.read", "code.read":
		if request.Path == "" {
			return adapter.Event{}, newCommandExecutionError(protocol.ErrInvalidRequest, errors.New("file path missing"))
		}
		var code CodeRead
		code, err = reader.ReadCode(request.Path)
		if err == nil {
			// content 只存在于本机 event，交给 EventEncoder 后才允许离开 Daemon。fixture encoder
			// 仅计算哈希，保证测试不会把文本伪装成真实 E2EE 结果。
			result = map[string]any{"path": code.Path, "content": string(code.Content)}
		}
	case "git.status":
		result, err = reader.GitStatus(ctx)
	case "git.changes":
		var status gitread.Status
		status, err = reader.GitStatus(ctx)
		if err == nil {
			result = map[string]any{"snapshot_token": status.SnapshotToken, "files": status.Files, "truncated": status.Truncated}
		}
	case "git.diff":
		if request.Path == "" || request.SnapshotToken == "" {
			return adapter.Event{}, newCommandExecutionError(protocol.ErrInvalidRequest, errors.New("diff path or snapshot token missing"))
		}
		limit := request.Limit
		if limit == 0 {
			limit = 100
		}
		result, err = reader.GitDiffPage(ctx, request.Path, request.SnapshotToken, request.Offset, limit)
	}
	if err != nil {
		return adapter.Event{}, newCommandExecutionError(readOnlyErrorCode(err), err)
	}
	return adapter.Event{
		Type: adapter.EventToolResult,
		Seq:  command.DeliverySeq,
		Payload: map[string]any{
			"command_kind": command.Kind,
			"workspace_id": command.WorkspaceID,
			"result":       result,
		},
	}, nil
}

type fixtureReadOnlyRequest struct {
	Path          string
	SnapshotToken string
	Offset        int
	Limit         int
}

func parseFixtureReadOnlyRequest(raw string) (fixtureReadOnlyRequest, error) {
	envelope, err := parseEnvelope(raw)
	if err != nil {
		return fixtureReadOnlyRequest{}, err
	}
	if envelope.Ciphertext == nil || envelope.Ciphertext.FixturePayload == nil {
		return fixtureReadOnlyRequest{}, errors.New("fixture payload missing for read-only command")
	}
	payload := envelope.Ciphertext.FixturePayload
	if payload.Offset < 0 || payload.Limit < 0 || payload.Limit > 500 {
		return fixtureReadOnlyRequest{}, errors.New("invalid read-only pagination")
	}
	return fixtureReadOnlyRequest{
		Path:          strings.TrimSpace(payload.Path),
		SnapshotToken: strings.TrimSpace(payload.SnapshotToken),
		Offset:        payload.Offset,
		Limit:         payload.Limit,
	}, nil
}

func readOnlyErrorCode(err error) string {
	switch {
	case errors.Is(err, ErrWorkspaceNotConfirmed),
		errors.Is(err, workspacesafe.ErrEscapeRoot),
		errors.Is(err, workspacesafe.ErrUnsafeSymlink),
		errors.Is(err, workspacesafe.ErrNotAbsolute),
		errors.Is(err, workspacesafe.ErrNotAGitRoot),
		errors.Is(err, workspacesafe.ErrControlChar):
		return protocol.ErrWorkspacePathDenied
	case errors.Is(err, workspacesafe.ErrWorkspaceMoved):
		return protocol.ErrWorkspaceMoved
	case errors.Is(err, gitread.ErrSnapshotStale):
		return protocol.ErrSnapshotStale
	case errors.Is(err, ErrReadOnlyTooLarge), errors.Is(err, gitread.ErrOutputLimit):
		return protocol.ErrPayloadTooLarge
	case errors.Is(err, ErrReadOnlyBinary), errors.Is(err, ErrReadOnlyDirectory):
		return protocol.ErrContentUnavailable
	default:
		return protocol.ErrInvalidRequest
	}
}
