package daemon

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/yubi233/agent-sessions/internal/workspacesafe"
)

// mustWriteDSHArtifact 构造符合 DSH 布局的 session.jsonl，作为工作区证据。
func mustWriteDSHArtifact(t *testing.T, project, id string) {
	t.Helper()
	canonical, err := filepath.EvalSymlinks(project)
	if err != nil {
		t.Fatalf("resolve %s: %v", project, err)
	}
	canonical, err = filepath.Abs(canonical)
	if err != nil {
		t.Fatalf("abs %s: %v", project, err)
	}
	writeDSHSessionArtifactForTest(t, filepath.Join(project, ".dsh-sessions"), filepath.Clean(canonical), id, "{}")
}

// V08-01/03/18：Scanner 只发现授权根内“有 DSH 证据且为 Git 根”的项目。
func TestDSHWorkspaceScannerFindsOnlyDSHGitRoots(t *testing.T) {
	root := t.TempDir()
	// 有效 DSH 项目：Git 根 + .dsh-sessions/session.jsonl
	valid := filepath.Join(root, "valid")
	mustMkdirAll(t, filepath.Join(valid, ".dsh-sessions"))
	mustWriteDSHArtifact(t, valid, "s1")
	mustGitInit(t, valid)

	// 仅 Git 根但没有 DSH 证据
	plainGit := filepath.Join(root, "plain-git")
	mustMkdirAll(t, plainGit)
	mustGitInit(t, plainGit)

	// 有 DSH 标记但不是 Git 根
	nonGit := filepath.Join(root, "non-git")
	mustMkdirAll(t, filepath.Join(nonGit, ".dsh-sessions"))
	mustWriteFile(t, filepath.Join(nonGit, ".dsh-sessions", "session-query.db"), "x")

	// 隐藏目录和 node_modules 被忽略
	mustMkdirAll(t, filepath.Join(root, "node_modules", "pkg", ".dsh-sessions"))
	mustWriteFile(t, filepath.Join(root, "node_modules", "pkg", ".dsh-sessions", "session.jsonl"), "{}")
	mustMkdirAll(t, filepath.Join(root, ".hidden", ".dsh-sessions"))
	mustWriteFile(t, filepath.Join(root, ".hidden", ".dsh-sessions", "session.jsonl"), "{}")

	scanner := NewDSHWorkspaceScanner(root)
	candidates, summary, err := scanner.Scan(context.Background())
	if err != nil {
		t.Fatalf("scan: %v", err)
	}
	canonicalValid, _ := filepath.EvalSymlinks(valid)
	canonicalValid, _ = filepath.Abs(canonicalValid)
	if len(candidates) != 1 || candidates[0].Root != filepath.Clean(canonicalValid) || candidates[0].DisplayName != "valid" {
		t.Fatalf("candidates=%+v want only %s", candidates, canonicalValid)
	}
	if summary.Candidates != 1 || summary.Ignored < 2 {
		t.Fatalf("unexpected summary: %+v", summary)
	}
}

// V081-01：公开显示名只能是 Daemon 从项目 basename 派生的单段 UTF-8 文案。
func TestDSHWorkspaceDisplayNameRejectsPathFragments(t *testing.T) {
	valid, err := dshWorkspaceDisplayName("/fixture/中文项目")
	if err != nil || valid != "中文项目" {
		t.Fatalf("valid display name=%q err=%v", valid, err)
	}
	for _, raw := range []string{"", "/", "/fixture/../", "/fixture/bad\\name", "/fixture/\x00name", "/fixture/C:drive"} {
		if _, err := dshWorkspaceDisplayName(raw); err == nil {
			t.Fatalf("unsafe root %q produced a display name", raw)
		}
	}
}

// V08-02：同一目录重复扫描稳定返回同一候选。
func TestDSHWorkspaceScannerIdempotent(t *testing.T) {
	root := t.TempDir()
	project := filepath.Join(root, "p")
	mustMkdirAll(t, filepath.Join(project, ".dsh-sessions"))
	mustWriteDSHArtifact(t, project, "s1")
	mustGitInit(t, project)

	scanner := NewDSHWorkspaceScanner(root)
	first, _, err := scanner.Scan(context.Background())
	if err != nil {
		t.Fatalf("first scan: %v", err)
	}
	second, _, err := scanner.Scan(context.Background())
	if err != nil {
		t.Fatalf("second scan: %v", err)
	}
	if len(first) != 1 || len(second) != 1 || first[0].Root != second[0].Root {
		t.Fatalf("non-idempotent scan: %+v vs %+v", first, second)
	}
}

