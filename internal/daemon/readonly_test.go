package daemon

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/yubi233/agent-sessions/internal/workspacesafe"
)

// GIT-07：真实临时 Git 仓库中的目录、代码读取和 Git 状态都经过同一 Workspace root 安全边界。
func TestWorkspaceReaderLimitsAndGitBoundary(t *testing.T) {
	root := t.TempDir()
	runGit(t, root, "init")
	runGit(t, root, "config", "user.email", "fixture@example.test")
	runGit(t, root, "config", "user.name", "Fixture")
	if err := os.MkdirAll(filepath.Join(root, "src"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "src", "main.go"), []byte("package main\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	runGit(t, root, "add", "src/main.go")
	runGit(t, root, "commit", "-m", "initial")
	if err := os.WriteFile(filepath.Join(root, "src", "main.go"), []byte("package main\n// changed\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "binary.bin"), []byte{1, 0, 2}, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "large.txt"), []byte(strings.Repeat("x", maxReadOnlyFileBytes+1)), 0o600); err != nil {
		t.Fatal(err)
	}

	reader := NewWorkspaceReader(root, "git")
	entries, err := reader.List(".")
	if err != nil {
		t.Fatalf("list root: %v", err)
	}
	if len(entries) == 0 || entries[0].Path == "" || strings.Contains(entries[0].Path, root) {
		t.Fatalf("list leaked or missed relative path: %+v", entries)
	}
	code, err := reader.ReadCode("src/main.go")
	if err != nil || string(code.Content) != "package main\n// changed\n" || code.Path != "src/main.go" {
		t.Fatalf("read code=%+v err=%v", code, err)
	}
	if _, err := reader.ReadCode("binary.bin"); !errors.Is(err, ErrReadOnlyBinary) {
		t.Fatalf("binary read err=%v, want ErrReadOnlyBinary", err)
	}
	if _, err := reader.ReadCode("large.txt"); !errors.Is(err, ErrReadOnlyTooLarge) {
		t.Fatalf("large read err=%v, want ErrReadOnlyTooLarge", err)
	}
	if _, err := reader.ReadCode("../outside.txt"); !errors.Is(err, workspacesafe.ErrEscapeRoot) {
		t.Fatalf("escape read err=%v, want ErrEscapeRoot", err)
	}

	status, err := reader.GitStatus(context.Background())
	if err != nil {
		t.Fatalf("git status: %v", err)
	}
	found := false
	for _, file := range status.Files {
		if file.Path == "src/main.go" {
			found = true
		}
	}
	if !found || status.SnapshotToken == "" {
		t.Fatalf("git status did not expose bounded changed-file metadata: %+v", status)
	}
	page, err := reader.GitDiffPage(context.Background(), "src/main.go", status.SnapshotToken, 0, 50)
	if err != nil || page.Path != "src/main.go" || len(page.Hunks) == 0 {
		t.Fatalf("git diff page=%+v err=%v", page, err)
	}

	// 恶意链接本身单独验证；其存在会使 gitread.Status fail-closed，这是预期安全降级，
	// 不应用来否定正常仓库的只读 Git 行为。
	outside := t.TempDir()
	if err := os.Symlink(outside, filepath.Join(root, "outside-link")); err == nil {
		if _, err := reader.ReadCode("outside-link/secret.txt"); !errors.Is(err, workspacesafe.ErrEscapeRoot) && !errors.Is(err, workspacesafe.ErrUnsafeSymlink) {
			t.Fatalf("symlink escape read err=%v", err)
		}
	}
}

func runGit(t *testing.T, dir string, args ...string) {
	t.Helper()
	command := exec.Command("git", args...)
	command.Dir = dir
	if output, err := command.CombinedOutput(); err != nil {
		t.Fatalf("git %v: %v (%s)", args, err, output)
	}
}
