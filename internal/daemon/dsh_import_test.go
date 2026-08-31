package daemon

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
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
	imported, err := manager.ImportDSHSessions(context.Background(), "ws-dsh", state)
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
	imported, err := manager.ImportDSHSessions(context.Background(), "ws-dsh", state)
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
	first, err := manager.ImportDSHSessions(context.Background(), "ws-dsh", state)
	if err != nil {
		t.Fatalf("first import: %v", err)
	}
	second, err := manager.ImportDSHSessions(context.Background(), "ws-dsh", state)
	if err != nil {
		t.Fatalf("second import: %v", err)
	}
	if len(first) != 0 || len(second) != 0 {
		t.Fatalf("expected both empty, got %+v vs %+v", first, second)
	}
}
