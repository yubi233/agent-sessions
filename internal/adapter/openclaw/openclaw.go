// Package openclawadapter 实现 OpenClaw adapter（P3）。
// 使用 Gateway WebSocket challenge/device auth；challenge 与设备授权必须在 Daemon 内完成。
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

// Detect 返回能力矩阵。
func (a *Adapter) Detect(ctx context.Context) (adapter.Capabilities, error) {
	_ = ctx
	// OpenClaw 通过 Gateway 支持 chat delta/thinking/tool/skill。
	native := map[string]bool{"start": true, "resume": true, "abort": true, "permission": true, "skill_catalog": true}
	caps := make([]adapter.Capability, 0, len(adapter.CapabilityNames))
	for _, name := range adapter.CapabilityNames {
		c := adapter.Capability{Name: name, Status: adapter.CapabilityUnsupported}
		if a.url != "" && native[name] {
			c.Status = adapter.CapabilityNative
		}
		caps = append(caps, c)
	}
	return adapter.Capabilities{Provider: "openclaw", Version: "unknown", Capabilities: caps}, nil
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
