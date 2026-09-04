package relay

import (
	"net/http"
	"slices"
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
	started := env.do(t, http.MethodPost, "/v1/daemon/commands/"+submitted.CommandID+"/ack", map[string]any{
		"protocol_version": 1, "delivery_seq": 1, "ack_kind": "started",
	}, terminal.AccessToken)
	if started.Code != http.StatusOK {
		t.Fatalf("dsh sync started ack status=%d body=%s", started.Code, started.Body.String())
	}
	// 模拟 Daemon 已完成扫描并回传专用 result。
	result := env.do(t, http.MethodPost, "/v1/daemon/commands/"+submitted.CommandID+"/dsh-workspace-result", map[string]any{
		"protocol_version": 1,
		"delivery_seq":     1,
		"candidates": []map[string]string{
			{"canonical_root": "/Users/test/code/proj-a", "display_name": "proj-a"},
			{"canonical_root": "/Users/test/code/proj-b", "display_name": "proj-b"},
		},
		"status": "succeeded",
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
			ID          string `json:"id"`
			TerminalID  string `json:"terminal_id"`
			Origin      string `json:"origin"`
			DisplayName string `json:"display_name"`
		} `json:"workspaces"`
	}
	decodeW1(t, list.Body.Bytes(), &listed)
	if len(listed.Workspaces) != 2 {
		t.Fatalf("expected 2 workspaces, got %+v", listed.Workspaces)
	}
	for _, ws := range listed.Workspaces {
		if ws.TerminalID == "" || ws.Origin != "dsh" || (ws.DisplayName != "proj-a" && ws.DisplayName != "proj-b") {
			t.Fatalf("workspace missing home terminal: %+v", ws)
		}
	}

	// 重复 result 幂等，不新增 Workspace。
	repeat := env.do(t, http.MethodPost, "/v1/daemon/commands/"+submitted.CommandID+"/dsh-workspace-result", map[string]any{
		"protocol_version": 1, "delivery_seq": 1,
		"candidates": []map[string]string{
			{"canonical_root": "/Users/test/code/proj-a", "display_name": "proj-a"},
			{"canonical_root": "/Users/test/code/proj-b", "display_name": "proj-b"},
		},
		"status": "succeeded",
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

// V081-10：同步命令已终态后，下一次点击必须创建新的扫描。否则一次历史拒绝会把
// 同账号永久锁在旧 command_id 上，客户端只能不断轮询已失败的结果。
func TestV081DSHWorkspaceSyncRetriesAfterRejectedCommand(t *testing.T) {
	env := newTestEnv(t)
	owner := env.registerAs(t, "v081-dsh-sync-retry@test.dev")
	terminal := env.pairTerminal(t, owner, "v081-dsh-sync-retry-terminal")
	_ = daemonHelloWithCapabilities(t, env, terminal.AccessToken, []string{"dsh_workspace_sync"})

	firstResponse := env.do(t, http.MethodPost, "/v1/workspaces/sync-dsh", map[string]any{}, owner.AccessToken)
	if firstResponse.Code != http.StatusAccepted {
		t.Fatalf("first sync status=%d body=%s", firstResponse.Code, firstResponse.Body.String())
	}
	var first struct {
		CommandID string `json:"command_id"`
	}
	decodeW1(t, firstResponse.Body.Bytes(), &first)
	if first.CommandID == "" {
		t.Fatalf("first sync missing command id: %s", firstResponse.Body.String())
	}
	if rejected := env.do(t, http.MethodPost, "/v1/daemon/commands/"+first.CommandID+"/ack", map[string]any{
		"protocol_version": 1, "delivery_seq": 1, "ack_kind": "rejected", "error_code": "TARGET_STALE",
	}, terminal.AccessToken); rejected.Code != http.StatusOK {
		t.Fatalf("reject first sync status=%d body=%s", rejected.Code, rejected.Body.String())
	}

	secondResponse := env.do(t, http.MethodPost, "/v1/workspaces/sync-dsh", map[string]any{}, owner.AccessToken)
	if secondResponse.Code != http.StatusAccepted {
		t.Fatalf("retry sync status=%d body=%s", secondResponse.Code, secondResponse.Body.String())
	}
	var second struct {
		CommandID string `json:"command_id"`
	}
	decodeW1(t, secondResponse.Body.Bytes(), &second)
	if second.CommandID == "" || second.CommandID == first.CommandID {
		t.Fatalf("retry must create a replacement sync command: first=%q second=%q", first.CommandID, second.CommandID)
	}
	if started := env.do(t, http.MethodPost, "/v1/daemon/commands/"+second.CommandID+"/ack", map[string]any{
		"protocol_version": 1, "delivery_seq": 2, "ack_kind": "started",
	}, terminal.AccessToken); started.Code != http.StatusOK {
		t.Fatalf("replacement started ack status=%d body=%s", started.Code, started.Body.String())
	}
	if resolved := env.do(t, http.MethodPost, "/v1/daemon/commands/"+second.CommandID+"/dsh-workspace-result", map[string]any{
		"protocol_version": 1, "delivery_seq": 2,
		"candidates": []map[string]string{{"canonical_root": "/fixture/retried-project", "display_name": "retried-project"}},
		"status":     "succeeded",
	}, terminal.AccessToken); resolved.Code != http.StatusOK {
		t.Fatalf("replacement dsh sync result status=%d body=%s", resolved.Code, resolved.Body.String())
	}

	oldState := env.do(t, http.MethodGet, "/v1/workspaces/sync-dsh/"+first.CommandID, nil, owner.AccessToken)
	var oldView struct {
		Status string `json:"status"`
	}
	decodeW1(t, oldState.Body.Bytes(), &oldView)
	if oldState.Code != http.StatusOK || oldView.Status != "rejected" {
		t.Fatalf("historical rejected sync must remain observable: status=%d view=%+v", oldState.Code, oldView)
	}
}

// V081-01：私有回执必须拒绝路径式 display name，避免路径经 Workspace 公开投影泄露。
func TestV081DSHWorkspaceResultRejectsUnsafeDisplayName(t *testing.T) {
	env := newTestEnv(t)
	owner := env.registerAs(t, "v081-dsh-display-name@test.dev")
	terminal := env.pairTerminal(t, owner, "v081-dsh-display-name-terminal")
	_ = daemonHelloWithCapabilities(t, env, terminal.AccessToken, []string{"dsh_workspace_sync"})

	sync := env.do(t, http.MethodPost, "/v1/workspaces/sync-dsh", map[string]any{}, owner.AccessToken)
	var state struct {
		CommandID string `json:"command_id"`
	}
	decodeW1(t, sync.Body.Bytes(), &state)
	unsafe := env.do(t, http.MethodPost, "/v1/daemon/commands/"+state.CommandID+"/dsh-workspace-result", map[string]any{
		"protocol_version": 1,
		"delivery_seq":     1,
		"candidates":       []map[string]string{{"canonical_root": "/fixture/project", "display_name": "../project"}},
		"status":           "succeeded",
	}, terminal.AccessToken)
	if unsafe.Code != http.StatusBadRequest || strings.Contains(unsafe.Body.String(), "/fixture/project") {
		t.Fatalf("unsafe display name status=%d body=%s", unsafe.Code, unsafe.Body.String())
	}
	list := env.do(t, http.MethodGet, "/v1/workspaces", nil, owner.AccessToken)
	if list.Code != http.StatusOK || strings.Contains(list.Body.String(), "project") {
		t.Fatalf("unsafe result created or leaked a workspace: %d %s", list.Code, list.Body.String())
	}
}

// V081-09：相同 basename 仍然按 canonical root + home Terminal 保持不同 identity，不能合并。
func TestV081DSHWorkspaceSameDisplayNameKeepsDistinctIdentities(t *testing.T) {
	env := newTestEnv(t)
	owner := env.registerAs(t, "v081-dsh-same-name@test.dev")
	terminal := env.pairTerminal(t, owner, "v081-dsh-same-name-terminal")
	_ = daemonHelloWithCapabilities(t, env, terminal.AccessToken, []string{"dsh_workspace_sync"})
	sync := env.do(t, http.MethodPost, "/v1/workspaces/sync-dsh", map[string]any{}, owner.AccessToken)
	var state struct {
		CommandID string `json:"command_id"`
	}
	decodeW1(t, sync.Body.Bytes(), &state)
	result := env.do(t, http.MethodPost, "/v1/daemon/commands/"+state.CommandID+"/dsh-workspace-result", map[string]any{
		"protocol_version": 1,
		"delivery_seq":     1,
		"candidates": []map[string]string{
			{"canonical_root": "/fixture/one/project", "display_name": "project"},
			{"canonical_root": "/fixture/two/project", "display_name": "project"},
		},
		"status": "succeeded",
	}, terminal.AccessToken)
	if result.Code != http.StatusOK {
		t.Fatalf("sync same-name workspaces: %d %s", result.Code, result.Body.String())
	}
	var list struct {
		Workspaces []struct {
			ID          string `json:"id"`
			Origin      string `json:"origin"`
			DisplayName string `json:"display_name"`
		} `json:"workspaces"`
	}
	decodeW1(t, env.do(t, http.MethodGet, "/v1/workspaces", nil, owner.AccessToken).Body.Bytes(), &list)
	if len(list.Workspaces) != 2 || list.Workspaces[0].ID == list.Workspaces[1].ID {
		t.Fatalf("same display name identities merged: %+v", list)
	}
	for _, workspace := range list.Workspaces {
		if workspace.Origin != "dsh" || workspace.DisplayName != "project" {
			t.Fatalf("unexpected same-name workspace projection: %+v", workspace)
		}
	}
}

// V081-05/06：DSH 建会话的服务端 fence 必须阻断 managed、无 start capability 和离线终端，
// 且所有拒绝发生在 Session 持久化之前。
func TestV081CreateDSHSessionRequiresOriginAndHomeTerminalCapability(t *testing.T) {
	env := newTestEnv(t)
	owner := env.registerAs(t, "v081-dsh-create@test.dev")
	terminal := env.pairTerminal(t, owner, "v081-dsh-create-terminal")
	terminalID := daemonHelloWithCapabilities(t, env, terminal.AccessToken, []string{"dsh_workspace_sync"})

	managed := env.do(t, http.MethodPost, "/v1/workspaces", map[string]any{
		"project_id": "v081-managed", "terminal_id": terminalID, "canonical_root": "/fixture/managed", "status": "active",
	}, owner.AccessToken)
	if managed.Code != http.StatusCreated {
		t.Fatalf("create managed workspace: %d %s", managed.Code, managed.Body.String())
	}
	var managedView struct {
		ID     string `json:"id"`
		Origin string `json:"origin"`
	}
	decodeW1(t, managed.Body.Bytes(), &managedView)
	if managedView.Origin != "managed" {
		t.Fatalf("managed workspace origin=%q", managedView.Origin)
	}
	deniedManaged := env.do(t, http.MethodPost, "/v1/sessions", map[string]any{"workspace_id": managedView.ID, "provider": "dsh"}, owner.AccessToken)
	if deniedManaged.Code != http.StatusForbidden {
		t.Fatalf("managed DSH create status=%d body=%s", deniedManaged.Code, deniedManaged.Body.String())
	}

	sync := env.do(t, http.MethodPost, "/v1/workspaces/sync-dsh", map[string]any{}, owner.AccessToken)
	var syncState struct {
		CommandID string `json:"command_id"`
	}
	decodeW1(t, sync.Body.Bytes(), &syncState)
	result := env.do(t, http.MethodPost, "/v1/daemon/commands/"+syncState.CommandID+"/dsh-workspace-result", map[string]any{
		"protocol_version": 1,
		"delivery_seq":     1,
		"candidates":       []map[string]string{{"canonical_root": "/fixture/dsh-project", "display_name": "dsh-project"}},
		"status":           "succeeded",
	}, terminal.AccessToken)
	if result.Code != http.StatusOK {
		t.Fatalf("sync dsh workspace: %d %s", result.Code, result.Body.String())
	}
	var list struct {
		Workspaces []struct {
			ID     string `json:"id"`
			Origin string `json:"origin"`
		} `json:"workspaces"`
	}
	decodeW1(t, env.do(t, http.MethodGet, "/v1/workspaces", nil, owner.AccessToken).Body.Bytes(), &list)
	var dshWorkspaceID string
	for _, workspace := range list.Workspaces {
		if workspace.Origin == "dsh" {
			dshWorkspaceID = workspace.ID
		}
	}
	if dshWorkspaceID == "" {
		t.Fatalf("missing dsh workspace: %+v", list)
	}

	deniedCapability := env.do(t, http.MethodPost, "/v1/sessions", map[string]any{"workspace_id": dshWorkspaceID, "provider": "dsh"}, owner.AccessToken)
	if deniedCapability.Code != http.StatusConflict {
		t.Fatalf("DSH create without start capability status=%d body=%s", deniedCapability.Code, deniedCapability.Body.String())
	}
	_ = daemonHelloWithCapabilities(t, env, terminal.AccessToken, []string{"dsh_workspace_sync", "start"})
	created := env.do(t, http.MethodPost, "/v1/sessions", map[string]any{"workspace_id": dshWorkspaceID, "provider": "dsh"}, owner.AccessToken)
	if created.Code != http.StatusCreated {
		t.Fatalf("DSH create with start capability status=%d body=%s", created.Code, created.Body.String())
	}
	// 第二台在线且支持 start 的 Terminal 不能代替失联的 home Terminal。
	otherTerminal := env.pairTerminal(t, owner, "v081-dsh-create-other-terminal")
	_ = daemonHelloWithCapabilities(t, env, otherTerminal.AccessToken, []string{"start"})
	if _, err := env.db.Exec(`UPDATE terminals SET status='offline' WHERE id=?`, terminalID); err != nil {
		t.Fatalf("take home terminal offline: %v", err)
	}
	deniedOffline := env.do(t, http.MethodPost, "/v1/sessions", map[string]any{"workspace_id": dshWorkspaceID, "provider": "dsh"}, owner.AccessToken)
	if deniedOffline.Code != http.StatusConflict {
		t.Fatalf("DSH create with offline home terminal status=%d body=%s", deniedOffline.Code, deniedOffline.Body.String())
	}
	var sessions struct {
		Sessions []struct {
			Provider string `json:"provider"`
		} `json:"sessions"`
	}
	decodeW1(t, env.do(t, http.MethodGet, "/v1/sessions", nil, owner.AccessToken).Body.Bytes(), &sessions)
	if len(sessions.Sessions) != 1 || sessions.Sessions[0].Provider != "dsh" {
		t.Fatalf("rejected DSH create persisted a session: %+v", sessions)
	}
}

// V08-08/09：session.import_dsh 只允许 home Terminal 发起，并只返回 opaque session ids。
func TestV08DSHImportAuthorizationAndResult(t *testing.T) {
	env := newTestEnv(t)
	owner := env.registerAs(t, "v08-dsh-import@test.dev")
	terminal := env.pairTerminal(t, owner, "v08-dsh-import-terminal")
	_ = daemonHelloWithCapabilities(t, env, terminal.AccessToken, []string{"dsh_workspace_sync", "dsh_session_import"})
	// 客户端详情页只从 Terminal 安全投影判断导入按钮；漏掉该能力会导致
	// 服务端已支持的导入路径永久不可达。未知能力仍不得借此投影出去。
	var terminals struct {
		Terminals []struct {
			Capabilities []string `json:"capabilities"`
		} `json:"terminals"`
	}
	decodeW1(t, env.do(t, http.MethodGet, "/v1/terminals", nil, owner.AccessToken).Body.Bytes(), &terminals)
	if len(terminals.Terminals) != 1 || !slices.Equal(terminals.Terminals[0].Capabilities, []string{"dsh_session_import", "dsh_workspace_sync"}) {
		t.Fatalf("unexpected public terminal capabilities: %+v", terminals)
	}

	// 先同步一个 DSH Workspace，取得 workspace_id。
	sync := env.do(t, http.MethodPost, "/v1/workspaces/sync-dsh", map[string]any{}, owner.AccessToken)
	var syncState struct {
		CommandID string `json:"command_id"`
	}
	decodeW1(t, sync.Body.Bytes(), &syncState)
	_ = env.do(t, http.MethodPost, "/v1/daemon/commands/"+syncState.CommandID+"/dsh-workspace-result", map[string]any{
		"protocol_version": 1, "delivery_seq": 1,
		"candidates": []map[string]string{{"canonical_root": "/Users/test/code/import-proj", "display_name": "import-proj"}},
		"status":     "succeeded",
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
	startedImport := env.do(t, http.MethodPost, "/v1/daemon/commands/"+importState.CommandID+"/ack", map[string]any{
		"protocol_version": 1, "delivery_seq": 2, "ack_kind": "started",
	}, terminal.AccessToken)
	if startedImport.Code != http.StatusOK {
		t.Fatalf("dsh import started ack status=%d body=%s", startedImport.Code, startedImport.Body.String())
	}

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

// V085-09：DSH 会话列表/快照的 workspace_name 必须由 Relay 从工作区表解析为
// 安全显示名（display_name），而不是下发 workspace_id 或让客户端回退到写死的
// 项目名。会话创建响应与快照都携带该字段（v0.8.5 §3.4 修复 ③ 副标题错名）。
func TestV085SessionViewCarriesWorkspaceDisplayName(t *testing.T) {
	env := newTestEnv(t)
	owner := env.registerAs(t, "v085-ws-name@test.dev")
	terminal := env.pairTerminal(t, owner, "v085-ws-name-terminal")
	_ = daemonHelloWithCapabilities(t, env, terminal.AccessToken, []string{"dsh_workspace_sync", "start"})

	sync := env.do(t, http.MethodPost, "/v1/workspaces/sync-dsh", map[string]any{}, owner.AccessToken)
	var syncState struct {
		CommandID string `json:"command_id"`
	}
	decodeW1(t, sync.Body.Bytes(), &syncState)
	result := env.do(t, http.MethodPost, "/v1/daemon/commands/"+syncState.CommandID+"/dsh-workspace-result", map[string]any{
		"protocol_version": 1,
		"delivery_seq":     1,
		"candidates":       []map[string]string{{"canonical_root": "/fixture/v085-money", "display_name": "money"}},
		"status":           "succeeded",
	}, terminal.AccessToken)
	if result.Code != http.StatusOK {
		t.Fatalf("sync dsh workspace: %d %s", result.Code, result.Body.String())
	}
	var list struct {
		Workspaces []struct {
			ID string `json:"id"`
		} `json:"workspaces"`
	}
	decodeW1(t, env.do(t, http.MethodGet, "/v1/workspaces", nil, owner.AccessToken).Body.Bytes(), &list)
	if len(list.Workspaces) != 1 {
		t.Fatalf("expected 1 workspace: %+v", list)
	}

	created := env.do(t, http.MethodPost, "/v1/sessions", map[string]any{"workspace_id": list.Workspaces[0].ID, "provider": "dsh"}, owner.AccessToken)
	if created.Code != http.StatusCreated {
		t.Fatalf("create DSH session: %d %s", created.Code, created.Body.String())
	}
	var createdView struct {
		ID            string `json:"id"`
		WorkspaceID   string `json:"workspace_id"`
		WorkspaceName string `json:"workspace_name"`
	}
	decodeW1(t, created.Body.Bytes(), &createdView)
	if createdView.WorkspaceName != "money" {
		t.Fatalf("create response workspace_name=%q, want money", createdView.WorkspaceName)
	}

	// 快照（会话详情）同样携带 workspace_name，移动端副标题直接消费。
	snapshot := env.do(t, http.MethodGet, "/v1/sessions/"+createdView.ID+"/snapshot", nil, owner.AccessToken)
	if snapshot.Code != http.StatusOK {
		t.Fatalf("snapshot: %d %s", snapshot.Code, snapshot.Body.String())
	}
	var snap struct {
		Session struct {
			WorkspaceName string `json:"workspace_name"`
		} `json:"session"`
	}
	decodeW1(t, snapshot.Body.Bytes(), &snap)
	if snap.Session.WorkspaceName != "money" {
		t.Fatalf("snapshot workspace_name=%q, want money", snap.Session.WorkspaceName)
	}
}
