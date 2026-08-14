package relay

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/yubi233/agent-sessions/internal/domain"
	"github.com/yubi233/agent-sessions/internal/store"
)

// testEnv 构造一个隔离 Relay（临时 SQLite）并返回测试用 HTTP 客户端。
type testEnv struct {
	router *gin.Engine
	repo   store.Repository
}

// newTestEnv 打开隔离库并装配完整路由。
func newTestEnv(t *testing.T) *testEnv {
	t.Helper()
	db, err := store.Open(filepath.Join(t.TempDir(), "relay.db"))
	if err != nil {
		t.Fatalf("open sqlite: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	repo := store.NewRepository(db)
	router := NewServer(db, nil)
	return &testEnv{router: router, repo: repo}
}

func (e *testEnv) do(t *testing.T, method, path string, body any, token string) *httptest.ResponseRecorder {
	t.Helper()
	var buf bytes.Buffer
	if body != nil {
		if err := json.NewEncoder(&buf).Encode(body); err != nil {
			t.Fatalf("encode body: %v", err)
		}
	}
	req := httptest.NewRequest(method, path, &buf)
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	rec := httptest.NewRecorder()
	e.router.ServeHTTP(rec, req)
	return rec
}

type authPair struct {
	AccountID    string
	AccessToken  string
	RefreshToken string
}

// registerAs 注册并 bootstrap owner，返回账号与令牌。
func (e *testEnv) registerAs(t *testing.T, email string) authPair {
	t.Helper()
	reg := e.do(t, http.MethodPost, "/v1/auth/register", map[string]any{
		"email": email, "password": "test-pass-123",
	}, "")
	if reg.Code != http.StatusCreated {
		t.Fatalf("register status=%d body=%s", reg.Code, reg.Body.String())
	}
	var pair struct {
		AccountID    string `json:"account_id"`
		AccessToken  string `json:"access_token"`
		RefreshToken string `json:"refresh_token"`
	}
	_ = json.Unmarshal(reg.Body.Bytes(), &pair)
	return authPair{AccountID: pair.AccountID, AccessToken: pair.AccessToken, RefreshToken: pair.RefreshToken}
}

// 创建一个会话所需的最小环境：先建 project/workspace，再建 session。
func (e *testEnv) createSession(t *testing.T, token, accountID string) (sessionID, workspaceID string) {
	t.Helper()
	ws := e.do(t, http.MethodPost, "/v1/workspaces", map[string]any{
		"project_id": "proj_test", "canonical_root": "/tmp/ws", "status": "active",
	}, token)
	if ws.Code != http.StatusOK && ws.Code != http.StatusCreated {
		t.Fatalf("create workspace status=%d body=%s", ws.Code, ws.Body.String())
	}
	var w struct {
		ID string `json:"id"`
	}
	_ = json.Unmarshal(ws.Body.Bytes(), &w)
	sess := e.do(t, http.MethodPost, "/v1/sessions", map[string]any{
		"workspace_id": w.ID, "provider": "mock",
	}, token)
	if sess.Code != http.StatusCreated {
		t.Fatalf("create session status=%d body=%s", sess.Code, sess.Body.String())
	}
	var s struct {
		ID string `json:"id"`
	}
	_ = json.Unmarshal(sess.Body.Bytes(), &s)
	return s.ID, w.ID
}

var _ = domain.RoleWeb