// V08-18：深度和候选上限可观察，不静默截断。
func TestDSHWorkspaceScannerLimits(t *testing.T) {
	root := t.TempDir()
	// 深度超过 4 的项目不应进入候选（但中间层若已是 DSH 根则仍会命中）。
	deep := filepath.Join(root, "a", "b", "c", "d", "deep")
	mustMkdirAll(t, filepath.Join(deep, ".dsh-sessions"))
	mustWriteDSHArtifact(t, deep, "deep-s1")
	mustGitInit(t, deep)

	scanner := NewDSHWorkspaceScanner(root)
	_, summary, err := scanner.Scan(context.Background())
	if err != nil {
		t.Fatalf("scan: %v", err)
	}
	if summary.DepthLimited < 1 {
		t.Fatalf("expected depth limit visible, summary=%+v", summary)
	}

	// 用极小上限验证 limit_reached 可见：根下先放一个可命中候选。
	rootLevel := filepath.Join(root, "root-level")
	mustMkdirAll(t, filepath.Join(rootLevel, ".dsh-sessions"))
	mustWriteDSHArtifact(t, rootLevel, "root-s1")
	mustGitInit(t, rootLevel)
	limited := &DSHWorkspaceScanner{root: root, maxDepth: 4, maxCandidates: 0}
	_, limitedSummary, err := limited.Scan(context.Background())
	if err != nil {
		t.Fatalf("limited scan: %v", err)
	}
	if !limitedSummary.LimitReached {
		t.Fatalf("expected limit reached, summary=%+v", limitedSummary)
	}
}

// V08-03：ConfirmExistingDSHWorkspace 拒绝越权/非 Git/无 DSH 证据。
func TestConfirmExistingDSHWorkspaceRejectsInvalid(t *testing.T) {
	root := t.TempDir()
	state, err := OpenStore(filepath.Join(t.TempDir(), "daemon.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer state.Close()
	manager, err := NewWorkspaceManager(state, root)
	if err != nil {
		t.Fatalf("new manager: %v", err)
	}
	project := filepath.Join(root, "p")
	mustMkdirAll(t, filepath.Join(project, ".dsh-sessions"))
	mustWriteDSHArtifact(t, project, "s1")
	mustGitInit(t, project)

	confirmed, err := manager.ConfirmExistingDSHWorkspace(context.Background(), "ws-dsh", project)
	if err != nil {
		t.Fatalf("confirm: %v", err)
	}
	canonicalProject, _ := filepath.EvalSymlinks(project)
	canonicalProject, _ = filepath.Abs(canonicalProject)
	if confirmed.ID != "ws-dsh" || confirmed.Root != filepath.Clean(canonicalProject) {
		t.Fatalf("unexpected confirm: %+v", confirmed)
	}
	// 重复确认幂等
	again, err := manager.ConfirmExistingDSHWorkspace(context.Background(), "ws-dsh", project)
	if err != nil || again.Root != confirmed.Root {
		t.Fatalf("repeat confirm: %+v, %v", again, err)
	}
	// 授权根外
	outside := t.TempDir()
	mustMkdirAll(t, filepath.Join(outside, ".dsh-sessions"))
	mustWriteDSHArtifact(t, outside, "outside-s1")
	mustGitInit(t, outside)
	if _, err := manager.ConfirmExistingDSHWorkspace(context.Background(), "ws-out", outside); err == nil {
		t.Fatal("expected outside rejection")
	}
	// 非 Git
	plain := filepath.Join(root, "plain")
	mustMkdirAll(t, filepath.Join(plain, ".dsh-sessions"))
	mustWriteDSHArtifact(t, plain, "plain-s1")
	if _, err := manager.ConfirmExistingDSHWorkspace(context.Background(), "ws-plain", plain); !errors.Is(err, workspacesafe.ErrNotAGitRoot) {
		t.Fatalf("expected not git rejection, got %v", err)
	}
	// 无 DSH 证据
	noDsh := filepath.Join(root, "no-dsh")
	mustMkdirAll(t, noDsh)
	mustGitInit(t, noDsh)
	if _, err := manager.ConfirmExistingDSHWorkspace(context.Background(), "ws-nodsh", noDsh); err == nil {
		t.Fatal("expected missing dsh evidence rejection")
	}
}

func mustMkdirAll(t *testing.T, path string) {
	t.Helper()
	if err := os.MkdirAll(path, 0o755); err != nil {
		t.Fatalf("mkdir %s: %v", path, err)
	}
}

func mustWriteFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
}

func mustGitInit(t *testing.T, root string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Join(root, ".git"), 0o755); err != nil {
		t.Fatalf("git init %s: %v", root, err)
	}
}
