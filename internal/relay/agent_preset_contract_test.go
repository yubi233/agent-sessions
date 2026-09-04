package relay

import (
	"encoding/json"
	"net/http"
	"testing"
)

// V085-12：会话级 agent preset 上行与只读投影（v0.8.5 §3.8）。
// Daemon 在会话建立/恢复后把 handle 的 agent preset 快照（_meta 回带）经同一
// 会话元数据上行端点同步到 Relay；sessionView 输出 agent_preset_id，供移动端
// SessionAgentPresetLabel 消费。未 joined 预设的会话保持空字段（客户端如实降级）。
func TestV085SessionAgentPresetUplinkProjection(t *testing.T) {
	env := newTestEnv(t)
	owner := env.registerAs(t, "v085-preset@test.dev")
	terminal := env.pairTerminal(t, owner, "v085-preset-terminal")
	terminalID := daemonHello(t, env, terminal.AccessToken)
	sessionID, _ := env.createBoundSession(t, owner, terminalID, "v085-preset")

	// 会话建立后 Daemon 上行元数据快照：mode + agent preset。
	upload := env.do(t, http.MethodPut, "/v1/daemon/sessions/"+sessionID+"/modes", map[string]any{
		"protocol_version":           1,
		"mode_id":                    "default",
		"agent_preset_id":            "standard",
		"available_permission_modes": []map[string]string{{"id": "default"}},
	}, terminal.AccessToken)
	if upload.Code != http.StatusOK {
		t.Fatalf("upload status=%d body=%s", upload.Code, upload.Body.String())
	}

	// 会话创建/快照响应携带 agent_preset_id（sessionView 投影）。
	snapshot := env.do(t, http.MethodGet, "/v1/sessions/"+sessionID+"/snapshot", nil, owner.AccessToken)
	if snapshot.Code != http.StatusOK {
		t.Fatalf("snapshot status=%d body=%s", snapshot.Code, snapshot.Body.String())
	}
	var body struct {
		Session struct {
			AgentPresetID string `json:"agent_preset_id"`
		} `json:"session"`
	}
	if err := json.Unmarshal(snapshot.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode snapshot: %v body=%s", err, snapshot.Body.String())
	}
	if body.Session.AgentPresetID != "standard" {
		t.Fatalf("snapshot agent_preset_id=%q, want standard", body.Session.AgentPresetID)
	}

	// 未 joined 预设（空串上行=清空）：字段不出现（omitempty）。
	clearUpload := env.do(t, http.MethodPut, "/v1/daemon/sessions/"+sessionID+"/modes", map[string]any{
		"protocol_version":           1,
		"mode_id":                    "default",
		"agent_preset_id":            "",
		"available_permission_modes": []map[string]string{{"id": "default"}},
	}, terminal.AccessToken)
	if clearUpload.Code != http.StatusOK {
		t.Fatalf("clear upload status=%d body=%s", clearUpload.Code, clearUpload.Body.String())
	}
	after := env.do(t, http.MethodGet, "/v1/sessions/"+sessionID+"/snapshot", nil, owner.AccessToken)
	var afterBody struct {
		Session struct {
			AgentPresetID string `json:"agent_preset_id"`
		} `json:"session"`
	}
	if err := json.Unmarshal(after.Body.Bytes(), &afterBody); err != nil {
		t.Fatalf("decode after: %v", err)
	}
	if afterBody.Session.AgentPresetID != "" {
		t.Fatalf("after agent_preset_id=%q, want empty", afterBody.Session.AgentPresetID)
	}
}
