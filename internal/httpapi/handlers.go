package httpapi

import (
	"errors"
	"log/slog"
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"
	"github.com/yubi233/agent-sessions/internal/domain"
	"github.com/yubi233/agent-sessions/internal/store"
	"github.com/yubi233/agent-sessions/packages/protocol"
)

// RegisterRoutes 把领域服务挂载到 /v1 分组，并装配鉴权/权限中间件。
// 业务 scope 一律从认证上下文推导，handler 不信任客户端目标前缀。
func (a *API) RegisterRoutes(router *gin.Engine, logger *slog.Logger, presence *domain.PresenceHub) {
	v1 := router.Group("/v1")
	v1.Use(localAPICORS())
	// 未匹配到业务路由的 OPTIONS 预检请求统一返回 204（浏览器跨源登录/授权需要）。
	router.NoRoute(func(c *gin.Context) {
		if c.Request.Method == http.MethodOptions {
			localAPICORS()(c)
			return
		}
		c.String(http.StatusNotFound, "not found")
	})
	{
		pub := v1.Group("")
		pub.POST("/auth/login", a.handleLogin)
		pub.POST("/auth/register", a.handleRegister)
		pub.POST("/auth/refresh", a.handleRefresh)

		auth := v1.Group("")
		auth.Use(a.RequireAuth())
		auth.POST("/auth/logout", a.handleLogout)
		auth.GET("/devices", a.handleListDevices)
		auth.DELETE("/devices/:id", a.handleRevokeDevice)
		auth.GET("/sessions", a.handleListSessions)
		auth.POST("/sessions", a.handleCreateSession)
		auth.POST("/sessions/:id/commands", a.RequireWrite(), a.handleSubmitCommand)
		auth.GET("/commands/:id", a.handleGetCommand)
		auth.POST("/sessions/:id/lease", a.RequireWrite(), a.handleAcquireLease)
		auth.GET("/capabilities", a.handleCapabilities)
		auth.POST("/workspaces", a.handleCreateWorkspace)
		auth.GET("/workspaces", a.handleListWorkspaces)

		owner := v1.Group("")
		owner.Use(a.RequireAuth(), a.RequireOwner())
		owner.POST("/pairing/requests/:id/approve", a.handleApprovePairing)
		owner.POST("/pairing/requests/:id/cancel", a.handleCancelPairing)
		owner.POST("/recovery-codes/restore", a.handleRestore)

		pair := v1.Group("")
		pair.Use(a.RequireAuth())
		pair.POST("/pairing/requests", a.handleCreatePairingRequest)

		// SSE 账号级事件读取，支持 Last-Event-ID / after_seq 恢复。
		auth.GET("/events", a.handleSSE(presence, logger))
	}
}

// 登录请求体。
type loginRequest struct {
	Email    string `json:"email"`
	Password string `json:"password"`
	DeviceID string `json:"device_id"`
	Role     string `json:"role"`
}

func (a *API) handleLogin(c *gin.Context) {
	var req loginRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		writeError(c, protocol.NewError(protocol.ErrInvalidRequest, "malformed request"))
		return
	}
	if req.DeviceID == "" {
		req.DeviceID = "web"
		req.Role = domain.RoleWeb
	}
	tokens, err := a.Auth.Login(c.Request.Context(), req.Email, req.Password, req.DeviceID, req.Role)
	if err != nil {
		writeError(c, err)
		return
	}
	writeOK(c, tokens)
}

// localAPICORS 允许本地 Web/Admin 开发端口访问业务 API，并处理预检。
// 生产部署用域名白名单替换；不信任任意 Origin。
func localAPICORS() gin.HandlerFunc {
	allowed := map[string]bool{
		"http://127.0.0.1:15173": true,
		"http://localhost:15173": true,
		"http://127.0.0.1:5173":  true,
		"http://localhost:5173":  true,
		"http://127.0.0.1:5174":  true,
		"http://localhost:5174":  true,
	}
	return func(c *gin.Context) {
		origin := c.GetHeader("Origin")
		if allowed[origin] {
			c.Header("Access-Control-Allow-Origin", origin)
			c.Header("Vary", "Origin")
			c.Header("Access-Control-Allow-Credentials", "true")
			c.Header("Access-Control-Allow-Headers", "Content-Type, Authorization")
			c.Header("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS")
		}
		if c.Request.Method == http.MethodOptions {
			c.AbortWithStatus(http.StatusNoContent)
			return
		}
		c.Next()
	}
}

