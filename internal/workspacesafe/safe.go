// Package workspacesafe 实现 Workspace 安全边界：
// canonical root、realpath、符号链接、目录越界与 repo-relative path 校验。
// 所有请求执行路径检查；实际读取前必须重新做安全检查，不能信任缓存。
package workspacesafe

import (
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// 稳定错误，供上层映射协议错误码。
var (
	ErrEscapeRoot     = errors.New("path escapes workspace root")
	ErrNotAbsolute    = errors.New("path must be absolute")
	ErrUnsafeSymlink  = errors.New("path traverses symlink outside root")
	ErrNotAGitRoot    = errors.New("path is not a git root")
	ErrWorkspaceMoved = errors.New("workspace moved")
	ErrControlChar    = errors.New("path contains control characters")
	ErrWorkspaceName  = errors.New("workspace name is invalid")
)

var workspaceNamePattern = regexp.MustCompile(`^[a-zA-Z0-9._-]{1,64}$`)

// ValidateWorkspaceName 是创建工作区共享的名称边界。名称只能成为授权根的直接子目录名，
// 因此拒绝隐藏目录、dot-segment、分隔符和控制字符，Relay 与 daemon 必须复用该规则。
func ValidateWorkspaceName(name string) error {
	if name == "" || strings.TrimSpace(name) != name || !workspaceNamePattern.MatchString(name) {
		return ErrWorkspaceName
	}
	if name == "." || name == ".." || strings.HasPrefix(name, ".") || strings.ContainsAny(name, `/\\`) {
		return ErrWorkspaceName
	}
	return nil
}

// Workspace 描述一个已确认的工作区及其 canonical root。
type Workspace struct {
	Root   string // canonical realpath 根目录
	Status string // pending | confirmed | moved | revoked
}

// ResolveRepoRelative 把客户端提供的 repo-relative 路径解析为根目录内的绝对路径。
// 拒绝绝对路径、`..` 越界、控制字符与根外符号链接。
func ResolveRepoRelative(workspaceRoot, rel string) (string, error) {
	if rel == "" {
		return "", errors.New("empty path")
	}
	if hasControlChar(rel) {
		return "", ErrControlChar
	}
	// 拒绝绝对路径，统一按相对根目录解析。
	if filepath.IsAbs(rel) {
		return "", ErrNotAbsolute
	}
	// 直接以根目录拼接相对路径，让 `..` 越界在 within 校验中被拒绝。
	joined := filepath.Join(workspaceRoot, rel)
	// 校验拼接结果仍在根内（`..` 上提越过根目录即拒绝）。
	if !within(joined, workspaceRoot) {
		return "", ErrEscapeRoot
	}
	return resolveInsideRoot(workspaceRoot, joined)
}

// ResolveAbsolute 校验客户端提供的绝对路径位于 workspaceRoot 内。
func ResolveAbsolute(workspaceRoot, abs string) (string, error) {
	if abs == "" {
		return "", errors.New("empty path")
	}
	if !filepath.IsAbs(abs) {
		return "", ErrNotAbsolute
	}
	return resolveInsideRoot(workspaceRoot, abs)
}

// resolveInsideRoot 解析路径并通过 realpath 校验符号链接不逃逸根目录。
func resolveInsideRoot(workspaceRoot, p string) (string, error) {
	if hasControlChar(p) {
		return "", ErrControlChar
	}
	// 解析 workspaceRoot 自身为真实路径。
	realRoot, err := filepath.EvalSymlinks(workspaceRoot)
	if err != nil {
		// 根目录本身不可解析：可能是 moved 或不存在。
		return "", ErrWorkspaceMoved
	}
	// 父目录链上的符号链接可能逃逸，因此逐级 EvalSymlinks 到根目录。
	abs, err := filepath.Abs(p)
	if err != nil {
		return "", err
	}
	// 逐级解析以捕获符号链接逃逸。
	resolved, err := evalWithin(abs, realRoot)
	if err != nil {
		return "", err
	}
	return resolved, nil
}

// evalWithin 逐级 EvalSymlinks，确保解析结果不越过 root 边界。
func evalWithin(abs, root string) (string, error) {
	resolved, err := filepath.EvalSymlinks(abs)
	if err != nil {
		if os.IsNotExist(err) {
			// 文件不存在时回退到父目录解析，避免误报。
			parent, perr := filepath.EvalSymlinks(filepath.Dir(abs))
			if perr != nil {
				return "", ErrWorkspaceMoved
			}
			resolved = filepath.Join(parent, filepath.Base(abs))
		} else {
			return "", ErrUnsafeSymlink
		}
	}
	if !within(resolved, root) {
		return "", ErrEscapeRoot
	}
	return resolved, nil
}

// within 判断 child 是否位于 root 内。
func within(child, root string) bool {
	rel, err := filepath.Rel(root, child)
	if err != nil {
		return false
	}
	return rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator))
}

// hasControlChar 检测 NUL、换行、回车与分隔控制字符。
func hasControlChar(p string) bool {
	for _, r := range p {
		if r == 0 || r == '\n' || r == '\r' || (r < 0x20) {
			return true
		}
	}
	return false
}

// IsGitRoot 检查给定根目录是否为 Git 仓库根（存在 .git）。
func IsGitRoot(root string) bool {
	_, err := os.Stat(filepath.Join(root, ".git"))
	return err == nil
}

// CandidateScan 只发现候选 Git 根目录，不自动授权（DAEMON-BOOT/WORKSPACE-01）。
func CandidateScan(roots []string) []string {
	out := []string{}
	seen := map[string]bool{}
	for _, r := range roots {
		entries, err := os.ReadDir(r)
		if err != nil {
			continue
		}
		for _, e := range entries {
			if !e.IsDir() {
				continue
			}
			// 跳过隐藏与常见无关目录。
			if strings.HasPrefix(e.Name(), ".") {
				continue
			}
			full := filepath.Join(r, e.Name())
			if IsGitRoot(full) && !seen[full] {
				seen[full] = true
				out = append(out, full)
			}
		}
	}
	return out
}
