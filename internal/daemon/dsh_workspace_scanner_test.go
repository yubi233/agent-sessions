package daemon

import (
	"context"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"testing"
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

// V08-01/03/18 + V085-10：Scanner 只发现授权根内“有 DSH 证据”的项目（v0.8.5 §3.6：
// Git 根不再是必要条件）；GitReady 标注候选是否支持 gitread，隐藏/node_modules/
// 符号链接与深度边界不放宽。
func TestDSHWorkspaceScannerFindsDSHEvidenceWithGitReadyFlag(t *testing.T) {
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

	// 有 DSH 标记但不是 Git 根：v0.8.5 §3.6 起照常候选（GitReady=false）
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
	canonicalNonGit, _ := filepath.EvalSymlinks(nonGit)
	canonicalNonGit, _ = filepath.Abs(canonicalNonGit)
	if len(candidates) != 2 {
		t.Fatalf("candidates=%+v want valid + non-git", candidates)
	}
	byRoot := map[string]DSHWorkspaceCandidate{}
	for _, cand := range candidates {
		byRoot[filepath.Clean(cand.Root)] = cand
	}
	validCand, hasValid := byRoot[filepath.Clean(canonicalValid)]
	if !hasValid || validCand.DisplayName != "valid" || !validCand.GitReady {
		t.Fatalf("valid candidate missing/git_ready false: %+v", candidates)
	}
	nonGitCand, hasNonGit := byRoot[filepath.Clean(canonicalNonGit)]
	if !hasNonGit || nonGitCand.DisplayName != "non-git" || nonGitCand.GitReady {
		t.Fatalf("non-git candidate missing/git_ready true: %+v", candidates)
	}
	if summary.Candidates != 2 || summary.NonGitCandidates != 1 || summary.Ignored < 2 {
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

// V08-03 + V085-10：ConfirmExistingDSHWorkspace 拒绝越权/无 DSH 证据；
// 非 Git 但有 DSH 证据的工作区 v0.8.5 §3.6 起确认成功。
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
	// 非 Git 但有 DSH 证据：v0.8.5 §3.6 起确认成功（gitread 由 GitReady 标注不可用）
	plain := filepath.Join(root, "plain")
	mustMkdirAll(t, filepath.Join(plain, ".dsh-sessions"))
	mustWriteDSHArtifact(t, plain, "plain-s1")
	plainConfirmed, err := manager.ConfirmExistingDSHWorkspace(context.Background(), "ws-plain", plain)
	if err != nil {
		t.Fatalf("non-git dsh confirm failed: %v", err)
	}
	canonicalPlain, _ := filepath.EvalSymlinks(plain)
	canonicalPlain, _ = filepath.Abs(canonicalPlain)
	if plainConfirmed.Root != filepath.Clean(canonicalPlain) {
		t.Fatalf("unexpected non-git confirm root: %+v", plainConfirmed)
	}

	// v0.8.5 §3.6：DSH 非 Git 条目在读取路径（ConfirmedWorkspaceByID）同样放行，
	// realpath 身份校验保留（目录移动仍 fail-closed）。
	plainRead, err := state.ConfirmedWorkspaceByID("ws-plain")
	if err != nil {
		t.Fatalf("read non-git dsh workspace: %v", err)
	}
	if !plainRead.DSH || plainRead.Root != plainConfirmed.Root {
		t.Fatalf("unexpected read-back: %+v", plainRead)
	}
	// Git 条目读取语义不变（DSH=false）。
	gitRead, err := state.ConfirmedWorkspaceByID("ws-dsh")
	if err != nil || gitRead.DSH || gitRead.Root != confirmed.Root {
		t.Fatalf("git read-back: %+v, %v", gitRead, err)
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

// V081-后续：sync_dsh 上报成功后，扫描出的候选必须按 Relay 回传的 workspace_ids
// 顺序写入本机 confirmed_workspace；否则 session.start 解析不到 workspace root，
// 会以 local_state_missing 语义 fail-closed（实测 money 工作区首启即命中）。
func TestRelayLoopConfirmDSHWorkspaceCandidatesPersistsConfirmedRoots(t *testing.T) {
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
	loop := &RelayLoop{WorkspaceManager: manager, Logger: slog.New(slog.NewTextHandler(io.Discard, nil))}

	canonical := func(project string) string {
		resolved, err := filepath.EvalSymlinks(project)
		if err != nil {
			t.Fatalf("eval %s: %v", project, err)
		}
		resolved, err = filepath.Abs(resolved)
		if err != nil {
			t.Fatalf("abs %s: %v", project, err)
		}
		return filepath.Clean(resolved)
	}
	alpha := filepath.Join(root, "alpha")
	mustMkdirAll(t, filepath.Join(alpha, ".dsh-sessions"))
	mustWriteDSHArtifact(t, alpha, "s-alpha")
	mustGitInit(t, alpha)
	beta := filepath.Join(root, "beta")
	mustMkdirAll(t, filepath.Join(beta, ".dsh-sessions"))
	mustWriteDSHArtifact(t, beta, "s-beta")
	mustGitInit(t, beta)

	candidates := []DSHWorkspaceCandidate{
		{Root: canonical(alpha), DisplayName: "alpha"},
		{Root: canonical(beta), DisplayName: "beta"},
	}
	receipt := DSHSyncCommandReceipt{CommandID: "cmd-1", Status: "succeeded", WorkspaceIDs: []string{"ws-alpha", "ws-beta"}}
	loop.confirmDSHWorkspaceCandidates(context.Background(), "cmd-1", candidates, receipt)

	for id, project := range map[string]string{"ws-alpha": alpha, "ws-beta": beta} {
		confirmed, err := state.ConfirmedWorkspaceByID(id)
		if err != nil {
			t.Fatalf("confirm %s missing: %v", id, err)
		}
		if confirmed.Root != canonical(project) {
			t.Fatalf("confirm %s root = %s, want %s", id, confirmed.Root, canonical(project))
		}
	}

	// failed 同步不写确认；nil 管理器也不得 panic。
	failed := DSHSyncCommandReceipt{CommandID: "cmd-2", Status: "failed", WorkspaceIDs: []string{"ws-failed"}}
	loop.confirmDSHWorkspaceCandidates(context.Background(), "cmd-2", candidates, failed)
	if _, err := state.ConfirmedWorkspaceByID("ws-failed"); err == nil {
		t.Fatalf("failed sync 不得写 confirmed_workspace")
	}
	emptyLoop := &RelayLoop{Logger: slog.New(slog.NewTextHandler(io.Discard, nil))}
	emptyLoop.confirmDSHWorkspaceCandidates(context.Background(), "cmd-3", candidates, receipt)
}
