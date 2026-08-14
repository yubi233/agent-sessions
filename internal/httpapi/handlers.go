package httpapi

import (
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"strconv"
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
		// 恢复入口故意不要求现有 bearer：丢失 owner 设备时仍可用恢复码恢复控制权。
		pub.POST("/recovery-codes/restore", a.handleRestore)

		auth := v1.Group("")
		auth.Use(a.RequireAuth())
		auth.POST("/auth/logout", a.handleLogout)
		auth.GET("/devices", a.handleListDevices)
		auth.DELETE("/devices/:id", a.handleRevokeDevice)
		auth.GET("/terminals", a.handleListTerminals)
		auth.GET("/projects", a.handleListProjects)
		auth.GET("/sessions", a.handleListSessions)
		auth.GET("/sessions/:id/snapshot", a.handleSessionSnapshot)
		// 创建 Workspace/Session 会改变账号元数据，和会话命令一样只允许 Android 控制端发起。
		auth.POST("/sessions", a.RequireWrite(), a.handleCreateSession)
		auth.POST("/sessions/:id/commands", a.RequireWrite(), a.handleSubmitCommand)
		auth.GET("/commands/:id", a.handleGetCommand)
		auth.POST("/sessions/:id/lease", a.RequireWrite(), a.handleAcquireLease)
		auth.GET("/capabilities", a.handleCapabilities)
		auth.POST("/workspaces", a.RequireWrite(), a.handleCreateWorkspace)
		auth.GET("/workspaces", a.handleListWorkspaces)

		owner := v1.Group("")
		owner.Use(a.RequireAuth(), a.RequireOwner())
		owner.POST("/pairing/bootstrap", a.handleBootstrapOwner)
		// 配对读取会返回待配对设备公钥，只能由 key-admin owner 查看。
		owner.GET("/pairing/requests/:id", a.handleGetPairing)
		owner.POST("/pairing/requests/:id/approve", a.handleApprovePairing)
		owner.POST("/pairing/requests/:id/cancel", a.handleCancelPairing)
		owner.POST("/recovery-codes", a.handleGenerateRecoveryCode)

		pair := v1.Group("")
		pair.Use(a.RequireAuth())
		pair.POST("/pairing/requests", a.handleCreatePairingRequest)

		// SSE 账号级事件读取，支持 Last-Event-ID / after_seq 恢复。
		auth.GET("/events", a.handleSSE(presence, logger))
	}
}

// 登录请求体。
type loginRequest struct {
	Email      string `json:"email"`
	Password   string `json:"password"`
	DeviceRole string `json:"device_role"`
}

func (a *API) handleLogin(c *gin.Context) {
	var req loginRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		writeError(c, protocol.NewError(protocol.ErrInvalidRequest, "malformed request"))
		return
	}
	// 密码登录不接受客户端传入 device_id；省略 role 时服务端固定签发未绑定 Web 只读 token。
	tokens, err := a.Auth.Login(c.Request.Context(), req.Email, req.Password, "", req.DeviceRole)
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
		"http://127.0.0.1:15174": true,
		"http://localhost:15174": true,
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

// handleRegister 单租户自托管 bootstrap 注册，首设备与首个令牌必须一并提交。
func (a *API) handleRegister(c *gin.Context) {
	var req loginRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		writeError(c, protocol.NewError(protocol.ErrInvalidRequest, "malformed request"))
		return
	}
	// 密钥 bootstrap 仍由 Android 在收到绑定 token 后补齐，但账号、owner 记录和 token 不允许分事务。
	_, tokens, err := a.Auth.RegisterInitialOwner(c.Request.Context(), req.Email, req.Password, domain.Device{
		Role: domain.RoleAndroidOwner, Status: domain.DeviceActive,
		DisplayName: "Android Owner", Platform: "android",
	})
	if err != nil {
		writeError(c, err)
		return
	}
	c.JSON(http.StatusCreated, tokens)
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
	if err := c.ShouldBindJSON(&req); err != nil || strings.TrimSpace(req.RefreshToken) == "" {
		writeError(c, protocol.NewError(protocol.ErrInvalidRequest, "refresh_token required"))
		return
	}
	// bearer 的账号范围和 refresh 哈希共同约束注销目标，不能让已登录用户凭 family 前缀注销他人。
	if err := a.Auth.Logout(c.Request.Context(), subject(c).AccountID, req.RefreshToken); err != nil {
		writeError(c, err)
		return
	}
	c.Status(http.StatusNoContent)
}

