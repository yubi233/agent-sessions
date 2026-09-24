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
	"strconv"
	"strings"
	"time"
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

// ConfirmGlobalDSHWorkspace 以 DSH 全局会话存储（~/.dsh/sessions）中的会话为证据
// 登记工作区——全局布局下项目目录没有自己的 .dsh-sessions，证据就是全局存储中
// 该 cwd 的会话文件。授权边界照验（root 必须仍在授权根内），登记走非 Git DSH 语义。
func (m *WorkspaceManager) ConfirmGlobalDSHWorkspace(ctx context.Context, workspaceID, root string) (ConfirmedWorkspace, error) {
	if m == nil || m.store == nil || strings.TrimSpace(m.root) == "" {
		return ConfirmedWorkspace{}, ErrWorkspaceRootInvalid
	}
	resolved, err := workspacesafe.ResolveAbsolute(m.root, root)
	if err != nil {
		return ConfirmedWorkspace{}, err
	}
	if !pathWithin(m.root, resolved) {
		return ConfirmedWorkspace{}, workspacesafe.ErrEscapeRoot
	}
	globalRoot, globalErr := dsh.GlobalSessionsDir()
	if globalErr != nil {
		return ConfirmedWorkspace{}, globalErr
	}
	artifacts, scanErr := dsh.ScanGlobalSessionArtifacts(globalRoot)
	if scanErr != nil {
		return ConfirmedWorkspace{}, scanErr
	}
	target := comparableWorkspacePath(resolved)
	for _, artifact := range artifacts {
		if sameCanonicalPath(artifact.CWD, target) {
			return m.store.ConfirmDSHWorkspace(workspaceID, resolved)
		}
	}
	return ConfirmedWorkspace{}, errors.New("DSH 全局存储中没有该工作区的会话证据")
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
	// LastActivityUnixMS 是 DSH artifact 的最后修改时间（会话真实活动时间），
	// Relay 以它作为导入会话的 last_activity 而不是导入时刻——「最近三天还在
	// 更新」的判定对用户是真实语义。
	LastActivityUnixMS int64
	// PersistenceRoot/Compression 是 artifact 实际所在的存储根与物理编码
	// （v0.9.5：写入 instance 映射，resume 把桥绑定到真实存储位置——全局存储
	// （zstd）来源的会话在工作区缺省根上不可续）。只存本机，不上传 Relay。
	PersistenceRoot string
	Compression     string
	// ImportedSeq/WatermarkValid 是本次导入的增量水位（v0.9.5 P1）：WatermarkValid
	// 为 true 时 ImportedSeq 是「已完整导入到哪一行」的 JSONL seq。回执成功收口后
	// 由 CommitDSHImportWatermarks 落账——回执失败不推进，下次导入重发同一批
	// 增量，不丢消息；空标题+零消息的导入不携带水位（无事可推进）。
	ImportedSeq    int64
	WatermarkValid bool
}

const (
	// importContextLimit 是每个导入会话保留的最近上下文条数（用户口径「十几条」取 14）。
	importContextLimit = 14
	// importIncrementalLimit 是单次导入为已导入线程补齐的增量消息上限（v0.9.5 P1）：
	// 超出部分留在下一次导入，水位停在最后一条已导入消息上，不产生空洞。
	importIncrementalLimit = 200
	// dshImportActiveWindow 是「活跃会话」的判定窗口（用户口径：最近三天还在更新
	// 的会话）。只有 DSH artifact 的最后修改时间落在窗口内的会话才会被导入——
	// 老会话不产生投影，客户端列表因此只加载活跃工作集；会话重新活跃（DSH 更新
	// 其 JSONL）后，下一次导入会自动把它带回。
	dshImportActiveWindow = 72 * time.Hour
)

// importActiveCutoff 返回活跃窗口的截止时间（now-72h），独立变量便于测试注入。
var importActiveCutoff = func() time.Time { return time.Now().Add(-dshImportActiveWindow) }

