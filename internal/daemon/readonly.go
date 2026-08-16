package daemon

import (
	"bytes"
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/yubi233/agent-sessions/internal/gitread"
	"github.com/yubi233/agent-sessions/internal/workspacesafe"
)

const (
	maxReadOnlyFileBytes = 1 << 20 // 1 MiB，移动端代码阅读不允许无界加载。
	maxReadOnlyEntries   = 512
)

var (
	ErrReadOnlyBinary    = errors.New("read-only file is binary")
	ErrReadOnlyTooLarge  = errors.New("read-only file exceeds limit")
	ErrReadOnlyDirectory = errors.New("read-only path is a directory")
)

// WorkspaceReader 是 Daemon 对确认过的单个 Workspace 的只读边界。所有输入均为 repo-relative
// 路径；返回结果在离开 Daemon 前必须由调用方加密，Relay 不接收这些明文字节。
type WorkspaceReader struct {
	root     string
	maxBytes int64
	git      *gitread.Service
}

// NewWorkspaceReader 不自动授权目录。调用方必须只为已经确认的 Git Workspace 创建该对象。
func NewWorkspaceReader(root, gitBin string) *WorkspaceReader {
	return &WorkspaceReader{root: root, maxBytes: maxReadOnlyFileBytes, git: gitread.New(root, gitBin)}
}

type FileEntry struct {
	Path  string `json:"path"`
	IsDir bool   `json:"is_dir"`
	Size  int64  `json:"size"`
}

type CodeRead struct {
	Path    string `json:"path"`
	Content []byte `json:"-"`
}

// List 返回单层、已排序且受上限约束的相对路径。它不会递归扫描 Workspace，也不会回显绝对 root。
func (r *WorkspaceReader) List(relPath string) ([]FileEntry, error) {
	abs, err := r.resolve(relPath)
	if err != nil {
		return nil, err
	}
	entries, err := os.ReadDir(abs)
	if err != nil {
		return nil, err
	}
	if len(entries) > maxReadOnlyEntries {
		entries = entries[:maxReadOnlyEntries]
	}
	result := make([]FileEntry, 0, len(entries))
	for _, entry := range entries {
		// 读取 entry 信息时再次避免通过符号链接得到根外目标；链接项只作为受限 metadata 返回。
		info, statErr := entry.Info()
		if statErr != nil {
			continue
		}
		child := filepath.Join(relPath, entry.Name())
		result = append(result, FileEntry{Path: filepath.ToSlash(filepath.Clean(child)), IsDir: entry.IsDir(), Size: info.Size()})
	}
	sort.Slice(result, func(i, j int) bool { return result[i].Path < result[j].Path })
	return result, nil
}

// ReadCode 读取受限文本文件。二进制、目录、超限内容和 root 外路径均拒绝，不做截断，以免调用方
// 把不完整内容误解为完整源码。
func (r *WorkspaceReader) ReadCode(relPath string) (CodeRead, error) {
	abs, err := r.resolve(relPath)
	if err != nil {
		return CodeRead{}, err
	}
	info, err := os.Stat(abs)
	if err != nil {
		return CodeRead{}, err
	}
	if info.IsDir() {
		return CodeRead{}, ErrReadOnlyDirectory
	}
	if !info.Mode().IsRegular() {
		return CodeRead{}, ErrReadOnlyBinary
	}
	if info.Size() > r.maxBytes {
		return CodeRead{}, ErrReadOnlyTooLarge
	}
	file, err := os.Open(abs)
	if err != nil {
		return CodeRead{}, err
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, r.maxBytes+1))
	if err != nil {
		return CodeRead{}, err
	}
	if int64(len(data)) > r.maxBytes {
		return CodeRead{}, ErrReadOnlyTooLarge
	}
	if bytes.IndexByte(data, 0) >= 0 {
		return CodeRead{}, ErrReadOnlyBinary
	}
	return CodeRead{Path: filepath.ToSlash(filepath.Clean(relPath)), Content: data}, nil
}

// GitStatus 和 GitDiffPage 复用已具备 snapshot、输出大小和 Git 参数数组约束的服务；这里不复制
// Git 调用逻辑，确保 file/code 与 diff 的 root realpath 判断一致。
func (r *WorkspaceReader) GitStatus(ctx context.Context) (gitread.Status, error) {
	return r.git.Status(ctx)
}

func (r *WorkspaceReader) GitDiffPage(ctx context.Context, relPath, snapshotToken string, offset, limit int) (gitread.DiffPage, error) {
	return r.git.DiffFilePage(ctx, relPath, snapshotToken, offset, limit)
}

func (r *WorkspaceReader) resolve(relPath string) (string, error) {
	if strings.TrimSpace(relPath) == "" {
		return "", errors.New("empty repo-relative path")
	}
	return workspacesafe.ResolveRepoRelative(r.root, relPath)
}