func (a *API) handleListDevices(c *gin.Context) {
	subj := subject(c)
	devices, err := a.Pairing.ListDevices(c.Request.Context(), subj.AccountID)
	if err != nil {
		writeError(c, err)
		return
	}
	views := make([]deviceView, 0, len(devices))
	for _, device := range devices {
		// 设备列表只返回 UI 所需元数据，不把公钥或账号内部字段暴露给只读客户端。
		views = append(views, newDeviceView(device))
	}
	writeOK(c, gin.H{"devices": views})
}

func (a *API) handleRevokeDevice(c *gin.Context) {
	subj := subject(c)
	if err := a.Pairing.RevokeDevice(c.Request.Context(), subj, c.Param("id")); err != nil {
		writeError(c, err)
		return
	}
	c.Status(http.StatusNoContent)
}

type bootstrapRequest struct {
	DisplayName         string `json:"display_name"`
	IdentityPublicKey   string `json:"identity_public_key"`
	EncryptionPublicKey string `json:"encryption_public_key"`
	Platform            string `json:"platform"`
}

// handleBootstrapOwner 为注册后初始 owner 写入一次设备公钥，服务端不记录私钥或恢复码明文。
func (a *API) handleBootstrapOwner(c *gin.Context) {
	var req bootstrapRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		writeError(c, protocol.NewError(protocol.ErrInvalidRequest, "malformed request"))
		return
	}
	dev, err := a.Pairing.CompleteOwnerBootstrap(c.Request.Context(), subject(c), domain.Device{
		DisplayName: req.DisplayName, Platform: req.Platform,
		IdentityPublicKey: req.IdentityPublicKey, EncryptionPublicKey: req.EncryptionPublicKey,
	})
	if err != nil {
		writeError(c, err)
		return
	}
	c.JSON(http.StatusCreated, newDeviceView(dev))
}

func (a *API) handleCreatePairingRequest(c *gin.Context) {
	subj := subject(c)
	var req pairingCreateRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		writeError(c, protocol.NewError(protocol.ErrInvalidRequest, "malformed request"))
		return
	}
	d := domain.Device{
		AccountID: subj.AccountID, Role: req.Role, DisplayName: req.DisplayName, Platform: req.Platform,
		IdentityPublicKey: req.IdentityPublicKey, EncryptionPublicKey: req.EncryptionPublicKey,
	}
	pairing, err := a.Pairing.CreatePairingRequest(c.Request.Context(), subj.AccountID, d)
	if err != nil {
		writeError(c, err)
		return
	}
	c.JSON(http.StatusCreated, newPairingView(pairing))
}

type pairingCreateRequest struct {
	Role                string `json:"role"`
	DisplayName         string `json:"display_name"`
	IdentityPublicKey   string `json:"identity_public_key"`
	EncryptionPublicKey string `json:"encryption_public_key"`
	Platform            string `json:"platform"`
}

func (a *API) handleGetPairing(c *gin.Context) {
	p, err := a.Pairing.GetPairing(c.Request.Context(), subject(c), c.Param("id"))
	if err != nil {
		writeError(c, err)
		return
	}
	writeOK(c, newPairingView(p))
}

func (a *API) handleApprovePairing(c *gin.Context) {
	subj := subject(c)
	dev, err := a.Pairing.ApprovePairing(c.Request.Context(), subj, c.Param("id"))
	if err != nil {
		writeError(c, err)
		return
	}
	writeOK(c, newDeviceView(dev))
}

func (a *API) handleCancelPairing(c *gin.Context) {
	subj := subject(c)
	if err := a.Pairing.CancelPairing(c.Request.Context(), subj, c.Param("id")); err != nil {
		writeError(c, err)
		return
	}
	c.Status(http.StatusNoContent)
}

