// Package gitread 提供 Daemon 内 Git 只读服务：status、listChanges、diffFile、diffAll。
// 所有 Git 调用用 exec.CommandContext 参数数组执行（不经过 shell），
// 路径必须经过 workspacesafe 校验，响应在 Daemon 加密后离开本机。
package gitread

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os/exec"
	"strings"
	"time"
)

// 最大输出字节数保护；超大 diff 返回受限状态而非截断真实内容。
const MaxOutputBytes = 4 << 20 // 4 MiB

// ChangeType 是变更类型。
type ChangeType string

// 变更类型常量。
const (
	ChangeAdded       ChangeType = "added"
	ChangeModified    ChangeType = "modified"
	ChangeDeleted     ChangeType = "deleted"
	ChangeRenamed     ChangeType = "renamed"
	ChangeTypeChanged ChangeType = "type_changed"
	ChangeUntracked   ChangeType = "untracked"
)

// FileStatus 是单个文件的结构化状态（porcelain v2 -z 解析结果）。
type FileStatus struct {
	Path      string     `json:"path"`
	Type      ChangeType `json:"type"`
	Staged    bool       `json:"staged"`
	Binary    bool       `json:"binary"`
	Rename    *Rename    `json:"rename,omitempty"`
	Submodule bool       `json:"submodule"`
	LFS       bool       `json:"lfs"`
}

// Rename 记录 rename 前后路径。
type Rename struct {
	From string `json:"from"`
	To   string `json:"to"`
}

// Status 是一次 status 快照。
type Status struct {
	Head      string       `json:"head"`
	Branch    string       `json:"branch"`
	Files     []FileStatus `json:"files"`
	Truncated bool         `json:"truncated"`
}

// DiffHunk 是统一 diff 的一个 hunk。
type DiffHunk struct {
	Header string   `json:"header"`
	Lines  []string `json:"lines"`
}

// FileDiff 是单个文件 diff。
type FileDiff struct {
	Path      string     `json:"path"`
	Binary    bool       `json:"binary"`
	LFS       bool       `json:"lfs"`
	Hunks     []DiffHunk `json:"hunks"`
	Truncated bool       `json:"truncated"`
}

// Service 执行 Git 只读 RPC，绑定已确认 workspace root。
type Service struct {
	root string
	git  string
	now  func() time.Time
}

// New 构造 Git 只读服务。
func New(root, gitBin string) *Service {
	if gitBin == "" {
		gitBin = "git"
	}
	return &Service{root: root, git: gitBin, now: time.Now}
}

// runGit 参数数组执行 Git；禁止 shell 拼接。
func (s *Service) runGit(ctx context.Context, args ...string) (string, error) {
	cmd := exec.CommandContext(ctx, s.git, args...)
	cmd.Dir = s.root
	out, err := cmd.Output()
	if err != nil {
		if ee, ok := err.(*exec.ExitError); ok {
			return string(out), fmt.Errorf("git %s: %s", strings.Join(args, " "), strings.TrimSpace(string(ee.Stderr)))
		}
		return "", err
	}
	return string(out), nil
}

// Status 返回工作区状态（porcelain v2 -z 解析）。
func (s *Service) Status(ctx context.Context) (Status, error) {
	head, _ := s.runGit(ctx, "rev-parse", "--short", "HEAD")
	branch, _ := s.runGit(ctx, "rev-parse", "--abbrev-ref", "HEAD")
	out, err := s.runGit(ctx, "status", "--porcelain=v2", "-z")
	if err != nil {
		return Status{}, err
	}
	return parseStatus(strings.TrimSpace(head), strings.TrimSpace(branch), out)
}

// ListChanges 返回变更文件列表（复用 Status 的 Files）。
func (s *Service) ListChanges(ctx context.Context) ([]FileStatus, error) {
	st, err := s.Status(ctx)
	if err != nil {
		return nil, err
	}
	return st.Files, nil
}

// DiffFile 返回指定文件 diff；root 必须为已确认工作区。
func (s *Service) DiffFile(ctx context.Context, relPath string) (FileDiff, error) {
	out, err := s.runGit(ctx, "diff", "--no-color", "-U3", "--", relPath)
	if err != nil {
		return FileDiff{}, err
	}
	return parseDiff(relPath, out)
}

// DiffAll 返回全量 diff（受 MaxOutputBytes 保护）。
func (s *Service) DiffAll(ctx context.Context) ([]FileDiff, error) {
	out, err := s.runGit(ctx, "diff", "--no-color", "-U3")
	if err != nil {
		return nil, err
	}
	return parseAllDiffs(out)
}

