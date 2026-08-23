package httpapi

import (
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"strconv"
	"strings"

	"github.com/gin-gonic/gin"
	"github.com/yubi233/agent-sessions/internal/domain"
	"github.com/yubi233/agent-sessions/internal/store"
	contentcrypto "github.com/yubi233/agent-sessions/packages/crypto"
	"github.com/yubi233/agent-sessions/packages/protocol"
)

// RegisterRoutes 把领域服务挂载到 /v1 分组，并装配鉴权/权限中间件。
// 业务 scope 一律从认证上下文推导，handler 不信任客户端目标前缀。
func (a *API) RegisterRoutes(router *gin.Engine, logger *slog.Logger, presence *domain.PresenceHub) {
	a.Events = presence
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
		pub.POST("/auth/device-bootstrap", a.handleDeviceBootstrap)
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
		auth.GET("/audit", a.handleListAudit)
		auth.GET("/sessions/:id/controls", a.handleSessionControls)
		auth.GET("/sessions/:id/snapshot", a.handleSessionSnapshot)
		auth.GET("/sessions/:id/feedback", a.handleListMessageFeedback)
		auth.GET("/sessions/:id/feedback/:messageID", a.handleGetMessageFeedback)
		// P2-F 只读观察使用独立投影，不把 Daemon 专用 SSE、命令 payload 或原始密文交给 Android。
		auth.GET("/sessions/:id/commands", a.handleSessionDaemonObservation)
		// Web 只读 transport 是受限的 request/response 通道，不使用 RequireWrite；领域层仍会
		// 限定 web 角色、kind、Session -> Workspace -> Terminal 与密文 envelope。
		auth.GET("/sessions/:id/readonly-transport", a.handleWebReadTransport)
		auth.POST("/sessions/:id/readonly-requests", a.handleSubmitWebReadRequest)
		auth.GET("/sessions/:id/readonly-requests/:requestID", a.handleGetWebReadRequest)
		// Delegation 图可由同账号所有已配对端只读；创建和决策仍只允许 Android 写控制端。
		auth.GET("/sessions/:id/delegations", a.handleListDelegations)
		// 创建 Workspace/Session 会改变账号元数据，和会话命令一样只允许 Android 控制端发起。
		auth.POST("/sessions", a.RequireWrite(), a.handleCreateSession)
		auth.POST("/sessions/:id/commands", a.RequireWrite(), a.handleSubmitCommand)
		auth.POST("/sessions/:id/forks", a.RequireWrite(), a.handleForkSession)
		auth.PUT("/sessions/:id/feedback/:messageID", a.RequireWrite(), a.handlePutMessageFeedback)
		auth.DELETE("/sessions/:id/feedback/:messageID", a.RequireWrite(), a.handleDeleteMessageFeedback)
		auth.POST("/sessions/:id/delegations", a.RequireWrite(), a.handleCreateDelegation)
		auth.POST("/delegations/:id/decision", a.RequireWrite(), a.handleDelegationDecision)
		auth.GET("/commands/:id", a.handleGetCommand)
		auth.POST("/sessions/:id/lease", a.RequireWrite(), a.handleAcquireLease)
		// 附件写入和会话命令共用 Android 写身份与 fencing；Relay 只接收密文块。
		auth.POST("/attachments/chunks", a.RequireWrite(), a.handleUploadAttachmentChunk)
		auth.POST("/attachments/:id/complete", a.RequireWrite(), a.handleCompleteAttachment)
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

		// Daemon 使用独立的 Terminal 范围 REST + SSE，绝不复用账号级 /events。
		daemon := v1.Group("/daemon")
		daemon.Use(a.RequireAuth(), a.RequireTerminal())
		daemon.POST("/hello", a.handleDaemonHello)
		daemon.POST("/heartbeat", a.handleDaemonHeartbeat)
		daemon.GET("/commands/stream", a.handleDaemonCommandSSE(logger))
		daemon.POST("/commands/:id/ack", a.handleDaemonCommandAck)
		daemon.POST("/commands/:id/result", a.handleDaemonCommandResult)
		daemon.POST("/commands/:id/readonly-response", a.handleDaemonWebReadResponse)
		daemon.POST("/events", a.handleDaemonEventUpload)

		// Usage（ADR-010）：Terminal 上传白名单计数，账号只读聚合摘要。
		daemon.POST("/usage/events", a.handleUsageUpload)
		auth.GET("/usage/summary", a.handleUsageSummary)
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
			c.Header("Access-Control-Allow-Headers", "Content-Type, Authorization, Last-Event-ID")
			c.Header("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
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

// handleDeviceBootstrap 是 Android/Happy 主入口：首台手机以本机公钥初始化 owner，不要求账号登录。
func (a *API) handleDeviceBootstrap(c *gin.Context) {
	var req bootstrapRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		writeError(c, protocol.NewError(protocol.ErrInvalidRequest, "malformed request"))
		return
	}
	platform := req.Platform
	if strings.TrimSpace(platform) == "" {
		platform = "android"
	}
	dev, tokens, err := a.Auth.BootstrapInitialOwnerDevice(c.Request.Context(), domain.Device{
		Role: domain.RoleAndroidOwner, Status: domain.DeviceActive,
		DisplayName: req.DisplayName, Platform: platform,
		IdentityPublicKey: req.IdentityPublicKey, EncryptionPublicKey: req.EncryptionPublicKey,
	})
	if err != nil {
		writeError(c, err)
		return
	}
	c.JSON(http.StatusCreated, recoveryRestoreView{Device: newDeviceView(dev), Tokens: tokens})
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
	tokens, err := a.Auth.IssueForDevice(c.Request.Context(), subj.AccountID, dev.ID)
	if err != nil {
		writeError(c, err)
		return
	}
	writeOK(c, newPairingApprovalView(dev, tokens))
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

// handleListAudit 分页返回当前账号的脱敏审计元数据（ADMIN-04）。
// 只暴露 action/metadata 白名单；limit 上限 100，offset 非负。
func (a *API) handleListAudit(c *gin.Context) {
	subj := subject(c)
	limit := 50
	if raw := c.Query("limit"); raw != "" {
		parsed, err := parseIntQuery(raw)
		if err != nil || parsed > 100 {
			writeError(c, protocol.NewError(protocol.ErrInvalidRequest, "limit must be 1..100"))
			return
		}
		limit = parsed
	}
	offset := 0
	if raw := c.Query("offset"); raw != "" {
		parsed, err := parseIntQuery(raw)
		if err != nil {
			writeError(c, protocol.NewError(protocol.ErrInvalidRequest, "offset must be non-negative"))
			return
		}
		offset = parsed
	}
	rows, err := a.Repo.ListAudit(c.Request.Context(), subj.AccountID, limit, offset)
	if err != nil {
		writeError(c, err)
		return
	}
	type auditView struct {
		ID       int64  `json:"id"`
		Action   string `json:"action"`
		Metadata string `json:"metadata"`
	}
	views := make([]auditView, 0, len(rows))
	for _, row := range rows {
		views = append(views, auditView{ID: row.ID, Action: row.Action, Metadata: row.MetadataJSON})
	}
	writeOK(c, gin.H{"audit": views})
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

// handleSessionControls 返回会话 composer 可安全展示的白名单控制投影。
// 真实 Plan/Goal/Skill 正文仍只能来自客户端已解密事件；这里不返回 prompt、回复或 Provider payload。
func (a *API) handleSessionControls(c *gin.Context) {
	projection, err := a.Usage.SessionProjection(c.Request.Context(), subject(c).AccountID, c.Param("id"))
	if err != nil {
		writeError(c, err)
		return
	}
	if projection == nil {
		writeOK(c, gin.H{})
		return
	}
	view := gin.H{}
	if projection.Model != "" {
		view["model"] = projection.Model
	}
	if projection.HasUsage {
		view["usage"] = newSessionUsageView(*projection)
	}
	writeOK(c, view)
}

func (a *API) handleListMessageFeedback(c *gin.Context) {
	rows, err := a.MessageFeedback.List(c.Request.Context(), subject(c).AccountID, c.Param("id"))
	if err != nil {
		writeError(c, err)
		return
	}
	views := make([]messageFeedbackItemView, 0, len(rows))
	for _, row := range rows {
		views = append(views, newMessageFeedbackItemView(row))
	}
	writeOK(c, gin.H{"items": views})
}

func (a *API) handleGetMessageFeedback(c *gin.Context) {
	item, err := a.MessageFeedback.Get(c.Request.Context(), subject(c).AccountID, c.Param("id"), c.Param("messageID"))
	if err != nil {
		writeError(c, err)
		return
	}
	if item == nil {
		writeOK(c, gin.H{"item": nil})
		return
	}
	writeOK(c, gin.H{"item": newMessageFeedbackItemView(*item)})
}

type messageFeedbackMutationRequest struct {
	Rating  string `json:"rating"`
	Note    string `json:"note"`
	Version *int64 `json:"version"`
}

func (a *API) handlePutMessageFeedback(c *gin.Context) {
	var req messageFeedbackMutationRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		writeError(c, protocol.NewError(protocol.ErrInvalidRequest, "malformed feedback request"))
		return
	}
	subj := subject(c)
	item, err := a.MessageFeedback.Put(c.Request.Context(), domain.MessageFeedbackInput{
		AccountID: subj.AccountID, DeviceID: subj.DeviceID, Role: subj.Role,
		SessionID: c.Param("id"), MessageID: c.Param("messageID"),
		Rating: req.Rating, Note: req.Note, ExpectedVersion: req.Version,
	})
	if err != nil {
		var conflict domain.MessageFeedbackConflictError
		if errors.As(err, &conflict) {
			writeOK(c, messageFeedbackMutationView{
				OK: false, ErrorCode: "version-conflict",
				Current: optionalMessageFeedbackItemView(conflict.Current),
			})
			return
		}
		writeError(c, err)
		return
	}
	writeOK(c, messageFeedbackMutationView{OK: true, Item: optionalMessageFeedbackItemView(&item)})
}

func (a *API) handleDeleteMessageFeedback(c *gin.Context) {
	var req messageFeedbackMutationRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		writeError(c, protocol.NewError(protocol.ErrInvalidRequest, "malformed feedback request"))
		return
	}
	subj := subject(c)
	_, err := a.MessageFeedback.Delete(c.Request.Context(), domain.MessageFeedbackInput{
		AccountID: subj.AccountID, DeviceID: subj.DeviceID, Role: subj.Role,
		SessionID: c.Param("id"), MessageID: c.Param("messageID"), ExpectedVersion: req.Version,
	})
	if err != nil {
		var conflict domain.MessageFeedbackConflictError
		if errors.As(err, &conflict) {
			writeOK(c, messageFeedbackMutationView{
				OK: false, ErrorCode: "version-conflict",
				Current: optionalMessageFeedbackItemView(conflict.Current),
			})
			return
		}
		writeError(c, err)
		return
	}
	writeOK(c, messageFeedbackMutationView{OK: true})
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

// handleSessionDaemonObservation 返回 Android 可消费的 Daemon 安全投影。
// 这里不复用 /v1/daemon/commands/stream：后者只属于目标 Terminal，向 Android 暴露会突破
// Terminal scope。观察页也不返回原始 envelope，防止无 DEK 的页面误解密或缓存密文。
func (a *API) handleSessionDaemonObservation(c *gin.Context) {
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
	commands, err := a.Sessions.ListDaemonCommandObservations(c.Request.Context(), session.AccountID, session.ID)
	if err != nil {
		writeError(c, err)
		return
	}
	events, err := a.Sessions.ListEventsAfter(c.Request.Context(), session.ID, afterSeq)
	if err != nil {
		writeError(c, err)
		return
	}
	eventViews := make([]daemonCipherEventObservationView, 0, len(events))
	for _, event := range events {
		eventViews = append(eventViews, newDaemonCipherEventObservationView(event))
	}
	commandViews := make([]daemonCommandObservationView, 0, len(commands))
	for _, command := range commands {
		commandViews = append(commandViews, newDaemonCommandObservationView(command))
	}
	writeOK(c, daemonSessionObservationView{
		Session: daemonObservationSessionView{
			Status: session.Status, Provider: session.Provider, LastSeq: session.LastSeq,
		},
		Commands: commandViews,
		Events:   eventViews,
	})
}

// handleWebReadTransport 返回当前会话所绑定 Terminal 的配对公钥。该公钥不是内容密钥；浏览器
// 仅用它为本次请求生成临时 ECDH secret，Relay 不会看到路径、文件或 diff 明文。
func (a *API) handleWebReadTransport(c *gin.Context) {
	info, err := a.Sessions.WebReadTransportForSession(c.Request.Context(), subject(c).AccountID, subject(c).Role, c.Param("id"))
	if err != nil {
		writeError(c, err)
		return
	}
	writeOK(c, gin.H{"terminal_id": info.TerminalID, "workspace_id": info.WorkspaceID, "encryption_public_key": info.EncryptionPublicKey, "algorithm": info.Algorithm})
}

type webReadRequestBody struct {
	RequestID string          `json:"request_id"`
	Kind      string          `json:"kind"`
	Envelope  json.RawMessage `json:"envelope"`
}

// handleSubmitWebReadRequest 只转发 opaque envelope。这里不解密、不打印 body，也不接受浏览器
// 提供 terminal/workspace/lease，避免只读页面演化成写控制入口。
func (a *API) handleSubmitWebReadRequest(c *gin.Context) {
	var req webReadRequestBody
	if err := c.ShouldBindJSON(&req); err != nil || !json.Valid(req.Envelope) {
		writeError(c, protocol.NewError(protocol.ErrInvalidRequest, "malformed web read request"))
		return
	}
	command, err := a.Sessions.SubmitWebReadCommand(c.Request.Context(), domain.WebReadCommandInput{
		AccountID: subject(c).AccountID, Role: subject(c).Role, SessionID: c.Param("id"),
		RequestID: req.RequestID, Kind: req.Kind, EnvelopeJSON: string(req.Envelope),
	})
	if err != nil {
		writeError(c, err)
		return
	}
	// Web 只读命令和 Android 写命令共用 Terminal 专用 delivery 表。提交事务已保证断线后能从
	// SQLite 重放；这里仅向已连接的 Daemon 推送实时通知，避免它在长连接期间错过新请求。
	if command.TargetTerminalID != "" {
		if delivery, deliveryErr := a.Sessions.DaemonDeliveryForCommand(c.Request.Context(), command.ID); deliveryErr == nil {
			a.DaemonDeliveries.Publish(command.TargetTerminalID, delivery)
		}
	}
	c.JSON(http.StatusAccepted, gin.H{"request_id": command.ID, "kind": command.Kind, "status": command.Status})
}

// handleGetWebReadRequest 返回 command 状态与完成后的 opaque response envelope；响应不会混入
// Session snapshot，防止既有 Web SSE 消费路径意外保存内容。
func (a *API) handleGetWebReadRequest(c *gin.Context) {
	result, err := a.Sessions.GetWebReadCommand(c.Request.Context(), subject(c).AccountID, subject(c).Role, c.Param("id"), c.Param("requestID"))
	if err != nil {
		writeError(c, err)
		return
	}
	view := gin.H{"request_id": result.RequestID, "kind": result.Kind, "status": result.Status}
	if result.ErrorCode != "" {
		view["error_code"] = result.ErrorCode
	}
	if result.ResponseEnvelopeJSON != "" {
		view["envelope"] = json.RawMessage(result.ResponseEnvelopeJSON)
	}
	writeOK(c, view)
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
	a.publishPersistedSessionEvents(c.Request.Context(), subj.AccountID, sess.ID, sess.LastSeq-1)
	c.JSON(http.StatusCreated, newSessionView(sess))
}

type forkSessionRequest struct {
	MessageID      string `json:"message_id"`
	IdempotencyKey string `json:"idempotency_key"`
	LeaseEpoch     int64  `json:"lease_epoch"`
}

func (a *API) handleForkSession(c *gin.Context) {
	var req forkSessionRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		writeError(c, protocol.NewError(protocol.ErrInvalidRequest, "malformed fork request"))
		return
	}
	subj := subject(c)
	child, err := a.Sessions.ForkSession(c.Request.Context(), domain.SessionForkInput{
		AccountID: subj.AccountID, DeviceID: subj.DeviceID, Role: subj.Role,
		ParentSessionID: c.Param("id"), MessageID: req.MessageID,
		IdempotencyKey: req.IdempotencyKey, LeaseEpoch: req.LeaseEpoch,
	})
	if err != nil {
		writeError(c, err)
		return
	}
	a.publishLatestSessionEvent(c.Request.Context(), subj.AccountID, c.Param("id"))
	a.publishPersistedSessionEvents(c.Request.Context(), subj.AccountID, child.ID, 0)
	c.JSON(http.StatusCreated, newSessionView(child))
}

type submitCommandRequest struct {
	Kind             string          `json:"kind"`
	IdempotencyKey   string          `json:"idempotency_key"`
	LeaseEpoch       int64           `json:"lease_epoch"`
	TargetInstanceID string          `json:"target_instance_id"`
	TargetTerminalID string          `json:"target_terminal_id"`
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
		LeaseEpoch: req.LeaseEpoch, TargetInstanceID: req.TargetInstanceID, TargetTerminalID: req.TargetTerminalID,
		CiphertextJSON: string(req.Ciphertext),
	})
	if err != nil {
		writeError(c, err)
		return
	}
	// 投递已经随命令事务提交；Hub 只缩短已连接 Daemon 的可见延迟，断线恢复仍读取 SQLite。
	if cmd.TargetTerminalID != "" {
		if delivery, deliveryErr := a.Sessions.DaemonDeliveryForCommand(c.Request.Context(), cmd.ID); deliveryErr == nil {
			a.DaemonDeliveries.Publish(cmd.TargetTerminalID, delivery)
		}
	}
	c.JSON(http.StatusAccepted, newCommandView(cmd))
}