type recoveryRestoreRequest struct {
	Email               string `json:"email"`
	RecoveryCode        string `json:"recovery_code"`
	Code                string `json:"code"`
	DisplayName         string `json:"display_name"`
	IdentityPublicKey   string `json:"identity_public_key"`
	EncryptionPublicKey string `json:"encryption_public_key"`
	Platform            string `json:"platform"`
}

func (a *API) handleRestore(c *gin.Context) {
	var req recoveryRestoreRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		writeError(c, protocol.NewError(protocol.ErrInvalidRequest, "malformed request"))
		return
	}
	if req.RecoveryCode == "" {
		req.RecoveryCode = req.Code
	}
	// 恢复码消费、旧 owner 撤销、新 owner 创建和 token 签发是同一个事务，防止返回 5xx 后控制权丢失。
	dev, tokens, err := a.Auth.RestoreOwnerWithRecoveryCode(c.Request.Context(), a.Pairing, req.Email, req.RecoveryCode, domain.Device{
		DisplayName: req.DisplayName, Platform: req.Platform,
		IdentityPublicKey: req.IdentityPublicKey, EncryptionPublicKey: req.EncryptionPublicKey,
	})
	if err != nil {
		writeError(c, err)
		return
	}
	writeOK(c, recoveryRestoreView{Device: newDeviceView(dev), Tokens: tokens})
}

// handleGenerateRecoveryCode 只向当前 owner 返回一次恢复码，持久化层仅保存哈希。
func (a *API) handleGenerateRecoveryCode(c *gin.Context) {
	code, err := a.Pairing.GenerateRecoveryCode(c.Request.Context(), subject(c).AccountID)
	if err != nil {
		writeError(c, err)
		return
	}
	writeOK(c, gin.H{"recovery_code": code})
}

func (a *API) handleListSessions(c *gin.Context) {
	subj := subject(c)
	sessions, err := a.Sessions.ListSessions(c.Request.Context(), subj.AccountID)
	if err != nil {
		writeError(c, err)
		return
	}
	views := make([]sessionView, 0, len(sessions))
	for _, session := range sessions {
		views = append(views, newSessionView(session))
	}
	writeOK(c, gin.H{"sessions": views})
}

// handleListTerminals 只返回当前账号的 Terminal 白名单元数据。
func (a *API) handleListTerminals(c *gin.Context) {
	rows, err := a.Repo.ListTerminals(c.Request.Context(), subject(c).AccountID)
	if err != nil {
		writeError(c, err)
		return
	}
	views := make([]terminalView, 0, len(rows))
	for _, row := range rows {
		views = append(views, newTerminalView(row))
	}
	writeOK(c, gin.H{"terminals": views})
}

// handleListProjects 仅返回项目指纹和密文名称，不解密或读取工作区内容。
func (a *API) handleListProjects(c *gin.Context) {
	rows, err := a.Repo.ListProjects(c.Request.Context(), subject(c).AccountID)
	if err != nil {
		writeError(c, err)
		return
	}
	views := make([]projectView, 0, len(rows))
	for _, row := range rows {
		views = append(views, newProjectView(row))
	}
	writeOK(c, gin.H{"projects": views})
}

// handleSessionSnapshot 读取当前账号指定会话的增量密文事件，after_seq 不允许为负数。
func (a *API) handleSessionSnapshot(c *gin.Context) {
	afterSeq := int64(0)
	if raw := c.Query("after_seq"); raw != "" {
		parsed, err := strconv.ParseInt(raw, 10, 64)
		if err != nil || parsed < 0 {
			writeError(c, protocol.NewError(protocol.ErrInvalidRequest, "after_seq must be a non-negative integer"))
			return
		}
		afterSeq = parsed
	}
	session, err := a.Sessions.GetSession(c.Request.Context(), c.Param("id"))
	if err != nil {
		writeError(c, err)
		return
	}
	if session.AccountID != subject(c).AccountID {
		writeError(c, domain.ErrScopeDenied)
		return
	}
	events, err := a.Sessions.ListEventsAfter(c.Request.Context(), session.ID, afterSeq)
	if err != nil {
		writeError(c, err)
		return
	}
	views := make([]cipherEventView, 0, len(events))
	for _, event := range events {
		if !json.Valid([]byte(event.EnvelopeJSON)) {
			writeError(c, errors.New("stored event envelope is invalid"))
			return
		}
		views = append(views, cipherEventView{
			EventSeq: event.EventSeq, EventType: event.EventType, Envelope: json.RawMessage(event.EnvelopeJSON),
		})
	}
	writeOK(c, sessionSnapshotView{Session: newSessionView(session), Events: views})
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
	c.JSON(http.StatusCreated, newSessionView(sess))
}

