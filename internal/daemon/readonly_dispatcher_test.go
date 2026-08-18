package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
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

	treeEvent, err := dispatcher.Execute(context.Background(), fixtureReadOnlyRelayCommand("file.tree", "src", "", "term-readonly"))
	if err != nil {
		t.Fatalf("file.tree dispatch: %v", err)
	}
	entries, ok := treeEvent.Payload["result"].([]FileEntry)
	if !ok || len(entries) != 1 || entries[0].Path != "src/main.go" {
		t.Fatalf("unexpected file.tree result: %#v", treeEvent.Payload["result"])
	}

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
	codeEvent, err := dispatcher.Execute(context.Background(), fixtureReadOnlyRelayCommand("code.read", "src/main.go", "", "term-readonly"))
	if err != nil {
		t.Fatalf("code.read dispatch: %v", err)
	}
	codeResult, ok := codeEvent.Payload["result"].(map[string]any)
	if !ok || codeResult["path"] != "src/main.go" || codeResult["content"] != "package sample\n// local-only fixture\n" {
		t.Fatalf("unexpected code.read result: %+v", codeEvent.Payload["result"])
	}

	statusEvent, err := dispatcher.Execute(context.Background(), fixtureReadOnlyRelayCommand("git.status", "", "", "term-readonly"))
	if err != nil {
		t.Fatalf("git.status dispatch: %v", err)
	}
	status, ok := statusEvent.Payload["result"].(gitread.Status)
	if !ok || status.SnapshotToken == "" {
		t.Fatalf("unexpected git.status result: %#v", statusEvent.Payload["result"])
	}
	changesEvent, err := dispatcher.Execute(context.Background(), fixtureReadOnlyRelayCommand("git.changes", "", "", "term-readonly"))
	if err != nil {
		t.Fatalf("git.changes dispatch: %v", err)
	}
	changes, ok := changesEvent.Payload["result"].(map[string]any)
	if !ok || changes["snapshot_token"] == "" {
		t.Fatalf("unexpected git.changes result: %#v", changesEvent.Payload["result"])
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

// GIT-07：普通 Relay dispatcher 必须逐项覆盖 P2 计划列出的拒绝边界。下层 reader/git helper
// 的单元测试不够，因为这里还要证明错误经 command 边界稳定映射，且不产生成功 event。
func TestReadOnlyDispatcherRejectsAllP2ReadBoundaries(t *testing.T) {
	root := t.TempDir()
	runGit(t, root, "init")
	runGit(t, root, "config", "user.email", "fixture@example.test")
	runGit(t, root, "config", "user.name", "Fixture")
	if err := os.WriteFile(filepath.Join(root, "safe.txt"), []byte("safe\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	runGit(t, root, "add", "safe.txt")
	runGit(t, root, "commit", "-m", "initial")
	if err := os.WriteFile(filepath.Join(root, "binary.bin"), []byte{1, 0, 2}, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "invalid-utf8.txt"), []byte{0xff, 0xfe}, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "large.txt"), []byte(strings.Repeat("x", maxReadOnlyFileBytes+1)), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(root, "directory"), 0o755); err != nil {
		t.Fatal(err)
	}

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

	assertRejected := func(name, path, wantCode string) {
		t.Helper()
		_, err := dispatcher.Execute(context.Background(), fixtureReadOnlyRelayCommand("file.read", path, "", "term-readonly"))
		if got := CommandErrorCode(err); got != wantCode {
			t.Fatalf("%s error=%v code=%q want %q", name, err, got, wantCode)
		}
	}
	assertRejected("binary", "binary.bin", protocol.ErrContentUnavailable)
	assertRejected("unknown UTF-8", "invalid-utf8.txt", protocol.ErrContentUnavailable)
	assertRejected("too large", "large.txt", protocol.ErrPayloadTooLarge)
	assertRejected("directory", "directory", protocol.ErrContentUnavailable)
	assertRejected("parent escape", "../secret.txt", protocol.ErrWorkspacePathDenied)
	assertRejected("absolute path", filepath.Join(root, "safe.txt"), protocol.ErrWorkspacePathDenied)

	outside := t.TempDir()
	if err := os.WriteFile(filepath.Join(outside, "secret.txt"), []byte("outside\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(root, "outside-link")); err == nil {
		assertRejected("outside symlink", "outside-link/secret.txt", protocol.ErrWorkspacePathDenied)
		// Git status 同样会对仓外链接 fail-closed；此处已完成 symlink 边界断言，移除链接后
		// 再独立验证 stale snapshot，避免两个安全拒绝条件互相遮蔽。
		if err := os.Remove(filepath.Join(root, "outside-link")); err != nil {
			t.Fatal(err)
		}
	} else {
		t.Logf("symlink unavailable; platform rejected test setup: %v", err)
	}

	unconfirmed := fixtureReadOnlyRelayCommand("file.read", "safe.txt", "", "term-readonly")
	unconfirmed.WorkspaceID = "ws-unconfirmed"
	if _, err := dispatcher.Execute(context.Background(), unconfirmed); CommandErrorCode(err) != protocol.ErrWorkspacePathDenied {
		t.Fatalf("unconfirmed workspace error=%v code=%q", err, CommandErrorCode(err))
	}

	statusEvent, err := dispatcher.Execute(context.Background(), fixtureReadOnlyRelayCommand("git.status", "", "", "term-readonly"))
	if err != nil {
		t.Fatalf("git status before stale test: %v", err)
	}
	status, ok := statusEvent.Payload["result"].(gitread.Status)
	if !ok || status.SnapshotToken == "" {
		t.Fatalf("git status result=%#v", statusEvent.Payload["result"])
	}
	if err := os.WriteFile(filepath.Join(root, "safe.txt"), []byte("changed after snapshot\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	_, err = dispatcher.Execute(context.Background(), fixtureReadOnlyRelayCommand("git.diff", "safe.txt", status.SnapshotToken, "term-readonly"))
	if got := CommandErrorCode(err); got != protocol.ErrSnapshotStale {
		t.Fatalf("stale snapshot error=%v code=%q want %q", err, got, protocol.ErrSnapshotStale)
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
