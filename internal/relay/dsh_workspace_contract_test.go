package relay

import (
	"encoding/base64"
	"encoding/json"
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

	// 显式历史发现才创建导入命令；缺省同步在无受管会话时不唤醒 Daemon。
	importReq := env.do(t, http.MethodPost, "/v1/workspaces/import-dsh", map[string]any{"workspace_id": wsID, "discover": true}, owner.AccessToken)
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

	// 历史候选不得进入默认列表；只有显式历史入口能看到。
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
	if len(sessionList.Sessions) != 0 {
		t.Fatalf("历史候选不得进入默认列表: %+v", sessionList.Sessions)
	}
	var historyList struct {
		Sessions []struct {
			ID          string `json:"id"`
			Provider    string `json:"provider"`
			WorkspaceID string `json:"workspace_id"`
			Origin      string `json:"origin"`
			Visibility  string `json:"visibility"`
		} `json:"sessions"`
	}
	decodeW1(t, env.do(t, http.MethodGet, "/v1/sessions?history=true", nil, owner.AccessToken).Body.Bytes(), &historyList)
	if len(historyList.Sessions) != 2 {
		t.Fatalf("expected 2 history candidates, got %+v", historyList.Sessions)
	}
	for _, sess := range historyList.Sessions {
		if sess.Provider != "dsh" || sess.WorkspaceID != wsID {
			t.Fatalf("unexpected imported session: %+v", sess)
		}
		if sess.Origin != "dsh_import" || sess.Visibility != "history" {
			t.Fatalf("历史候选来源/可见性不符: %+v", sess)
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

// V094（2026-09-21 用户需求：对齐 DSH 实际会话——标题+十几条上下文）：导入回执
// 携带展示标题与最近上下文事件（已编码 envelope），Relay 登记会话时一并落库；
// 客户端打开导入会话即可见真实标题与历史正文，不再只是元数据空壳。
func TestV094DSHImportCarriesTitleAndContextEvents(t *testing.T) {
	env := newTestEnv(t)
	owner := env.registerAs(t, "v094-import-context@test.dev")
	terminal := env.pairTerminal(t, owner, "v094-import-context-terminal")
	_ = daemonHelloWithCapabilities(t, env, terminal.AccessToken, []string{"dsh_workspace_sync", "dsh_session_import"})

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
			ID string `json:"id"`
		} `json:"workspaces"`
	}
	decodeW1(t, env.do(t, http.MethodGet, "/v1/workspaces", nil, owner.AccessToken).Body.Bytes(), &list)
	wsID := list.Workspaces[0].ID

	importReq := env.do(t, http.MethodPost, "/v1/workspaces/import-dsh", map[string]any{"workspace_id": wsID, "discover": true}, owner.AccessToken)
	var importState struct {
		CommandID string `json:"command_id"`
	}
	decodeW1(t, importReq.Body.Bytes(), &importState)
	_ = env.do(t, http.MethodPost, "/v1/daemon/commands/"+importState.CommandID+"/ack", map[string]any{
		"protocol_version": 1, "delivery_seq": 2, "ack_kind": "started",
	}, terminal.AccessToken)

	// localdev fixture envelope：与 daemon 本地明文链路同构，客户端可直接渲染。
	envelope := func(text string) string {
		payload := map[string]any{"kind": "user_message", "label": "你", "text": text, "copy_text": text}
		inner, _ := json.Marshal(map[string]any{"fixture_payload": payload})
		// 顶层 fixture_payload 与 ciphertext 内层保持同一载荷（与 LocalDevEventEncoder 一致）。
		raw, _ := json.Marshal(map[string]any{
			"alg": "local-dev-fixture", "key_id": "local-dev", "nonce": "local-dev",
			"ciphertext": base64.StdEncoding.EncodeToString(inner), "aad_hash": "local-dev", "payload_version": 1,
			"fixture_payload": payload,
		})
		return string(raw)
	}

	result := env.do(t, http.MethodPost, "/v1/daemon/commands/"+importState.CommandID+"/dsh-import-result", map[string]any{
		"protocol_version": 1, "delivery_seq": 2,
		"session_ids":    []string{"sess_v094_ctx_1", "sess_v094_ctx_2"},
		"session_titles": []string{"真实标题：统计脚本", ""},
		"session_context": []map[string]any{
			{"session_id": "sess_v094_ctx_1", "events": []map[string]any{
				{"event_id": "evt-ctx-1", "event_type": "user.message",
					"envelope": envelope("第一条历史消息"), "created_at_unix_ms": 1789965000000},
				{"event_id": "evt-ctx-2", "event_type": "message.completed",
					"envelope": envelope("已完成的历史回答"), "created_at_unix_ms": 1789965001000},
			}},
		},
		"status": "succeeded",
	}, terminal.AccessToken)
	if result.Code != http.StatusOK {
		t.Fatalf("import result status=%d body=%s", result.Code, result.Body.String())
	}

	// 标题断言走历史候选列表：新发现的历史不进默认列表（v0.9.6 展示边界）。
	sessions := env.do(t, http.MethodGet, "/v1/sessions?history=true", nil, owner.AccessToken)
	var sessionList struct {
		Sessions []struct {
			ID          string `json:"id"`
			DisplayName string `json:"display_name"`
		} `json:"sessions"`
	}
	decodeW1(t, sessions.Body.Bytes(), &sessionList)
	titles := map[string]string{}
	for _, sess := range sessionList.Sessions {
		titles[sess.ID] = sess.DisplayName
	}
	if titles["sess_v094_ctx_1"] != "真实标题：统计脚本" {
		t.Fatalf("会话标题应随导入落库: %q", titles["sess_v094_ctx_1"])
	}
	if titles["sess_v094_ctx_2"] != "" {
		t.Fatalf("无标题会话应为空串（客户端 id 回退）: %q", titles["sess_v094_ctx_2"])
	}

	// 上下文事件落在导入会话的 snapshot 事件流里，正文可渲染。
	snapshot := env.do(t, http.MethodGet, "/v1/sessions/sess_v094_ctx_1/snapshot?after_seq=0", nil, owner.AccessToken)
	if snapshot.Code != http.StatusOK {
		t.Fatalf("snapshot status=%d body=%s", snapshot.Code, snapshot.Body.String())
	}
	var snapView struct {
		Events []struct {
			EventType string `json:"event_type"`
			// envelope 在快照投影中是字符串化 JSON，需要二次解析。
			Envelope string `json:"envelope"`
		} `json:"events"`
	}
	decodeW1(t, snapshot.Body.Bytes(), &snapView)
	texts := map[string]string{}
	for _, event := range snapView.Events {
		var envelope struct {
			FixturePayload struct {
				Kind string `json:"kind"`
				Text string `json:"text"`
			} `json:"fixture_payload"`
		}
		if err := json.Unmarshal([]byte(event.Envelope), &envelope); err != nil {
			t.Fatalf("解析 envelope: %v", err)
		}
		texts[event.EventType] = envelope.FixturePayload.Text
	}
	if texts["user.message"] != "第一条历史消息" {
		t.Fatalf("上下文 user.message 正文缺失: %+v", texts)
	}
	if texts["message.completed"] != "已完成的历史回答" {
		t.Fatalf("上下文 message.completed 正文缺失: %+v", texts)
	}
	// 无上下文的导入会话（sess_v094_ctx_2）事件流保持为空，不得串写。
	emptySnapshot := env.do(t, http.MethodGet, "/v1/sessions/sess_v094_ctx_2/snapshot?after_seq=0", nil, owner.AccessToken)
	var emptyView struct {
		Events []struct{} `json:"events"`
	}
	decodeW1(t, emptySnapshot.Body.Bytes(), &emptyView)
	if len(emptyView.Events) != 0 {
		t.Fatalf("无上下文会话不得串入事件: %+v", emptyView.Events)
	}
}

// v0.9.6 展示边界端到端：历史候选显式接续（manage）后才进入默认列表；缺省
// 同步受服务端允许列表约束，未接续的历史与陌生会话都不得借同步回执混入。
func TestDSHHistoryManagePromotesAndSyncAllowlistDeniesUnknown(t *testing.T) {
	env := newTestEnv(t)
	owner := env.registerAs(t, "v096-manage@test.dev")
	terminal := env.pairTerminal(t, owner, "v096-manage-terminal")
	_ = daemonHelloWithCapabilities(t, env, terminal.AccessToken, []string{"dsh_workspace_sync", "dsh_session_import"})

	sync := env.do(t, http.MethodPost, "/v1/workspaces/sync-dsh", map[string]any{}, owner.AccessToken)
	var syncState struct {
		CommandID string `json:"command_id"`
	}
	decodeW1(t, sync.Body.Bytes(), &syncState)
	_ = env.do(t, http.MethodPost, "/v1/daemon/commands/"+syncState.CommandID+"/dsh-workspace-result", map[string]any{
		"protocol_version": 1, "delivery_seq": 1,
		"candidates": []map[string]string{{"canonical_root": "/Users/test/code/manage-proj", "display_name": "manage-proj"}},
		"status":     "succeeded",
	}, terminal.AccessToken)
	var list struct {
		Workspaces []struct {
			ID string `json:"id"`
		} `json:"workspaces"`
	}
	decodeW1(t, env.do(t, http.MethodGet, "/v1/workspaces", nil, owner.AccessToken).Body.Bytes(), &list)
	wsID := list.Workspaces[0].ID

	// 显式发现一条历史候选。
	importReq := env.do(t, http.MethodPost, "/v1/workspaces/import-dsh", map[string]any{"workspace_id": wsID, "discover": true}, owner.AccessToken)
	var importState struct {
		CommandID string `json:"command_id"`
	}
	decodeW1(t, importReq.Body.Bytes(), &importState)
	_ = env.do(t, http.MethodPost, "/v1/daemon/commands/"+importState.CommandID+"/ack", map[string]any{
		"protocol_version": 1, "delivery_seq": 2, "ack_kind": "started",
	}, terminal.AccessToken)
	result := env.do(t, http.MethodPost, "/v1/daemon/commands/"+importState.CommandID+"/dsh-import-result", map[string]any{
		"protocol_version": 1, "delivery_seq": 2,
		"session_ids": []string{"sess_hist_manage"},
		"status":      "succeeded",
	}, terminal.AccessToken)
	if result.Code != http.StatusOK {
		t.Fatalf("discover result status=%d body=%s", result.Code, result.Body.String())
	}

	countSessions := func(path string) int {
		t.Helper()
		var view struct {
			Sessions []struct {
				ID         string `json:"id"`
				Visibility string `json:"visibility"`
				Origin     string `json:"origin"`
			} `json:"sessions"`
		}
		decodeW1(t, env.do(t, http.MethodGet, path, nil, owner.AccessToken).Body.Bytes(), &view)
		return len(view.Sessions)
	}
	if got := countSessions("/v1/sessions"); got != 0 {
		t.Fatalf("接续前默认列表应为空: %d", got)
	}
	if got := countSessions("/v1/sessions?history=true"); got != 1 {
		t.Fatalf("接续前历史候选应为 1: %d", got)
	}

	// 显式接续：history -> default，origin 保持 dsh_import；幂等可重复。
	for i := 0; i < 2; i++ {
		managed := env.do(t, http.MethodPost, "/v1/sessions/sess_hist_manage/manage", map[string]any{}, owner.AccessToken)
		if managed.Code != http.StatusOK {
			t.Fatalf("manage status=%d body=%s", managed.Code, managed.Body.String())
		}
		var manageView struct {
			Session struct {
				ID         string `json:"id"`
				Origin     string `json:"origin"`
				Visibility string `json:"visibility"`
			} `json:"session"`
		}
		decodeW1(t, managed.Body.Bytes(), &manageView)
		if manageView.Session.ID != "sess_hist_manage" || manageView.Session.Origin != "dsh_import" || manageView.Session.Visibility != "default" {
			t.Fatalf("接续响应不符: %+v", manageView.Session)
		}
	}
	if got := countSessions("/v1/sessions"); got != 1 {
		t.Fatalf("接续后默认列表应为 1: %d", got)
	}
	if got := countSessions("/v1/sessions?history=true"); got != 0 {
		t.Fatalf("接续后历史候选应为空: %d", got)
	}

	// 缺省同步只允许受管会话；混入陌生会话的回执整体拒绝，且不落库。
	syncImport := env.do(t, http.MethodPost, "/v1/workspaces/import-dsh", map[string]any{"workspace_id": wsID}, owner.AccessToken)
	var syncImportState struct {
		CommandID string `json:"command_id"`
	}
	decodeW1(t, syncImport.Body.Bytes(), &syncImportState)
	if syncImportState.CommandID == "" {
		t.Fatalf("存在受管会话时缺省同步应创建命令: %s", syncImport.Body.String())
	}
	_ = env.do(t, http.MethodPost, "/v1/daemon/commands/"+syncImportState.CommandID+"/ack", map[string]any{
		"protocol_version": 1, "delivery_seq": 3, "ack_kind": "started",
	}, terminal.AccessToken)
	syncResult := env.do(t, http.MethodPost, "/v1/daemon/commands/"+syncImportState.CommandID+"/dsh-import-result", map[string]any{
		"protocol_version": 1, "delivery_seq": 3,
		"session_ids": []string{"sess_hist_manage", "sess_intruder"},
		"status":      "succeeded",
	}, terminal.AccessToken)
	if syncResult.Code != http.StatusForbidden {
		t.Fatalf("同步回执混入陌生会话应 403: status=%d body=%s", syncResult.Code, syncResult.Body.String())
	}
	if got := countSessions("/v1/sessions"); got != 1 {
		t.Fatalf("被拒回执不得改动默认列表: %d", got)
	}
	if got := countSessions("/v1/sessions?history=true"); got != 0 {
		t.Fatalf("被拒回执不得登记新历史: %d", got)
	}
}

// v0.9.6 回执幂等端到端：导入事件的稳定 event_id 允许跨命令重试去重；
// 同一 event_id 绑定其他会话必须拒绝。
func TestDSHImportEventReceiptsDedupAcrossCommands(t *testing.T) {
	env := newTestEnv(t)
	owner := env.registerAs(t, "v096-dedup@test.dev")
	terminal := env.pairTerminal(t, owner, "v096-dedup-terminal")
	_ = daemonHelloWithCapabilities(t, env, terminal.AccessToken, []string{"dsh_workspace_sync", "dsh_session_import"})

	sync := env.do(t, http.MethodPost, "/v1/workspaces/sync-dsh", map[string]any{}, owner.AccessToken)
	var syncState struct {
		CommandID string `json:"command_id"`
	}
	decodeW1(t, sync.Body.Bytes(), &syncState)
	_ = env.do(t, http.MethodPost, "/v1/daemon/commands/"+syncState.CommandID+"/dsh-workspace-result", map[string]any{
		"protocol_version": 1, "delivery_seq": 1,
		"candidates": []map[string]string{{"canonical_root": "/Users/test/code/dedup-proj", "display_name": "dedup-proj"}},
		"status":     "succeeded",
	}, terminal.AccessToken)
	var list struct {
		Workspaces []struct {
			ID string `json:"id"`
		} `json:"workspaces"`
	}
	decodeW1(t, env.do(t, http.MethodGet, "/v1/workspaces", nil, owner.AccessToken).Body.Bytes(), &list)
	wsID := list.Workspaces[0].ID

	envelope := func(text string) string {
		payload := map[string]any{"kind": "user_message", "label": "你", "text": text, "copy_text": text}
		inner, _ := json.Marshal(map[string]any{"fixture_payload": payload})
		raw, _ := json.Marshal(map[string]any{
			"alg": "local-dev-fixture", "key_id": "local-dev", "nonce": "local-dev",
			"ciphertext": base64.StdEncoding.EncodeToString(inner), "aad_hash": "local-dev", "payload_version": 1,
			"fixture_payload": payload,
		})
		return string(raw)
	}
	discoverImport := func(deliverySeq int64) string {
		t.Helper()
		importReq := env.do(t, http.MethodPost, "/v1/workspaces/import-dsh", map[string]any{"workspace_id": wsID, "discover": true}, owner.AccessToken)
		var state struct {
			CommandID string `json:"command_id"`
		}
		decodeW1(t, importReq.Body.Bytes(), &state)
		if state.CommandID == "" {
			t.Fatalf("discover import 应创建命令: %s", importReq.Body.String())
		}
		_ = env.do(t, http.MethodPost, "/v1/daemon/commands/"+state.CommandID+"/ack", map[string]any{
			"protocol_version": 1, "delivery_seq": deliverySeq, "ack_kind": "started",
		}, terminal.AccessToken)
		return state.CommandID
	}

	first := discoverImport(2)
	result := env.do(t, http.MethodPost, "/v1/daemon/commands/"+first+"/dsh-import-result", map[string]any{
		"protocol_version": 1, "delivery_seq": 2,
		"session_ids": []string{"sess_dedup"},
		"session_context": []map[string]any{
			{"session_id": "sess_dedup", "events": []map[string]any{
				{"event_id": "evt-dup-1", "event_type": "user.message",
					"envelope": envelope("去重验证消息"), "created_at_unix_ms": 1789965000000},
			}},
		},
		"status": "succeeded",
	}, terminal.AccessToken)
	if result.Code != http.StatusOK {
		t.Fatalf("first result status=%d body=%s", result.Code, result.Body.String())
	}

	// 第二条导入命令重放同一事件 ID：幂等收口，事件不重复。
	second := discoverImport(3)
	retry := env.do(t, http.MethodPost, "/v1/daemon/commands/"+second+"/dsh-import-result", map[string]any{
		"protocol_version": 1, "delivery_seq": 3,
		"session_ids": []string{"sess_dedup"},
		"session_context": []map[string]any{
			{"session_id": "sess_dedup", "events": []map[string]any{
				{"event_id": "evt-dup-1", "event_type": "user.message",
					"envelope": envelope("去重验证消息"), "created_at_unix_ms": 1789965000000},
			}},
		},
		"status": "succeeded",
	}, terminal.AccessToken)
	if retry.Code != http.StatusOK {
		t.Fatalf("跨命令重试应幂等: status=%d body=%s", retry.Code, retry.Body.String())
	}
	snapshot := env.do(t, http.MethodGet, "/v1/sessions/sess_dedup/snapshot?after_seq=0", nil, owner.AccessToken)
	var snapView struct {
		Events []struct {
			EventType string `json:"event_type"`
		} `json:"events"`
	}
	decodeW1(t, snapshot.Body.Bytes(), &snapView)
	if len(snapView.Events) != 1 {
		t.Fatalf("重试后事件不得重复: %+v", snapView.Events)
	}

	// 同一 event_id 绑定其他会话：整体拒绝。
	third := discoverImport(4)
	hijack := env.do(t, http.MethodPost, "/v1/daemon/commands/"+third+"/dsh-import-result", map[string]any{
		"protocol_version": 1, "delivery_seq": 4,
		"session_ids": []string{"sess_other"},
		"session_context": []map[string]any{
			{"session_id": "sess_other", "events": []map[string]any{
				{"event_id": "evt-dup-1", "event_type": "user.message",
					"envelope": envelope("越权消息"), "created_at_unix_ms": 1789965000000},
			}},
		},
		"status": "succeeded",
	}, terminal.AccessToken)
	if hijack.Code != http.StatusForbidden {
		t.Fatalf("事件 ID 跨会话复用应 403: status=%d body=%s", hijack.Code, hijack.Body.String())
	}
}
