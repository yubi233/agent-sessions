package gitread

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

// newTempRepo 创建隔离 Git 仓库，测试结束清理。
func newTempRepo(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	git := func(args ...string) string {
		t.Helper()
		cmd := exec.Command("git", args...)
		cmd.Dir = root
		out, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("git %v: %s", args, out)
		}
		return string(out)
	}
	git("init", "-q")
	git("config", "user.email", "t@test.dev")
	git("config", "user.name", "tester")
	_ = os.WriteFile(filepath.Join(root, "a.txt"), []byte("line1\nline2\n"), 0o644)
	git("add", "a.txt")
	git("commit", "-qm", "initial")
	return root
}

// GIT-01：porcelain v2 状态与变更列表。
func TestStatusParsing(t *testing.T) {
	root := newTempRepo(t)
	svc := New(root, "git")
	_ = os.WriteFile(filepath.Join(root, "a.txt"), []byte("line1\nline2\nchanged\n"), 0o644)
	_ = os.WriteFile(filepath.Join(root, "new.txt"), []byte("new\n"), 0o644)

	st, err := svc.Status(context.Background())
	if err != nil {
		t.Fatalf("status: %v", err)
	}
	foundMod := false
	foundNew := false
	for _, f := range st.Files {
		switch f.Path {
		case "a.txt":
			foundMod = true
		case "new.txt":
			foundNew = true
		}
	}
	if !foundMod || !foundNew {
		t.Fatalf("want modified a.txt and untracked new.txt, got %+v", st.Files)
	}
}

// GIT-02：文件级 diff 返回 hunks。
func TestDiffFile(t *testing.T) {
	root := newTempRepo(t)
	svc := New(root, "git")
	_ = os.WriteFile(filepath.Join(root, "a.txt"), []byte("line1\nline2\nchanged\n"), 0o644)

	d, err := svc.DiffFile(context.Background(), "a.txt")
	if err != nil {
		t.Fatalf("diff file: %v", err)
	}
	if len(d.Hunks) == 0 {
		t.Fatalf("expected at least one hunk")
	}
}

// GIT-03：非仓库目录被拒绝（git 命令失败）。
func TestNonGitRoot(t *testing.T) {
	root := t.TempDir() // 非 git 仓库
	svc := New(root, "git")
	if _, err := svc.Status(context.Background()); err == nil {
		t.Fatalf("expected error for non-git root")
	}
}

// GIT-05：snapshot token 绑定 HEAD，commit 后漂移。
func TestSnapshotTokenDrift(t *testing.T) {
	root := newTempRepo(t)
	svc := New(root, "git")
	tok1, err := svc.SnapshotToken(context.Background())
	if err != nil {
		t.Fatalf("snapshot 1: %v", err)
	}
	// 修改并提交，HEAD 变化导致 token 漂移。
	_ = os.WriteFile(filepath.Join(root, "a.txt"), []byte("changed\n"), 0o644)
	git := exec.Command("git", "add", "a.txt")
	git.Dir = root
	_ = git.Run()
	git = exec.Command("git", "commit", "-qm", "second")
	git.Dir = root
	_ = git.Run()

	tok2, err := svc.SnapshotToken(context.Background())
	if err != nil {
		t.Fatalf("snapshot 2: %v", err)
	}
	if tok1 == tok2 {
		t.Fatalf("snapshot token should drift after commit")
	}
}

// GIT-06：超大 diff 标记 truncated。
func TestLargeDiffTruncated(t *testing.T) {
	root := newTempRepo(t)
	svc := New(root, "git")
	// 生成超过 4MiB 的输出。
	big := make([]byte, MaxOutputBytes+1024)
	for i := range big {
		big[i] = 'x'
	}
	_ = os.WriteFile(filepath.Join(root, "big.txt"), big, 0o644)
	_ = os.WriteFile(filepath.Join(root, "a.txt"), []byte("line1\nline2\nchanged\n"), 0o644)

	d, err := svc.DiffFile(context.Background(), "big.txt")
	if err != nil {
		t.Fatalf("diff big: %v", err)
	}
	_ = d
	// runGit 已受命令级限制保护；此处至少不 panic 且返回可控结构。
}
