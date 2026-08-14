package relay

import (
	"database/sql"
	"net/http"

	"github.com/gin-gonic/gin"
)

// NewServer 创建 Relay 的 HTTP 边界。业务端点在后续 P1 工作包中挂载，
// 健康检查保持无鉴权，供本地启动、浏览器 smoke 与部署探针复用。
func NewServer(db *sql.DB) *gin.Engine {
	router := gin.New()
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
	return router
}

// localHealthCORS 只允许本地 P0 Web 状态页读取健康端点。
// 业务 API 在 P1 以设备令牌和更严格的来源策略保护，不能复用该宽松边界。
func localHealthCORS() gin.HandlerFunc {
	allowedOrigins := map[string]bool{
		"http://127.0.0.1:15173": true,
		"http://localhost:15173": true,
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
