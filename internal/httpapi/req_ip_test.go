package httpapi

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"
)

// reqIP 必须透传 ClientIP：IPv6 地址（含 ::1）不得被端口截断逻辑破坏
// （旧实现 strings.Split(ip, ":")[0] 会把 "::1" 截成空串）。
func TestReqIPKeepsIPv6Intact(t *testing.T) {
	router := gin.New()
	if err := router.SetTrustedProxies(nil); err != nil {
		t.Fatalf("SetTrustedProxies: %v", err)
	}
	var got string
	router.GET("/__probe_ip", func(c *gin.Context) { got = reqIP(c) })

	req := httptest.NewRequest(http.MethodGet, "/__probe_ip", nil)
	req.RemoteAddr = "[::1]:5555"
	router.ServeHTTP(httptest.NewRecorder(), req)

	if got != "::1" {
		t.Fatalf("reqIP 应保留完整 IPv6 地址: got %q", got)
	}
}

// IPv4 直连场景：ClientIP 即套接字对端，reqIP 原样返回。
func TestReqIPReturnsIPv4(t *testing.T) {
	router := gin.New()
	if err := router.SetTrustedProxies(nil); err != nil {
		t.Fatalf("SetTrustedProxies: %v", err)
	}
	var got string
	router.GET("/__probe_ip", func(c *gin.Context) { got = reqIP(c) })

	req := httptest.NewRequest(http.MethodGet, "/__probe_ip", nil)
	req.RemoteAddr = "127.0.0.1:1234"
	router.ServeHTTP(httptest.NewRecorder(), req)

	if got != "127.0.0.1" {
		t.Fatalf("reqIP 应返回对端 IPv4: got %q", got)
	}
}
