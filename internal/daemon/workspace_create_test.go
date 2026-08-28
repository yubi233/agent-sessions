package daemon

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/yubi233/agent-sessions/internal/workspacesafe"
)

func TestValidateWorkspaceNameRejectsPathLikeAndHiddenNames(t *testing.T) {
	for _, name := range []string{"", " ", ".", "..", ".hidden", "../escape", "/absolute", "a/b", "a\\b", "a\n"} {
		if err := ValidateWorkspaceName(name); !errors.Is(err, ErrWorkspaceNameInvalid) {
			t.Fatalf("ValidateWorkspaceName(%q) = %v, want ErrWorkspaceNameInvalid", name, err)
		}
	}
	if err := ValidateWorkspaceName("demo-v07-01"); err != nil {
		t.Fatalf("valid workspace name rejected: %v", err)
	}
}

func TestWorkspaceManagerCreateInitializesAndConfirmsGitRoot(t *testing.T) {
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
	confirmed, err := manager.Create(context.Background(), "ws-test", "demo-v07-01")
	if err != nil {
		t.Fatalf("create workspace: %v", err)
	}
	canonicalRoot, _ := filepath.EvalSymlinks(root)
	if confirmed.ID != "ws-test" || confirmed.Root != filepath.Join(canonicalRoot, "demo-v07-01") {
		t.Fatalf("unexpected confirmation: %+v", confirmed)
	}
	if !workspacesafe.IsGitRoot(confirmed.Root) {
		t.Fatalf("created workspace is not a git root: %s", confirmed.Root)
	}
	reloaded, err := state.ConfirmedWorkspaceByID("ws-test")
	if err != nil || reloaded.Root != confirmed.Root {
		t.Fatalf("reload confirmation: %+v, %v", reloaded, err)
	}

	// 同名重试必须复用同一目录和本机确认，不重复创建第二个根。
	reused, err := manager.Create(context.Background(), "ws-test", "demo-v07-01")
	if err != nil || reused.Root != confirmed.Root {
		t.Fatalf("idempotent reuse: %+v, %v", reused, err)
	}
}

func TestWorkspaceManagerRejectsExistingNonDirectoryAndNonGit(t *testing.T) {
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
	if err := os.WriteFile(filepath.Join(root, "occupied"), []byte("x"), 0o600); err != nil {
		t.Fatalf("seed file: %v", err)
	}
	if _, err := manager.Create(context.Background(), "ws-file", "occupied"); err == nil {
		t.Fatal("expected existing file rejection")
	}
	if err := os.Mkdir(filepath.Join(root, "plain"), 0o755); err != nil {
		t.Fatalf("seed directory: %v", err)
	}
	if _, err := manager.Create(context.Background(), "ws-plain", "plain"); !errors.Is(err, workspacesafe.ErrNotAGitRoot) {
		t.Fatalf("expected non-git rejection, got %v", err)
	}
	if _, err := manager.Create(context.Background(), "ws-escape", "../outside"); !errors.Is(err, ErrWorkspaceNameInvalid) {
		t.Fatalf("expected name rejection before path resolution, got %v", err)
	}
}

func TestResolveWorkspaceRootRequiresExistingDirectory(t *testing.T) {
	if _, err := ResolveWorkspaceRoot(filepath.Join(t.TempDir(), "missing")); !errors.Is(err, ErrWorkspaceRootInvalid) {
		t.Fatalf("expected missing root rejection, got %v", err)
	}
	root := t.TempDir()
	canonical, err := ResolveWorkspaceRoot(root)
	if err != nil || canonical == "" {
		t.Fatalf("resolve temp root: %q, %v", canonical, err)
	}
}
