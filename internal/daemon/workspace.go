package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/yubi233/agent-sessions/internal/workspacesafe"
	"github.com/yubi233/agent-sessions/packages/protocol"
)

const (
	// WorkspaceRootEnv 是 daemon 创建工作区使用的授权根配置。
	WorkspaceRootEnv = "AGENT_SESSIONS_WORKSPACE_ROOT"
	// DefaultWorkspaceRoot 与发布计划保持一致；部署环境应通过环境变量显式覆盖。
	DefaultWorkspaceRoot = "/Users/yubi/code/"
)

var (
	ErrWorkspaceNameInvalid = workspacesafe.ErrWorkspaceName
	ErrWorkspaceRootInvalid = errors.New("workspace root is invalid")
)

// WorkspaceManager 是 daemon 本机唯一的 workspace.create 执行边界。
// Relay 只传 opaque workspace ID 和名称；绝对路径由这里依据授权根推导，不能由客户端指定。
type WorkspaceManager struct {
	store *Store
	root  string
	git   string
}

// ResolveWorkspaceRoot 校验授权根存在、是目录，并规约为 realpath。
// 启动时失败比运行中收到命令后才失败更安全，避免 daemon 在错误根目录下提供服务。
func ResolveWorkspaceRoot(configured string) (string, error) {
	root := strings.TrimSpace(configured)
	if root == "" {
		root = DefaultWorkspaceRoot
	}
	if !filepath.IsAbs(root) || containsControl(root) {
		return "", ErrWorkspaceRootInvalid
	}
	info, err := os.Stat(root)
	if err != nil || !info.IsDir() {
		return "", ErrWorkspaceRootInvalid
	}
	canonical, err := filepath.EvalSymlinks(root)
	if err != nil {
		return "", ErrWorkspaceRootInvalid
	}
	canonical, err = filepath.Abs(canonical)
	if err != nil {
		return "", ErrWorkspaceRootInvalid
	}
	// 再经共享边界检查，确保后续 Join/Resolve 使用的根本身可被 realpath 解析。
	resolved, err := workspacesafe.ResolveRepoRelative(canonical, ".")
	if err != nil || resolved != canonical {
		return "", ErrWorkspaceRootInvalid
	}
	return canonical, nil
}

// NewWorkspaceManager 构造本机工作区创建器。git 可执行文件固定为 PATH 中的 git，
// 测试可通过 SetGitBinary 注入隔离脚本而不改变生产行为。
func NewWorkspaceManager(store *Store, configuredRoot string) (*WorkspaceManager, error) {
	root, err := ResolveWorkspaceRoot(configuredRoot)
	if err != nil {
		return nil, err
	}
	return &WorkspaceManager{store: store, root: root, git: "git"}, nil
}

// SetGitBinary 仅供本地测试替换 git 命令；生产调用方不要设置非系统 git。
func (m *WorkspaceManager) SetGitBinary(binary string) {
	if m != nil && strings.TrimSpace(binary) != "" {
		m.git = strings.TrimSpace(binary)
	}
}

func (m *WorkspaceManager) Root() string {
	if m == nil {
		return ""
	}
	return m.root
}

// ValidateWorkspaceName 统一 Relay 输入与 daemon 根因层校验，拒绝隐藏名、路径分隔符、
// 控制字符和 dot-segment；只允许授权根的直接子目录。
func ValidateWorkspaceName(name string) error {
	return workspacesafe.ValidateWorkspaceName(name)
}

// WorkspaceCreatePayload 是 workspace.create command 的非敏感最小载荷。
// canonical_root 永远不在 payload 中出现。
type WorkspaceCreatePayload struct {
	WorkspaceID string `json:"workspace_id"`
	Name        string `json:"name"`
}

// DecodeWorkspaceCreatePayload 校验 Relay 下发的 workspace.create 载荷。
// v0.9.2 P2/P3 命令投递契约修正后，`name` 在 ciphertext envelope 内
// （`{"ciphertext":{"name":...},"workspace_id":...}`），workspace_id 在顶层；
// 本解码双读两代形态（顶层 name 为旧客户端兼容），两者都缺失才判非法——
// 否则 workspace.create 永远 PATH_DENIED，create-with-folder 收敛失败
// （R17 实测：V07 契约回归暴露）。
func DecodeWorkspaceCreatePayload(raw, expectedWorkspaceID string) (WorkspaceCreatePayload, error) {
	var payload WorkspaceCreatePayload
	if err := json.Unmarshal([]byte(raw), &payload); err != nil {
		return WorkspaceCreatePayload{}, ErrWorkspaceNameInvalid
	}
	if strings.TrimSpace(payload.WorkspaceID) != strings.TrimSpace(expectedWorkspaceID) || expectedWorkspaceID == "" {
		return WorkspaceCreatePayload{}, ErrWorkspaceNameInvalid
	}
	if strings.TrimSpace(payload.Name) == "" {
		var envelope struct {
			Ciphertext struct {
				Name string `json:"name"`
			} `json:"ciphertext"`
		}
		if err := json.Unmarshal([]byte(raw), &envelope); err == nil {
			payload.Name = strings.TrimSpace(envelope.Ciphertext.Name)
		}
	}
	if err := ValidateWorkspaceName(payload.Name); err != nil {
		return WorkspaceCreatePayload{}, err
	}
	return payload, nil
}

