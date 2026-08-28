package relay

import (
	"context"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/yubi233/agent-sessions/internal/adapter"
	"github.com/yubi233/agent-sessions/internal/daemon"
	"github.com/yubi233/agent-sessions/internal/domain"
)

// V07-03：名称创建必须经过真实 Relay -> Terminal delivery -> 专用 workspace result
// 回执链路；客户端投影始终不包含 canonical_root，重复点击只复用同一命令/Workspace。
func TestV07WorkspaceCreateWithFolderLifecycleAndIdempotency(t *testing.T) {
	env := newTestEnv(t)
	owner := env.registerAs(t, "v07-workspace-owner@test.dev")
	terminal := env.pairTerminal(t, owner, "v07-workspace-terminal")
	_ = daemonHelloWithCapabilities(t, env, terminal.AccessToken, []string{"workspace_create"})

	create := env.do(t, http.MethodPost, "/v1/workspaces/create-with-folder", map[string]any{
		"name": "v07-demo",
	}, owner.AccessToken)
	if create.Code != http.StatusAccepted {
		t.Fatalf("create status=%d body=%s", create.Code, create.Body.String())
	}
	var first struct {
		Status      string `json:"status"`
		CommandID   string `json:"command_id"`
		WorkspaceID string `json:"workspace_id"`
	}
	decodeW1(t, create.Body.Bytes(), &first)
	if first.Status != domain.CommandAccepted && first.Status != "pending" {
		t.Fatalf("unexpected pending state: %+v", first)
	}
	if first.CommandID == "" || first.WorkspaceID == "" {
		t.Fatalf("missing command/workspace id: %+v", first)
	}
	if strings.Contains(create.Body.String(), "canonical_root") {
		t.Fatalf("create response leaked canonical_root: %s", create.Body.String())
	}

	duplicate := env.do(t, http.MethodPost, "/v1/workspaces/create-with-folder", map[string]any{
		"name": "v07-demo",
	}, owner.AccessToken)
	if duplicate.Code != http.StatusAccepted {
		t.Fatalf("duplicate pending status=%d body=%s", duplicate.Code, duplicate.Body.String())
	}
	var second struct {
		CommandID string `json:"command_id"`
	}
	decodeW1(t, duplicate.Body.Bytes(), &second)
	if second.CommandID != first.CommandID {
		t.Fatalf("idempotency command changed: %q != %q", second.CommandID, first.CommandID)
	}

	// 先走通用 ack，再走只允许 workspace.create 使用的专用结果端点。
	for _, ackKind := range []string{"received", "started"} {
		ack := env.do(t, http.MethodPost, "/v1/daemon/commands/"+first.CommandID+"/ack", map[string]any{
			"protocol_version": 1, "delivery_seq": 1, "ack_kind": ackKind,
		}, terminal.AccessToken)
		if ack.Code != http.StatusOK {
			t.Fatalf("%s ack status=%d body=%s", ackKind, ack.Code, ack.Body.String())
		}
	}
	result := env.do(t, http.MethodPost, "/v1/daemon/commands/"+first.CommandID+"/workspace-result", map[string]any{
		"protocol_version": 1,
		"delivery_seq":     1,
		"workspace_id":     first.WorkspaceID,
		"canonical_root":   "/Users/test/code/v07-demo",
		"status":           "succeeded",
	}, terminal.AccessToken)
	if result.Code != http.StatusOK {
		t.Fatalf("workspace result status=%d body=%s", result.Code, result.Body.String())
	}
	if strings.Contains(result.Body.String(), "Users/test/code") || strings.Contains(result.Body.String(), "canonical_root") {
		t.Fatalf("workspace result leaked canonical root: %s", result.Body.String())
	}

	state := env.do(t, http.MethodGet, "/v1/workspaces/create-with-folder/"+first.CommandID, nil, owner.AccessToken)
	if state.Code != http.StatusOK || strings.Contains(state.Body.String(), "canonical_root") {
		t.Fatalf("state status=%d body=%s", state.Code, state.Body.String())
	}
	var completed struct {
		Status      string         `json:"status"`
		WorkspaceID string         `json:"workspace_id"`
		Workspace   map[string]any `json:"workspace"`
	}
	decodeW1(t, state.Body.Bytes(), &completed)
	if completed.Status != domain.CommandSucceeded || completed.WorkspaceID != first.WorkspaceID || completed.Workspace == nil {
		t.Fatalf("unexpected completed state: %+v", completed)
	}

	list := env.do(t, http.MethodGet, "/v1/workspaces", nil, owner.AccessToken)
	if list.Code != http.StatusOK || strings.Contains(list.Body.String(), "Users/test/code") || strings.Contains(list.Body.String(), "canonical_root") {
		t.Fatalf("workspace list leaked host root: %s", list.Body.String())
	}

	// 成功后的同名请求直接返回既有 Workspace，仍不返回命令 payload 或路径。
	reused := env.do(t, http.MethodPost, "/v1/workspaces/create-with-folder", map[string]any{"name": "v07-demo"}, owner.AccessToken)
	if reused.Code != http.StatusOK || strings.Contains(reused.Body.String(), "canonical_root") {
		t.Fatalf("reused status=%d body=%s", reused.Code, reused.Body.String())
	}
}

