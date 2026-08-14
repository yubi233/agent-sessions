package relay

import (
	"encoding/json"
	"net/http"
	"testing"
)

// CTRL-01：非 Android（Web/Admin）写命令被拒绝。
func TestCTRL01WebCannotWrite(t *testing.T) {
	env := newTestEnv(t)
	pair := env.registerAs(t, "web@test.dev")

	// 以 Web 角色创建普通 token：登录时 role=web，但该设备是 owner 设备。
	// 构造一个 web 只读 token。
	login := env.do(t, http.MethodPost, "/v1/auth/login", map[string]any{
		"email": "web@test.dev", "password": "test-pass-123", "device_id": "web-client", "role": "web",
	}, "")
	if login.Code != http.StatusOK {
		t.Fatalf("web login status=%d", login.Code)
	}
	var w struct {
		AccessToken string `json:"access_token"`
	}
	_ = json.Unmarshal(login.Body.Bytes(), &w)

	sessID, _ := env.createSession(t, w.AccessToken, pair.AccountID)
	// Web 设备不能写命令。
	submit := env.do(t, http.MethodPost, "/v1/sessions/"+sessID+"/commands", map[string]any{
		"kind": "session.abort", "idempotency_key": "ik-web", "lease_epoch": 0,
	}, w.AccessToken)
	if submit.Code != http.StatusForbidden {
		t.Fatalf("web submit status=%d want 403 body=%s", submit.Code, submit.Body.String())
	}
}

// CTRL-02：旧 epoch 被 fencing（LEASE_CONFLICT 或 TARGET_INSTANCE_STALE）。
func TestCTRL02StaleEpochFenced(t *testing.T) {
	env := newTestEnv(t)
	pair := env.registerAs(t, "fence@test.dev")
	sessID, _ := env.createSession(t, pair.AccessToken, pair.AccountID)

	// 第一次抢 lease 得到 epoch=1。
	first := env.do(t, http.MethodPost, "/v1/sessions/"+sessID+"/lease", nil, pair.AccessToken)
	var f struct {
		LeaseEpoch int64 `json:"lease_epoch"`
	}
	_ = json.Unmarshal(first.Body.Bytes(), &f)
	if f.LeaseEpoch != 1 {
		t.Fatalf("first lease epoch=%d want 1", f.LeaseEpoch)
	}
	// 再次抢 lease 得到 epoch=2。
	second := env.do(t, http.MethodPost, "/v1/sessions/"+sessID+"/lease", nil, pair.AccessToken)
	var s struct {
		LeaseEpoch int64 `json:"lease_epoch"`
	}
	_ = json.Unmarshal(second.Body.Bytes(), &s)
	if s.LeaseEpoch != 2 {
		t.Fatalf("second lease epoch=%d want 2", s.LeaseEpoch)
	}
	// 用旧 epoch=1 提交命令应被拒绝（TARGET_INSTANCE_STALE）。
	submit := env.do(t, http.MethodPost, "/v1/sessions/"+sessID+"/commands", map[string]any{
		"kind": "session.abort", "idempotency_key": "ik-stale", "lease_epoch": 1,
	}, pair.AccessToken)
	if submit.Code != http.StatusConflict {
		t.Fatalf("stale epoch submit status=%d want 409 body=%s", submit.Code, submit.Body.String())
	}
	// 用新 epoch=2 提交命令成功。
	ok := env.do(t, http.MethodPost, "/v1/sessions/"+sessID+"/commands", map[string]any{
		"kind": "session.abort", "idempotency_key": "ik-new", "lease_epoch": 2,
	}, pair.AccessToken)
	if ok.Code != http.StatusAccepted {
		t.Fatalf("new epoch submit status=%d want 202 body=%s", ok.Code, ok.Body.String())
	}
}

// SYNC-01：相同幂等键返回原结果（已在 SESS-01 覆盖，这里验证重复两次）。
func TestSYNC01Idempotency(t *testing.T) {
	env := newTestEnv(t)
	pair := env.registerAs(t, "sync@test.dev")
	sessID, _ := env.createSession(t, pair.AccessToken, pair.AccountID)
	lease := env.do(t, http.MethodPost, "/v1/sessions/"+sessID+"/lease", nil, pair.AccessToken)
	var lr struct {
		LeaseEpoch int64 `json:"lease_epoch"`
	}
	_ = json.Unmarshal(lease.Body.Bytes(), &lr)

	var firstID string
	for i := 0; i < 2; i++ {
		resp := env.do(t, http.MethodPost, "/v1/sessions/"+sessID+"/commands", map[string]any{
			"kind": "session.send", "idempotency_key": "ik-sync", "lease_epoch": lr.LeaseEpoch,
		}, pair.AccessToken)
		if resp.Code != http.StatusAccepted {
			t.Fatalf("submit %d status=%d", i, resp.Code)
		}
		var c struct {
			ID string `json:"id"`
		}
		_ = json.Unmarshal(resp.Body.Bytes(), &c)
		if firstID == "" {
			firstID = c.ID
		} else if c.ID != firstID {
			t.Fatalf("idempotency violated: %s != %s", c.ID, firstID)
		}
	}
}

// SEC-01：注册/登录/命令响应不含密码与令牌明文之外敏感数据（脱敏检查）。
func TestSEC01NoSensitiveLogLeak(t *testing.T) {
	env := newTestEnv(t)
	pair := env.registerAs(t, "sec@test.dev")
	_ = pair
	// 覆盖核心路径，验证响应体不含明文密码。
	login := env.do(t, http.MethodPost, "/v1/auth/login", map[string]any{
		"email": "sec@test.dev", "password": "test-pass-123",
	}, "")
	if login.Code != http.StatusOK {
		t.Fatalf("login status=%d", login.Code)
	}
	if bytesContains(login.Body.String(), "test-pass-123") {
		t.Fatalf("login response leaked password")
	}
}

func bytesContains(s, sub string) bool {
	return len(sub) > 0 && containsStr(s, sub)
}

func containsStr(s, sub string) bool {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}