// parseStatus 解析 porcelain v2 -z 输出。
func parseStatus(head, branch, raw string) (Status, error) {
	st := Status{Head: head, Branch: branch}
	if len(raw) >= MaxOutputBytes {
		st.Truncated = true
	}
	fields := strings.Split(raw, "\x00")
	for i := 0; i < len(fields); i++ {
		f := strings.TrimSpace(fields[i])
		if f == "" {
			continue
		}
		fs, err := parseRecord(f, fields, &i)
		if err == nil {
			st.Files = append(st.Files, fs)
		}
	}
	return st, nil
}

// parseRecord 解析单条 porcelain v2 记录（-z 下 path 是记录末尾空格分隔字段）。
func parseRecord(f string, fields []string, i *int) (FileStatus, error) {
	parts := strings.Fields(f)
	if len(parts) < 2 {
		return FileStatus{}, fmt.Errorf("short record: %s", f)
	}
	fs := FileStatus{Path: parts[len(parts)-1]}
	switch {
	case strings.HasPrefix(parts[0], "1"):
		// 1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>
		xy := parts[1]
		fs.Type = xyType(xy)
		fs.Submodule = len(parts) > 2 && parts[2] == "160000"
		fs.Staged = xy[0] != '.'
	case strings.HasPrefix(parts[0], "2"):
		// 2 <XY> <sub> ... <Xscore> <path> <Xpath>
		from := parts[len(parts)-2]
		fs.Path = parts[len(parts)-1]
		fs.Type = ChangeRenamed
		fs.Rename = &Rename{From: from, To: fs.Path}
	case strings.HasPrefix(parts[0], "?"):
		// ? <path>
		fs.Path = strings.TrimPrefix(f, "? ")
		fs.Type = ChangeUntracked
	default:
		return fs, fmt.Errorf("unknown record: %s", f)
	}
	return fs, nil
}

// xyType 把 porcelain XY 状态映射为 ChangeType。
func xyType(xy string) ChangeType {
	if len(xy) < 2 {
		return ChangeModified
	}
	switch xy[1] {
	case 'A':
		return ChangeAdded
	case 'D':
		return ChangeDeleted
	case 'M', 'T':
		return ChangeModified
	case 'R':
		return ChangeRenamed
	default:
		return ChangeModified
	}
}

// parseDiff 解析单文件统一 diff 为 hunks。
func parseDiff(path, raw string) (FileDiff, error) {
	d := FileDiff{Path: path}
	if len(raw) >= MaxOutputBytes {
		d.Truncated = true
	}
	lines := strings.Split(raw, "\n")
	var cur *DiffHunk
	for _, ln := range lines {
		if strings.HasPrefix(ln, "@@") {
			if cur != nil {
				d.Hunks = append(d.Hunks, *cur)
			}
			cur = &DiffHunk{Header: ln}
			continue
		}
		if cur != nil {
			cur.Lines = append(cur.Lines, ln)
		}
	}
	if cur != nil {
		d.Hunks = append(d.Hunks, *cur)
	}
	return d, nil
}

// parseAllDiffs 把全量 diff 按文件切分。
func parseAllDiffs(raw string) ([]FileDiff, error) {
	out := []FileDiff{}
	blocks := splitDiffByFile(raw)
	for _, b := range blocks {
		path := diffFilePath(b)
		d, err := parseDiff(path, b)
		if err == nil {
			out = append(out, d)
		}
	}
	return out, nil
}

// splitDiffByFile 依据 `diff --git a/... b/...` 行切分。
func splitDiffByFile(raw string) []string {
	blocks := []string{}
	cur := ""
	for _, ln := range strings.Split(raw, "\n") {
		if strings.HasPrefix(ln, "diff --git ") && cur != "" {
			blocks = append(blocks, cur)
			cur = ""
		}
		cur += ln + "\n"
	}
	if cur != "" {
		blocks = append(blocks, cur)
	}
	return blocks
}

// diffFilePath 从 diff 块首行提取 a/ 路径。
func diffFilePath(block string) string {
	first := strings.SplitN(block, "\n", 2)[0]
	parts := strings.Split(first, " ")
	if len(parts) >= 4 {
		return strings.TrimPrefix(parts[2], "a/")
	}
	return ""
}

// SnapshotToken 生成绑定工作区与 HEAD/index 指纹的 token，供分页校验漂移。
func (s *Service) SnapshotToken(ctx context.Context) (string, error) {
	head, err := s.runGit(ctx, "rev-parse", "HEAD")
	if err != nil {
		return "", err
	}
	index, _ := s.runGit(ctx, "write-tree")
	fp := sha256.Sum256([]byte(s.root + "|" + strings.TrimSpace(head) + "|" + strings.TrimSpace(index)))
	return hex.EncodeToString(fp[:]), nil
}
