package daemon

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
	"unicode/utf16"
)

func writeDSHSessionArtifactForTest(t *testing.T, root, cwd, id, body string) string {
	t.Helper()
	path := filepath.Join(root, dshProjectKeyForTest(cwd), dshEncodeSegmentForTest(id), "session.jsonl")
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	header, _ := json.Marshal(map[string]any{
		"type": "session", "version": 0, "id": id, "createdAt": 1,
		"cwd": cwd, "delegationDepth": 0,
	})
	payload := append(append(header, '\n'), []byte(body)...)
	if err := os.WriteFile(path, payload, 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

// dshProjectKeyForTest 与 internal/adapter/dsh 的 DSH 项目目录键保持一致，
// 仅用于构造符合布局的测试 artifact，不进入生产代码。
func dshProjectKeyForTest(cwd string) string {
	if cwd == "" {
		return "--root--"
	}
	var b strings.Builder
	separatorRun := false
	for _, code := range utf16.Encode([]rune(cwd)) {
		r := rune(code)
		if r == '/' || r == '\\' || r == ':' {
			if !separatorRun {
				b.WriteByte('-')
			}
			separatorRun = true
			continue
		}
		if r == '~' || !(r == '.' || r == '_' || r == '-' || r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9') {
			fmt.Fprintf(&b, "~%04X", code)
		} else {
			b.WriteRune(r)
		}
		separatorRun = false
	}
	slug := strings.TrimLeft(b.String(), "-")
	if slug == "" {
		slug = "root"
	}
	if len(slug) > 251 {
		slug = slug[:251]
	}
	return "--" + slug + "--"
}

// dshEncodeSegmentForTest 与 internal/adapter/dsh 的会话目录段编码保持一致。
func dshEncodeSegmentForTest(raw string) string {
	if raw == "" {
		return ""
	}
	if raw == "." || raw == ".." {
		raw = strings.ReplaceAll(raw, ".", "~002E")
		return raw
	}
	var b strings.Builder
	for _, code := range utf16.Encode([]rune(raw)) {
		r := rune(code)
		if r == '~' || !(r == '.' || r == '_' || r == '-' || r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9') {
			fmt.Fprintf(&b, "~%04X", code)
		} else {
			b.WriteRune(r)
		}
	}
	return b.String()
}

func TestImportDSHSessionsGeneratesMappingAndPendingReplay(t *testing.T) {
	root := t.TempDir()
	project := filepath.Join(root, "p")
	mustMkdirAll(t, filepath.Join(project, ".dsh-sessions"))
	mustGitInit(t, project)
	canonicalProject, err := filepath.EvalSymlinks(project)
	if err != nil {
		t.Fatalf("resolve project: %v", err)
	}
	canonicalProject, err = filepath.Abs(canonicalProject)
	if err != nil {
		t.Fatalf("abs project: %v", err)
	}
	canonicalProject = filepath.Clean(canonicalProject)
	writeDSHSessionArtifactForTest(t, filepath.Join(project, ".dsh-sessions"), canonicalProject, "dsh-sess-1", `{"type":"user/message"}`)

	state, err := OpenStore(filepath.Join(t.TempDir(), "daemon.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer state.Close()
	manager, err := NewWorkspaceManager(state, root)
	if err != nil {
		t.Fatalf("new manager: %v", err)
	}
	if _, err := manager.ConfirmExistingDSHWorkspace(context.Background(), "ws-dsh", project); err != nil {
		t.Fatalf("confirm: %v", err)
	}
	imported, err := manager.ImportDSHSessions(context.Background(), "ws-dsh", state, false)
	if err != nil {
		t.Fatalf("import: %v", err)
	}
	if len(imported) != 1 {
		t.Fatalf("expected 1 imported session, got %+v", imported)
	}
	got := imported[0]
	if got.RelaySessionID == "" || got.DSHSessionID != "dsh-sess-1" || got.WorkspaceRoot != canonicalProject {
		t.Fatalf("unexpected imported mapping: %+v", got)
	}

	rawMapping, err := state.Get(instanceKey(got.RelaySessionID))
	if err != nil {
		t.Fatalf("read instance mapping: %v", err)
	}
	var th providerThread
	if err := json.Unmarshal([]byte(rawMapping), &th); err != nil {
		t.Fatalf("unmarshal instance mapping: %v", err)
	}
	if th.Provider != "dsh" || th.InstanceID != "dsh-sess-1" || th.WorkspaceRoot != canonicalProject {
		t.Fatalf("unexpected provider thread: %+v", th)
	}
	replayState, err := state.Get(replayStateKey(got.RelaySessionID))
	if err != nil {
		t.Fatalf("read replay state: %v", err)
	}
	if replayState != replayPending {
		t.Fatalf("expected replay state pending, got %q", replayState)
	}
}

func dshImportFixtureProject(t *testing.T, root string) string {
	t.Helper()
	project := filepath.Join(root, "p")
	mustMkdirAll(t, filepath.Join(project, ".dsh-sessions"))
	mustWriteFile(t, filepath.Join(project, ".dsh-sessions", "session-query.db"), "x")
	mustGitInit(t, project)
	return project
}

func TestImportDSHSessionsMissingPersistenceRootIsEmpty(t *testing.T) {
	root := t.TempDir()
	project := dshImportFixtureProject(t, root)
	state, err := OpenStore(filepath.Join(t.TempDir(), "daemon.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer state.Close()
	manager, err := NewWorkspaceManager(state, root)
	if err != nil {
		t.Fatalf("new manager: %v", err)
	}
	if _, err := manager.ConfirmExistingDSHWorkspace(context.Background(), "ws-dsh", project); err != nil {
		t.Fatalf("confirm: %v", err)
	}
	imported, err := manager.ImportDSHSessions(context.Background(), "ws-dsh", state, false)
	if err != nil {
		t.Fatalf("import: %v", err)
	}
	if len(imported) != 0 {
		t.Fatalf("expected empty import, got %+v", imported)
	}
}

func TestImportDSHSessionsIdempotentEmpty(t *testing.T) {
	root := t.TempDir()
	project := dshImportFixtureProject(t, root)
	state, err := OpenStore(filepath.Join(t.TempDir(), "daemon.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer state.Close()
	manager, err := NewWorkspaceManager(state, root)
	if err != nil {
		t.Fatalf("new manager: %v", err)
	}
	if _, err := manager.ConfirmExistingDSHWorkspace(context.Background(), "ws-dsh", project); err != nil {
		t.Fatalf("confirm: %v", err)
	}
	first, err := manager.ImportDSHSessions(context.Background(), "ws-dsh", state, false)
	if err != nil {
		t.Fatalf("first import: %v", err)
	}
	second, err := manager.ImportDSHSessions(context.Background(), "ws-dsh", state, false)
	if err != nil {
		t.Fatalf("second import: %v", err)
	}
	if len(first) != 0 || len(second) != 0 {
		t.Fatalf("expected both empty, got %+v vs %+v", first, second)
	}
}

// V094（2026-09-21 用户需求：只加载最近三天还在更新的会话）：活跃窗口外的 DSH
// artifact 不导入、不产生投影；窗口内的会话正常导入且 LastActivity 取真实文件时间。
func TestImportDSHSessionsFiltersStaleSessionsByActiveWindow(t *testing.T) {
	ctx := context.Background()
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
	// fresh 工作区：artifact 修改时间在 72h 窗口内，应被导入。
	freshProject := dshImportFixtureProject(t, filepath.Join(root, "fresh"))
	freshCanonical, err := filepath.EvalSymlinks(freshProject)
	if err != nil {
		t.Fatalf("resolve fresh: %v", err)
	}
	freshRoot := filepath.Join(freshProject, ".dsh-sessions")
	freshPath := writeDSHSessionArtifactForTest(t, freshRoot, freshCanonical, "fresh-id", `{"type":"user/message"}`)
	freshTime := time.Now().Add(-1 * time.Hour)
	if err := os.Chtimes(freshPath, freshTime, freshTime); err != nil {
		t.Fatalf("chtimes fresh: %v", err)
	}
	if _, err := manager.ConfirmExistingDSHWorkspace(context.Background(), "ws-dsh-fresh", freshCanonical); err != nil {
		t.Fatalf("confirm fresh: %v", err)
	}

	// stale 工作区：artifact 修改时间在 72h 窗口外，应被跳过。
	staleProject := dshImportFixtureProject(t, filepath.Join(root, "stale"))
	staleCanonical, err := filepath.EvalSymlinks(staleProject)
	if err != nil {
		t.Fatalf("resolve stale: %v", err)
	}
	staleRoot := filepath.Join(staleProject, ".dsh-sessions")
	stalePath := writeDSHSessionArtifactForTest(t, staleRoot, staleCanonical, "stale-id", `{"type":"user/message"}`)
	staleTime := time.Now().Add(-10 * 24 * time.Hour)
	if err := os.Chtimes(stalePath, staleTime, staleTime); err != nil {
		t.Fatalf("chtimes stale: %v", err)
	}
	if _, err := manager.ConfirmExistingDSHWorkspace(context.Background(), "ws-dsh-stale", staleCanonical); err != nil {
		t.Fatalf("confirm stale: %v", err)
	}

	freshImported, err := manager.ImportDSHSessions(ctx, "ws-dsh-fresh", state, false)
	if err != nil {
		t.Fatalf("import fresh: %v", err)
	}
	if len(freshImported) != 1 || freshImported[0].DSHSessionID != "fresh-id" {
		t.Fatalf("窗口内会话应导入: %+v", freshImported)
	}
	if freshImported[0].LastActivityUnixMS != freshTime.UnixMilli() {
		t.Fatalf("LastActivity 应取 DSH artifact 修改时间: %d", freshImported[0].LastActivityUnixMS)
	}

	staleImported, err := manager.ImportDSHSessions(ctx, "ws-dsh-stale", state, false)
	if err != nil {
		t.Fatalf("import stale: %v", err)
	}
	if len(staleImported) != 0 {
		t.Fatalf("窗口外的老会话不得导入: %+v", staleImported)
	}
}
