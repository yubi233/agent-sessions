package daemon

// 本文件实现 v0.8 P2 的 DSH 本地工作区扫描与确认边界（v0.8.5 §3.6 重裁决：
// Git 根不再是 dsh 候选的必要条件——有 DSH 持久化证据即登记，Git 只读功能按
// GitReady 标记如实标注；ADR-005 的 Git 门槛继续约束 Agent Sessions 自管项目
// 与 gitread 功能面）。扫描只读、不创建目录、不初始化 Git、不跟随符号链接；
// canonical root 只进入本机确认表与 Relay 专用 result，不进入普通日志。

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"unicode/utf8"

	"github.com/yubi233/agent-sessions/internal/adapter/dsh"
	"github.com/yubi233/agent-sessions/internal/id"
	"github.com/yubi233/agent-sessions/internal/workspacesafe"
)

const (
	// dshMaxScanDepth 是扫描目录的最大深度（授权根自身为 0）。
	dshMaxScanDepth = 4
	// dshMaxCandidates 是单次同步最多确认的候选工作区数量；达到上限必须返回可见状态。
	dshMaxCandidates = 1000
)

// DSHScanSummary 是脱敏的扫描统计，只含计数和稳定分类，不包含路径。
type DSHScanSummary struct {
	Scanned    int `json:"scanned"`
	Candidates int `json:"candidates"`
	// NonGitCandidates 是“有 DSH 证据但非 Git 根”的候选数（v0.8.5 §3.6）：
	// 这些工作区登记但 gitread 不可用。
	NonGitCandidates int            `json:"non_git_candidates"`
	Skipped          int            `json:"skipped"`
	Ignored          int            `json:"ignored"`
	Symlinks         int            `json:"symlinks"`
	DepthLimited     int            `json:"depth_limited"`
	LimitReached     bool           `json:"limit_reached"`
	SkippedReasons   map[string]int `json:"skipped_reasons"`
}

// DSHWorkspaceCandidate 是扫描器返回的本机候选；Root 只在本机使用，不能进入 Relay 普通响应。
type DSHWorkspaceCandidate struct {
	Root        string `json:"canonical_root"`
	DisplayName string `json:"display_name"`
	// GitReady 标注候选是否为 Git 根（v0.8.5 §3.6）：非 Git 根的 DSH 工作区照常
	// 登记与会话，但 Git 只读功能（gitread）不可用，消费方如实标注。
	GitReady bool `json:"git_ready"`
}

// DSHWorkspaceScanner 在授权根内发现已有 DSH 工作区。它不修改文件系统。
type DSHWorkspaceScanner struct {
	root          string
	maxDepth      int
	maxCandidates int
}

// NewDSHWorkspaceScanner 构造扫描器；root 必须是已经规约的授权根。
func NewDSHWorkspaceScanner(root string) *DSHWorkspaceScanner {
	if root == "" {
		root = DefaultWorkspaceRoot
	}
	return &DSHWorkspaceScanner{root: root, maxDepth: dshMaxScanDepth, maxCandidates: dshMaxCandidates}
}

