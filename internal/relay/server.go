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
func NewServer(db *sql.DB, logger *slog.Logger) *gin.Engine {
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
	api.RegisterRoutes(router, logger, presence)
	return router
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
