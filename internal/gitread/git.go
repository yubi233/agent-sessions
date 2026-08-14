// Package gitread 提供 Daemon 内 Git 只读服务：status、listChanges、diffFile、diffAll。
// 所有 Git 调用都使用参数数组，并且在读取工作区前重新经过 workspacesafe 校验。
// Diff 内容只在 Daemon 本地短暂存在，离开 Daemon 前应由上层加密；本包不负责 Relay 传输。
package gitread

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/yubi233/agent-sessions/internal/workspacesafe"
)

// 最大单次 Git 输出字节数；超限时终止子进程并返回受限结果，不截断成可误读的 diff。
const MaxOutputBytes = 4 << 20 // 4 MiB

// 稳定错误供 Daemon RPC 映射为受限或可重试状态。
var (
	ErrOutputLimit   = errors.New("git output exceeds limit")
	ErrSnapshotStale = errors.New("git snapshot is stale")
	ErrNotGitRoot    = errors.New("workspace is not the confirmed git root")
)

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
	Unstaged  bool       `json:"unstaged"`
	Binary    bool       `json:"binary"`
	Additions int        `json:"additions"`
	Deletions int        `json:"deletions"`
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
	Head          string       `json:"head"`
	Branch        string       `json:"branch"`
	SnapshotToken string       `json:"snapshot_token"`
	Files         []FileStatus `json:"files"`
	Truncated     bool         `json:"truncated"`
}

// DiffHunk 是统一 diff 的一个 hunk。
type DiffHunk struct {
	Header string   `json:"header"`
	Lines  []string `json:"lines"`
}

// FileDiff 是单个文件 diff。受限文件只返回元数据，不把二进制或超大内容当文本。
type FileDiff struct {
	Path      string     `json:"path"`
	Binary    bool       `json:"binary"`
	LFS       bool       `json:"lfs"`
	Submodule bool       `json:"submodule"`
	Untracked bool       `json:"untracked"`
	Rename    *Rename    `json:"rename,omitempty"`
	Additions int        `json:"additions"`
	Deletions int        `json:"deletions"`
	Hunks     []DiffHunk `json:"hunks"`
	Truncated bool       `json:"truncated"`
}

