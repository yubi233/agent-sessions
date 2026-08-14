package gitread

import (
	"bytes"
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"testing"

	"github.com/yubi233/agent-sessions/internal/workspacesafe"
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

func runGit(t *testing.T, root string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = root
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v: %s", args, out)
	}
	return string(out)
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

// GIT-02：文件级读取必须拒绝客户端传入的仓库外路径，不能把 `--` 当作唯一安全边界。
func TestDiffFileRejectsEscapingPath(t *testing.T) {
	root := newTempRepo(t)
	outside := filepath.Join(t.TempDir(), "secret.txt")
	if err := os.WriteFile(outside, []byte("secret"), 0o600); err != nil {
		t.Fatal(err)
	}
	svc := New(root, "git")
	if _, err := svc.DiffFile(context.Background(), "../"+filepath.Base(outside)); err == nil {
		t.Fatal("expected parent traversal to be rejected")
	}
	if err := os.Symlink(filepath.Dir(outside), filepath.Join(root, "outside-link")); err == nil {
		_, err = svc.DiffFile(context.Background(), "outside-link/secret.txt")
		if !errors.Is(err, workspacesafe.ErrEscapeRoot) && !errors.Is(err, workspacesafe.ErrUnsafeSymlink) {
			t.Fatalf("expected symlink escape to be rejected, got %v", err)
		}
	}
}

// GIT-01/GIT-04：porcelain v2 -z 的 rename 原路径位于下一个 NUL 字段，路径本身可以含空格。
func TestStatusParsesRenameWithSpaces(t *testing.T) {
	root := newTempRepo(t)
	runGit(t, root, "mv", "a.txt", "renamed file.txt")
	svc := New(root, "git")
	st, err := svc.Status(context.Background())
	if err != nil {
		t.Fatalf("status: %v", err)
	}
	if len(st.Files) != 1 {
		t.Fatalf("want one rename, got %+v", st.Files)
	}
	got := st.Files[0]
	if got.Path != "renamed file.txt" || got.Rename == nil || got.Rename.From != "a.txt" || got.Rename.To != "renamed file.txt" {
		t.Fatalf("unexpected rename: %+v", got)
	}
	if !got.Staged || got.Type != ChangeRenamed {
		t.Fatalf("rename staged/type mismatch: %+v", got)
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

// GIT-05：未提交内容即使文件大小相同，也必须使 snapshot token 漂移。
func TestSnapshotTokenDetectsUnstagedContentDrift(t *testing.T) {
	root := newTempRepo(t)
	svc := New(root, "git")
	if err := os.WriteFile(filepath.Join(root, "a.txt"), []byte("line1\nline2\nalpha\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	token, err := svc.SnapshotToken(context.Background())
	if err != nil {
		t.Fatalf("snapshot: %v", err)
	}
	if err := os.WriteFile(filepath.Join(root, "a.txt"), []byte("line1\nline2\nomega\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := svc.ValidateSnapshot(context.Background(), token); !errors.Is(err, ErrSnapshotStale) {
		t.Fatalf("want stale token after unstaged edit, got %v", err)
	}
	if _, err := svc.DiffFileAtSnapshot(context.Background(), "a.txt", token); !errors.Is(err, ErrSnapshotStale) {
		t.Fatalf("old snapshot must not return mixed diff, got %v", err)
	}
}

// GIT-04：binary、LFS 与 submodule 都要以可渲染元数据返回，不能误当普通文本。
func TestStatusClassifiesRestrictedGitFiles(t *testing.T) {
	root := newTempRepo(t)
	if err := os.WriteFile(filepath.Join(root, ".gitattributes"), []byte("*.lfs filter=lfs diff=lfs merge=lfs -text\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "asset.lfs"), []byte("version https://git-lfs.github.com/spec/v1\noid sha256:fixture\nsize 1\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "image.bin"), []byte{0x00, 0x01, 0x02, 0x03}, 0o644); err != nil {
		t.Fatal(err)
	}
	runGit(t, root, "add", ".gitattributes", "asset.lfs", "image.bin")
	runGit(t, root, "commit", "-qm", "add restricted fixtures")
	if err := os.WriteFile(filepath.Join(root, "asset.lfs"), []byte("version https://git-lfs.github.com/spec/v1\noid sha256:changed\nsize 2\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "image.bin"), []byte{0x00, 0x04, 0x05, 0x06}, 0o644); err != nil {
		t.Fatal(err)
	}

	child := t.TempDir()
	runGit(t, child, "init", "-q")
	runGit(t, child, "config", "user.email", "t@test.dev")
	runGit(t, child, "config", "user.name", "tester")
	if err := os.WriteFile(filepath.Join(child, "nested.txt"), []byte("nested\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	runGit(t, child, "add", "nested.txt")
	runGit(t, child, "commit", "-qm", "initial")
	runGit(t, root, "-c", "protocol.file.allow=always", "submodule", "add", "-q", child, "nested")
	runGit(t, root, "commit", "-qm", "add submodule")
	nested := filepath.Join(root, "nested")
	runGit(t, nested, "config", "user.email", "t@test.dev")
	runGit(t, nested, "config", "user.name", "tester")
	if err := os.WriteFile(filepath.Join(nested, "nested.txt"), []byte("nested changed\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	svc := New(root, "git")
	st, err := svc.Status(context.Background())
	if err != nil {
		t.Fatalf("status: %v", err)
	}
	byPath := map[string]FileStatus{}
	for _, file := range st.Files {
		byPath[file.Path] = file
	}
	if !byPath["asset.lfs"].LFS {
		t.Fatalf("LFS file not classified: %+v", byPath["asset.lfs"])
	}
	if !byPath["image.bin"].Binary {
		t.Fatalf("binary file not classified: %+v", byPath["image.bin"])
	}
	if !byPath["nested"].Submodule {
		t.Fatalf("submodule not classified: %+v", byPath["nested"])
	}
	diff, err := svc.DiffFile(context.Background(), "image.bin")
	if err != nil {
		t.Fatalf("binary diff: %v", err)
	}
	if !diff.Binary || len(diff.Hunks) != 0 {
		t.Fatalf("binary diff must not be exposed as text: %+v", diff)
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
	if !d.Truncated || len(d.Hunks) != 0 {
		t.Fatalf("large diff must return a limited structure, got %+v", d)
	}
}

// GIT-06：分页边界复用 snapshot，且不会通过 hunk 数量改变工具栏尺寸的隐式契约。
func TestDiffFilePageUsesSnapshot(t *testing.T) {
	root := newTempRepo(t)
	if err := os.WriteFile(filepath.Join(root, "a.txt"), bytes.Repeat([]byte("changed line\n"), 16), 0o644); err != nil {
		t.Fatal(err)
	}
	svc := New(root, "git")
	token, err := svc.SnapshotToken(context.Background())
	if err != nil {
		t.Fatalf("snapshot: %v", err)
	}
	page, err := svc.DiffFilePage(context.Background(), "a.txt", token, 0, 1)
	if err != nil {
		t.Fatalf("page: %v", err)
	}
	if page.Path != "a.txt" || page.SnapshotToken != token || len(page.Hunks) != 1 {
		t.Fatalf("unexpected page: %+v", page)
	}
}
