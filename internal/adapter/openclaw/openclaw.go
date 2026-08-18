// Package openclawadapter 实现 OpenClaw adapter（P3）。
// Gateway WebSocket challenge/device auth 接入完成前，配置 URL 也不能推断服务可用。
package openclaw

import (
	"context"
	"os"
	"strings"

	"github.com/yubi233/agent-sessions/internal/adapter"
)

// EnvURL 是 OpenClaw Gateway 地址。
const EnvURL = "AGENT_SESSIONS_OPENCLAW_URL"

// Adapter 是 OpenClaw 适配器。
type Adapter struct {
	url string
}

// New 构造 OpenClaw 适配器。
func New() *Adapter {
	return &Adapter{url: strings.TrimSpace(os.Getenv(EnvURL))}
}

// Detect 返回能力矩阵。当前没有 Gateway 握手，URL 仅是配置，不是可用性证据。
func (a *Adapter) Detect(ctx context.Context) (adapter.Capabilities, error) {
	_ = ctx
	reason := "OpenClaw Gateway 未配置，控制能力已安全禁用。"
	if a.url != "" {
		reason = "OpenClaw Gateway 已配置，但 WebSocket 握手与设备授权尚未接入，控制能力已安全禁用。"
	}
	// Start/Resume 尚未实现，所有依赖 Gateway 会话的能力必须保持 unsupported。
	caps := make([]adapter.Capability, 0, len(adapter.CapabilityNames))
	for _, name := range adapter.CapabilityNames {
		caps = append(caps, adapter.Capability{
			Name:   name,
			Status: adapter.CapabilityUnsupported,
			Reason: reason,
		})
	}
	// 未完成真实握手前不写伪版本，避免 Registry 将仅配置 URL 的 Provider 标成 available。
	return adapter.Capabilities{Provider: "openclaw", Capabilities: caps}, nil
}

// Capabilities 返回能力矩阵。
func (a *Adapter) Capabilities() adapter.Capabilities {
	caps, _ := a.Detect(context.Background())
	return caps
}

// Start 未接入真实 Gateway。
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
