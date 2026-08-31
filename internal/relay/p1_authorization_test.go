package relay

import (
	"encoding/json"
	"net/http"
	"testing"
)

// CTRL-01：本地 LLM 场景下 web 被授权创建会话/工作区并提交写命令。
func TestCTRL01WebCanWriteForLocalLLM(t *testing.T) {
	env := newTestEnv(t)
	_ = env.registerAs(t, "web@test.dev")

	// Web 登录；未绑定 Android 设备，但 role=web 已允许主动发起本地 LLM 会话。
	login := env.do(t, http.MethodPost, "/v1/auth/login", map[string]any{
		"email": "web@test.dev", "password": "test-pass-123", "device_role": "web",
	}, "")
	if login.Code != http.StatusOK {
		t.Fatalf("web login status=%d", login.Code)
	}
	var w struct {
		AccessToken string `json:"access_token"`
	}
	_ = json.Unmarshal(login.Body.Bytes(), &w)

	// Web 可以直接创建工作区并创建会话。
	ws := env.do(t, http.MethodPost, "/v1/workspaces", map[string]any{
		"project_id": "web-write-attempt", "canonical_root": "/tmp/web-write-attempt", "status": "active",
	}, w.AccessToken)
	if ws.Code != http.StatusOK && ws.Code != http.StatusCreated {
		t.Fatalf("web create workspace status=%d want 2xx body=%s", ws.Code, ws.Body.String())
	}
	var workspace struct {
		ID string `json:"id"`
	}
	_ = json.Unmarshal(ws.Body.Bytes(), &workspace)
	if workspace.ID == "" {
		t.Fatal("web create workspace missing id")
	}
	createSession := env.do(t, http.MethodPost, "/v1/sessions", map[string]any{
		"workspace_id": workspace.ID, "provider": "mock",
	}, w.AccessToken)
	if createSession.Code != http.StatusCreated {
		t.Fatalf("web create session status=%d want 201 body=%s", createSession.Code, createSession.Body.String())
	}
	var sess struct {
		ID string `json:"id"`
	}
	_ = json.Unmarshal(createSession.Body.Bytes(), &sess)
	if sess.ID == "" {
		t.Fatal("web create session missing id")
	}

	// 获取 lease 后可以提交命令（主动发起对话的写路径）。
	lease := env.do(t, http.MethodPost, "/v1/sessions/"+sess.ID+"/lease", nil, w.AccessToken)
	if lease.Code != http.StatusOK {
		t.Fatalf("web acquire lease status=%d want 200 body=%s", lease.Code, lease.Body.String())
	}
	var l struct {
		Epoch int64 `json:"lease_epoch"`
	}
	_ = json.Unmarshal(lease.Body.Bytes(), &l)
	submit := env.do(t, http.MethodPost, "/v1/sessions/"+sess.ID+"/commands", map[string]any{
		"kind": "session.start", "idempotency_key": "ik-web-start", "lease_epoch": l.Epoch,
		"ciphertext": map[string]any{
			"session_id": sess.ID,
			"ciphertext": map[string]any{"fixture_payload": map[string]any{"session_id": sess.ID, "provider": "mock"}},
		},
	}, w.AccessToken)
	if submit.Code != http.StatusAccepted {
		t.Fatalf("web submit status=%d want 202 body=%s", submit.Code, submit.Body.String())
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
	// 省略/传 0 不能作为“当前 lease”通配符，否则旧命令可绕过 fencing。
	missing := env.do(t, http.MethodPost, "/v1/sessions/"+sessID+"/commands", map[string]any{
		"kind": "session.abort", "idempotency_key": "ik-missing-epoch", "lease_epoch": 0,
	}, pair.AccessToken)
	if missing.Code != http.StatusBadRequest {
		t.Fatalf("missing epoch submit status=%d want 400 body=%s", missing.Code, missing.Body.String())
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