// Delegation 请求只包含密文任务书/摘要、目标 Provider 与父会话 fencing；不接受正文、路径或 child 会话内容。
type createDelegationRequest struct {
	TargetWorkspaceID string          `json:"target_workspace_id"`
	TargetTerminalID  string          `json:"target_terminal_id"`
	TargetProvider    string          `json:"target_provider"`
	TaskEnvelope      json.RawMessage `json:"task_envelope"`
	SummaryEnvelope   json.RawMessage `json:"summary_envelope"`
	IdempotencyKey    string          `json:"idempotency_key"`
	LeaseEpoch        int64           `json:"lease_epoch"`
}

type delegationDecisionRequest struct {
	Decision       string `json:"decision"`
	IdempotencyKey string `json:"idempotency_key"`
	LeaseEpoch     int64  `json:"lease_epoch"`
}

const maxDelegationRequestBytes int64 = 96 * 1024

// handleCreateDelegation 只创建 Android 可见的 proposed 卡片；批准前不能创建 child 或启动 Provider。
func (a *API) handleCreateDelegation(c *gin.Context) {
	var req createDelegationRequest
	if err := decodeStrictDelegationJSON(c, &req); err != nil {
		writeError(c, protocol.NewError(protocol.ErrInvalidRequest, "malformed delegation request"))
		return
	}
	subj := subject(c)
	delegation, err := a.Delegations.CreateProposal(c.Request.Context(), domain.DelegationCreateInput{
		AccountID: subj.AccountID, DeviceID: subj.DeviceID, Role: subj.Role,
		ParentSessionID: c.Param("id"), TargetWorkspaceID: req.TargetWorkspaceID,
		TargetTerminalID: req.TargetTerminalID, TargetProvider: req.TargetProvider,
		TaskEnvelope: req.TaskEnvelope, SummaryEnvelope: req.SummaryEnvelope,
		IdempotencyKey: req.IdempotencyKey, LeaseEpoch: req.LeaseEpoch,
	})
	if err != nil {
		writeError(c, err)
		return
	}
	a.publishLatestSessionEvent(c.Request.Context(), subj.AccountID, delegation.ParentSessionID)
	c.JSON(http.StatusAccepted, newDelegationView(delegation))
}

