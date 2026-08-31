package relay

import (
	"net/http"
	"strings"
	"testing"
)

// V08-19：只有 owner/write + 在线 Terminal + dsh_workspace_sync capability 才能发起同步。
func TestV08DSHWorkspaceSyncAuthorization(t *testing.T) {
	env := newTestEnv(t)
	owner := env.registerAs(t, "v08-dsh-sync-auth@test.dev")

	// 未配对任何 Terminal 时同步请求应冲突（Terminal offline / capability missing）。
	blocked := env.do(t, http.MethodPost, "/v1/workspaces/sync-dsh", map[string]any{}, owner.AccessToken)
	if blocked.Code != http.StatusConflict && blocked.Code != http.StatusForbidden {
		t.Fatalf("offline sync status=%d body=%s", blocked.Code, blocked.Body.String())
	}

	terminal := env.pairTerminal(t, owner, "v08-dsh-sync-terminal")
	_ = daemonHelloWithCapabilities(t, env, terminal.AccessToken, []string{"dsh_workspace_sync"})
	create := env.do(t, http.MethodPost, "/v1/workspaces/sync-dsh", map[string]any{}, owner.AccessToken)
	if create.Code != http.StatusAccepted && create.Code != http.StatusOK {
		t.Fatalf("sync status=%d body=%s", create.Code, create.Body.String())
	}
	var first struct {
		Status       string   `json:"status"`
		CommandID    string   `json:"command_id"`
		WorkspaceIDs []string `json:"workspace_ids"`
	}
	decodeW1(t, create.Body.Bytes(), &first)
	if first.CommandID == "" || first.Status == "" {
		t.Fatalf("missing sync command fields: %+v", first)
	}
	if strings.Contains(create.Body.String(), "canonical_root") || strings.Contains(create.Body.String(), "Users/") {
		t.Fatalf("sync response leaked path: %s", create.Body.String())
	}

	// 重复请求幂等返回同一 command。
	duplicate := env.do(t, http.MethodPost, "/v1/workspaces/sync-dsh", map[string]any{}, owner.AccessToken)
	var second struct {
		CommandID string `json:"command_id"`
	}
	decodeW1(t, duplicate.Body.Bytes(), &second)
	if second.CommandID != first.CommandID {
		t.Fatalf("dsh sync idempotency command changed: %q != %q", second.CommandID, first.CommandID)
	}

	// 只读 Web 登录不能发起同步。
	webToken := loginP4Web(t, env, "v08-dsh-sync-auth@test.dev")
	denied := env.do(t, http.MethodPost, "/v1/workspaces/sync-dsh", map[string]any{}, webToken)
	if denied.Code != http.StatusForbidden && denied.Code != http.StatusConflict {
		t.Fatalf("web sync status=%d body=%s", denied.Code, denied.Body.String())
	}
}

// V08-02/09：专用 result 收口后返回 opaque workspace ids，不泄漏 canonical roots；重复回执幂等。
func TestV08DSHWorkspaceSyncResultRegistersOpaqueWorkspaces(t *testing.T) {
	env := newTestEnv(t)
	owner := env.registerAs(t, "v08-dsh-sync-result@test.dev")
	terminal := env.pairTerminal(t, owner, "v08-dsh-sync-result-terminal")
	_ = daemonHelloWithCapabilities(t, env, terminal.AccessToken, []string{"dsh_workspace_sync"})

	create := env.do(t, http.MethodPost, "/v1/workspaces/sync-dsh", map[string]any{}, owner.AccessToken)
	var submitted struct {
		CommandID string `json:"command_id"`
	}
	decodeW1(t, create.Body.Bytes(), &submitted)
	// 同步命令没有 Session lease；Relay 接受 started ack 后由 Daemon 走专用 result。
	// 这里直接模拟 Daemon 已完成扫描并回传 result（不依赖 ack）。
	result := env.do(t, http.MethodPost, "/v1/daemon/commands/"+submitted.CommandID+"/dsh-workspace-result", map[string]any{
		"protocol_version": 1,
		"delivery_seq":     1,
		"canonical_roots":  []string{"/Users/test/code/proj-a", "/Users/test/code/proj-b"},
		"status":           "succeeded",
	}, terminal.AccessToken)
	if result.Code != http.StatusOK {
		t.Fatalf("dsh result status=%d body=%s", result.Code, result.Body.String())
	}
	if strings.Contains(result.Body.String(), "Users/test/code") || strings.Contains(result.Body.String(), "canonical_root") {
		t.Fatalf("dsh result leaked canonical root: %s", result.Body.String())
	}
	var view struct {
		WorkspaceIDs []string `json:"workspace_ids"`
	}
	decodeW1(t, result.Body.Bytes(), &view)
	if len(view.WorkspaceIDs) != 2 {
		t.Fatalf("expected 2 workspace ids, got %+v", view.WorkspaceIDs)
	}

	// 列表可看到两个 DSH Workspace，且不包含路径。
	list := env.do(t, http.MethodGet, "/v1/workspaces", nil, owner.AccessToken)
	if list.Code != http.StatusOK || strings.Contains(list.Body.String(), "Users/test/code") {
		t.Fatalf("workspace list leaked path: %d %s", list.Code, list.Body.String())
	}
	var listed struct {
		Workspaces []struct {
			ID         string `json:"id"`
			TerminalID string `json:"terminal_id"`
		} `json:"workspaces"`
	}
	decodeW1(t, list.Body.Bytes(), &listed)
	if len(listed.Workspaces) != 2 {
		t.Fatalf("expected 2 workspaces, got %+v", listed.Workspaces)
	}
	for _, ws := range listed.Workspaces {
		if ws.TerminalID == "" {
			t.Fatalf("workspace missing home terminal: %+v", ws)
		}
	}

	// 重复 result 幂等，不新增 Workspace。
	repeat := env.do(t, http.MethodPost, "/v1/daemon/commands/"+submitted.CommandID+"/dsh-workspace-result", map[string]any{
		"protocol_version": 1, "delivery_seq": 1,
		"canonical_roots": []string{"/Users/test/code/proj-a", "/Users/test/code/proj-b"},
		"status":          "succeeded",
	}, terminal.AccessToken)
	if repeat.Code != http.StatusOK {
		t.Fatalf("repeat dsh result status=%d body=%s", repeat.Code, repeat.Body.String())
	}
	listAfter := env.do(t, http.MethodGet, "/v1/workspaces", nil, owner.AccessToken)
	decodeW1(t, listAfter.Body.Bytes(), &listed)
	if len(listed.Workspaces) != 2 {
		t.Fatalf("repeat result created duplicate workspaces: %d", len(listed.Workspaces))
	}
}

