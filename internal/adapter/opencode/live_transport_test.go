// live_transport_test.go 是 ADPT-OPENCODE-05 授权 live gate：
// 启动隔离临时目录的真实 opencode serve，用 Adapter 完成 Detect/Start/Send/Abort/Resume，
// 证明 transport 在真实 server 上工作，而不是仅靠 fixture。
//
// 门禁开关：AGENT_SESSIONS_LIVE_OPENCODE=1 才运行（避免常规 `task test:contract` 消耗额度）。
// 凭据只从 OPENCODE_SERVER_USERNAME / OPENCODE_SERVER_PASSWORD 读取，报告只留脱敏摘要。
package opencode

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"os/exec"
	"sort"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/yubi233/agent-sessions/internal/adapter"
)

// liveEnabled 返回是否开启真实服务 gate。
func liveEnabled() bool {
	return os.Getenv("AGENT_SESSIONS_LIVE_OPENCODE") == "1"
}

// startRealServe 在隔离临时目录启动 opencode serve，返回 baseURL 与清理函数。
// 凭据使用当前环境的 OPENCODE_SERVER_USERNAME/PASSWORD；URL 端口随机。
func startRealServe(t *testing.T) (string, func()) {
	t.Helper()
	if !liveEnabled() {
		t.Skip("AGENT_SESSIONS_LIVE_OPENCODE=1 未设置，跳过授权 live gate")
	}
	if os.Getenv(EnvPassword) == "" {
		t.Skip("OPENCODE_SERVER_PASSWORD 未配置，无法鉴权，live gate 标记 blocked")
	}
	dir := t.TempDir()
	port := freePort(t)
	cmd := exec.Command("opencode", "serve", "--port", port, "--log-level", "ERROR")
	cmd.Dir = dir
	cmd.Env = append(
		os.Environ(),
		"OPENCODE_SERVER_USERNAME="+defaultUsername(),
		"OPENCODE_SERVER_PASSWORD="+os.Getenv(EnvPassword),
	)
	if err := cmd.Start(); err != nil {
		t.Fatalf("opencode serve 启动失败: %v", err)
	}
	baseURL := "http://127.0.0.1:" + port
	cleanup := func() {
		_ = cmd.Process.Kill()
		_, _ = cmd.Process.Wait()
	}
	t.Cleanup(cleanup)

	// 等待服务健康（最长 60s）：本机同时运行桌面端/happy 时启动可能明显变慢。
	deadline := time.Now().Add(60 * time.Second)
	for time.Now().Before(deadline) {
		health, err := probeHealth(baseURL)
		if err == nil && health.Healthy {
			return baseURL, cleanup
		}
		time.Sleep(250 * time.Millisecond)
	}
	t.Fatalf("opencode serve 未在超时内健康")
	return "", cleanup
}

// probeHealth 使用独立 client 探测健康（不依赖被测适配器）。
func probeHealth(baseURL string) (HealthResult, error) {
	oldURL := os.Getenv(EnvURL)
	oldUser := os.Getenv(EnvUsername)
	oldPass := os.Getenv(EnvPassword)
	_ = os.Setenv(EnvURL, baseURL)
	_ = os.Setenv(EnvUsername, defaultUsername())
	_ = os.Setenv(EnvPassword, os.Getenv(EnvPassword))
	defer func() {
		_ = os.Setenv(EnvURL, oldURL)
		_ = os.Setenv(EnvUsername, oldUser)
		_ = os.Setenv(EnvPassword, oldPass)
	}()
	client, err := NewClient()
	if err != nil {
		return HealthResult{}, err
	}
	return client.Health(context.Background())
}

// freePort 分配一个空闲端口号（O_TMPFILE 竞态可接受：serve 立即绑定）。
func freePort(t *testing.T) string {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("port: %v", err)
	}
	port := listener.Addr().(*net.TCPAddr).Port
	_ = listener.Close()
	return strconv.Itoa(port)
}

// defaultUsername 返回 Basic Auth 用户名默认值（与 opencode 默认一致）。
func defaultUsername() string {
	if user := strings.TrimSpace(os.Getenv(EnvUsername)); user != "" {
		return user
	}
	return "opencode"
}

