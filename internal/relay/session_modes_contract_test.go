package relay

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"
)

// V085-07：会话级 permission mode 目录上行契约（v0.8.5 §3.4）。
// 只有拥有该会话的 home Terminal 能上行 mode 快照（签名窗口内 bearer 放行，
// 归属仍按 workspace.TerminalID 校验）；其它 Terminal/账号 fail-closed。
// Relay 只存快照不下发明文，controls 按目录下发 permission_mode 与
// available_permission_modes（空目录不下发字段，客户端维持禁用+原因）。
func TestV085SessionModeCatalogUplinkAndControls(t *testing.T) {
	env := newTestEnv(t)
	owner := env.registerAs(t, "v085-modes@test.dev")
	terminal := env.pairTerminal(t, owner, "v085-modes-terminal")
	terminalID := daemonHello(t, env, terminal.AccessToken)
	sessionID, _ := env.createBoundSession(t, owner, terminalID, "v085-modes")

	// 归属 Terminal 上行目录快照。
	upload := env.do(t, http.MethodPut, "/v1/daemon/sessions/"+sessionID+"/modes", map[string]any{
		"protocol_version": 1,
		"mode_id":          "default",
		"available_permission_modes": []map[string]string{
			{"id": "default", "name": "默认", "description": "标准权限"},
			{"id": "acceptEdits", "name": "自动接受编辑", "description": "接受文件编辑"},
			{"id": "danger-full-access", "name": "完整访问", "description": "无限制"},
		},
	}, terminal.AccessToken)
	if upload.Code != http.StatusOK {
		t.Fatalf("modes upload status=%d body=%s", upload.Code, upload.Body.String())
	}

	// 其它 Terminal 不能上行同一会话（home Terminal 归属 fail-closed）。
	otherTerminal := env.pairTerminal(t, owner, "v085-modes-other")
	daemonHello(t, env, otherTerminal.AccessToken)
	forbidden := env.do(t, http.MethodPut, "/v1/daemon/sessions/"+sessionID+"/modes", map[string]any{
		"protocol_version":           1,
		"mode_id":                    "default",
		"available_permission_modes": []map[string]string{{"id": "default"}},
	}, otherTerminal.AccessToken)
	if forbidden.Code != http.StatusForbidden {
		t.Fatalf("other terminal upload status=%d body=%s", forbidden.Code, forbidden.Body.String())
	}

	// controls 下发会话级目录（owner 读取）。
	controls := env.do(t, http.MethodGet, "/v1/sessions/"+sessionID+"/controls", nil, owner.AccessToken)
	if controls.Code != http.StatusOK {
		t.Fatalf("controls status=%d body=%s", controls.Code, controls.Body.String())
	}
	var body struct {
		PermissionMode           string   `json:"permission_mode"`
		AvailablePermissionModes []string `json:"available_permission_modes"`
	}
	if err := json.Unmarshal(controls.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode controls: %v body=%s", err, controls.Body.String())
	}
	if body.PermissionMode != "default" {
		t.Fatalf("controls permission_mode=%q, want default", body.PermissionMode)
	}
	if len(body.AvailablePermissionModes) != 3 {
		t.Fatalf("controls available_permission_modes=%v", body.AvailablePermissionModes)
	}

	// 目录快照不下发 canonical root / 明文正文（安全投影）。
	if strings.Contains(controls.Body.String(), "canonical_root") {
		t.Fatalf("controls leaked path: %s", controls.Body.String())
	}

	// 无 mode 快照的会话：controls 不下发 mode 字段（客户端维持禁用+原因）。
	plainID, _ := env.createBoundSession(t, owner, terminalID, "v085-modes-plain")
	plainControls := env.do(t, http.MethodGet, "/v1/sessions/"+plainID+"/controls", nil, owner.AccessToken)
	if plainControls.Code != http.StatusOK {
		t.Fatalf("plain controls status=%d body=%s", plainControls.Code, plainControls.Body.String())
	}
	var plain struct {
		PermissionMode string `json:"permission_mode"`
	}
	_ = json.Unmarshal(plainControls.Body.Bytes(), &plain)
	if plain.PermissionMode != "" {
		t.Fatalf("plain controls unexpectedly has permission_mode=%q", plain.PermissionMode)
	}
}

// V085-08：mode.set 命令后目录更新——Daemon 在 setMode 成功后把最新目录快照
// 同步到 Relay，下一次 controls 读取即反映新 mode（run-mode 事实来自 handle）。
func TestV085SessionModeSelectRefreshesControls(t *testing.T) {
	env := newTestEnv(t)
	owner := env.registerAs(t, "v085-mode-select@test.dev")
	terminal := env.pairTerminal(t, owner, "v085-mode-select-terminal")
	terminalID := daemonHello(t, env, terminal.AccessToken)
	sessionID, _ := env.createBoundSession(t, owner, terminalID, "v085-mode-select")

	upload := env.do(t, http.MethodPut, "/v1/daemon/sessions/"+sessionID+"/modes", map[string]any{
		"protocol_version": 1,
		"mode_id":          "default",
		"available_permission_modes": []map[string]string{
			{"id": "default"},
			{"id": "acceptEdits"},
		},
	}, terminal.AccessToken)
	if upload.Code != http.StatusOK {
		t.Fatalf("upload status=%d body=%s", upload.Code, upload.Body.String())
	}

	// 模拟 setMode 成功后的第二次上行：mode_id 变为 acceptEdits。
	refresh := env.do(t, http.MethodPut, "/v1/daemon/sessions/"+sessionID+"/modes", map[string]any{
		"protocol_version": 1,
		"mode_id":          "acceptEdits",
		"available_permission_modes": []map[string]string{
			{"id": "default"},
			{"id": "acceptEdits"},
		},
	}, terminal.AccessToken)
	if refresh.Code != http.StatusOK {
		t.Fatalf("refresh status=%d body=%s", refresh.Code, refresh.Body.String())
	}

	controls := env.do(t, http.MethodGet, "/v1/sessions/"+sessionID+"/controls", nil, owner.AccessToken)
	var body struct {
		PermissionMode string `json:"permission_mode"`
	}
	if err := json.Unmarshal(controls.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode controls: %v", err)
	}
	if body.PermissionMode != "acceptEdits" {
		t.Fatalf("controls permission_mode=%q, want acceptEdits", body.PermissionMode)
	}
}
