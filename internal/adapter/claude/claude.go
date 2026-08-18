// Package claudeadapter 实现 Claude CLI 适配器（P3）。
// 当前只探测 CLI 版本；stream-json 接入完成前所有控制能力必须 fail-closed。
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
	version := strings.TrimSpace(string(out))
	if version == "" {
		return
	}
	a.detected = true
	a.version = version
}

// Detect 返回能力矩阵。CLI 可探测只代表已安装，不代表尚未接入的 transport 可用。
func (a *Adapter) Detect(ctx context.Context) (adapter.Capabilities, error) {
	_ = ctx
	reason := "Claude CLI 未配置或探测失败，控制能力已安全禁用。"
	if a.detected {
		reason = "Claude CLI 已探测到，但 stream-json 传输尚未接入，控制能力已安全禁用。"
	}
	// Start/Resume 尚未实现，依赖会话 handle 的其余能力也不能提前宣称 native 或 emulated。
	caps := make([]adapter.Capability, 0, len(adapter.CapabilityNames))
	for _, name := range adapter.CapabilityNames {
		caps = append(caps, adapter.Capability{
			Name:   name,
			Status: adapter.CapabilityUnsupported,
			Reason: reason,
		})
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
