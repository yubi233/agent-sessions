package relay

import (
	"database/sql"
	"log/slog"
	"net"
	"net/http"
	"os"
	"strings"

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
	// 代理信任面（XFF 伪造防线）：显式声明受信任网段，取代 Gin 默认的"信任所有"。
	// 云端 Caddy 经 compose 私网反代并追加真实客户端 IP（默认网段已覆盖）；
	// 公网直连 peer 不受信任，其 X-Forwarded-For 一律忽略，ClientIP 回落为套接字对端。
	if err := router.SetTrustedProxies(trustedProxies(logger)); err != nil {
		logger.Warn("设置受信任代理网段失败，回退为不信任任何代理", "error", err)
		_ = router.SetTrustedProxies(nil)
	}

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
	// v0.10.0（ADR-017）：owner 配对加入总开关，默认 off；显式开启后新设备
	// 可经未认证创建端点发起配对、由现役 owner 批准为第二个 active owner。
	pairing.OwnerPairingEnabled = os.Getenv("AGENT_SESSIONS_OWNER_PAIRING") == "on"
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

// EnvTrustedProxies 覆盖受信任代理网段（逗号分隔 CIDR 或裸 IP）；值 "none" 表示
// 全不信任（ClientIP 恒为套接字对端）。未设置→默认网段；显式置空或含非法条目→
// warn 并回落默认网段（保守方向，不阻断起服）。
const EnvTrustedProxies = "AGENT_SESSIONS_TRUSTED_PROXIES"

// defaultTrustedProxies 是默认信任网段：loopback + 私网 + 链路本地。
// 覆盖本地开发（127.0.0.1 直连）与云端部署（Caddy 容器经 compose 私网反代）两类拓扑。
var defaultTrustedProxies = []string{
	"127.0.0.0/8", "::1/128",
	"10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16",
	"fc00::/7", "fe80::/10", "169.254.0.0/16",
}

// trustedProxies 解析生效的受信任代理网段（见 EnvTrustedProxies）。
func trustedProxies(logger *slog.Logger) []string {
	raw, ok := os.LookupEnv(EnvTrustedProxies)
	if !ok {
		return defaultTrustedProxies
	}
	raw = strings.TrimSpace(raw)
	if raw == "" {
		logger.Warn("受信任代理网段显式置空，回落默认网段", "default", defaultTrustedProxies)
		return defaultTrustedProxies
	}
	if strings.EqualFold(raw, "none") {
		return nil
	}
	var proxies []string
	for _, part := range strings.Split(raw, ",") {
		entry := strings.TrimSpace(part)
		if entry == "" {
			continue
		}
		if _, _, err := net.ParseCIDR(entry); err != nil && net.ParseIP(entry) == nil {
			logger.Warn("受信任代理网段含非法条目，回落默认网段", "entry", entry)
			return defaultTrustedProxies
		}
		proxies = append(proxies, entry)
	}
	if len(proxies) == 0 {
		logger.Warn("受信任代理网段未包含有效条目，回落默认网段", "default", defaultTrustedProxies)
		return defaultTrustedProxies
	}
	return proxies
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