// handleListDelegations 仅投影 parent 的状态、child id、Provider 和加密摘要；任务书与 child 正文都不会离开 Relay。
func (a *API) handleListDelegations(c *gin.Context) {
	rows, err := a.Delegations.ListForParent(c.Request.Context(), subject(c).AccountID, c.Param("id"))
	if err != nil {
		writeError(c, err)
		return
	}
	views := make([]delegationView, 0, len(rows))
	for _, row := range rows {
		views = append(views, newDelegationView(row))
	}
	writeOK(c, gin.H{"delegations": views})
}

// handleDelegationDecision 用 parent 当前 lease 保护 approve/reject/cancel；进入 child 后由 child lease 接管写控制。
func (a *API) handleDelegationDecision(c *gin.Context) {
	var req delegationDecisionRequest
	if err := decodeStrictDelegationJSON(c, &req); err != nil {
		writeError(c, protocol.NewError(protocol.ErrInvalidRequest, "malformed delegation decision"))
		return
	}
	subj := subject(c)
	delegation, err := a.Delegations.Decide(c.Request.Context(), domain.DelegationDecisionInput{
		AccountID: subj.AccountID, DeviceID: subj.DeviceID, Role: subj.Role,
		DelegationID: c.Param("id"), Decision: req.Decision, IdempotencyKey: req.IdempotencyKey,
		ParentLeaseEpoch: req.LeaseEpoch,
	})
	if err != nil {
		writeError(c, err)
		return
	}
	a.publishLatestSessionEvent(c.Request.Context(), subj.AccountID, delegation.ParentSessionID)
	writeOK(c, newDelegationView(delegation))
}

