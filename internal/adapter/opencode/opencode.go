// Package opencodeadapter 实现 OpenCode adapter（P3）。
// 使用本地 server API/WebSocket/SSE；原生线程无法恢复时明确返回 unsupported。
package opencode

import (
	"context"
	"os"
	"strings"

	"github.com/yubi233/agent-sessions/internal/adapter"
)

// EnvURL 是 OpenCode 本地 server 地址。
const EnvURL = "AGENT_SESSIONS_OPENCODE_URL"

// Adapter 是 OpenCode 适配器。
type Adapter struct {
	url string
}

// New 构造 OpenCode 适配器。
func New() *Adapter {
	return &Adapter{url: strings.TrimSpace(os.Getenv(EnvURL))}
}

// Detect 返回能力矩阵。
func (a *Adapter) Detect(ctx context.Context) (adapter.Capabilities, error) {
	_ = ctx
	// OpenCode 原生支持会话与工具、文件/Git 读取；跨 Provider 派发 unsupported。
	native := map[string]bool{"start": true, "resume": true, "abort": true, "permission": true, "git_read": true, "file_read": true}
	caps := make([]adapter.Capability, 0, len(adapter.CapabilityNames))
	for _, name := range adapter.CapabilityNames {
		c := adapter.Capability{Name: name, Status: adapter.CapabilityUnsupported}
		if a.url != "" && native[name] {
			c.Status = adapter.CapabilityNative
		}
		caps = append(caps, c)
	}
	return adapter.Capabilities{Provider: "opencode", Version: "unknown", Capabilities: caps}, nil
}

// Capabilities 返回能力矩阵。
func (a *Adapter) Capabilities() adapter.Capabilities {
	caps, _ := a.Detect(context.Background())
	return caps
}

// Start 未接入真实 server。
func (a *Adapter) Start(ctx context.Context, req adapter.StartRequest) (adapter.Handle, error) {
	_ = ctx
	_ = req
	return nil, os.ErrNotExist
}

// Resume 未接入真实线程恢复。
func (a *Adapter) Resume(ctx context.Context, req adapter.ResumeRequest) (adapter.ResumeResult, error) {
	_ = ctx
	_ = req
	return adapter.ResumeResult{Result: adapter.WakeUnsupported}, nil
}
