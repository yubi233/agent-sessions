package workspacesafe

import (
	"os"
	"path/filepath"
	"testing"
)

// WORKSPACE-01：路径不可逃逸。
func TestResolveRejectsEscape(t *testing.T) {
	root := t.TempDir()
	// `..` 越界被拒绝。
	if _, err := ResolveRepoRelative(root, "../../etc/passwd"); err == nil {
		t.Fatalf("expected escape rejection")
	}
	if _, err := ResolveRepoRelative(root, "a/../../../etc"); err == nil {
		t.Fatalf("expected escape rejection via nested ..")
	}
	// 控制字符被拒绝。
	if _, err := ResolveRepoRelative(root, "a\x00b"); err != ErrControlChar {
		t.Fatalf("expected ErrControlChar, got %v", err)
	}
	if _, err := ResolveRepoRelative(root, "a\nb"); err != ErrControlChar {
		t.Fatalf("expected ErrControlChar for newline, got %v", err)
	}
}

// WORKSPACE-01：符号链接逃逸被拒绝。
func TestResolveRejectsSymlinkEscape(t *testing.T) {
	root := t.TempDir()
	outside := t.TempDir()
	target := filepath.Join(outside, "secret.txt")
	_ = os.WriteFile(target, []byte("secret"), 0o600)
	if err := os.Symlink(outside, filepath.Join(root, "link")); err != nil {
		t.Skipf("symlink not supported: %v", err)
	}
	_, err := ResolveRepoRelative(root, "link/secret.txt")
	if err != ErrEscapeRoot && err != ErrUnsafeSymlink {
		t.Fatalf("expected escape rejection for symlink, got %v", err)
	}
}

// WORKSPACE-01：根内合法相对路径可解析。
func TestResolveAllowsInside(t *testing.T) {
	root := t.TempDir()
	dir := filepath.Join(root, "sub", "dir")
	_ = os.MkdirAll(dir, 0o755)
	got, err := ResolveRepoRelative(root, "sub/dir")
	if err != nil {
		t.Fatalf("resolve inside: %v", err)
	}
	if !filepath.IsAbs(got) {
		t.Fatalf("expected absolute path, got %q", got)
	}
}

// IsGitRoot 判断。
func TestIsGitRoot(t *testing.T) {
	root := t.TempDir()
	if IsGitRoot(root) {
		t.Fatalf("should not be git root")
	}
	_ = os.MkdirAll(filepath.Join(root, ".git"), 0o755)
	if !IsGitRoot(root) {
		t.Fatalf("should be git root")
	}
}