// Scan 遍历授权根，返回满足 DSH 证据且自身是 Git 根的候选目录。
// 扫描不读取 JSONL 正文，只检查 `.dsh-sessions` 目录下的有效 artifact 或 `session-query.db` 标记。
func (s *DSHWorkspaceScanner) Scan(ctx context.Context) ([]DSHWorkspaceCandidate, DSHScanSummary, error) {
	if s == nil || strings.TrimSpace(s.root) == "" {
		return nil, DSHScanSummary{}, ErrWorkspaceRootInvalid
	}
	canonicalRoot, err := filepath.EvalSymlinks(s.root)
	if err != nil {
		return nil, DSHScanSummary{}, ErrWorkspaceRootInvalid
	}
	canonicalRoot, err = filepath.Abs(canonicalRoot)
	if err != nil {
		return nil, DSHScanSummary{}, ErrWorkspaceRootInvalid
	}
	canonicalRoot = filepath.Clean(canonicalRoot)

	summary := DSHScanSummary{SkippedReasons: map[string]int{}}
	var candidates []DSHWorkspaceCandidate
	seen := map[string]bool{}

	// 使用显式栈做深度受限遍历，避免 filepath.WalkDir 在遇到符号链接时难以控制忽略规则。
	type item struct {
		path  string
		depth int
	}
	stack := []item{{path: canonicalRoot, depth: 0}}
	for len(stack) > 0 {
		if ctx != nil {
			if err := ctx.Err(); err != nil {
				return nil, summary, err
			}
		}
		cur := stack[len(stack)-1]
		stack = stack[:len(stack)-1]
		info, err := os.Lstat(cur.path)
		if err != nil {
			summary.Skipped++
			continue
		}
		// 不跟随符号链接：授权根内的链接可能指向根外目录。
		if info.Mode()&os.ModeSymlink != 0 {
			summary.Symlinks++
			continue
		}
		if !info.IsDir() {
			continue
		}
		// 跳过隐藏目录、.git 与 node_modules；但授权根本身如果是隐藏路径仍继续。
		if cur.depth > 0 && (strings.HasPrefix(filepath.Base(cur.path), ".") ||
			filepath.Base(cur.path) == ".git" || filepath.Base(cur.path) == "node_modules") {
			summary.Ignored++
			continue
		}
		// 授权根边界再次确认，防止符号链接或竞态把路径带出根。
		if !pathWithin(canonicalRoot, cur.path) {
			summary.Skipped++
			continue
		}
		if s.hasDSHEvidence(cur.path) {
			// v0.8.5 §3.6：有 DSH 证据即候选（Git 根不再是必要条件）；GitReady 供
			// gitread 功能标注，非 Git 根不影响登记与会话。
			gitReady := workspacesafe.IsGitRoot(cur.path)
			if !gitReady {
				summary.NonGitCandidates++
			}
			if len(candidates) >= s.maxCandidates {
				summary.LimitReached = true
				return candidates, summary, nil
			}
			key := filepath.Clean(cur.path)
			if !seen[key] {
				seen[key] = true
				displayName, nameErr := dshWorkspaceDisplayName(key)
				if nameErr != nil {
					summary.Skipped++
					summary.SkippedReasons["unsafe_display_name"]++
					continue
				}
				// 名称在 Daemon 的扫描边界派生；Relay 只校验并投影，不能从根路径再推导用户文案。
				candidates = append(candidates, DSHWorkspaceCandidate{Root: key, DisplayName: displayName, GitReady: gitReady})
				summary.Candidates++
			}
			// 已确认的项目不再深入其子目录，避免把项目内的嵌套 DSH 仓库重复登记。
			continue
		}
		if cur.depth >= s.maxDepth {
			summary.DepthLimited++
			continue
		}
		entries, err := os.ReadDir(cur.path)
		if err != nil {
			summary.Skipped++
			continue
		}
		for _, entry := range entries {
			if entry.IsDir() {
				stack = append(stack, item{path: filepath.Join(cur.path, entry.Name()), depth: cur.depth + 1})
			}
		}
	}
	// 输出稳定排序，便于幂等与测试。
	sort.Slice(candidates, func(i, j int) bool { return candidates[i].Root < candidates[j].Root })
	return candidates, summary, nil
}

// dshWorkspaceDisplayName 只接受 canonical root 的最后一个目录名，防止路径、驱动器前缀或
// 控制字符作为公开 Workspace 文案跨出 Daemon 边界。中文等合法 UTF-8 项目名保持原样。
func dshWorkspaceDisplayName(root string) (string, error) {
	name := strings.TrimSpace(filepath.Base(filepath.Clean(root)))
	if name == "" || name == "." || name == ".." || len(name) > 128 || !utf8.ValidString(name) ||
		strings.ContainsAny(name, `/\\`) || filepath.IsAbs(name) || filepath.VolumeName(name) != "" {
		return "", errors.New("unsafe DSH workspace display name")
	}
	if len(name) >= 2 && name[1] == ':' && ((name[0] >= 'A' && name[0] <= 'Z') || (name[0] >= 'a' && name[0] <= 'z')) {
		return "", errors.New("unsafe DSH workspace display name")
	}
	for _, r := range name {
		if r < 0x20 || r == 0x7f {
			return "", errors.New("unsafe DSH workspace display name")
		}
	}
	return name, nil
}