type submitCommandRequest struct {
	Kind             string          `json:"kind"`
	IdempotencyKey   string          `json:"idempotency_key"`
	LeaseEpoch       int64           `json:"lease_epoch"`
	TargetInstanceID string          `json:"target_instance_id"`
	Ciphertext       json.RawMessage `json:"ciphertext"`
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
	if req.LeaseEpoch <= 0 {
		// 0 不再作为兼容通配符，所有会话写命令必须显式携带当前 fencing epoch。
		writeError(c, protocol.NewError(protocol.ErrInvalidRequest, "lease_epoch must be a positive integer"))
		return
	}
	cmd, err := a.Sessions.SubmitCommand(c.Request.Context(), domain.CommandInput{
		AccountID: subj.AccountID, DeviceID: subj.DeviceID, Role: subj.Role,
		SessionID: c.Param("id"), Kind: req.Kind, IdempotencyKey: req.IdempotencyKey,
		LeaseEpoch: req.LeaseEpoch, TargetInstanceID: req.TargetInstanceID, CiphertextJSON: string(req.Ciphertext),
	})
	if err != nil {
		writeError(c, err)
		return
	}
	c.JSON(http.StatusAccepted, newCommandView(cmd))
}

func (a *API) handleGetCommand(c *gin.Context) {
	cmd, err := a.Sessions.GetCommand(c.Request.Context(), c.Param("id"))
	if err != nil {
		writeError(c, err)
		return
	}
	if cmd.AccountID != subject(c).AccountID {
		writeError(c, domain.ErrScopeDenied)
		return
	}
	writeOK(c, newCommandView(cmd))
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
	session, err := a.Sessions.GetSession(c.Request.Context(), c.Param("id"))
	if err != nil {
		writeError(c, err)
		return
	}
	if session.AccountID != subj.AccountID {
		writeError(c, domain.ErrScopeDenied)
		return
	}
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
	// project 自动登记（P1 只存元数据，不解析 Git）；唯一键冲突不能忽略，避免跨账号复用 project。
	projID := req.ProjectID
	projects, err := a.Repo.ListProjects(c.Request.Context(), subj.AccountID)
	if err != nil {
		writeError(c, err)
		return
	}
	owned := false
	for _, project := range projects {
		if project.ID == projID {
			owned = true
			break
		}
	}
	if !owned {
		if err := a.Repo.CreateProject(c.Request.Context(), store.ProjectRow{
			ID: projID, AccountID: subj.AccountID, Fingerprint: "fp_" + projID,
		}); err != nil {
			writeError(c, err)
			return
		}
	}
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
	c.JSON(http.StatusCreated, newWorkspaceView(ws))
}

func (a *API) handleListWorkspaces(c *gin.Context) {
	subj := subject(c)
	ws, err := a.Sessions.ListWorkspaces(c.Request.Context(), subj.AccountID)
	if err != nil {
		writeError(c, err)
		return
	}
	views := make([]workspaceView, 0, len(ws))
	for _, workspace := range ws {
		views = append(views, newWorkspaceView(workspace))
	}
	writeOK(c, gin.H{"workspaces": views})
}

// 以下 DTO 是 REST 白名单投影，避免直接序列化 store/domain 行而泄露账号、公钥或密文参数。
type deviceView struct {
	ID             string `json:"id"`
	Role           string `json:"role"`
	Status         string `json:"status"`
	DisplayName    string `json:"display_name"`
	Platform       string `json:"platform,omitempty"`
	LastSeenUnixMS int64  `json:"last_seen_unix_ms,omitempty"`
}

func newDeviceView(device domain.Device) deviceView {
	return deviceView{
		ID: device.ID, Role: device.Role, Status: device.Status, DisplayName: device.DisplayName,
		Platform: device.Platform, LastSeenUnixMS: device.LastSeenUnixMS,
	}
}

