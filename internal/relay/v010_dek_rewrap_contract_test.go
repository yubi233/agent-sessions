// v0.10.0 §5.1（ADR-017 §6）DEK 批量补 wrap 的 Relay 契约：
//   - daemon 端点 GET /v1/daemon/dek-wraps/pending 只列「active android_owner
//     设备 × 有 DEK 会话」中缺失 wrap 的组合（terminal 角色不列）；
//   - wrap 补齐后同一查询收敛为空（对账幂等口径）；
//   - owner（非 terminal）不能访问 daemon 端点。
package relay

import (
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/yubi233/agent-sessions/internal/store"
)

// storeKeyWrap 构造一行 fixture wrap（wrapped 内容对本契约不重要：只验存在性）。
func storeKeyWrap(dekID, recipientDeviceID string) store.KeyWrapRow {
	return store.KeyWrapRow{
		DEKID:             dekID,
		RecipientDeviceID: recipientDeviceID,
		SenderDeviceID:    "fixture-sender",
		WrappedDEK:        []byte("fixture-wrapped-dek-bytes"),
		CreatedAt:         time.Now(),
	}
}

// upsertSessionDEKFixture 为会话登记 content_dek_id 并给指定设备预置一行 wrap。
func upsertSessionDEKFixture(t *testing.T, env *testEnv, sessionID, deviceID string) {
	t.Helper()
	dekID := "dek-" + sessionID
	if err := env.repo.SetSessionContentDEK(t.Context(), sessionID, dekID); err != nil {
		t.Fatalf("set session dek id: %v", err)
	}
	if deviceID == "" {
		return
	}
	if err := env.repo.PutKeyWrap(t.Context(), storeKeyWrap(dekID, deviceID)); err != nil {
		t.Fatalf("seed key wrap: %v", err)
	}
}

// joinSecondOwnerDevice 经 owner 配对批准路径产生第二个 active android_owner，
// 返回其设备 id（加密公钥由请求体带给 Relay，approve 只签发 claim 令牌）。
// 注意：AGENT_SESSIONS_OWNER_PAIRING 需由调用方在 newTestEnv 之前 Setenv——
// 开关在路由装配时读取。
func joinSecondOwnerDevice(t *testing.T, env *testEnv, owner authPair, name string) string {
	t.Helper()
	resp := postUnauth(t, env, ownerPairingPath, map[string]any{
		"display_name":          name,
		"platform":              "android",
		"identity_public_key":   "idk-" + name,
		"encryption_public_key": "ekk-" + name,
	})
	if resp.Code != http.StatusCreated {
		t.Fatalf("owner pairing create status=%d body=%s", resp.Code, resp.Body.String())
	}
	view := decodeJSONMap(t, resp)
	pairingID, _ := view["pairing_id"].(string)
	if pairingID == "" {
		t.Fatalf("pairing id missing: %s", resp.Body.String())
	}
	approve := env.do(t, http.MethodPost, "/v1/pairing/requests/"+pairingID+"/approve", nil, owner.AccessToken)
	if approve.Code != http.StatusOK {
		t.Fatalf("approve owner pairing status=%d body=%s", approve.Code, approve.Body.String())
	}
	devices := env.do(t, http.MethodGet, "/v1/devices", nil, owner.AccessToken)
	if devices.Code != http.StatusOK {
		t.Fatalf("list devices status=%d body=%s", devices.Code, devices.Body.String())
	}
	var listed struct {
		Devices []struct {
			ID   string `json:"id"`
			Role string `json:"role"`
			Name string `json:"display_name"`
		} `json:"devices"`
	}
	decodeW1(t, devices.Body.Bytes(), &listed)
	for _, device := range listed.Devices {
		if device.Name == name && device.Role == "android_owner" {
			return device.ID
		}
	}
	t.Fatalf("second owner device %s not active in list: %s", name, devices.Body.String())
	return ""
}

// DEKW-01：pending 清单只列缺失组合；补齐后收敛为空；terminal 角色不列。
func TestDaemonPendingDEKWrapsListsMissingOnly(t *testing.T) {
	// 开关在路由装配时读取，必须先于 newTestEnv 设置。
	t.Setenv("AGENT_SESSIONS_OWNER_PAIRING", "on")
	env := newTestEnv(t)
	owner := env.registerAs(t, "dek-rewrap@test.dev")
	terminal := env.pairTerminal(t, owner, "dek-recon-terminal")
	terminalID := daemonHello(t, env, terminal.AccessToken)
	sessionID, _ := env.createBoundSession(t, owner, terminalID, "dek-recon")

	// 会话已有 DEK。注册制首 owner 设备无密钥材料（encryption_public_key 空），
	// 不进清单——空公钥设备无法 wrap，属 fail-safe 排除口径。
	upsertSessionDEKFixture(t, env, sessionID, "")
	secondOwnerID := joinSecondOwnerDevice(t, env, owner, "OWN06-Joiner-B")

	pending := env.do(t, http.MethodGet, "/v1/daemon/dek-wraps/pending", nil, terminal.AccessToken)
	if pending.Code != http.StatusOK {
		t.Fatalf("pending status=%d body=%s", pending.Code, pending.Body.String())
	}
	body := pending.Body.String()
	if !strings.Contains(body, `"session_id":"`+sessionID+`"`) ||
		!strings.Contains(body, `"device_id":"`+secondOwnerID+`"`) ||
		!strings.Contains(body, `"dek_id":"dek-`+sessionID+`"`) {
		t.Fatalf("pending 应只含新 owner 缺失组合: %s", body)
	}
	if strings.Contains(body, terminal.DeviceID) {
		t.Fatalf("terminal 角色设备不应出现在清单: %s", body)
	}

	// 对账收敛：补上该行后清单为空。
	if err := env.repo.PutKeyWrap(t.Context(), storeKeyWrap("dek-"+sessionID, secondOwnerID)); err != nil {
		t.Fatalf("put second owner wrap: %v", err)
	}
	after := env.do(t, http.MethodGet, "/v1/daemon/dek-wraps/pending", nil, terminal.AccessToken)
	if after.Code != http.StatusOK || !strings.Contains(after.Body.String(), `"pending":[]`) {
		t.Fatalf("补齐后应收敛为空: %d %s", after.Code, after.Body.String())
	}
}

// DEKW-02：owner 认证态不能访问 daemon 端点（Terminal 范围隔离）。
func TestDaemonPendingDEKWrapsRejectsOwnerToken(t *testing.T) {
	env := newTestEnv(t)
	owner := env.registerAs(t, "dek-rewrap-owner@test.dev")
	denied := env.do(t, http.MethodGet, "/v1/daemon/dek-wraps/pending", nil, owner.AccessToken)
	if denied.Code != http.StatusForbidden {
		t.Fatalf("owner 访问 daemon 端点应 403: %d %s", denied.Code, denied.Body.String())
	}
}
