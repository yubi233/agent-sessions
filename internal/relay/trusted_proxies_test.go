package relay

import (
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/yubi233/agent-sessions/internal/store"
)

// newTrustedProxyTestEnv 构造带 /__probe_ip 探针路由的引擎：
// 探针原样返回 gin 计算的 ClientIP，用于断言受信任代理网段的端到端效果。
// logger 固定 discard，避免回落 warn 污染测试输出。
func newTrustedProxyTestEnv(t *testing.T) *gin.Engine {
	t.Helper()
	path := filepath.Join(t.TempDir(), "relay.db")
	db, err := store.Open(path)
	if err != nil {
		t.Fatalf("open sqlite: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	router, _ := NewServerWithPresence(db, slog.New(slog.NewTextHandler(io.Discard, nil)))
	router.GET("/__probe_ip", func(c *gin.Context) {
		c.String(http.StatusOK, c.ClientIP())
	})
	return router
}

// probeClientIP 以指定 RemoteAddr/XFF 请求探针路由，返回引擎计算的 ClientIP。
func probeClientIP(t *testing.T, router *gin.Engine, remoteAddr string, xff string) string {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, "/__probe_ip", nil)
	req.RemoteAddr = remoteAddr
	if xff != "" {
		req.Header.Set("X-Forwarded-For", xff)
	}
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("探针状态码 %d", rec.Code)
	}
	return rec.Body.String()
}

// (a) 默认网段：公网直连 peer 的 XFF 必须被忽略（防伪造），ClientIP=套接字对端。
func TestTrustedProxiesPublicPeerIgnoresXFF(t *testing.T) {
	router := newTrustedProxyTestEnv(t)
	got := probeClientIP(t, router, "203.0.113.7:9999", "1.2.3.4")
	if got != "203.0.113.7" {
		t.Fatalf("公网 peer 的 XFF 必须被忽略: got %q", got)
	}
}

// (b) 默认网段：私网反代（Caddy 拓扑，真实客户端 IP 由代理追加在最右）正常解析。
func TestTrustedProxiesPrivateProxyResolvesClientIP(t *testing.T) {
	router := newTrustedProxyTestEnv(t)
	got := probeClientIP(t, router, "172.20.0.5:80", "1.2.3.4, 5.6.7.8")
	if got != "5.6.7.8" {
		t.Fatalf("私网代理链应取最右非信任条目: got %q", got)
	}
}

// (c) env=none：全不信任，任何 peer 的 XFF 都被忽略。
func TestTrustedProxiesNoneDisablesAll(t *testing.T) {
	t.Setenv(EnvTrustedProxies, "none")
	router := newTrustedProxyTestEnv(t)
	got := probeClientIP(t, router, "172.20.0.5:80", "9.9.9.9")
	if got != "172.20.0.5" {
		t.Fatalf("none 模式必须忽略 XFF: got %q", got)
	}
}

// (d) env 自定义网段：裸 IP/CIDR 混合合法，命中即信任其 XFF。
func TestTrustedProxiesCustomCIDROverride(t *testing.T) {
	t.Setenv(EnvTrustedProxies, "203.0.113.0/24, 10.0.0.1")
	router := newTrustedProxyTestEnv(t)
	got := probeClientIP(t, router, "203.0.113.7:80", "5.6.7.8")
	if got != "5.6.7.8" {
		t.Fatalf("自定义受信任网段应生效: got %q", got)
	}
}

// (e) env 含非法条目：warn 后回落默认网段（保守方向，行为等同默认）。
func TestTrustedProxiesInvalidEntryFallsBackToDefault(t *testing.T) {
	t.Setenv(EnvTrustedProxies, "not-a-cidr")
	router := newTrustedProxyTestEnv(t)
	got := probeClientIP(t, router, "203.0.113.7:9999", "1.2.3.4")
	if got != "203.0.113.7" {
		t.Fatalf("非法配置回落默认后 XFF 仍须被忽略: got %q", got)
	}
}

// (f) trustedProxies 解析语义：未设置→默认；置空/非法→默认；none→nil；合法列表去空。
func TestTrustedProxiesParsing(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	if got := trustedProxies(logger); len(got) != len(defaultTrustedProxies) {
		t.Fatalf("未设置时应返回默认网段: %v", got)
	}
	t.Setenv(EnvTrustedProxies, "   ")
	if got := trustedProxies(logger); len(got) != len(defaultTrustedProxies) {
		t.Fatalf("显式置空应回落默认网段: %v", got)
	}
	t.Setenv(EnvTrustedProxies, "none")
	if got := trustedProxies(logger); got != nil {
		t.Fatalf("none 应返回 nil: %v", got)
	}
	t.Setenv(EnvTrustedProxies, "10.0.0.0/8, , 192.168.1.1")
	got := trustedProxies(logger)
	if len(got) != 2 || got[0] != "10.0.0.0/8" || got[1] != "192.168.1.1" {
		t.Fatalf("合法列表应去空保留原序: %v", got)
	}
	t.Setenv(EnvTrustedProxies, "bogus")
	if got := trustedProxies(logger); len(got) != len(defaultTrustedProxies) {
		t.Fatalf("非法条目应回落默认网段: %v", got)
	}
}

// (g) 健康端点在信任面改动后保持 200（装配 smoke）。
func TestTrustedProxiesHealthzStillOK(t *testing.T) {
	router := newTrustedProxyTestEnv(t)
	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), "ok") {
		t.Fatalf("healthz 应为 200 ok: %d %s", rec.Code, rec.Body.String())
	}
}
