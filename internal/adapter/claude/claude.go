// Package claudeadapter 实现 Claude CLI 适配器（P3）。
// 优先 Claude CLI stream-json；未知版本只提供安全能力子集，不伪造 native。
package claude

import (
	"context"
	"os"
	"os/exec"
	"strings"

	"github.com/yubi233/agent-sessions/internal/adapter"
)

// 最低支持版本与当前探测版本。
const (
	MinVersion = "1.0.0"
	EnvBin     = "AGENT_SESSIONS_CLAUDE_BIN"
)

// Adapter 是 Claude 适配器。
type Adapter struct {
	bin      string
	detected bool
	version  string
}

// New 探测并构造 Claude 适配器。
func New() *Adapter {
	a := &Adapter{}
	a.bin = os.Getenv(EnvBin)
	if a.bin != "" {
		a.detect()
	}
	return a
}

func (a *Adapter) detect() {
	cmd := exec.Command(a.bin, "--version")
	out, err := cmd.Output()
	if err != nil {
		return
	}
	a.detected = true
	a.version = strings.TrimSpace(string(out))
}

// Detect 返回能力矩阵。未安装或版本未知时仅提供安全能力子集（unsupported）。
func (a *Adapter) Detect(ctx context.Context) (adapter.Capabilities, error) {
	_ = ctx
	// 以 native/emulated/unsupported 三态声明，绝不推断为可用。
	native := map[string]bool{"start": true, "resume": true, "abort": true, "permission": true}
	emulated := map[string]bool{"plan": true, "goal": true, "usage": true}
	caps := make([]adapter.Capability, 0, len(adapter.CapabilityNames))
	for _, name := range adapter.CapabilityNames {
		c := adapter.Capability{Name: name, Status: adapter.CapabilityUnsupported}
		if a.detected {
			switch {
			case native[name]:
				c.Status = adapter.CapabilityNative
			case emulated[name]:
				c.Status = adapter.CapabilityEmulated
			}
		}
		caps = append(caps, c)
	}
	return adapter.Capabilities{Provider: "claude", Version: a.version, Capabilities: caps}, nil
}

// Capabilities 返回能力矩阵。
func (a *Adapter) Capabilities() adapter.Capabilities {
	caps, _ := a.Detect(context.Background())
	return caps
}

// Start 尚未接入真实 CLI 传输；返回 unsupported（fixture/live 阶段）。
func (a *Adapter) Start(ctx context.Context, req adapter.StartRequest) (adapter.Handle, error) {
	_ = ctx
	_ = req
	return nil, os.ErrNotExist
}

// Resume 尚未接入真实线程恢复。
func (a *Adapter) Resume(ctx context.Context, req adapter.ResumeRequest) (adapter.ResumeResult, error) {
	_ = ctx
	_ = req
	return adapter.ResumeResult{Result: adapter.WakeUnsupported}, nil
}

// Available 报告是否探测到可执行二进制。
func (a *Adapter) Available() bool { return a.detected }