// V08-08/09：session.import_dsh 只允许 home Terminal 发起，并只返回 opaque session ids。
func TestV08DSHImportAuthorizationAndResult(t *testing.T) {
	env := newTestEnv(t)
	owner := env.registerAs(t, "v08-dsh-import@test.dev")
	terminal := env.pairTerminal(t, owner, "v08-dsh-import-terminal")
	_ = daemonHelloWithCapabilities(t, env, terminal.AccessToken, []string{"dsh_workspace_sync", "dsh_session_import"})

	// 先同步一个 DSH Workspace，取得 workspace_id。
	sync := env.do(t, http.MethodPost, "/v1/workspaces/sync-dsh", map[string]any{}, owner.AccessToken)
	var syncState struct {
		CommandID string `json:"command_id"`
	}
	decodeW1(t, sync.Body.Bytes(), &syncState)
	_ = env.do(t, http.MethodPost, "/v1/daemon/commands/"+syncState.CommandID+"/dsh-workspace-result", map[string]any{
		"protocol_version": 1, "delivery_seq": 1,
		"canonical_roots": []string{"/Users/test/code/import-proj"},
		"status":          "succeeded",
	}, terminal.AccessToken)
	var list struct {
		Workspaces []struct {
			ID         string `json:"id"`
			TerminalID string `json:"terminal_id"`
		} `json:"workspaces"`
	}
	decodeW1(t, env.do(t, http.MethodGet, "/v1/workspaces", nil, owner.AccessToken).Body.Bytes(), &list)
	if len(list.Workspaces) != 1 {
		t.Fatalf("expected one dsh workspace, got %+v", list.Workspaces)
	}
	wsID := list.Workspaces[0].ID

	importReq := env.do(t, http.MethodPost, "/v1/workspaces/import-dsh", map[string]any{"workspace_id": wsID}, owner.AccessToken)
	if importReq.Code != http.StatusAccepted && importReq.Code != http.StatusOK {
		t.Fatalf("import status=%d body=%s", importReq.Code, importReq.Body.String())
	}
	var importState struct {
		CommandID string `json:"command_id"`
	}
	decodeW1(t, importReq.Body.Bytes(), &importState)

	result := env.do(t, http.MethodPost, "/v1/daemon/commands/"+importState.CommandID+"/dsh-import-result", map[string]any{
		"protocol_version": 1, "delivery_seq": 2,
		"session_ids": []string{"sess_import_1", "sess_import_2"},
		"status":      "succeeded",
	}, terminal.AccessToken)
	if result.Code != http.StatusOK {
		t.Fatalf("import result status=%d body=%s", result.Code, result.Body.String())
	}
	if strings.Contains(result.Body.String(), "Users/test/code") || strings.Contains(result.Body.String(), "canonical_root") {
		t.Fatalf("import result leaked path: %s", result.Body.String())
	}
	var importView struct {
		SessionIDs []string `json:"session_ids"`
	}
	decodeW1(t, result.Body.Bytes(), &importView)
	if len(importView.SessionIDs) != 2 {
		t.Fatalf("expected 2 session ids, got %+v", importView.SessionIDs)
	}

	// 会话列表应出现两个 dsh 会话。
	sessions := env.do(t, http.MethodGet, "/v1/sessions", nil, owner.AccessToken)
	if sessions.Code != http.StatusOK {
		t.Fatalf("list sessions status=%d body=%s", sessions.Code, sessions.Body.String())
	}
	var sessionList struct {
		Sessions []struct {
			ID          string `json:"id"`
			Provider    string `json:"provider"`
			WorkspaceID string `json:"workspace_id"`
		} `json:"sessions"`
	}
	decodeW1(t, sessions.Body.Bytes(), &sessionList)
	if len(sessionList.Sessions) != 2 {
		t.Fatalf("expected 2 imported sessions, got %+v", sessionList.Sessions)
	}
	for _, sess := range sessionList.Sessions {
		if sess.Provider != "dsh" || sess.WorkspaceID != wsID {
			t.Fatalf("unexpected imported session: %+v", sess)
		}
	}
}