// decodeStrictDelegationJSON 与附件链路一样拒绝未知字段，避免任务明文在协议扩展时被悄悄接收。
func decodeStrictDelegationJSON(c *gin.Context, destination any) error {
	c.Request.Body = http.MaxBytesReader(c.Writer, c.Request.Body, maxDelegationRequestBytes)
	decoder := json.NewDecoder(c.Request.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(destination); err != nil {
		return err
	}
	if err := decoder.Decode(&struct{}{}); err != io.EOF {
		if err == nil {
			return errors.New("multiple JSON values")
		}
		return err
	}
	return nil
}

// attachmentChunkRequest 是附件上传 wire DTO。没有 filename 或正文，所有可识别元数据都必须位于 metadata_ciphertext。
type attachmentChunkRequest struct {
	AttachmentID       string `json:"attachment_id"`
	SessionID          string `json:"session_id"`
	MimeType           string `json:"mime_type"`
	ByteSize           int64  `json:"byte_size"`
	Compression        string `json:"compression"`
	MetadataCiphertext []byte `json:"metadata_ciphertext"`
	ChunkIndex         int    `json:"chunk_index"`
	TotalChunks        int    `json:"total_chunks"`
	Ciphertext         []byte `json:"ciphertext"`
	IdempotencyKey     string `json:"idempotency_key"`
	LeaseEpoch         int64  `json:"lease_epoch"`
}

const (
	// 最大 chunk 为 512 KiB、metadata 为 16 KiB；预留 base64 编码和 JSON 字段开销后，
	// 768 KiB 足以承载合法请求，同时避免解码器先把任意大的 base64 字符串留在内存中。
	maxAttachmentChunkRequestBytes int64 = 768 * 1024
	// complete 没有密文，单独使用较小上限，避免 path/body 型接口成为大请求入口。
	maxAttachmentCompleteRequestBytes int64 = 32 * 1024
)

// handleUploadAttachmentChunk 从认证上下文写入设备/账号边界，绝不采信客户端声称的 device_id。
func (a *API) handleUploadAttachmentChunk(c *gin.Context) {
	var req attachmentChunkRequest
	if err := decodeStrictAttachmentJSON(c, &req, maxAttachmentChunkRequestBytes); err != nil {
		writeAttachmentDecodeError(c, err, "malformed attachment upload")
		return
	}
	subj := subject(c)
	receipt, err := a.Attachments.UploadChunk(c.Request.Context(), domain.AttachmentChunkInput{
		AccountID: subj.AccountID, DeviceID: subj.DeviceID, Role: subj.Role,
		AttachmentID: req.AttachmentID, SessionID: req.SessionID,
		MimeType: req.MimeType, ByteSize: req.ByteSize, Compression: req.Compression,
		MetadataCiphertext: req.MetadataCiphertext, ChunkIndex: req.ChunkIndex,
		TotalChunks: req.TotalChunks, Ciphertext: req.Ciphertext,
		IdempotencyKey: req.IdempotencyKey, LeaseEpoch: req.LeaseEpoch,
	})
	if err != nil {
		writeError(c, err)
		return
	}
	c.JSON(http.StatusCreated, newAttachmentReceiptView(receipt))
}

// attachmentCompleteRequest 仅允许收口已完整到达的密文块，完成本身也必须具有独立幂等键。
type attachmentCompleteRequest struct {
	SessionID      string `json:"session_id"`
	TotalChunks    int    `json:"total_chunks"`
	IdempotencyKey string `json:"idempotency_key"`
	LeaseEpoch     int64  `json:"lease_epoch"`
}

// handleCompleteAttachment 用 path attachment id 避免 body 与资源路径出现双重、可被混淆的身份字段。
func (a *API) handleCompleteAttachment(c *gin.Context) {
	var req attachmentCompleteRequest
	if err := decodeStrictAttachmentJSON(c, &req, maxAttachmentCompleteRequestBytes); err != nil {
		writeAttachmentDecodeError(c, err, "malformed attachment completion")
		return
	}
	subj := subject(c)
	receipt, err := a.Attachments.Complete(c.Request.Context(), domain.AttachmentCompleteInput{
		AccountID: subj.AccountID, DeviceID: subj.DeviceID, Role: subj.Role,
		AttachmentID: c.Param("id"), SessionID: req.SessionID,
		TotalChunks: req.TotalChunks, IdempotencyKey: req.IdempotencyKey,
		LeaseEpoch: req.LeaseEpoch,
	})
	if err != nil {
		writeError(c, err)
		return
	}
	writeOK(c, newAttachmentReceiptView(receipt))
}

// decodeStrictAttachmentJSON 禁止未知字段，特别是 filename/明文摘要等不能进入 Relay 的字段。
// 其他历史 API 保持兼容绑定；附件链路从首次发布起即固定为最小密文契约。
func decodeStrictAttachmentJSON(c *gin.Context, destination any, maxBytes int64) error {
	// 必须在 JSON/base64 解码前截断 body，不能只在领域层校验解码后的 []byte。
	c.Request.Body = http.MaxBytesReader(c.Writer, c.Request.Body, maxBytes)
	decoder := json.NewDecoder(c.Request.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(destination); err != nil {
		return err
	}
	if err := decoder.Decode(&struct{}{}); err != io.EOF {
		if err == nil {
			return errors.New("multiple JSON values")
		}
		return err
	}
	return nil
}

// writeAttachmentDecodeError 为 body 超限保留稳定的 413/PAYLOAD_TOO_LARGE 契约，其他格式错误仍为 400。
func writeAttachmentDecodeError(c *gin.Context, err error, malformedMessage string) {
	var maxBytesErr *http.MaxBytesError
	if errors.As(err, &maxBytesErr) {
		c.AbortWithStatusJSON(http.StatusRequestEntityTooLarge,
			protocol.NewError(protocol.ErrPayloadTooLarge, "attachment request too large"))
		return
	}
	writeError(c, protocol.NewError(protocol.ErrInvalidRequest, malformedMessage))
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
// 每次请求都实时执行 Detect（见 adapterreg.Registry.List），因此反映真实探测结果：
// opencode 未健康时 fail-closed，绝不把 mock/静态矩阵伪造成可用。
// 口径见 docs/zh/项目文档.md「8. 统一能力模型」；Web 只读消费方式见「Vue Web App」章节。
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
	TerminalID    string `json:"terminal_id"`
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
	if req.TerminalID != "" {
		terminal, terminalErr := a.Repo.TerminalByID(c.Request.Context(), req.TerminalID)
		if terminalErr != nil || terminal.AccountID != subj.AccountID {
			writeError(c, domain.ErrScopeDenied)
			return
		}
	}
	ws := store.WorkspaceRow{
		ID: "ws_" + projID, ProjectID: projID, TerminalID: req.TerminalID,
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

type pairingApprovalView struct {
	deviceView
	Tokens domain.TokenPair `json:"tokens"`
}

func newPairingApprovalView(device domain.Device, tokens domain.TokenPair) pairingApprovalView {
	return pairingApprovalView{deviceView: newDeviceView(device), Tokens: tokens}
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
	ID              string `json:"id"`
	DeviceID        string `json:"device_id"`
	Hostname        string `json:"hostname,omitempty"`
	Platform        string `json:"platform,omitempty"`
	Status          string `json:"status"`
	LastSeenUnixMS  int64  `json:"last_seen_unix_ms,omitempty"`
	ProtocolVersion int    `json:"protocol_version,omitempty"`
	DaemonVersion   string `json:"daemon_version,omitempty"`
}

func newTerminalView(terminal store.TerminalRow) terminalView {
	return terminalView{
		ID: terminal.ID, DeviceID: terminal.DeviceID, Hostname: terminal.Hostname,
		Platform: terminal.Platform, Status: terminal.Status, LastSeenUnixMS: terminal.LastSeenUnixMS,
		ProtocolVersion: terminal.ProtocolVersion, DaemonVersion: terminal.DaemonVersion,
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
	ID                  string `json:"id"`
	WorkspaceID         string `json:"workspace_id"`
	Status              string `json:"status"`
	Provider            string `json:"provider,omitempty"`
	Model               string `json:"model,omitempty"`
	LastSeq             int64  `json:"last_seq"`
	ParentSessionID     string `json:"parent_session_id,omitempty"`
	ForkedFromMessageID string `json:"forked_from_message_id,omitempty"`
}

func newSessionView(session store.SessionRow) sessionView {
	return sessionView{
		ID: session.ID, WorkspaceID: session.WorkspaceID, Status: session.Status,
		Provider: session.Provider, Model: session.Model, LastSeq: session.LastSeq,
		ParentSessionID: session.ParentSessionID, ForkedFromMessageID: session.ForkedFromMessageID,
	}
}

type sessionUsageView struct {
	InputTokens      int64    `json:"input_tokens"`
	OutputTokens     int64    `json:"output_tokens"`
	CacheReadTokens  int64    `json:"cache_read_tokens,omitempty"`
	CacheWriteTokens int64    `json:"cache_write_tokens,omitempty"`
	ContextTokens    int64    `json:"context_tokens,omitempty"`
	TTFTMS           *int64   `json:"ttft_ms,omitempty"`
	DecodeThroughput *float64 `json:"decode_throughput,omitempty"`
}

func newSessionUsageView(usage domain.SessionUsageProjection) sessionUsageView {
	return sessionUsageView{
		InputTokens: usage.InputTokens, OutputTokens: usage.OutputTokens,
		CacheReadTokens: usage.CacheReadTokens, CacheWriteTokens: usage.CacheWriteTokens,
		ContextTokens: usage.InputTokens + usage.OutputTokens + usage.CacheReadTokens + usage.CacheWriteTokens,
		TTFTMS:        usage.TTFTMS, DecodeThroughput: usage.DecodeThroughput,
	}
}

type messageFeedbackItemView struct {
	MessageID         string `json:"message_id"`
	Rating            string `json:"rating"`
	Note              string `json:"note,omitempty"`
	Version           int64  `json:"version"`
	UpdatedByDeviceID string `json:"updated_by_device_id,omitempty"`
	UpdatedAtUnixMS   int64  `json:"updated_at_unix_ms"`
}

type messageFeedbackMutationView struct {
	OK        bool                     `json:"ok"`
	ErrorCode string                   `json:"error_code,omitempty"`
	Item      *messageFeedbackItemView `json:"item,omitempty"`
	Current   *messageFeedbackItemView `json:"current,omitempty"`
}

func newMessageFeedbackItemView(row store.MessageFeedbackRow) messageFeedbackItemView {
	return messageFeedbackItemView{
		MessageID: row.MessageID, Rating: row.Rating, Note: row.Note,
		Version: row.Version, UpdatedByDeviceID: row.UpdatedByDeviceID, UpdatedAtUnixMS: row.UpdatedAtUnixMS,
	}
}

func optionalMessageFeedbackItemView(row *store.MessageFeedbackRow) *messageFeedbackItemView {
	if row == nil {
		return nil
	}
	view := newMessageFeedbackItemView(*row)
	return &view
}

type commandView struct {
	ID               string `json:"id"`
	Kind             string `json:"kind"`
	Status           string `json:"status"`
	IdempotencyKey   string `json:"idempotency_key"`
	LeaseEpoch       int64  `json:"lease_epoch,omitempty"`
	TargetTerminalID string `json:"target_terminal_id,omitempty"`
}

// delegationView 是 parent 图的安全投影。task_envelope 从不返回；summary_envelope 仍是客户端加密对象。
type delegationView struct {
	ID                    string          `json:"id"`
	ParentSessionID       string          `json:"parent_session_id"`
	ChildSessionID        string          `json:"child_session_id,omitempty"`
	TargetProvider        string          `json:"target_provider"`
	Status                string          `json:"status"`
	SummaryEnvelope       json.RawMessage `json:"summary_envelope"`
	SummaryEnvelopeSHA256 string          `json:"summary_envelope_sha256"`
}

func newDelegationView(delegation store.DelegationRow) delegationView {
	return delegationView{
		ID: delegation.ID, ParentSessionID: delegation.ParentSessionID,
		ChildSessionID: delegation.ChildSessionID, TargetProvider: delegation.TargetProvider,
		Status: delegation.Status, SummaryEnvelope: json.RawMessage(delegation.SummaryEnvelopeJSON),
		SummaryEnvelopeSHA256: delegation.SummaryEnvelopeSHA256,
	}
}

// attachmentReceiptView 不回显 ciphertext、metadata_ciphertext 或客户端显示名，避免响应链路扩大可见范围。
type attachmentReceiptView struct {
	AttachmentID string `json:"attachment_id"`
	ChunkIndex   int    `json:"chunk_index"`
	Status       string `json:"status"`
	Idempotent   bool   `json:"idempotent"`
}

func newAttachmentReceiptView(receipt domain.AttachmentReceipt) attachmentReceiptView {
	return attachmentReceiptView{
		AttachmentID: receipt.AttachmentID,
		ChunkIndex:   receipt.ChunkIndex,
		Status:       receipt.Status,
		Idempotent:   receipt.Idempotent,
	}
}

func newCommandView(command store.CommandRow) commandView {
	return commandView{
		ID: command.ID, Kind: command.Kind, Status: command.Status,
		IdempotencyKey: command.IdempotencyKey, LeaseEpoch: command.LeaseEpoch, TargetTerminalID: command.TargetTerminalID,
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

// daemonSessionObservationView 只保留 Flutter 观察页显示状态所需的字段。
// workspace_id、session id 由路由已知但不在投影中重传，降低只读响应的关联面。
type daemonSessionObservationView struct {
	Session  daemonObservationSessionView       `json:"session"`
	Commands []daemonCommandObservationView     `json:"commands"`
	Events   []daemonCipherEventObservationView `json:"events"`
}

type daemonObservationSessionView struct {
	Status   string `json:"status"`
	Provider string `json:"provider,omitempty"`
	LastSeq  int64  `json:"last_seq"`
}

// daemonCommandObservationView 不回显 command ID、target terminal、lease、幂等键或密文。
type daemonCommandObservationView struct {
	Kind          string `json:"kind"`
	Status        string `json:"status"`
	DeliveryState string `json:"delivery_state"`
	ErrorCode     string `json:"error_code,omitempty"`
}

func newDaemonCommandObservationView(command domain.DaemonCommandObservation) daemonCommandObservationView {
	return daemonCommandObservationView{
		Kind: command.Kind, Status: command.Status, DeliveryState: command.DeliveryState, ErrorCode: command.ErrorCode,
	}
}

type daemonCipherEventObservationView struct {
	EventSeq  int64                      `json:"event_seq"`
	EventType string                     `json:"event_type"`
	Envelope  cipherEnvelopeMetadataView `json:"envelope"`
}

type cipherEnvelopeMetadataView struct {
	State          string `json:"state"`
	Algorithm      string `json:"algorithm,omitempty"`
	PayloadVersion int    `json:"payload_version,omitempty"`
}

// newDaemonCipherEventObservationView 只验证并转发安全元数据；原始 envelope 永远不进入该 DTO。
func newDaemonCipherEventObservationView(event store.SessionEventRow) daemonCipherEventObservationView {
	return daemonCipherEventObservationView{
		EventSeq: event.EventSeq, EventType: daemonObservationEventType(event.EventType),
		Envelope: daemonCipherEnvelopeMetadata(event.EnvelopeJSON),
	}
}

func daemonObservationEventType(value string) string {
	switch value {
	case "session.lifecycle", "turn.started", "message.delta", "message.completed", "tool.call", "tool.result", "usage.updated", "file.changed", "git.snapshot", "command.updated":
		return value
	default:
		return "unknown"
	}
}

func daemonCipherEnvelopeMetadata(raw string) cipherEnvelopeMetadataView {
	var envelope map[string]json.RawMessage
	if err := json.Unmarshal([]byte(raw), &envelope); err != nil {
		return cipherEnvelopeMetadataView{State: "opaque"}
	}
	var algorithm, keyID, nonce, ciphertext, aadHash string
	var payloadVersion int
	if json.Unmarshal(envelope["alg"], &algorithm) != nil || algorithm != contentcrypto.AlgorithmVersion ||
		json.Unmarshal(envelope["key_id"], &keyID) != nil || strings.TrimSpace(keyID) == "" ||
		json.Unmarshal(envelope["nonce"], &nonce) != nil || strings.TrimSpace(nonce) == "" ||
		json.Unmarshal(envelope["ciphertext"], &ciphertext) != nil || strings.TrimSpace(ciphertext) == "" ||
		json.Unmarshal(envelope["aad_hash"], &aadHash) != nil || strings.TrimSpace(aadHash) == "" ||
		json.Unmarshal(envelope["payload_version"], &payloadVersion) != nil || payloadVersion < 1 {
		return cipherEnvelopeMetadataView{State: "opaque"}
	}
	return cipherEnvelopeMetadataView{
		State: "verified", Algorithm: contentcrypto.AlgorithmVersion, PayloadVersion: payloadVersion,
	}
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