// Create 在授权根直接子级创建或复用一个 Git 工作区，并把 ID+canonical root 写入 daemon 本地 store。
// 新目录只执行一次 git init；已存在目录必须已经是 Git 根，避免悄悄改写用户已有目录。
func (m *WorkspaceManager) Create(ctx context.Context, workspaceID, name string) (ConfirmedWorkspace, error) {
	if m == nil || m.store == nil || strings.TrimSpace(m.root) == "" {
		return ConfirmedWorkspace{}, ErrWorkspaceRootInvalid
	}
	if err := ValidateWorkspaceName(name); err != nil {
		return ConfirmedWorkspace{}, err
	}
	if strings.TrimSpace(workspaceID) == "" {
		return ConfirmedWorkspace{}, ErrWorkspaceNameInvalid
	}
	// 名称已经禁止分隔符，但仍以共享边界复核最终路径，防止未来校验放宽时产生回归。
	candidate := filepath.Join(m.root, name)
	resolvedCandidate, err := workspacesafe.ResolveAbsolute(m.root, candidate)
	if err != nil {
		return ConfirmedWorkspace{}, err
	}
	if filepath.Dir(resolvedCandidate) != m.root {
		return ConfirmedWorkspace{}, workspacesafe.ErrEscapeRoot
	}

	created := false
	if info, statErr := os.Stat(resolvedCandidate); statErr == nil {
		if !info.IsDir() {
			return ConfirmedWorkspace{}, ErrWorkspaceRootInvalid
		}
	} else if os.IsNotExist(statErr) {
		if err := os.Mkdir(resolvedCandidate, 0o755); err != nil && !os.IsExist(err) {
			return ConfirmedWorkspace{}, err
		}
		created = true
	} else {
		return ConfirmedWorkspace{}, statErr
	}

	if created {
		if err := m.gitInit(ctx, resolvedCandidate); err != nil {
			// 只清理本次刚创建且尚未完成初始化的空目录；不触碰已存在用户目录。
			_ = os.Remove(resolvedCandidate)
			return ConfirmedWorkspace{}, err
		}
	}
	canonical, err := workspacesafe.ResolveRepoRelative(m.root, name)
	if err != nil {
		return ConfirmedWorkspace{}, err
	}
	if filepath.Dir(canonical) != m.root || !workspacesafe.IsGitRoot(canonical) {
		return ConfirmedWorkspace{}, workspacesafe.ErrNotAGitRoot
	}
	return m.store.ConfirmWorkspace(workspaceID, canonical)
}

func (m *WorkspaceManager) gitInit(ctx context.Context, root string) error {
	cmd := exec.CommandContext(ctx, m.git, "-C", root, "init", "--quiet")
	if output, err := cmd.CombinedOutput(); err != nil {
		// git 输出可能包含绝对路径，故只返回稳定错误，不把 output 写入日志或 Relay。
		_ = output
		return fmt.Errorf("git init failed: %w", err)
	}
	return nil
}

func containsControl(value string) bool {
	for _, r := range value {
		if r == 0 || r < 0x20 {
			return true
		}
	}
	return false
}

// WorkspaceCreateErrorCode 将本机路径/名称错误收口为稳定协议码。
func WorkspaceCreateErrorCode(err error) string {
	switch {
	case errors.Is(err, ErrWorkspaceNameInvalid), errors.Is(err, ErrWorkspaceRootInvalid),
		errors.Is(err, workspacesafe.ErrEscapeRoot), errors.Is(err, workspacesafe.ErrUnsafeSymlink),
		errors.Is(err, workspacesafe.ErrNotAbsolute), errors.Is(err, workspacesafe.ErrNotAGitRoot),
		errors.Is(err, workspacesafe.ErrControlChar):
		return protocol.ErrWorkspacePathDenied
	case errors.Is(err, workspacesafe.ErrWorkspaceMoved):
		return protocol.ErrWorkspaceMoved
	default:
		return protocol.ErrDaemonExecutionFailed
	}
}