// ImportDSHSessions 扫描已确认 DSH 工作区下的 JSONL artifact，为每个**活跃**会话
// （用户口径：最近三天还在更新，即 artifact ModTime 在 72h 窗口内）生成 opaque
// Relay session id 并写入本机 instance/replay 映射；同时提取真实标题与最近上下文
// 消息（v0.9.4：客户端打开导入会话即可见最近十几条正文）。窗口外的历史会话不导入、
// 不产生投影，客户端列表因此只加载活跃工作集。DSH session id、cwd 或路径仍不上传
// 到 Relay；正文只进入用户自己的事件流。
func (m *WorkspaceManager) ImportDSHSessions(ctx context.Context, workspaceID string, store *Store, includeAll bool) ([]DSHImportedSession, error) {
	if m == nil || store == nil {
		return nil, ErrWorkspaceRootInvalid
	}
	confirmed, err := store.ConfirmedWorkspaceByID(workspaceID)
	if err != nil {
		return nil, err
	}
	// 来源合并（v0.9.4 遗漏修齐）：① 项目绑定布局 <root>/.dsh-sessions；
	// ② DSH 全局存储 ~/.dsh/sessions（CLI/Web 在任意 cwd 发起的会话都集中存放在
	// 这里，ai_novel 等项目只出现在全局布局）。两个来源都按 cwd==工作区 root 过滤。
	persistenceRoot := filepath.Join(confirmed.Root, ".dsh-sessions")
	artifacts, err := dsh.ScanSessionArtifacts(persistenceRoot)
	if err != nil {
		// 没有持久化根时视为空导入，而不是让整个同步失败。
		if !os.IsNotExist(err) {
			return nil, err
		}
		artifacts = nil
	}
	if globalRoot, globalErr := dsh.GlobalSessionsDir(); globalErr == nil {
		if globalArtifacts, scanErr := dsh.ScanGlobalSessionArtifacts(globalRoot); scanErr == nil {
			artifacts = append(artifacts, globalArtifacts...)
		}
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
		// 跨轮幂等（v0.9.4）：同一 DSH 会话只对应一个 Relay 会话——复用已有映射。
		// v0.9.5 P1（持续同步）：复用时不再只回活动时间，而是按水位做增量补齐——
		// 只携带上次导入之后的新正文（上限 importIncrementalLimit，超出留到下一
		// 次导入）与 watermark 之后的新标题；无新行时零消息零标题，绝不重发预览。
		threadKey := "dshthread:" + confirmed.Root + ":" + artifact.ID
		if existingRelayID, getErr := store.Get(threadKey); getErr == nil && existingRelayID != "" {
			item := DSHImportedSession{
				RelaySessionID:     existingRelayID,
				DSHSessionID:       artifact.ID,
				WorkspaceRoot:      confirmed.Root,
				LastActivityUnixMS: artifact.ModTime.UnixMilli(),
			}
			watermark := int64(-1)
			if raw, seqErr := store.Get(threadSeqKey(confirmed.Root, artifact.ID)); seqErr == nil {
				if parsed, parseErr := strconv.ParseInt(strings.TrimSpace(raw), 10, 64); parseErr == nil {
					watermark = parsed
				}
			}
			if incrementalCtx, incrErr := dsh.ReadSessionEventsAfter(artifact.Path, watermark, importIncrementalLimit); incrErr == nil &&
				(len(incrementalCtx.Messages) > 0 || incrementalCtx.Title != "") {
				item.Messages = incrementalCtx.Messages
				item.Title = incrementalCtx.Title
				item.ImportedSeq = incrementalCtx.LastSeq
				item.WatermarkValid = true
			}
			out = append(out, item)
			continue
		}
		// 活跃过滤：只导入最近三天还在更新的会话（ModTime 即会话最后活动时间）。
		// 老会话跳过；一旦 DSH 侧再次更新它，下一次导入会自动带回来。
		// includeAll（v0.9.5 P2 按需导入全部）：显式请求时绕过窗口，把窗口外的
		// 历史会话也按需带入（每个会话仍是标题+最近十几条预览，水位增量照常）。
		if !includeAll && artifact.ModTime.Before(importActiveCutoff()) {
			continue
		}
		relaySessionID := id.New("sess")
		// v0.9.4：提取真实标题与最近上下文。读取失败不阻断导入（上下文尽力而为）。
		artifactContext, ctxErr := dsh.ReadSessionContext(artifact.Path, importContextLimit)
		if ctxErr != nil {
			artifactContext = dsh.SessionContext{}
		}
		// 写本机 instance 映射：Relay session -> DSH session + workspace root，
		// 并记录 artifact 来源存储根与物理编码（v0.9.5）：resume 据此把桥绑定到
		// 真实存储位置，全局存储（zstd）来源的会话才能在原会话上继续。
		mapping, err := json.Marshal(providerThread{
			Provider:        "dsh",
			InstanceID:      artifact.ID,
			WorkspaceRoot:   confirmed.Root,
			PersistenceRoot: artifact.SourceRoot,
			Compression:     artifact.Compression,
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
		if err := store.Set(threadKey, relaySessionID); err != nil {
			return nil, err
		}
		out = append(out, DSHImportedSession{
			RelaySessionID:     relaySessionID,
			DSHSessionID:       artifact.ID,
			WorkspaceRoot:      confirmed.Root,
			Title:              artifactContext.Title,
			Messages:           artifactContext.Messages,
			LastActivityUnixMS: artifact.ModTime.UnixMilli(),
			PersistenceRoot:    artifact.SourceRoot,
			Compression:        artifact.Compression,
			// 首次导入的水位 = 预览读取的行尾；同样等回执成功后由
			// CommitDSHImportWatermarks 落账（与映射写入的失败窗口解耦）。
			ImportedSeq:    artifactContext.LastSeq,
			WatermarkValid: true,
		})
	}
	return out, nil
}

// threadSeqKey 是 <root>:<dshID> -> 已导入最大 JSONL seq 的 local_state 键
// （v0.9.5 P1 增量同步水位）。只存本机。
func threadSeqKey(root, dshID string) string {
	return "dshthreadseq:" + root + ":" + dshID
}

// CommitDSHImportWatermarks 在导入回执成功收口后推进各线程水位（v0.9.5 P1）。
// 由 daemon RelayLoop 在 receipt succeeded 之后调用：回执失败/未收口不推进，
// 下次导入会重发同一批增量，保证不丢消息（可能重复的窗口仅限「回执成功但
// 本机落账前崩溃」，与既有命令收口语义一致）。落账失败静默忽略——重复导入
// 只会由客户端投影层折叠，不会丢数据。
func (m *WorkspaceManager) CommitDSHImportWatermarks(store *Store, imported []DSHImportedSession) {
	if m == nil || store == nil {
		return
	}
	for _, item := range imported {
		if !item.WatermarkValid {
			continue
		}
		_ = store.Set(threadSeqKey(item.WorkspaceRoot, item.DSHSessionID), strconv.FormatInt(item.ImportedSeq, 10))
	}
}

// sameCanonicalPath 比较两个路径是否指向同一 canonical 目录。
func sameCanonicalPath(left, right string) bool {
	left = comparableWorkspacePath(left)
	right = comparableWorkspacePath(right)
	return left != "" && right != "" && left == right
}

// locateDSHArtifactSource 按 DSH 会话 id 在两源存储中定位 artifact（v0.9.5 P0）：
// 工作区绑定布局优先，其次全局存储（~/.dsh/sessions）。返回来源存储根与物理编码，
// 供 resume 把桥绑定到 artifact 实际位置——旧映射（无 persistence_root）首次恢复时
// 由它完成一次性自升级。找不到时 ok=false，调用方保持缺省行为（不阻断恢复）。
func locateDSHArtifactSource(instanceID, workspaceRoot string) (root, compression string, ok bool) {
	instanceID = strings.TrimSpace(instanceID)
	if instanceID == "" {
		return "", "", false
	}
	// ① 工作区绑定布局：与生产 Start/Resume 的缺省根一致，优先命中。
	if strings.TrimSpace(workspaceRoot) != "" {
		if artifacts, err := dsh.ScanSessionArtifacts(filepath.Join(workspaceRoot, ".dsh-sessions")); err == nil {
			for _, artifact := range artifacts {
				if artifact.ID == instanceID {
					return artifact.SourceRoot, artifact.Compression, true
				}
			}
		}
	}
	// ② 全局存储：DSH CLI/Web 在任意 cwd 发起的会话集中存放（zstd）。
	if globalRoot, err := dsh.GlobalSessionsDir(); err == nil {
		if artifacts, scanErr := dsh.ScanGlobalSessionArtifacts(globalRoot); scanErr == nil {
			for _, artifact := range artifacts {
				if artifact.ID == instanceID {
					return artifact.SourceRoot, artifact.Compression, true
				}
			}
		}
	}
	return "", "", false
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
			// v0.9.4 遗漏修齐：全局布局（DSH CLI/Web 在任意 cwd 发起的会话集中在
			// ~/.dsh/sessions）下，项目目录没有 .dsh-sessions 证据——回退用「全局
			// 存储中存在该 cwd 的会话」作为 DSH 证据登记工作区。
			if _, globalErr := l.WorkspaceManager.ConfirmGlobalDSHWorkspace(ctx, workspaceID, orderedRoots[i]); globalErr != nil {
				l.Logger.Warn("daemon dsh workspace confirm failed",
					"command", commandID, "workspace", workspaceID, "error", globalErr)
			}
		}
	}
}
