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
	// 本机地址的存在只能说明未来可尝试建立传输，不能证明 SPI 的 Start/Resume
	// 已经可用。当前 transport 尚未实现，必须让客户端 fail-closed，避免暴露
	// 实际会返回 unsupported 的会话控制入口。
	reason := "OpenCode 本地服务未配置，控制能力已安全禁用。"
	if a.url != "" {
		reason = "OpenCode transport 尚未接入，控制能力已安全禁用。"
	}
	caps := make([]adapter.Capability, 0, len(adapter.CapabilityNames))
	for _, name := range adapter.CapabilityNames {
		caps = append(caps, adapter.Capability{
			Name:   name,
			Status: adapter.CapabilityUnsupported,
			Reason: reason,
		})
	}
	// 未连接并确认本地服务版本前不声明 Provider available；Registry 会据此保持入口关闭。
	return adapter.Capabilities{Provider: "opencode", Capabilities: caps}, nil
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
