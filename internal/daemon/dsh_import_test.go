package daemon

import (
	"context"
	"path/filepath"
	"testing"
)

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
