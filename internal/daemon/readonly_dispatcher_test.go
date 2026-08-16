package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/yubi233/agent-sessions/internal/adapter"
	"github.com/yubi233/agent-sessions/internal/gitread"
	"github.com/yubi233/agent-sessions/internal/workspacesafe"
	"github.com/yubi233/agent-sessions/packages/protocol"
)

// GIT-07 / HTTP-03：Relay 下行只读命令只可落到已本机确认、目标 Terminal 匹配的真实 Git 根。
// 成功结果仍作为 canonical event 留在 Daemon，测试可直接观察 payload；Relay 上传由 encoder 单独覆盖。
func TestReadOnlyDispatcherUsesConfirmedWorkspaceAndBoundedResults(t *testing.T) {
	root := t.TempDir()
	runGit(t, root, "init")
	runGit(t, root, "config", "user.email", "fixture@example.test")
	runGit(t, root, "config", "user.name", "Fixture")
	if err := os.MkdirAll(filepath.Join(root, "src"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "src", "main.go"), []byte("package sample\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	runGit(t, root, "add", "src/main.go")
	runGit(t, root, "commit", "-m", "initial")
	if err := os.WriteFile(filepath.Join(root, "src", "main.go"), []byte("package sample\n// local-only fixture\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	store, err := OpenStore(filepath.Join(t.TempDir(), "daemon.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if _, err := store.ConfirmWorkspace("ws-readonly", root); err != nil {
		t.Fatalf("confirm workspace: %v", err)
	}
	if err := store.Set("terminal_id", "term-readonly"); err != nil {
		t.Fatal(err)
	}
	dispatcher := NewReadOnlyDispatcher(store, "git")

	readEvent, err := dispatcher.Execute(context.Background(), fixtureReadOnlyRelayCommand("file.read", "src/main.go", "", "term-readonly"))
	if err != nil {
		t.Fatalf("file.read dispatch: %v", err)
	}
	if readEvent.Type != adapter.EventToolResult || readEvent.Payload["workspace_id"] != "ws-readonly" {
		t.Fatalf("unexpected read event: %+v", readEvent)
	}
	readResult, ok := readEvent.Payload["result"].(map[string]any)
	if !ok || readResult["path"] != "src/main.go" || readResult["content"] != "package sample\n// local-only fixture\n" {
		t.Fatalf("unexpected file.read result: %+v", readEvent.Payload["result"])
	}

	statusEvent, err := dispatcher.Execute(context.Background(), fixtureReadOnlyRelayCommand("git.status", "", "", "term-readonly"))
	if err != nil {
		t.Fatalf("git.status dispatch: %v", err)
	}
	status, ok := statusEvent.Payload["result"].(gitread.Status)
	if !ok || status.SnapshotToken == "" {
		t.Fatalf("unexpected git.status result: %#v", statusEvent.Payload["result"])
	}
	diffEvent, err := dispatcher.Execute(context.Background(), fixtureReadOnlyRelayCommand("git.diff", "src/main.go", status.SnapshotToken, "term-readonly"))
	if err != nil {
		t.Fatalf("git.diff dispatch: %v", err)
	}
	diff, ok := diffEvent.Payload["result"].(gitread.DiffPage)
	if !ok || diff.Path != "src/main.go" || len(diff.Hunks) == 0 {
		t.Fatalf("unexpected git.diff result: %#v", diffEvent.Payload["result"])
	}
}

func TestReadOnlyDispatcherFailsClosedForTargetWorkspaceAndPath(t *testing.T) {
	root := t.TempDir()
	runGit(t, root, "init")
	runGit(t, root, "config", "user.email", "fixture@example.test")
	runGit(t, root, "config", "user.name", "Fixture")
	if err := os.WriteFile(filepath.Join(root, "safe.txt"), []byte("safe\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	runGit(t, root, "add", "safe.txt")
	runGit(t, root, "commit", "-m", "initial")

	store, err := OpenStore(filepath.Join(t.TempDir(), "daemon.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if _, err := store.ConfirmWorkspace("ws-readonly", root); err != nil {
		t.Fatal(err)
	}
	if err := store.Set("terminal_id", "term-readonly"); err != nil {
		t.Fatal(err)
	}
	dispatcher := NewReadOnlyDispatcher(store, "git")

	_, err = dispatcher.Execute(context.Background(), fixtureReadOnlyRelayCommand("file.read", "../secret.txt", "", "term-readonly"))
	if CommandErrorCode(err) != protocol.ErrWorkspacePathDenied || !errors.Is(err, workspacesafe.ErrEscapeRoot) {
		t.Fatalf("escape error=%v code=%s", err, CommandErrorCode(err))
	}
	_, err = dispatcher.Execute(context.Background(), fixtureReadOnlyRelayCommand("file.read", "safe.txt", "", "term-other"))
	if CommandErrorCode(err) != protocol.ErrScopeDenied {
		t.Fatalf("target mismatch error=%v code=%s", err, CommandErrorCode(err))
	}
	unknown := fixtureReadOnlyRelayCommand("file.read", "safe.txt", "", "term-readonly")
	unknown.WorkspaceID = "ws-unconfirmed"
	_, err = dispatcher.Execute(context.Background(), unknown)
	if CommandErrorCode(err) != protocol.ErrWorkspacePathDenied || !errors.Is(err, ErrWorkspaceNotConfirmed) {
		t.Fatalf("unconfirmed workspace error=%v code=%s", err, CommandErrorCode(err))
	}
	opaque := fixtureReadOnlyRelayCommand("file.read", "safe.txt", "", "term-readonly")
	opaque.PayloadJSON = `{"ciphertext":{"nonce":"n","ciphertext":"opaque"}}`
	_, err = dispatcher.Execute(context.Background(), opaque)
	if CommandErrorCode(err) != protocol.ErrCapabilityUnsupported {
		t.Fatalf("opaque payload error=%v code=%s", err, CommandErrorCode(err))
	}
}

func fixtureReadOnlyRelayCommand(kind, path, snapshotToken, terminalID string) RelayCommand {
	payload, _ := json.Marshal(map[string]any{
		"ciphertext": map[string]any{"fixture_payload": map[string]any{
			"path": path, "snapshot_token": snapshotToken, "limit": 100,
		}},
	})
	return RelayCommand{
		CommandID: "cmd-readonly", DeliverySeq: 1, SessionID: "sess-readonly", WorkspaceID: "ws-readonly",
		Kind: kind, LeaseEpoch: 1, TargetTerminalID: terminalID, PayloadJSON: string(payload),
	}
}
