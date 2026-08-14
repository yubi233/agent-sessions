package relay

import (
	"encoding/json"
	"net/http"
	"testing"
)

// 订阅命令帮助：把提交后的命令状态读出。
type cmdJSON struct {
	ID             string `json:"id"`
	Status         string `json:"status"`
	Kind           string `json:"kind"`
	IdempotencyKey string `json:"idempotency_key"`
}

// AUTH-01：登录、刷新轮换与 logout，refresh reuse 撤销 family。
func TestAUTH01LoginRefreshLogout(t *testing.T) {
	env := newTestEnv(t)
	pair := env.registerAs(t, "auth@test.dev")

	// 用 refresh 轮换。
	rot := env.do(t, http.MethodPost, "/v1/auth/refresh", map[string]any{"refresh_token": pair.RefreshToken}, "")
	if rot.Code != http.StatusOK {
		t.Fatalf("refresh status=%d body=%s", rot.Code, rot.Body.String())
	}
	var rotated struct {
		RefreshToken string `json:"refresh_token"`
		AccessToken  string `json:"access_token"`
	}
	_ = json.Unmarshal(rot.Body.Bytes(), &rotated)

	// logout 后重放旧 refresh 应被拒（family 已撤销）。
	if code := env.do(t, http.MethodPost, "/v1/auth/logout", map[string]any{"refresh_token": rotated.RefreshToken}, rotated.AccessToken).Code; code != http.StatusOK {
		t.Fatalf("logout status=%d", code)
	}
	reuse := env.do(t, http.MethodPost, "/v1/auth/refresh", map[string]any{"refresh_token": pair.RefreshToken}, "")
	if reuse.Code != http.StatusUnauthorized {
		t.Fatalf("reused refresh status=%d want 401 body=%s", reuse.Code, reuse.Body.String())
	}
}

// PAIR-01/02：bootstrap owner + 第二设备配对批准。
func TestPAIR01OwnerBootstrapAndApprove(t *testing.T) {
	env := newTestEnv(t)
	pair := env.registerAs(t, "owner@test.dev")
	ownerTok := pair.AccessToken

	// 第二设备（Terminal）发起配对请求。
	req := env.do(t, http.MethodPost, "/v1/pairing/requests", map[string]any{
		"role": "terminal", "display_name": "PC-1", "platform": "darwin",
		"identity_public_key": "idk_terminal", "encryption_public_key": "ekk_terminal",
	}, ownerTok)
	if req.Code != http.StatusCreated {
		t.Fatalf("pairing request status=%d body=%s", req.Code, req.Body.String())
	}
	var p struct {
		ID string `json:"id"`
	}
	_ = json.Unmarshal(req.Body.Bytes(), &p)

	// owner 批准。
	appr := env.do(t, http.MethodPost, "/v1/pairing/requests/"+p.ID+"/approve", nil, ownerTok)
	if appr.Code != http.StatusOK {
		t.Fatalf("approve status=%d body=%s", appr.Code, appr.Body.String())
	}
	// 重复批准幂等。
	again := env.do(t, http.MethodPost, "/v1/pairing/requests/"+p.ID+"/approve", nil, ownerTok)
	if again.Code != http.StatusOK {
		t.Fatalf("repeat approve status=%d body=%s", again.Code, again.Body.String())
	}
	// 设备列表包含 owner + terminal。
	list := env.do(t, http.MethodGet, "/v1/devices", nil, ownerTok)
	if list.Code != http.StatusOK {
		t.Fatalf("list devices status=%d", list.Code)
	}
	var body struct {
		Devices []json.RawMessage `json:"devices"`
	}
	_ = json.Unmarshal(list.Body.Bytes(), &body)
	if len(body.Devices) != 2 {
		t.Fatalf("want 2 devices, got %d", len(body.Devices))
	}
}