// handleRegister 单租户自托管 bootstrap 注册，首设备自动成为 owner。
func (a *API) handleRegister(c *gin.Context) {
	var req loginRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		writeError(c, protocol.NewError(protocol.ErrInvalidRequest, "malformed request"))
		return
	}
	accountID, err := a.Auth.Register(c.Request.Context(), req.Email, req.Password)
	if err != nil {
		writeError(c, err)
		return
	}
	// 首个设备成为 owner，后续经配对批准。
	owner, err := a.Pairing.BootstrapOwner(c.Request.Context(), accountID, domain.Device{
		Role: domain.RoleAndroidOwner, Status: domain.DeviceActive,
		DisplayName: "Android Owner", Platform: "android",
	})
	if err != nil {
		writeError(c, err)
		return
	}
	tokens, err := a.Auth.Login(c.Request.Context(), req.Email, req.Password, owner.ID, domain.RoleAndroidOwner)
	if err != nil {
		writeError(c, err)
		return
	}
	c.JSON(http.StatusCreated, gin.H{
		"account_id":    accountID,
		"access_token":  tokens.AccessToken,
		"refresh_token": tokens.RefreshToken,
	})
}

func (a *API) handleRefresh(c *gin.Context) {
	var req struct {
		RefreshToken string `json:"refresh_token"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		writeError(c, protocol.NewError(protocol.ErrInvalidRequest, "malformed request"))
		return
	}
	tokens, err := a.Auth.Refresh(c.Request.Context(), req.RefreshToken)
	if err != nil {
		writeError(c, err)
		return
	}
	writeOK(c, tokens)
}

func (a *API) handleLogout(c *gin.Context) {
	var req struct {
		RefreshToken string `json:"refresh_token"`
	}
	_ = c.ShouldBindJSON(&req)
	if err := a.Auth.Logout(c.Request.Context(), req.RefreshToken); err != nil {
		writeError(c, err)
		return
	}
	writeOK(c, gin.H{"ok": true})
}

func (a *API) handleListDevices(c *gin.Context) {
	subj := subject(c)
	devices, err := a.Pairing.ListDevices(c.Request.Context(), subj.AccountID)
	if err != nil {
		writeError(c, err)
		return
	}
	writeOK(c, gin.H{"devices": devices})
}

func (a *API) handleRevokeDevice(c *gin.Context) {
	subj := subject(c)
	if err := a.Pairing.RevokeDevice(c.Request.Context(), subj, c.Param("id")); err != nil {
		writeError(c, err)
		return
	}
	writeOK(c, gin.H{"ok": true})
}

func (a *API) handleCreatePairingRequest(c *gin.Context) {
	subj := subject(c)
	var d domain.Device
	if err := c.ShouldBindJSON(&d); err != nil {
		writeError(c, protocol.NewError(protocol.ErrInvalidRequest, "malformed request"))
		return
	}
	d.AccountID = subj.AccountID
	if d.Role == "" {
		d.Role = domain.RoleTerminal
	}
	req, err := a.Pairing.CreatePairingRequest(c.Request.Context(), subj.AccountID, d)
	if err != nil {
		writeError(c, err)
		return
	}
	c.JSON(http.StatusCreated, req)
}

func (a *API) handleApprovePairing(c *gin.Context) {
	subj := subject(c)
	dev, err := a.Pairing.ApprovePairing(c.Request.Context(), subj, c.Param("id"))
	if err != nil {
		writeError(c, err)
		return
	}
	writeOK(c, dev)
}

func (a *API) handleCancelPairing(c *gin.Context) {
	subj := subject(c)
	if err := a.Pairing.CancelPairing(c.Request.Context(), subj.AccountID, c.Param("id")); err != nil {
		writeError(c, err)
		return
	}
	writeOK(c, gin.H{"ok": true})
}

func (a *API) handleRestore(c *gin.Context) {
	subj := subject(c)
	var req struct {
		Code string `json:"code"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		writeError(c, protocol.NewError(protocol.ErrInvalidRequest, "malformed request"))
		return
	}
	if err := a.Pairing.RestoreWithRecoveryCode(c.Request.Context(), subj.AccountID, req.Code); err != nil {
		writeError(c, err)
		return
	}
	writeOK(c, gin.H{"ok": true})
}

func (a *API) handleListSessions(c *gin.Context) {
	subj := subject(c)
	sessions, err := a.Sessions.ListSessions(c.Request.Context(), subj.AccountID)
	if err != nil {
		writeError(c, err)
		return
	}
	writeOK(c, gin.H{"sessions": sessions})
}

type createSessionRequest struct {
	WorkspaceID string `json:"workspace_id"`
	Provider    string `json:"provider"`
}

func (a *API) handleCreateSession(c *gin.Context) {
	subj := subject(c)
	var req createSessionRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		writeError(c, protocol.NewError(protocol.ErrInvalidRequest, "malformed request"))
		return
	}
	if req.WorkspaceID == "" {
		writeError(c, protocol.NewError(protocol.ErrInvalidRequest, "workspace_id required"))
		return
	}
	sess, err := a.Sessions.CreateSession(c.Request.Context(), subj.AccountID, req.WorkspaceID, req.Provider)
	if err != nil {
		writeError(c, err)
		return
	}
	c.JSON(http.StatusCreated, sess)
}