// hasDSHEvidence 检查目录下是否存在 DSH 持久化证据：
// `.dsh-sessions` 内存在 `session-query.db` 标记，或存在符合 DSH 布局的有效
// `session.jsonl` / `session.jsonl.zstd` artifact。它不读取事件正文，也不把
// `session-query.db` 当作会话事实来源。
func (s *DSHWorkspaceScanner) hasDSHEvidence(projectRoot string) bool {
	sessionRoot := filepath.Join(projectRoot, ".dsh-sessions")
	info, err := os.Lstat(sessionRoot)
	if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return false
	}
	entries, err := os.ReadDir(sessionRoot)
	if err != nil {
		return false
	}
	for _, entry := range entries {
		if entry.Type()&os.ModeSymlink != 0 {
			continue
		}
		if !entry.IsDir() && entry.Name() == "session-query.db" {
			return true
		}
	}
	// 真实 DSH 布局是 `.dsh-sessions/<project>/<session>/session.jsonl[.zstd]`，
	// 因此用持久化层扫描来确认至少一个有效 artifact；无效文件不会被当作证据。
	artifacts, err := dsh.ScanSessionArtifacts(sessionRoot)
	return err == nil && len(artifacts) > 0
}

func pathWithin(root, path string) bool {
	rel, err := filepath.Rel(root, path)
	if err != nil {
		return false
	}
	return rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator))
}

// ConfirmExistingDSHWorkspace 把已存在的 DSH 项目目录确认到本机 Workspace 映射。
// 与 WorkspaceManager.Create 不同，它不创建目录、不 git init，并允许授权根内任意深度（扫描器已限深）。
// v0.8.5 §3.6：不再要求 Git 根（DSH 证据即登记）；非 Git 根工作区的 gitread 由
// GitReady 标注为不可用，会话功能不受影响。
func (m *WorkspaceManager) ConfirmExistingDSHWorkspace(ctx context.Context, workspaceID, root string) (ConfirmedWorkspace, error) {
	if m == nil || m.store == nil || strings.TrimSpace(m.root) == "" {
		return ConfirmedWorkspace{}, ErrWorkspaceRootInvalid
	}
	if strings.TrimSpace(workspaceID) == "" {
		return ConfirmedWorkspace{}, ErrWorkspaceNameInvalid
	}
	if !filepath.IsAbs(root) {
		return ConfirmedWorkspace{}, workspacesafe.ErrNotAbsolute
	}
	// 先解析到 canonical，并确保仍在授权根内。
	resolved, err := workspacesafe.ResolveAbsolute(m.root, root)
	if err != nil {
		return ConfirmedWorkspace{}, err
	}
	if !pathWithin(m.root, resolved) {
		return ConfirmedWorkspace{}, workspacesafe.ErrEscapeRoot
	}
	scanner := NewDSHWorkspaceScanner(m.root)
	if !scanner.hasDSHEvidence(resolved) {
		return ConfirmedWorkspace{}, errors.New("directory 缺少 DSH 持久化证据")
	}
	// v0.8.5 §3.6：有 DSH 证据即确认。候选本身是 Git 根时走 Git 语义条目
	//（gitread 可用、DSH=false）；非 Git 根走 DSH 条目（gitread 标注不可用）。
	if workspacesafe.IsGitRoot(resolved) {
		return m.store.ConfirmWorkspace(workspaceID, resolved)
	}
	return m.store.ConfirmDSHWorkspace(workspaceID, resolved)
}

// DSHImportedSession 是一次按需导入的本机映射结果。Relay 只接收 opaque relay session id。
// Title/Messages 来自本机 JSONL 提取（v0.9.4 用户需求：每个历史会话保留十几条上下文与
// 真实标题），仅经用户自己的 Relay 事件流回流，不进入任何第三方或日志。
type DSHImportedSession struct {
	RelaySessionID string
	DSHSessionID   string
	WorkspaceRoot  string
	Title          string
	Messages       []dsh.SessionContextMessage
}

// importContextLimit 是每个导入会话保留的最近上下文条数（用户口径「十几条」取 14）。
const importContextLimit = 14