// DiffPage 是移动端分页消费的稳定边界；分页期间必须带回同一个 snapshot token。
type DiffPage struct {
	Path          string     `json:"path"`
	SnapshotToken string     `json:"snapshot_token"`
	Offset        int        `json:"offset"`
	NextOffset    int        `json:"next_offset"`
	HasMore       bool       `json:"has_more"`
	Hunks         []DiffHunk `json:"hunks"`
	Binary        bool       `json:"binary"`
	LFS           bool       `json:"lfs"`
	Submodule     bool       `json:"submodule"`
	Truncated     bool       `json:"truncated"`
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

// boundedBuffer 限制 stderr，避免 Git 错误文本成为另一个无界缓冲区。
type boundedBuffer struct {
	bytes []byte
	limit int
}

func (b *boundedBuffer) Write(p []byte) (int, error) {
	remaining := b.limit - len(b.bytes)
	if remaining > 0 {
		if remaining > len(p) {
			remaining = len(p)
		}
		b.bytes = append(b.bytes, p[:remaining]...)
	}
	// 返回完整写入长度，让 exec 不因诊断输出超限而阻塞。
	return len(p), nil
}

func (b *boundedBuffer) String() string { return string(b.bytes) }

// readLimitedOutput 流式读取 stdout；第一次超过上限就终止子进程并继续排空管道。
func readLimitedOutput(reader io.Reader, limit int, process *os.Process) (string, bool, error) {
	buf := make([]byte, 32*1024)
	out := make([]byte, 0, minInt(limit, 128*1024))
	limited := false
	for {
		n, err := reader.Read(buf)
		if n > 0 {
			if len(out)+n > limit {
				limited = true
				if process != nil {
					_ = process.Kill()
				}
			} else if !limited {
				out = append(out, buf[:n]...)
			}
		}
		if err != nil {
			if errors.Is(err, io.EOF) {
				break
			}
			return string(out), limited, err
		}
	}
	return string(out), limited, nil
}

func minInt(a, b int) int {
	if a < b {
		return a
	}
	return b
}

// runGitAtRoot 使用固定环境和参数数组执行 Git，不经过 shell。
func (s *Service) runGitAtRoot(ctx context.Context, root string, args ...string) (string, error) {
	return s.runGitAtRootAllowed(ctx, root, map[int]bool{}, args...)
}

// runGitAtRootAllowed 允许少量 Git 语义退出码（例如 diff --no-index 的 1）。
func (s *Service) runGitAtRootAllowed(
	ctx context.Context,
	root string,
	allowed map[int]bool,
	args ...string,
) (string, error) {
	cmd := exec.CommandContext(ctx, s.git, args...)
	cmd.Dir = root
	cmd.Env = []string{
		"PATH=" + os.Getenv("PATH"),
		"LC_ALL=C",
		"LANG=C",
		"GIT_CONFIG_NOSYSTEM=1",
		"GIT_OPTIONAL_LOCKS=0",
		"GIT_TERMINAL_PROMPT=0",
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return "", err
	}
	var stderr boundedBuffer
	stderr.limit = 64 * 1024
	cmd.Stderr = &stderr
	if err := cmd.Start(); err != nil {
		return "", err
	}
	out, limited, readErr := readLimitedOutput(stdout, MaxOutputBytes, cmd.Process)
	waitErr := cmd.Wait()
	if readErr != nil {
		return "", readErr
	}
	if limited {
		return "", ErrOutputLimit
	}
	if ctx.Err() != nil {
		return "", ctx.Err()
	}
	if waitErr != nil {
		if exitErr, ok := waitErr.(*exec.ExitError); ok && allowed[exitErr.ExitCode()] {
			return out, nil
		}
		detail := strings.TrimSpace(stderr.String())
		if detail == "" {
			detail = strings.TrimSpace(waitErr.Error())
		}
		return out, fmt.Errorf("git %s: %s", strings.Join(args, " "), detail)
	}
	return out, nil
}

// repositoryRoot 每次请求重新解析 canonical root，并确认它正是 Git 根，防止 Workspace 移动后继续读取。
func (s *Service) repositoryRoot(ctx context.Context) (string, error) {
	root, err := workspacesafe.ResolveRepoRelative(s.root, ".")
	if err != nil {
		return "", err
	}
	top, err := s.runGitAtRoot(ctx, root, "rev-parse", "--show-toplevel")
	if err != nil {
		return "", fmt.Errorf("%w: %v", ErrNotGitRoot, err)
	}
	canonicalTop, err := filepath.EvalSymlinks(strings.TrimSpace(top))
	if err != nil || !samePath(canonicalTop, root) {
		return "", ErrNotGitRoot
	}
	return root, nil
}

func samePath(left, right string) bool {
	leftAbs, leftErr := filepath.Abs(left)
	rightAbs, rightErr := filepath.Abs(right)
	return leftErr == nil && rightErr == nil && filepath.Clean(leftAbs) == filepath.Clean(rightAbs)
}

// safeRepoPath 把客户端路径解析到 canonical root，并返回给 Git 的相对路径。
func safeRepoPath(root, relPath string) (string, error) {
	if _, err := workspacesafe.ResolveRepoRelative(root, relPath); err != nil {
		return "", err
	}
	cleaned := filepath.Clean(relPath)
	if cleaned == "." || cleaned == ".." || strings.HasPrefix(cleaned, ".."+string(filepath.Separator)) {
		return "", workspacesafe.ErrEscapeRoot
	}
	return filepath.ToSlash(cleaned), nil
}

func statusFileForPath(status Status, path string) *FileStatus {
	for index := range status.Files {
		if status.Files[index].Path == path {
			return &status.Files[index]
		}
	}
	return nil
}

func readRevision(ctx context.Context, s *Service, root string, args ...string) string {
	out, err := s.runGitAtRoot(ctx, root, args...)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(out)
}

// Status 返回工作区状态，并将未提交工作区状态纳入 snapshot token。
func (s *Service) Status(ctx context.Context) (Status, error) {
	root, err := s.repositoryRoot(ctx)
	if err != nil {
		return Status{}, err
	}
	return s.statusAtRoot(ctx, root)
}

func (s *Service) statusAtRoot(ctx context.Context, root string) (Status, error) {
	head := readRevision(ctx, s, root, "rev-parse", "--short", "HEAD")
	branch := readRevision(ctx, s, root, "rev-parse", "--abbrev-ref", "HEAD")
	raw, err := s.runGitAtRoot(ctx, root, "status", "--porcelain=v2", "-z", "--untracked-files=all")
	if errors.Is(err, ErrOutputLimit) {
		return Status{Head: head, Branch: branch, Truncated: true}, nil
	}
	if err != nil {
		return Status{}, err
	}
	st, err := parseStatus(head, branch, raw)
	if err != nil {
		return Status{}, err
	}
	for index := range st.Files {
		if err := s.enrichStatusFile(ctx, root, &st.Files[index]); err != nil {
			return Status{}, err
		}
	}
	token, err := s.snapshotTokenFor(ctx, root, head, branch, raw, st.Files)
	if err != nil {
		return Status{}, err
	}
	st.SnapshotToken = token
	return st, nil
}

// ListChanges 返回变更文件列表（复用 Status 的 Files）。
func (s *Service) ListChanges(ctx context.Context) ([]FileStatus, error) {
	st, err := s.Status(ctx)
	if err != nil {
		return nil, err
	}
	return st.Files, nil
}

// DiffFile 返回指定文件相对 HEAD 的只读 diff；路径先经过 realpath 校验。
func (s *Service) DiffFile(ctx context.Context, relPath string) (FileDiff, error) {
	root, err := s.repositoryRoot(ctx)
	if err != nil {
		return FileDiff{}, err
	}
	safePath, err := safeRepoPath(root, relPath)
	if err != nil {
		return FileDiff{}, err
	}
	status, err := s.statusAtRoot(ctx, root)
	if err != nil {
		return FileDiff{}, err
	}
	if status.Truncated {
		return FileDiff{Path: safePath, Truncated: true}, nil
	}
	return s.diffFileAtRoot(ctx, root, safePath, statusFileForPath(status, safePath))
}

func (s *Service) diffFileAtRoot(ctx context.Context, root, relPath string, status *FileStatus) (FileDiff, error) {
	d := FileDiff{Path: relPath}
	if status != nil {
		d.Rename = status.Rename
		d.Untracked = status.Type == ChangeUntracked
		d.Submodule = status.Submodule
		d.LFS = status.LFS
		d.Binary = status.Binary
		d.Additions = status.Additions
		d.Deletions = status.Deletions
	}
	traits, err := s.fileTraits(ctx, root, relPath)
	if err != nil {
		return FileDiff{}, err
	}
	d.Binary = d.Binary || traits.binary
	d.LFS = d.LFS || traits.lfs
	d.Submodule = d.Submodule || traits.submodule
	raw, err := s.runGitAtRoot(ctx, root,
		"diff", "--no-color", "--no-ext-diff", "--no-textconv", "-U3", "HEAD", "--", relPath,
	)
	if errors.Is(err, ErrOutputLimit) {
		d.Truncated = true
		return d, nil
	}
	if err != nil {
		return FileDiff{}, err
	}
	if raw == "" && d.Untracked {
		// diff --no-index 的退出码 1 代表有差异，属于成功读取而非错误。
		raw, err = s.runGitAtRootAllowed(ctx, root, map[int]bool{1: true},
			"diff", "--no-color", "--no-ext-diff", "--no-textconv", "-U3", "--no-index", "--", "/dev/null", relPath,
		)
		if errors.Is(err, ErrOutputLimit) {
			d.Truncated = true
			return d, nil
		}
		if err != nil {
			return FileDiff{}, err
		}
	}
	parsed := parseDiff(relPath, raw)
	parsed.Rename = d.Rename
	parsed.Untracked = d.Untracked
	parsed.Binary = parsed.Binary || d.Binary
	parsed.LFS = d.LFS
	parsed.Submodule = parsed.Submodule || d.Submodule
	parsed.Additions = maxInt(parsed.Additions, d.Additions)
	parsed.Deletions = maxInt(parsed.Deletions, d.Deletions)
	return parsed, nil
}

// DiffAll 返回状态快照对应的文件 diff；每个文件仍受单文件上限和总 payload 上限保护。
func (s *Service) DiffAll(ctx context.Context) ([]FileDiff, error) {
	root, err := s.repositoryRoot(ctx)
	if err != nil {
		return nil, err
	}
	status, err := s.statusAtRoot(ctx, root)
	if err != nil {
		return nil, err
	}
	if status.Truncated {
		return []FileDiff{{Truncated: true}}, nil
	}
	out := make([]FileDiff, 0, len(status.Files))
	totalBytes := 0
	for index := range status.Files {
		diff, err := s.diffFileAtRoot(ctx, root, status.Files[index].Path, &status.Files[index])
		if err != nil {
			return nil, err
		}
		totalBytes += diffBytes(diff)
		if totalBytes > MaxOutputBytes {
			return append(out, FileDiff{Path: diff.Path, Truncated: true}), nil
		}
		out = append(out, diff)
	}
	return out, nil
}

// DiffFileAtSnapshot 在读取前后检查 snapshot，任何漂移都返回 ErrSnapshotStale。
func (s *Service) DiffFileAtSnapshot(ctx context.Context, relPath, snapshotToken string) (FileDiff, error) {
	if err := s.ValidateSnapshot(ctx, snapshotToken); err != nil {
		return FileDiff{}, err
	}
	diff, err := s.DiffFile(ctx, relPath)
	if err != nil {
		return FileDiff{}, err
	}
	if err := s.ValidateSnapshot(ctx, snapshotToken); err != nil {
		return FileDiff{}, err
	}
	return diff, nil
}

// DiffAllAtSnapshot 为全量读取提供同样的漂移保护。
func (s *Service) DiffAllAtSnapshot(ctx context.Context, snapshotToken string) ([]FileDiff, error) {
	if err := s.ValidateSnapshot(ctx, snapshotToken); err != nil {
		return nil, err
	}
	diffs, err := s.DiffAll(ctx)
	if err != nil {
		return nil, err
	}
	if err := s.ValidateSnapshot(ctx, snapshotToken); err != nil {
		return nil, err
	}
	return diffs, nil
}

// DiffFilePage 只分页 hunk，不允许调用方用旧 token 继续拼接新的工作区内容。
func (s *Service) DiffFilePage(ctx context.Context, relPath, snapshotToken string, offset, limit int) (DiffPage, error) {
	if offset < 0 || limit <= 0 || limit > 500 {
		return DiffPage{}, fmt.Errorf("invalid diff page: offset=%d limit=%d", offset, limit)
	}
	diff, err := s.DiffFileAtSnapshot(ctx, relPath, snapshotToken)
	if err != nil {
		return DiffPage{}, err
	}
	start := minInt(offset, len(diff.Hunks))
	end := minInt(start+limit, len(diff.Hunks))
	page := DiffPage{
		Path:          diff.Path,
		SnapshotToken: snapshotToken,
		Offset:        start,
		NextOffset:    end,
		HasMore:       end < len(diff.Hunks),
		Hunks:         append([]DiffHunk(nil), diff.Hunks[start:end]...),
		Binary:        diff.Binary,
		LFS:           diff.LFS,
		Submodule:     diff.Submodule,
		Truncated:     diff.Truncated,
	}
	return page, nil
}

// SnapshotToken 生成绑定工作区、HEAD、index 和未提交内容的指纹。
func (s *Service) SnapshotToken(ctx context.Context) (string, error) {
	root, err := s.repositoryRoot(ctx)
	if err != nil {
		return "", err
	}
	status, err := s.statusAtRoot(ctx, root)
	if err != nil {
		return "", err
	}
	if status.Truncated {
		return "", ErrOutputLimit
	}
	return status.SnapshotToken, nil
}

// ValidateSnapshot 将客户端携带的 token 与当前工作区重新计算的 token 做常量时间比较。
func (s *Service) ValidateSnapshot(ctx context.Context, token string) error {
	if strings.TrimSpace(token) == "" {
		return ErrSnapshotStale
	}
	current, err := s.SnapshotToken(ctx)
	if err != nil {
		return err
	}
	if subtle.ConstantTimeCompare([]byte(current), []byte(token)) != 1 {
		return ErrSnapshotStale
	}
	return nil
}

// parseStatus 解析 porcelain v2 -z，保留路径中的空格和 rename 的第二个 NUL 字段。
func parseStatus(head, branch, raw string) (Status, error) {
	st := Status{Head: head, Branch: branch}
	fields := strings.Split(raw, "\x00")
	for index := 0; index < len(fields); index++ {
		record := fields[index]
		if record == "" {
			continue
		}
		fs, needsOrigin, err := parseRecord(record)
		if err != nil {
			return Status{}, err
		}
		if fs.Path == "" {
			continue
		}
		if needsOrigin {
			index++
			if index >= len(fields) || fields[index] == "" {
				return Status{}, fmt.Errorf("rename record missing origin path")
			}
			fs.Rename.From = fields[index]
		}
		st.Files = append(st.Files, fs)
	}
	return st, nil
}

// parseRecord 解析单条记录。固定字段用 SplitN，最后的 path 不会因空格被截断。
func parseRecord(record string) (FileStatus, bool, error) {
	if strings.HasPrefix(record, "? ") {
		return FileStatus{Path: strings.TrimPrefix(record, "? "), Type: ChangeUntracked}, false, nil
	}
	if strings.HasPrefix(record, "! ") {
		return FileStatus{}, false, nil
	}
	if len(record) < 2 {
		return FileStatus{}, false, fmt.Errorf("short porcelain record")
	}
	switch record[0] {
	case '1':
		parts := strings.SplitN(record, " ", 9)
		if len(parts) != 9 {
			return FileStatus{}, false, fmt.Errorf("invalid ordinary porcelain record")
		}
		return statusFromXY(parts[1], parts[2], parts[8]), false, nil
	case '2':
		parts := strings.SplitN(record, " ", 10)
		if len(parts) != 10 {
			return FileStatus{}, false, fmt.Errorf("invalid rename porcelain record")
		}
		fs := statusFromXY(parts[1], parts[2], parts[9])
		fs.Type = ChangeRenamed
		fs.Rename = &Rename{To: parts[9]}
		return fs, true, nil
	case 'u':
		parts := strings.SplitN(record, " ", 11)
		if len(parts) != 11 {
			return FileStatus{}, false, fmt.Errorf("invalid unmerged porcelain record")
		}
		fs := statusFromXY(parts[1], parts[2], parts[10])
		return fs, false, nil
	default:
		return FileStatus{}, false, fmt.Errorf("unknown porcelain record type %q", record[:1])
	}
}

func statusFromXY(xy, submodule, path string) FileStatus {
	if len(xy) < 2 {
		xy = ".."
	}
	staged, unstaged := xy[0] != '.', xy[1] != '.'
	change := xyType(xy)
	return FileStatus{
		Path:      path,
		Type:      change,
		Staged:    staged,
		Unstaged:  unstaged,
		Submodule: strings.HasPrefix(submodule, "S"),
	}
}

// xyType 优先使用 staged 状态，再回退到 worktree 状态。
func xyType(xy string) ChangeType {
	if len(xy) < 2 {
		return ChangeModified
	}
	status := xy[0]
	if status == '.' {
		status = xy[1]
	}
	switch status {
	case 'A', 'C':
		return ChangeAdded
	case 'D':
		return ChangeDeleted
	case 'R':
		return ChangeRenamed
	case 'T':
		return ChangeTypeChanged
	default:
		return ChangeModified
	}
}

// parseDiff 解析统一 diff，并将 binary patch/submodule 识别为受限文件。
func parseDiff(path, raw string) FileDiff {
	d := FileDiff{Path: path}
	var current *DiffHunk
	for _, line := range strings.Split(raw, "\n") {
		switch {
		case strings.HasPrefix(line, "Binary files "), line == "GIT binary patch":
			d.Binary = true
		case strings.HasPrefix(line, "Submodule "):
			d.Submodule = true
		case strings.HasPrefix(line, "@@"):
			if current != nil {
				d.Hunks = append(d.Hunks, *current)
			}
			current = &DiffHunk{Header: line}
		case current != nil:
			current.Lines = append(current.Lines, line)
		}
	}
	if current != nil {
		d.Hunks = append(d.Hunks, *current)
	}
	for _, hunk := range d.Hunks {
		for _, line := range hunk.Lines {
			if strings.HasPrefix(line, "+") && !strings.HasPrefix(line, "+++") {
				d.Additions++
			}
			if strings.HasPrefix(line, "-") && !strings.HasPrefix(line, "---") {
				d.Deletions++
			}
		}
	}
	return d
}

type fileTraitsResult struct {
	binary    bool
	lfs       bool
	submodule bool
}

// fileTraits 读取 Git 元数据，不打开二进制内容，也不跟随仓库外的符号链接。
func (s *Service) fileTraits(ctx context.Context, root, relPath string) (fileTraitsResult, error) {
	traits := fileTraitsResult{}
	attr, err := s.runGitAtRoot(ctx, root, "check-attr", "-z", "filter", "--", relPath)
	if err == nil {
		parts := strings.Split(attr, "\x00")
		for index := 0; index+2 < len(parts); index += 3 {
			if parts[index+1] == "filter" && parts[index+2] == "lfs" {
				traits.lfs = true
			}
		}
	}
	mode, err := s.runGitAtRoot(ctx, root, "ls-files", "-s", "--", relPath)
	if err == nil {
		traits.submodule = strings.HasPrefix(strings.TrimSpace(mode), "160000 ")
	}
	return traits, nil
}

func (s *Service) enrichStatusFile(ctx context.Context, root string, file *FileStatus) error {
	safePath, err := safeRepoPath(root, file.Path)
	if err != nil {
		return err
	}
	file.Path = safePath
	traits, err := s.fileTraits(ctx, root, safePath)
	if err != nil {
		return err
	}
	file.LFS = traits.lfs
	file.Submodule = file.Submodule || traits.submodule
	add, del, binary, err := s.diffNumstat(ctx, root, safePath, file.Type == ChangeUntracked)
	if err != nil {
		if errors.Is(err, ErrOutputLimit) {
			file.Binary = true
			return nil
		}
		return err
	}
	file.Additions = add
	file.Deletions = del
	file.Binary = binary
	return nil
}

func (s *Service) diffNumstat(ctx context.Context, root, relPath string, untracked bool) (int, int, bool, error) {
	args := []string{"diff", "--numstat", "--no-ext-diff", "--no-textconv", "HEAD", "--", relPath}
	allowed := map[int]bool{}
	if untracked {
		args = []string{"diff", "--numstat", "--no-ext-diff", "--no-textconv", "--no-index", "--", "/dev/null", relPath}
		allowed[1] = true
	}
	out, err := s.runGitAtRootAllowed(ctx, root, allowed, args...)
	if err != nil {
		return 0, 0, false, err
	}
	line := strings.TrimSpace(strings.SplitN(out, "\x00", 2)[0])
	parts := strings.SplitN(line, "\t", 3)
	if len(parts) < 2 {
		return 0, 0, false, nil
	}
	if parts[0] == "-" || parts[1] == "-" {
		return 0, 0, true, nil
	}
	add, _ := strconv.Atoi(parts[0])
	del, _ := strconv.Atoi(parts[1])
	return add, del, false, nil
}

func (s *Service) snapshotTokenFor(ctx context.Context, root, head, branch, raw string, files []FileStatus) (string, error) {
	hash := sha256.New()
	_, _ = io.WriteString(hash, root+"\x00"+head+"\x00"+branch+"\x00")
	_, _ = hash.Write([]byte(raw))
	for _, file := range files {
		_, _ = io.WriteString(hash, file.Path+"\x00"+string(file.Type)+"\x00")
		contentHash, err := s.worktreeContentHash(ctx, root, file.Path)
		if err != nil {
			return "", err
		}
		_, _ = io.WriteString(hash, contentHash+"\x00")
	}
	return hex.EncodeToString(hash.Sum(nil)), nil
}

func (s *Service) worktreeContentHash(ctx context.Context, root, relPath string) (string, error) {
	absPath, err := workspacesafe.ResolveRepoRelative(root, relPath)
	if err != nil {
		return "", err
	}
	if _, err := os.Lstat(absPath); errors.Is(err, os.ErrNotExist) {
		return "missing", nil
	} else if err != nil {
		return "", err
	}
	out, err := s.runGitAtRoot(ctx, root, "hash-object", "--no-filters", "--", relPath)
	if err != nil {
		return "unavailable", nil
	}
	return strings.TrimSpace(out), nil
}

func diffBytes(diff FileDiff) int {
	total := 0
	for _, hunk := range diff.Hunks {
		total += len(hunk.Header)
		for _, line := range hunk.Lines {
			total += len(line)
		}
	}
	return total
}

func maxInt(a, b int) int {
	if a > b {
		return a
	}
	return b
}