// pairingView 保留待批准设备的公钥，以便 owner 在客户端完成 DEK 包装；不会出现在普通设备列表。
type pairingView struct {
	ID                  string `json:"id"`
	Role                string `json:"role"`
	Status              string `json:"status"`
	DisplayName         string `json:"display_name"`
	IdentityPublicKey   string `json:"identity_public_key"`
	EncryptionPublicKey string `json:"encryption_public_key"`
	Platform            string `json:"platform,omitempty"`
	ExpiresAt           string `json:"expires_at"`
}

func newPairingView(pairing domain.PairingRequest) pairingView {
	return pairingView{
		ID: pairing.ID, Role: pairing.Role, Status: pairing.Status, DisplayName: pairing.DisplayName,
		IdentityPublicKey: pairing.IdentityPublicKey, EncryptionPublicKey: pairing.EncryptionPublicKey,
		Platform: pairing.Platform, ExpiresAt: pairing.ExpiresAt.UTC().Format("2006-01-02T15:04:05Z07:00"),
	}
}

type terminalView struct {
	ID             string `json:"id"`
	DeviceID       string `json:"device_id"`
	Hostname       string `json:"hostname,omitempty"`
	Platform       string `json:"platform,omitempty"`
	Status         string `json:"status"`
	LastSeenUnixMS int64  `json:"last_seen_unix_ms,omitempty"`
}

func newTerminalView(terminal store.TerminalRow) terminalView {
	return terminalView{
		ID: terminal.ID, DeviceID: terminal.DeviceID, Hostname: terminal.Hostname,
		Platform: terminal.Platform, Status: terminal.Status, LastSeenUnixMS: terminal.LastSeenUnixMS,
	}
}

type projectView struct {
	ID            string `json:"id"`
	Fingerprint   string `json:"fingerprint"`
	EncryptedName string `json:"encrypted_name,omitempty"`
}

func newProjectView(project store.ProjectRow) projectView {
	return projectView{ID: project.ID, Fingerprint: project.Fingerprint, EncryptedName: project.EncryptedName}
}

type workspaceView struct {
	ID         string `json:"id"`
	ProjectID  string `json:"project_id"`
	TerminalID string `json:"terminal_id"`
	Branch     string `json:"branch,omitempty"`
	Status     string `json:"status,omitempty"`
}

func newWorkspaceView(workspace store.WorkspaceRow) workspaceView {
	return workspaceView{
		ID: workspace.ID, ProjectID: workspace.ProjectID, TerminalID: workspace.TerminalID,
		Branch: workspace.Branch, Status: workspace.Status,
	}
}

type sessionView struct {
	ID          string `json:"id"`
	WorkspaceID string `json:"workspace_id"`
	Status      string `json:"status"`
	Provider    string `json:"provider,omitempty"`
	LastSeq     int64  `json:"last_seq"`
}

func newSessionView(session store.SessionRow) sessionView {
	return sessionView{
		ID: session.ID, WorkspaceID: session.WorkspaceID, Status: session.Status,
		Provider: session.Provider, LastSeq: session.LastSeq,
	}
}

type commandView struct {
	ID             string `json:"id"`
	Kind           string `json:"kind"`
	Status         string `json:"status"`
	IdempotencyKey string `json:"idempotency_key"`
	LeaseEpoch     int64  `json:"lease_epoch,omitempty"`
}

func newCommandView(command store.CommandRow) commandView {
	return commandView{
		ID: command.ID, Kind: command.Kind, Status: command.Status,
		IdempotencyKey: command.IdempotencyKey, LeaseEpoch: command.LeaseEpoch,
	}
}

type cipherEventView struct {
	EventSeq  int64           `json:"event_seq"`
	EventType string          `json:"event_type"`
	Envelope  json.RawMessage `json:"envelope"`
}

type sessionSnapshotView struct {
	Session sessionView       `json:"session"`
	Events  []cipherEventView `json:"events"`
}

type recoveryRestoreView struct {
	Device deviceView       `json:"device"`
	Tokens domain.TokenPair `json:"tokens"`
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