// ImportDSHSessions 扫描已确认 DSH 工作区下的 JSONL artifact，为每个有效会话生成
// opaque Relay session id 并写入本机 instance/replay 映射；同时提取真实标题与最近
// 上下文消息（v0.9.4：客户端打开导入会话即可见最近十几条正文）。DSH session id、
// cwd 或路径仍不上传到 Relay；正文只进入用户自己的事件流。
func (m *WorkspaceManager) ImportDSHSessions(ctx context.Context, workspaceID string, store *Store) ([]DSHImportedSession, error) {
	if m == nil || store == nil {
		return nil, ErrWorkspaceRootInvalid
	}
	confirmed, err := store.ConfirmedWorkspaceByID(workspaceID)
	if err != nil {
		return nil, err
	}
	// 只扫描该 Workspace 自己的 .dsh-sessions，不递归到其他项目。
	persistenceRoot := filepath.Join(confirmed.Root, ".dsh-sessions")
	artifacts, err := dsh.ScanSessionArtifacts(persistenceRoot)
	if err != nil {
		// 没有持久化根时视为空导入，而不是让整个同步失败。
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	seen := map[string]bool{}
	var out []DSHImportedSession
	for _, artifact := range artifacts {
		if artifact.ID == "" || artifact.CWD == "" {
			continue
		}
		// 只导入 cwd 与当前 canonical workspace 一致的会话；不一致视为移动/越权，跳过。
		if !sameCanonicalPath(artifact.CWD, confirmed.Root) {
			continue
		}
		if seen[artifact.ID] {
			continue
		}
		seen[artifact.ID] = true
		relaySessionID := id.New("sess")
		// v0.9.4：提取真实标题与最近上下文。读取失败不阻断导入（上下文尽力而为）。
		artifactContext, ctxErr := dsh.ReadSessionContext(artifact.Path, importContextLimit)
		if ctxErr != nil {
			artifactContext = dsh.SessionContext{}
		}
		// 写本机 instance 映射：Relay session -> DSH session + workspace root。
		mapping, err := json.Marshal(providerThread{
			Provider:      "dsh",
			InstanceID:    artifact.ID,
			WorkspaceRoot: confirmed.Root,
		})
		if err != nil {
			return nil, err
		}
		if err := store.Set(instanceKey(relaySessionID), string(mapping)); err != nil {
			return nil, err
		}
		// 新导入的 DSH 会话应走 session.load 回放，因此 replay state 置 pending。
		if err := store.Set(replayStateKey(relaySessionID), replayPending); err != nil {
			return nil, err
		}
		out = append(out, DSHImportedSession{
			RelaySessionID: relaySessionID,
			DSHSessionID:   artifact.ID,
			WorkspaceRoot:  confirmed.Root,
			Title:          artifactContext.Title,
			Messages:       artifactContext.Messages,
		})
	}
	return out, nil
}

// sameCanonicalPath 比较两个路径是否指向同一 canonical 目录。
func sameCanonicalPath(left, right string) bool {
	left = comparableWorkspacePath(left)
	right = comparableWorkspacePath(right)
	return left != "" && right != "" && left == right
}

// confirmDSHWorkspaceCandidates 把本次 sync_dsh 上报成功的候选在本机 confirmed_workspace
// 落账。扫描出的 DSH 工作区若不写本机确认表，后续 session.start 解析不到 workspace root，
// 会以 local_state_missing 语义 fail-closed。Relay 按去重后的候选顺序回传 workspace_ids，
// 这里的去重规则（按 canonical root 保序）必须与其一致。候选根来自本机扫描器，
// ConfirmExistingDSHWorkspace 仍会重验授权根边界与 DSH 证据（v0.8.5 §3.6：Git 根不再是
// 确认必要条件，非 Git 候选按 DSH 条目登记、gitread 标注不可用）；单个候选确认失败只
// 降级为告警，不能让已成功的同步整体失败。
func (l *RelayLoop) confirmDSHWorkspaceCandidates(ctx context.Context, commandID string, candidates []DSHWorkspaceCandidate, receipt DSHSyncCommandReceipt) {
	if receipt.Status != "succeeded" || l == nil || l.WorkspaceManager == nil || len(receipt.WorkspaceIDs) == 0 {
		return
	}
	seenRoots := map[string]struct{}{}
	orderedRoots := make([]string, 0, len(candidates))
	for _, candidate := range candidates {
		if _, exists := seenRoots[candidate.Root]; exists {
			continue
		}
		seenRoots[candidate.Root] = struct{}{}
		orderedRoots = append(orderedRoots, candidate.Root)
	}
	if len(orderedRoots) != len(receipt.WorkspaceIDs) {
		l.Logger.Warn("daemon dsh workspace receipt mismatch",
			"command", commandID, "roots", len(orderedRoots), "ids", len(receipt.WorkspaceIDs))
		return
	}
	for i, workspaceID := range receipt.WorkspaceIDs {
		if _, err := l.WorkspaceManager.ConfirmExistingDSHWorkspace(ctx, workspaceID, orderedRoots[i]); err != nil {
			l.Logger.Warn("daemon dsh workspace confirm failed",
				"command", commandID, "workspace", workspaceID, "error", err)
		}
	}
}
