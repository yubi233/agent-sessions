// Package codexadapter 实现 Codex adapter（P3）。
// 当前只探测 CLI 版本；app-server JSON-RPC 接入完成前所有能力必须 fail-closed。
package codex

import (
	"context"
	"os"
	"os/exec"
	"strings"

	"github.com/yubi233/agent-sessions/internal/adapter"
)

// EnvBin 是 Codex 可执行环境变量。
const EnvBin = "AGENT_SESSIONS_CODEX_BIN"

// Adapter 是 Codex 适配器。
type Adapter struct {
	bin      string
	detected bool
	version  string
}

// New 构造 Codex 适配器。
func New() *Adapter {
	a := &Adapter{bin: os.Getenv(EnvBin)}
	if a.bin != "" {
		if out, err := exec.Command(a.bin, "--version").Output(); err == nil {
			version := strings.TrimSpace(string(out))
			if version != "" {
				a.detected = true
				a.version = version
			}
		}
	}
	return a
}

// Detect 返回能力矩阵。CLI 可探测只代表已安装，不代表 JSON-RPC transport 已兑现。
func (a *Adapter) Detect(ctx context.Context) (adapter.Capabilities, error) {
	_ = ctx
	reason := "Codex CLI 未配置或探测失败，控制能力已安全禁用。"
	if a.detected {
		reason = "Codex CLI 已探测到，但 app-server JSON-RPC 传输尚未接入，控制能力已安全禁用。"
	}
	// Start/Resume 尚未实现，依赖会话 handle 的审批、技能等能力同样不能提前升级。
	caps := make([]adapter.Capability, 0, len(adapter.CapabilityNames))
	for _, name := range adapter.CapabilityNames {
		caps = append(caps, adapter.Capability{
			Name:   name,
			Status: adapter.CapabilityUnsupported,
			Reason: reason,
		})
	}
	return adapter.Capabilities{Provider: "codex", Version: a.version, Capabilities: caps}, nil
}

// Capabilities 返回能力矩阵。
func (a *Adapter) Capabilities() adapter.Capabilities {
	caps, _ := a.Detect(context.Background())
	return caps
}

// Start 未接入真实 JSON-RPC。
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

// Available 报告是否探测到可执行二进制。
func (a *Adapter) Available() bool { return a.detected }