type submitCommandRequest struct {
	Kind             string `json:"kind"`
	IdempotencyKey   string `json:"idempotency_key"`
	LeaseEpoch       int64  `json:"lease_epoch"`
	TargetInstanceID string `json:"target_instance_id"`
	Ciphertext       string `json:"ciphertext"`
}

func (a *API) handleSubmitCommand(c *gin.Context) {
	subj := subject(c)
	var req submitCommandRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		writeError(c, protocol.NewError(protocol.ErrInvalidRequest, "malformed request"))
		return
	}
	if req.IdempotencyKey == "" || req.Kind == "" {
		writeError(c, protocol.NewError(protocol.ErrInvalidRequest, "kind and idempotency_key required"))
		return
	}
	cmd, err := a.Sessions.SubmitCommand(c.Request.Context(), domain.CommandInput{
		AccountID: subj.AccountID, DeviceID: subj.DeviceID, Role: subj.Role,
		SessionID: c.Param("id"), Kind: req.Kind, IdempotencyKey: req.IdempotencyKey,
		LeaseEpoch: req.LeaseEpoch, TargetInstanceID: req.TargetInstanceID, CiphertextJSON: req.Ciphertext,
	})
	if err != nil {
		writeError(c, err)
		return
	}
	c.JSON(http.StatusAccepted, cmd)
}

func (a *API) handleGetCommand(c *gin.Context) {
	cmd, err := a.Sessions.GetCommand(c.Request.Context(), c.Param("id"))
	if err != nil {
		writeError(c, err)
		return
	}
	writeOK(c, cmd)
}

// handleCapabilities 返回四类 Provider 的能力矩阵（客户端据此渲染入口）。
func (a *API) handleCapabilities(c *gin.Context) {
	providers, err := a.Capabilities.List(c.Request.Context())
	if err != nil {
		writeError(c, err)
		return
	}
	writeOK(c, gin.H{"providers": providers})
}

// handleAcquireLease 抢占写控制权并返回新 epoch。
func (a *API) handleAcquireLease(c *gin.Context) {
	subj := subject(c)
	epoch, err := a.Sessions.AcquireLease(c.Request.Context(), c.Param("id"), subj.DeviceID, "")
	if err != nil {
		writeError(c, err)
		return
	}
	writeOK(c, gin.H{"session_id": c.Param("id"), "lease_epoch": epoch})
}

type createWorkspaceRequest struct {
	ProjectID     string `json:"project_id"`
	CanonicalRoot string `json:"canonical_root"`
	Branch        string `json:"branch"`
	Status        string `json:"status"`
}

// handleCreateWorkspace 登记一个 Workspace；project 不存在时自动创建索引。
func (a *API) handleCreateWorkspace(c *gin.Context) {
	subj := subject(c)
	var req createWorkspaceRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		writeError(c, protocol.NewError(protocol.ErrInvalidRequest, "malformed request"))
		return
	}
	if req.ProjectID == "" || req.CanonicalRoot == "" {
		writeError(c, protocol.NewError(protocol.ErrInvalidRequest, "project_id and canonical_root required"))
		return
	}
	// project 自动登记（P1 只存元数据，不解析 Git）。
	projID := req.ProjectID
	if _, err := a.Repo.ListProjects(c.Request.Context(), subj.AccountID); err != nil {
		writeError(c, err)
		return
	}
	_ = a.Repo.CreateProject(c.Request.Context(), store.ProjectRow{
		ID: projID, AccountID: subj.AccountID, Fingerprint: "fp_" + projID,
	})
	ws := store.WorkspaceRow{
		ID: "ws_" + projID, ProjectID: projID, TerminalID: "",
		CanonicalRoot: req.CanonicalRoot, Branch: req.Branch, Status: req.Status,
	}
	if ws.Status == "" {
		ws.Status = "active"
	}
	if err := a.Repo.CreateWorkspace(c.Request.Context(), ws); err != nil {
		writeError(c, err)
		return
	}
	c.JSON(http.StatusCreated, ws)
}

func (a *API) handleListWorkspaces(c *gin.Context) {
	subj := subject(c)
	ws, err := a.Sessions.ListWorkspaces(c.Request.Context(), subj.AccountID)
	if err != nil {
		writeError(c, err)
		return
	}
	writeOK(c, gin.H{"workspaces": ws})
}

// ErrDecode 用于标记 handler 内部映射失败（不泄露细节）。
func isDomain(err error) bool {
	return errors.Is(err, domain.ErrSessionNotFound) ||
		errors.Is(err, domain.ErrLeaseConflict) ||
		errors.Is(err, domain.ErrReadOnlyDevice) ||
		errors.Is(err, store.ErrNotFound) ||
		errors.Is(err, domain.ErrAlreadyResolved)
}

// reqIP 提取脱敏的客户端标识，仅用于审计，不记录 token/正文。
func reqIP(c *gin.Context) string {
	return strings.Split(c.ClientIP(), ":")[0]
}
