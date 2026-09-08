package relay

import (
	"database/sql"
	"log/slog"
	"net/http"

	"github.com/gin-gonic/gin"
	"github.com/yubi233/agent-sessions/internal/daemon"
	"github.com/yubi233/agent-sessions/internal/domain"
	"github.com/yubi233/agent-sessions/internal/httpapi"
	"github.com/yubi233/agent-sessions/internal/store"
)

// NewServer 创建 Relay 的 HTTP 边界，装配健康检查与 /v1 业务路由。
// 健康检查无鉴权；业务 API 以设备令牌和中间件保护。
// 默认保持 ADR-012 的 optional 兼容窗口（bearer + 签名双轨）。
func NewServer(db *sql.DB, logger *slog.Logger) *gin.Engine {
	return newServer(db, logger, false)
}

// NewServerWithTerminalSignatureRequired 以 required 签名模式创建 Relay：
// 旧 bearer Daemon 的签名端点一律返回稳定 UPGRADE_REQUIRED，用于兼容窗口结束后的发布形态。
func NewServerWithTerminalSignatureRequired(db *sql.DB, logger *slog.Logger) *gin.Engine {
	return newServer(db, logger, true)
}

// NewServerWithPresence 与 NewServer 相同，但额外返回进程内 PresenceHub，
// 供测试断言 session SSE「断开即释放订阅」契约（v0.9.0 V090-08）。
func NewServerWithPresence(db *sql.DB, logger *slog.Logger) (*gin.Engine, *domain.PresenceHub) {
	return newServerWithPresence(db, logger, false)
}

// NewServerWithRuntime 创建 Relay 并额外返回进程内运行时组件：PresenceHub 与
// 有界 presence reaper（v0.9.1 P1）。调用方负责 `go reaper.Run()` 并在进程关闭时
// `reaper.Stop()`；测试/不需要过期通知的装配可继续使用 NewServer（不启动 reaper，
// read/command 路径不依赖它，见 V091-03）。
func NewServerWithRuntime(db *sql.DB, logger *slog.Logger, signatureRequired bool) (*gin.Engine, *domain.PresenceHub, *domain.PresenceReaper) {
	router, presence := newServerWithPresence(db, logger, signatureRequired)
	reaper := domain.NewPresenceReaper(store.NewRepository(db), presence, logger)
	return router, presence, reaper
}

func newServer(db *sql.DB, logger *slog.Logger, signatureRequired bool) *gin.Engine {
	router, _ := newServerWithPresence(db, logger, signatureRequired)
	return router
}

func newServerWithPresence(db *sql.DB, logger *slog.Logger, signatureRequired bool) (*gin.Engine, *domain.PresenceHub) {
	router := gin.New()
	if logger == nil {
		logger = slog.Default()
	}
	router.Use(gin.Logger(), gin.Recovery())

	health := router.Group("/")
	health.Use(localHealthCORS())
	health.GET("healthz", func(c *gin.Context) {
		c.JSON(http.StatusOK, gin.H{"status": "ok"})
	})
	health.GET("readyz", func(c *gin.Context) {
		if err := db.PingContext(c.Request.Context()); err != nil {
			c.JSON(http.StatusServiceUnavailable, gin.H{"status": "unavailable"})
			return
		}
		c.JSON(http.StatusOK, gin.H{"status": "ready"})
	})

	// 装配 P1 业务路由。
	repo := store.NewRepository(db)
	auth := domain.NewAuthService(repo)
	pairing := domain.NewPairingService(repo)
	sessions := domain.NewSessionService(repo)
	// v0.1 只注入 deterministic mock dispatcher；真实 Provider 需专属凭据与授权后另行装配。
	delegations := domain.NewDelegationService(repo, daemon.NewDeterministicDelegationDispatcher())
	presence := domain.NewPresenceHub(0)
	api := httpapi.New(auth, pairing, sessions, delegations, repo)
	// 签名窗口开关在路由装配前注入，保证首个请求就按当前模式校验。
	api.Daemons.SetTerminalSignatureRequired(signatureRequired)
	// v0.9.1 C3：hello/heartbeat 的 presence invalidation 经同一 Hub 发布给
	// 账号级 SSE 订阅者；nil 时服务不发布（仅失去加速，不失去正确性）。
	api.Daemons.Hub = presence
	api.RegisterRoutes(router, logger, presence)
	return router, presence
}

// localHealthCORS 只允许本地 P0 Web 状态页读取健康端点。
// 与业务 API 的 localAPICORS 保持同一本地开发端口白名单（5173/5174 为 Vite Web/Admin 端口）。
// 业务 API 在 P1 以设备令牌和更严格的来源策略保护，不能复用该宽松边界。
func localHealthCORS() gin.HandlerFunc {
	allowedOrigins := map[string]bool{
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
		if allowedOrigins[origin] {
			c.Header("Access-Control-Allow-Origin", origin)
			c.Header("Vary", "Origin")
		}
		if c.Request.Method == http.MethodOptions {
			c.Status(http.StatusNoContent)
			c.Abort()
			return
		}
		c.Next()
	}
}
