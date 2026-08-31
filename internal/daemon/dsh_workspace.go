package daemon

// 本文件实现 v0.8 P2 的 DSH 本地工作区扫描与确认边界。
// 扫描只读、不创建目录、不初始化 Git、不跟随符号链接；只有“授权根内 + DSH 持久化证据 + Git 根”
// 的项目才会被确认为 Workspace。canonical root 只进入本机确认表与 Relay 专用 result，不进入普通日志。

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strings"

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
	Scanned        int            `json:"scanned"`
	Candidates     int            `json:"candidates"`
	Skipped        int            `json:"skipped"`
	Ignored        int            `json:"ignored"`
	Symlinks       int            `json:"symlinks"`
	DepthLimited   int            `json:"depth_limited"`
	LimitReached   bool           `json:"limit_reached"`
	SkippedReasons map[string]int `json:"skipped_reasons"`
}

// DSHWorkspaceCandidate 是扫描器返回的本机候选；Root 只在本机使用，不能进入 Relay 普通响应。
type DSHWorkspaceCandidate struct {
	Root string
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
		if s.hasDSHEvidence(cur.path) && workspacesafe.IsGitRoot(cur.path) {
			if len(candidates) >= s.maxCandidates {
				summary.LimitReached = true
				return candidates, summary, nil
			}
			key := filepath.Clean(cur.path)
			if !seen[key] {
				seen[key] = true
				candidates = append(candidates, DSHWorkspaceCandidate{Root: key})
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

// hasDSHEvidence 检查目录下是否存在 DSH 持久化证据：
// `.dsh-sessions` 内至少有一个 `session.jsonl` / `session.jsonl.zstd`，或存在 `session-query.db` 标记。
// 它不解析正文，也不把 `session-query.db` 当作会话事实来源。
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
		if entry.IsDir() || entry.Type()&os.ModeSymlink != 0 {
			continue
		}
		name := entry.Name()
		if name == "session.jsonl" || name == "session.jsonl.zstd" || name == "session-query.db" {
			return true
		}
	}
	return false
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
	if !workspacesafe.IsGitRoot(resolved) {
		return ConfirmedWorkspace{}, workspacesafe.ErrNotAGitRoot
	}
	scanner := NewDSHWorkspaceScanner(m.root)
	if !scanner.hasDSHEvidence(resolved) {
		return ConfirmedWorkspace{}, errors.New("directory 缺少 DSH 持久化证据")
	}
	return m.store.ConfirmWorkspace(workspaceID, resolved)
}
