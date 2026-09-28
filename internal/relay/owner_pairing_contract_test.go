// OWN-01/02/05/07（ADR-017 owner 配对加入）HTTP 契约：
//   - 总开关关闭 → 未认证创建端点稳定 403（SCOPE_DENIED）；
//   - 开启 → 创建 201（比对码）→ 单 pending 409 → 现役 owner 批准 →
//     新设备凭 pairing_id 领取令牌 → 既有 owner 设备零变化（OWN-02）；
//   - 撤销第二个 owner 不影响第一个（OWN-05 HTTP 面）。
package relay

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

const ownerPairingPath = "/v1/owner-pairing/requests"

func ownerPairingBody() map[string]any {
	return map[string]any{
		"display_name":          "新加入的测试手机",
		"platform":              "android",
		"identity_public_key":   "own-pair-identity",
		"encryption_public_key": "own-pair-encryption",
	}
}

func jsonBodyReader(body map[string]any) *strings.Reader {
	var sb strings.Builder
	_ = json.NewEncoder(&sb).Encode(body)
	return strings.NewReader(sb.String())
}

// postUnauth 未认证 POST（新设备没有 Relay 凭据，正是被测场景）。
func postUnauth(t *testing.T, env *testEnv, path string, body map[string]any) *httptest.ResponseRecorder {
	t.Helper()
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, path, jsonBodyReader(body))
	env.router.ServeHTTP(rec, req)
	return rec
}

func getUnauth(env *testEnv, path string) *httptest.ResponseRecorder {
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, path, nil)
	env.router.ServeHTTP(rec, req)
	return rec
}

// OWN-07：总开关默认关闭，创建端点必须稳定拒绝（不以无治理端点暴露公网）。
func TestOwnerPairingDisabledByDefault(t *testing.T) {
	env := newTestEnv(t)
	resp := postUnauth(t, env, ownerPairingPath, ownerPairingBody())
	if resp.Code != http.StatusForbidden {
		t.Fatalf("开关关闭应 403: %d %s", resp.Code, resp.Body.String())
	}
}

// OWN-01/02：开启后全流程——创建（比对码）/单 pending 409/批准/领取令牌/
// 既有设备零变化。
func TestOwnerPairingJoinFlowEndToEnd(t *testing.T) {
	t.Setenv("AGENT_SESSIONS_OWNER_PAIRING", "on")
	env := newTestEnv(t)
	owner := env.registerAs(t, "owner-pairing-e2e@test.dev")

	// 1) 未认证创建 → 201 + 比对码。
	resp := postUnauth(t, env, ownerPairingPath, ownerPairingBody())
	if resp.Code != http.StatusCreated {
		t.Fatalf("create status=%d body=%s", resp.Code, resp.Body.String())
	}
	first := decodeJSONMap(t, resp)
	pairingID, _ := first["pairing_id"].(string)
	code, _ := first["compare_code"].(string)
	if pairingID == "" || len(code) != 6 {
		t.Fatalf("create 响应缺 pairing_id/比对码: %s", resp.Body.String())
	}

	// 2) 单 pending：第二个未认证创建必须 409。
	if dup := postUnauth(t, env, ownerPairingPath, ownerPairingBody()); dup.Code != http.StatusConflict {
		t.Fatalf("第二个 pending 应 409: %d %s", dup.Code, dup.Body.String())
	}

	// 3) 现役 owner 批准（既有端点）→ 设备 active + 令牌签发。
	approve := env.do(t, http.MethodPost, "/v1/pairing/requests/"+pairingID+"/approve", nil, owner.AccessToken)
	if approve.Code != http.StatusOK {
		t.Fatalf("approve status=%d body=%s", approve.Code, approve.Body.String())
	}

	// 4) 新设备凭 pairing_id 领取令牌。
	claimed := getUnauth(env, ownerPairingPath+"/"+pairingID)
	if claimed.Code != http.StatusOK {
		t.Fatalf("claim status=%d body=%s", claimed.Code, claimed.Body.String())
	}
	claimedView := decodeJSONMap(t, claimed)
	status, _ := claimedView["status"].(string)
	access, _ := claimedView["access_token"].(string)
	if status != "approved" || access == "" {
		t.Fatalf("领取应返回 approved+令牌: %s", claimed.Body.String())
	}

	// 5) 硬不变量：既有 owner 设备零变化（仍 active），且新设备在册。
	devices := env.do(t, http.MethodGet, "/v1/devices", nil, owner.AccessToken)
	if devices.Code != http.StatusOK {
		t.Fatalf("list devices status=%d", devices.Code)
	}
	// 设备列表按安全边界不回显公钥——按 display_name 与 active 计数断言。
	if !strings.Contains(devices.Body.String(), "新加入的测试手机") {
		t.Fatalf("新 owner 设备应在册: %s", devices.Body.String())
	}
	if n := strings.Count(devices.Body.String(), `"status":"revoked"`); n != 0 {
		t.Fatalf("加入路径不得撤销既有设备: %s", devices.Body.String())
	}

	// 6) 新设备令牌真实可用（owner 权限读取设备清单）。
	asNew := env.do(t, http.MethodGet, "/v1/devices", nil, access)
	if asNew.Code != http.StatusOK {
		t.Fatalf("新设备令牌应可用: %d %s", asNew.Code, asNew.Body.String())
	}
}

