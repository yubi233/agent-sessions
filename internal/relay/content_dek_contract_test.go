package relay

import (
	"encoding/json"
	"net/http"
	"testing"
)

// V085-01（ADR-016 §3）：会话内容密钥分发端点契约。home Terminal 上行 wrapped DEK
// 落 device_key_wraps + sessions.content_dek_id；owner 读取只回本设备 wrap；
// 异 dek_id 拒绝（防降级覆盖）；非 home Terminal/非 owner 403；无 DEK 404。
func TestV085ContentDEKUplinkAndOwnerRead(t *testing.T) {
	env := newTestEnv(t)
	owner := env.registerAs(t, "v085-cdek@test.dev")
	terminal := env.pairTerminal(t, owner, "v085-cdek-terminal")
	terminalID := daemonHello(t, env, terminal.AccessToken)
	sessionID, _ := env.createBoundSession(t, owner, terminalID, "v085-cdek")

	// registerAs 不返回设备 id：查 /v1/devices 取 bootstrap 的 android_owner 设备。
	ownerDeviceID := firstOwnerDeviceID(t, env, owner.AccessToken)
	if ownerDeviceID == "" {
		t.Fatal("owner device missing")
	}
	wrapped := []byte("fixture-wrapped-dek-bytes-0123456789abcdef")
	upload := env.do(t, http.MethodPut, "/v1/daemon/sessions/"+sessionID+"/content-dek", map[string]any{
		"protocol_version": 1, "dek_id": "dek_v085_a", "wrapped_dek": wrapped,
		"recipient_device_id": ownerDeviceID,
	}, terminal.AccessToken)
	if upload.Code != http.StatusOK {
		t.Fatalf("upload status=%d body=%s", upload.Code, upload.Body.String())
	}

	// owner 读取本设备 wrap：只回自己、dek_id 一致。
	read := env.do(t, http.MethodGet, "/v1/sessions/"+sessionID+"/content-dek", nil, owner.AccessToken)
	if read.Code != http.StatusOK {
		t.Fatalf("owner read status=%d body=%s", read.Code, read.Body.String())
	}
	var view struct {
		DEKID       string `json:"dek_id"`
		RecipientID string `json:"recipient_device_id"`
		WrappedDEK  []byte `json:"wrapped_dek"`
	}
	if err := json.Unmarshal(read.Body.Bytes(), &view); err != nil {
		t.Fatalf("decode read: %v body=%s", err, read.Body.String())
	}
	if view.DEKID != "dek_v085_a" || view.RecipientID != ownerDeviceID || string(view.WrappedDEK) != string(wrapped) {
		t.Fatalf("unexpected content dek view: %+v", view)
	}

	// 幂等：同 dek_id 重放放行。
	retry := env.do(t, http.MethodPut, "/v1/daemon/sessions/"+sessionID+"/content-dek", map[string]any{
		"protocol_version": 1, "dek_id": "dek_v085_a", "wrapped_dek": wrapped,
		"recipient_device_id": ownerDeviceID,
	}, terminal.AccessToken)
	if retry.Code != http.StatusOK {
		t.Fatalf("retry status=%d body=%s", retry.Code, retry.Body.String())
	}

	// 异 dek_id 拒绝（防降级覆盖）。
	conflict := env.do(t, http.MethodPut, "/v1/daemon/sessions/"+sessionID+"/content-dek", map[string]any{
		"protocol_version": 1, "dek_id": "dek_v085_b", "wrapped_dek": wrapped,
		"recipient_device_id": ownerDeviceID,
	}, terminal.AccessToken)
	if conflict.Code != http.StatusConflict {
		t.Fatalf("conflict status=%d body=%s (want 409)", conflict.Code, conflict.Body.String())
	}

	// 非 home Terminal 上行被拒。
	otherTerminal := env.pairTerminal(t, owner, "v085-cdek-other")
	daemonHello(t, env, otherTerminal.AccessToken)
	forbidden := env.do(t, http.MethodPut, "/v1/daemon/sessions/"+sessionID+"/content-dek", map[string]any{
		"protocol_version": 1, "dek_id": "dek_v085_a", "wrapped_dek": wrapped,
		"recipient_device_id": ownerDeviceID,
	}, otherTerminal.AccessToken)
	if forbidden.Code != http.StatusForbidden {
		t.Fatalf("other terminal upload status=%d body=%s", forbidden.Code, forbidden.Body.String())
	}
}

// V085-01b：无 DEK 会话读取 404（fail-closed）；回复其它收件人的 wrap 不回显。
func TestV085ContentDEKMissingAndOtherRecipient(t *testing.T) {
	env := newTestEnv(t)
	owner := env.registerAs(t, "v085-cdek2@test.dev")
	terminal := env.pairTerminal(t, owner, "v085-cdek2-terminal")
	terminalID := daemonHello(t, env, terminal.AccessToken)
	sessionID, _ := env.createBoundSession(t, owner, terminalID, "v085-cdek2")

	// 未上行任何 DEK → owner 读取 404。
	missing := env.do(t, http.MethodGet, "/v1/sessions/"+sessionID+"/content-dek", nil, owner.AccessToken)
	if missing.Code != http.StatusNotFound {
		t.Fatalf("missing status=%d body=%s (want 404)", missing.Code, missing.Body.String())
	}

	// wrap 只发给另一 owner 设备：本设备读取仍 404（不回显其它收件人 wrap）。
	wrapped := []byte("fixture-wrapped-dek-for-other")
	upload := env.do(t, http.MethodPut, "/v1/daemon/sessions/"+sessionID+"/content-dek", map[string]any{
		"protocol_version": 1, "dek_id": "dek_v085_c", "wrapped_dek": wrapped,
		"recipient_device_id": "dev-not-my-device",
	}, terminal.AccessToken)
	if upload.Code != http.StatusForbidden && upload.Code != http.StatusBadRequest {
		t.Fatalf("unknown recipient upload status=%d body=%s", upload.Code, upload.Body.String())
	}
}

// firstOwnerDeviceID 返回账号设备列表里第一个 android_owner 设备 id（bootstrap owner）。
func firstOwnerDeviceID(t *testing.T, env *testEnv, token string) string {
	t.Helper()
	list := env.do(t, http.MethodGet, "/v1/devices", nil, token)
	if list.Code != http.StatusOK {
		t.Fatalf("list devices status=%d", list.Code)
	}
	var body struct {
		Devices []struct {
			ID   string `json:"id"`
			Role string `json:"role"`
		} `json:"devices"`
	}
	if err := json.Unmarshal(list.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode devices: %v", err)
	}
	for _, d := range body.Devices {
		if d.Role == "android_owner" {
			return d.ID
		}
	}
	return ""
}