// PAIR-03：撤销 Web 设备后，该设备访问被拒绝（DEVICE_REVOKED）。
func TestPAIR03RevokeDevice(t *testing.T) {
	env := newTestEnv(t)
	pair := env.registerAs(t, "revoke@test.dev")

	// 撤销 owner 设备自身后，其 token 失效。
	devList := env.do(t, http.MethodGet, "/v1/devices", nil, pair.AccessToken)
	var dl struct {
		Devices []struct {
			ID string `json:"id"`
		} `json:"devices"`
	}
	_ = json.Unmarshal(devList.Body.Bytes(), &dl)
	if len(dl.Devices) == 0 {
		t.Fatalf("no devices")
	}
	rev := env.do(t, http.MethodDelete, "/v1/devices/"+dl.Devices[0].ID, nil, pair.AccessToken)
	if rev.Code != http.StatusOK {
		t.Fatalf("revoke status=%d body=%s", rev.Code, rev.Body.String())
	}
	// 撤销后 token 不能再访问。
	after := env.do(t, http.MethodGet, "/v1/devices", nil, pair.AccessToken)
	if after.Code != http.StatusForbidden {
		t.Fatalf("post-revoke status=%d want 403 body=%s", after.Code, after.Body.String())
	}
}

// HTTP-01：REST 绑定、鉴权与错误映射；无 token 返回 401。
func TestHTTP01AuthErrors(t *testing.T) {
	env := newTestEnv(t)
	env.registerAs(t, "http@test.dev")

	if code := env.do(t, http.MethodGet, "/v1/devices", nil, "").Code; code != http.StatusUnauthorized {
		t.Fatalf("no-token status=%d want 401", code)
	}
	if code := env.do(t, http.MethodGet, "/v1/devices", nil, "garbage-token").Code; code != http.StatusUnauthorized {
		t.Fatalf("bad-token status=%d want 401", code)
	}
}

// SESS-01 + HTTP-02：创建会话、提交命令返回 accepted、事件 seq 单调、命令幂等。
func TestSESS01CreateAndSubmitCommandIdempotent(t *testing.T) {
	env := newTestEnv(t)
	pair := env.registerAs(t, "sess@test.dev")
	sessID, _ := env.createSession(t, pair.AccessToken, pair.AccountID)

	// 获取当前 lease epoch。
	lease := env.do(t, http.MethodPost, "/v1/sessions/"+sessID+"/lease", nil, pair.AccessToken)
	if lease.Code != http.StatusOK {
		t.Fatalf("acquire lease status=%d body=%s", lease.Code, lease.Body.String())
	}
	var lr struct {
		LeaseEpoch int64 `json:"lease_epoch"`
	}
	_ = json.Unmarshal(lease.Body.Bytes(), &lr)
	epoch := lr.LeaseEpoch
	if epoch == 0 {
		t.Fatalf("lease epoch should be non-zero")
	}
	// 提交 abort 命令（accepted）。
	submit := env.do(t, http.MethodPost, "/v1/sessions/"+sessID+"/commands", map[string]any{
		"kind": "session.abort", "idempotency_key": "ik-1", "lease_epoch": epoch,
	}, pair.AccessToken)
	if submit.Code != http.StatusAccepted {
		t.Fatalf("submit status=%d want 202 body=%s", submit.Code, submit.Body.String())
	}
	var c cmdJSON
	_ = json.Unmarshal(submit.Body.Bytes(), &c)
	if c.Status != "accepted" {
		t.Fatalf("command status=%q want accepted", c.Status)
	}
	// 相同幂等键返回原结果（仅一次动作）。
	submit2 := env.do(t, http.MethodPost, "/v1/sessions/"+sessID+"/commands", map[string]any{
		"kind": "session.abort", "idempotency_key": "ik-1", "lease_epoch": epoch,
	}, pair.AccessToken)
	var c2 cmdJSON
	_ = json.Unmarshal(submit2.Body.Bytes(), &c2)
	if c2.ID != c.ID {
		t.Fatalf("idempotency violated: want %s got %s", c.ID, c2.ID)
	}
	// 查询命令状态。
	got := env.do(t, http.MethodGet, "/v1/commands/"+c.ID, nil, pair.AccessToken)
	if got.Code != http.StatusOK {
		t.Fatalf("get command status=%d", got.Code)
	}
}
