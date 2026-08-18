package relay

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/yubi233/agent-sessions/internal/authz"
	"github.com/yubi233/agent-sessions/internal/domain"
	"github.com/yubi233/agent-sessions/internal/id"
	"github.com/yubi233/agent-sessions/internal/store"
)

// testEnv 构造一个隔离 Relay（临时 SQLite）并返回测试用 HTTP 客户端。
type testEnv struct {
	db     *sql.DB
	path   string
	router *gin.Engine
	repo   store.Repository
}

// newTestEnv 打开隔离库并装配完整路由。
func newTestEnv(t *testing.T) *testEnv {
	t.Helper()
	path := filepath.Join(t.TempDir(), "relay.db")
	db, err := store.Open(path)
	if err != nil {
		t.Fatalf("open sqlite: %v", err)
	}
	env := &testEnv{db: db, path: path, router: NewServer(db, nil), repo: store.NewRepository(db)}
	t.Cleanup(func() {
		if env.db != nil {
			_ = env.db.Close()
		}
	})
	return env
}

// restartRelay 关闭同一 SQLite 连接后重新打开并装配 HTTP 服务，模拟 Relay 进程退出及启动。
// 这不是仅替换 gin router：令牌、lease、命令和事件必须都从持久化数据库重新读回。
func (e *testEnv) restartRelay(t *testing.T) {
	t.Helper()
	if e.db == nil {
		t.Fatal("Relay database is not open")
	}
	if err := e.db.Close(); err != nil {
		t.Fatalf("close Relay database for restart: %v", err)
	}
	e.db = nil
	db, err := store.Open(e.path)
	if err != nil {
		t.Fatalf("reopen Relay database after restart: %v", err)
	}
	e.db = db
	e.repo = store.NewRepository(db)
	e.router = NewServer(db, nil)
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
	DeviceID     string
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

// provisionAdditionalAccount 仅用于账号 scope 根因测试：生产 API 只允许首个 owner 注册。
// 该 helper 直接写入隔离测试 SQLite，不能被业务代码或浏览器验收复用。
func (e *testEnv) provisionAdditionalAccount(t *testing.T, email string) authPair {
	t.Helper()
	ctx := t.Context()
	accountID := id.New("acct_test")
	if err := e.repo.CreateAccount(ctx, accountID, email, authz.HashPassword("test-pass-123"), time.Now()); err != nil {
		t.Fatalf("provision additional account: %v", err)
	}
	owner, err := domain.NewPairingService(e.repo).BootstrapOwner(ctx, accountID, domain.Device{
		DisplayName: "scope test owner", Platform: "android",
	})
	if err != nil {
		t.Fatalf("bootstrap additional owner: %v", err)
	}
	tokens, err := domain.NewAuthService(e.repo).IssueForDevice(ctx, accountID, owner.ID)
	if err != nil {
		t.Fatalf("issue additional owner token: %v", err)
	}
	return authPair{AccountID: accountID, AccessToken: tokens.AccessToken, RefreshToken: tokens.RefreshToken}
}

// 创建一个会话所需的最小环境：先建 project/workspace，再建 session。
func (e *testEnv) createSession(t *testing.T, token, accountID string) (sessionID, workspaceID string) {
	return e.createSessionForProject(t, token, accountID, "proj_test")
}

// createSessionForProject 允许多账号 scope 用例使用独立 project 主键，避免 fixture 假冲突掩盖授权断言。
func (e *testEnv) createSessionForProject(t *testing.T, token, accountID, projectID string) (sessionID, workspaceID string) {
	t.Helper()
	ws := e.do(t, http.MethodPost, "/v1/workspaces", map[string]any{
		"project_id": projectID, "canonical_root": "/tmp/" + projectID, "status": "active",
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