// OWN-05 HTTP 面：撤销第二个 owner 不影响第一个。
func TestOwnerPairingRevokeSecondOwnerKeepsFirst(t *testing.T) {
	t.Setenv("AGENT_SESSIONS_OWNER_PAIRING", "on")
	env := newTestEnv(t)
	owner := env.registerAs(t, "owner-pairing-revoke@test.dev")

	resp := postUnauth(t, env, ownerPairingPath, ownerPairingBody())
	if resp.Code != http.StatusCreated {
		t.Fatalf("create status=%d", resp.Code)
	}
	first := decodeJSONMap(t, resp)
	pairingID, _ := first["pairing_id"].(string)

	approve := env.do(t, http.MethodPost, "/v1/pairing/requests/"+pairingID+"/approve", nil, owner.AccessToken)
	if approve.Code != http.StatusOK {
		t.Fatalf("approve status=%d body=%s", approve.Code, approve.Body.String())
	}

	list := env.do(t, http.MethodGet, "/v1/devices", nil, owner.AccessToken)
	newDeviceID := extractDeviceIDByDisplayName(t, list.Body.String(), "新加入的测试手机")
	if newDeviceID == "" {
		t.Fatalf("新设备未在册: %s", list.Body.String())
	}
	revoke := env.do(t, http.MethodDelete, "/v1/devices/"+newDeviceID, nil, owner.AccessToken)
	if revoke.Code != http.StatusNoContent {
		t.Fatalf("revoke status=%d body=%s", revoke.Code, revoke.Body.String())
	}
	after := env.do(t, http.MethodGet, "/v1/devices", nil, owner.AccessToken)
	// 语义断言：新加入的 owner 设备状态转 revoked（行保留）；
	// 首个 owner 设备保持 active（加入路径不得连带撤销）。
	var devicesView struct {
		Devices []struct {
			DisplayName string `json:"display_name"`
			Status      string `json:"status"`
		} `json:"devices"`
	}
	if err := json.Unmarshal([]byte(after.Body.String()), &devicesView); err != nil {
		t.Fatalf("decode devices: %v", err)
	}
	joinedRevoked, firstActive := false, false
	for _, dv := range devicesView.Devices {
		switch dv.DisplayName {
		case "新加入的测试手机":
			joinedRevoked = dv.Status == "revoked"
		case "Android Owner":
			firstActive = dv.Status == "active"
		}
	}
	if !joinedRevoked {
		t.Fatalf("第二个 owner 应已撤销: %s", after.Body.String())
	}
	if !firstActive {
		t.Fatalf("首个 owner 设备不得被连带撤销: %s", after.Body.String())
	}
}

// decodeJSONMap 把响应体解码为 map（测试断言用）。
func decodeJSONMap(t *testing.T, rec *httptest.ResponseRecorder) map[string]any {
	t.Helper()
	var out map[string]any
	body := rec.Body.String()
	if err := json.Unmarshal([]byte(body), &out); err != nil {
		t.Fatalf("decode %q: %v", body[:min(len(body), 200)], err)
	}
	return out
}

func extractDeviceIDByDisplayName(t *testing.T, body, name string) string {
	t.Helper()
	idx := strings.Index(body, `"display_name":"`+name+`"`)
	if idx < 0 {
		return ""
	}
	head := body[:idx]
	last := strings.LastIndex(head, `"id":"`)
	if last < 0 {
		return ""
	}
	rest := head[last+len(`"id":"`):]
	end := strings.Index(rest, `"`)
	if end < 0 {
		return ""
	}
	return rest[:end]
}