// V07-04：非法名称、无在线能力 Terminal 和非 owner 设备都在 Relay 入口 fail-closed。
func TestV07WorkspaceCreateWithFolderAuthorizationAndValidation(t *testing.T) {
	env := newTestEnv(t)
	owner := env.registerAs(t, "v07-workspace-auth@test.dev")
	for _, name := range []string{"", ".", "..", ".hidden", "a/b", "/absolute", "bad name", strings.Repeat("a", 65)} {
		response := env.do(t, http.MethodPost, "/v1/workspaces/create-with-folder", map[string]any{"name": name}, owner.AccessToken)
		if response.Code != http.StatusBadRequest {
			t.Fatalf("invalid name %q status=%d body=%s", name, response.Code, response.Body.String())
		}
	}

	// 没有在线 Terminal 时不得创建 command 或伪造成功 Workspace。
	offline := env.do(t, http.MethodPost, "/v1/workspaces/create-with-folder", map[string]any{"name": "offline-demo"}, owner.AccessToken)
	if offline.Code != http.StatusConflict {
		t.Fatalf("offline status=%d body=%s", offline.Code, offline.Body.String())
	}

	webLogin := env.do(t, http.MethodPost, "/v1/auth/login", map[string]any{
		"email": "v07-workspace-auth@test.dev", "password": "test-pass-123", "device_role": "web",
	}, "")
	var web struct {
		AccessToken string `json:"access_token"`
	}
	decodeW1(t, webLogin.Body.Bytes(), &web)
	denied := env.do(t, http.MethodPost, "/v1/workspaces/create-with-folder", map[string]any{"name": "web-attempt"}, web.AccessToken)
	if denied.Code != http.StatusForbidden {
		t.Fatalf("web create status=%d body=%s", denied.Code, denied.Body.String())
	}
}

// V07-03 根因回归：真实本地 HTTP Relay、Terminal SSE、Daemon WorkspaceManager 和
// SQLite 本机确认一起运行，证明目录创建不依赖 UI fixture，也不会把 Host 路径上传回客户端。
func TestV07WorkspaceCreateWithFolderDaemonLoop(t *testing.T) {
	env := newTestEnv(t)
	owner := env.registerAs(t, "v07-workspace-loop@test.dev")
	terminal := env.pairTerminal(t, owner, "v07-workspace-loop-terminal")
	_ = daemonHelloWithCapabilities(t, env, terminal.AccessToken, []string{"workspace_create"})

	server := httptest.NewServer(env.router)
	defer server.Close()
	local, err := daemon.OpenStore(filepath.Join(t.TempDir(), "daemon.db"))
	if err != nil {
		t.Fatalf("open daemon store: %v", err)
	}
	defer local.Close()
	workspaceRoot := t.TempDir()
	manager, err := daemon.NewWorkspaceManager(local, workspaceRoot)
	if err != nil {
		t.Fatalf("new workspace manager: %v", err)
	}
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	runner := daemon.NewSessionRunner(local, map[string]adapter.Adapter{"mock": adapter.NewMockAdapter()}, logger)
	defer runner.Close(context.Background())
	loop := daemon.NewRelayLoop(local, &daemon.RelayClient{BaseURL: server.URL, AccessToken: terminal.AccessToken}, runner, daemon.FixtureEventEncoder{}, logger)
	loop.DaemonVersion = "v07-workspace-loop"
	loop.Hostname = "v07-workspace-loop"
	loop.Platform = "test"
	loop.Capabilities = []string{"workspace_create"}
	loop.WorkspaceManager = manager
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- loop.RunWithRetry(ctx) }()

	create := env.do(t, http.MethodPost, "/v1/workspaces/create-with-folder", map[string]any{"name": "loop-demo"}, owner.AccessToken)
	if create.Code != http.StatusAccepted {
		cancel()
		<-done
		t.Fatalf("loop create status=%d body=%s", create.Code, create.Body.String())
	}
	var submitted struct {
		CommandID   string `json:"command_id"`
		WorkspaceID string `json:"workspace_id"`
	}
	decodeW1(t, create.Body.Bytes(), &submitted)
	deadline := time.Now().Add(4 * time.Second)
	for time.Now().Before(deadline) {
		state := env.do(t, http.MethodGet, "/v1/workspaces/create-with-folder/"+submitted.CommandID, nil, owner.AccessToken)
		var view struct {
			Status string `json:"status"`
		}
		decodeW1(t, state.Body.Bytes(), &view)
		if state.Code == http.StatusOK && view.Status == domain.CommandSucceeded {
			canonicalRoot, _ := filepath.EvalSymlinks(filepath.Join(workspaceRoot, "loop-demo"))
			if !daemonStoreHasWorkspaceRoot(t, local, submitted.WorkspaceID, canonicalRoot) {
				t.Fatalf("daemon did not persist confirmed workspace root")
			}
			if _, err := os.Stat(filepath.Join(workspaceRoot, "loop-demo", ".git")); err != nil {
				t.Fatalf("workspace git root missing: %v", err)
			}
			cancel()
			if runErr := <-done; runErr != context.Canceled {
				t.Fatalf("loop result=%v want context.Canceled", runErr)
			}
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	cancel()
	<-done
	t.Fatalf("workspace create daemon loop did not converge")
}

func daemonStoreHasWorkspaceRoot(t *testing.T, local *daemon.Store, workspaceID, expectedRoot string) bool {
	t.Helper()
	confirmed, err := local.ConfirmedWorkspaceByID(workspaceID)
	return err == nil && confirmed.Root == expectedRoot
}