// TestLiveTransport 走真实 opencode serve：Detect/Start/Send/事件流/Abort/Resume。
func TestLiveTransport(t *testing.T) {
	baseURL, _ := startRealServe(t)
	// 让被测适配器从真实环境读取 URL 与凭据。
	t.Setenv(EnvURL, baseURL)
	t.Setenv(EnvUsername, defaultUsername())
	a := New()

	// Detect：health 通过后 Version 写入，核心能力 native。
	caps, err := a.Detect(context.Background())
	if err != nil {
		t.Fatalf("detect: %v", err)
	}
	if caps.Version == "" {
		t.Fatalf("version 为空，探测未通过")
	}
	byName := map[string]string{}
	for _, c := range caps.Capabilities {
		byName[c.Name] = c.Status
	}
	for _, name := range []string{"start", "resume", "abort", "usage"} {
		if byName[name] != adapter.CapabilityNative {
			t.Fatalf("%s = %q, want native", name, byName[name])
		}
	}

	// Start + 初始 prompt：最小算术契约，证明 Adapter 而非仅 CLI。
	handle, err := a.Start(context.Background(), adapter.StartRequest{
		WorkspaceRoot: t.TempDir(),
		Provider:      "opencode",
		Prompt:        "只输出数字：1+1 等于多少？",
	})
	if err != nil {
		t.Fatalf("start: %v", err)
	}
	defer handle.Dispose(context.Background())

	// 收集事件直到 usage 出现（turn 结束）或超时。
	deadline := time.After(3 * time.Minute)
	observed := map[adapter.EventType]bool{}
	var usageEvent adapter.Event
	for {
		select {
		case ev, ok := <-handle.Events():
			if !ok {
				t.Fatalf("事件流提前关闭；已观察到 %v", observed)
			}
			observed[ev.Type] = true
			if ev.Type == adapter.EventUsage {
				usageEvent = ev
			}
			if observed[adapter.EventMessageDelta] && observed[adapter.EventUsage] {
				goto collected
			}
		case <-deadline:
			t.Fatalf("等待事件超时；已观察到 %v", observed)
		}
	}
collected:
	if usageEvent.Payload["total_tokens"] == nil {
		t.Fatalf("usage 缺少 total_tokens：%v", usageEvent.Payload)
	}
	// 输出脱敏摘要供编排脚本写入报告（只含计数，不含正文/凭据）。
	fmt.Printf("LIVE_SUMMARY %s\n", liveSummary(observed, usageEvent.Payload))

	// Send：追加一条消息（204 受理即可，不校验模型回复正文）。
	if err := handle.Send(context.Background(), "只输出数字：2+2 等于多少？"); err != nil {
		t.Fatalf("send: %v", err)
	}

	// Abort：中止当前 turn。
	if err := handle.Abort(context.Background()); err != nil {
		t.Fatalf("abort: %v", err)
	}

	// Resume：真实会话应返回 resumed（有历史消息）。
	sessionID := handle.(interface{ ID() string }).ID()
	_ = handle.Dispose(context.Background())
	r, err := a.Resume(context.Background(), adapter.ResumeRequest{InstanceID: sessionID, WorkspaceRoot: t.TempDir()})
	if err != nil {
		t.Fatalf("resume: %v", err)
	}
	if r.Result != adapter.WakeResumed {
		t.Fatalf("resume result = %q, want resumed", r.Result)
	}
	if resumedHandle, ok := a.handles[sessionID]; ok {
		_ = resumedHandle.Dispose(context.Background())
	}
}

// liveSummary 构造脱敏的 live 摘要 JSON（只含事件类型计数与 usage 计数）。
func liveSummary(observed map[adapter.EventType]bool, usage map[string]any) string {
	types := make([]string, 0, len(observed))
	for eventType := range observed {
		types = append(types, string(eventType))
	}
	sort.Strings(types)
	usageSummary := map[string]any{}
	for _, key := range []string{"input_tokens", "output_tokens", "total_tokens"} {
		if value, ok := usage[key]; ok {
			usageSummary[key] = value
		}
	}
	summary, _ := json.Marshal(map[string]any{
		"observed_event_types": types,
		"usage":                usageSummary,
	})
	return string(summary)
}
