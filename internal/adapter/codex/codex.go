// Package codexadapter 实现 Codex adapter（P3）。
// 使用 app-server JSON-RPC/stdio；未知能力必须 unsupported。
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
			a.detected = true
			a.version = strings.TrimSpace(string(out))
		}
	}
	return a
}

// Detect 返回能力矩阵。
func (a *Adapter) Detect(ctx context.Context) (adapter.Capabilities, error) {
	_ = ctx
	// Codex 通过 JSON-RPC 支持 thread resume、审批与 skills。
	native := map[string]bool{"start": true, "resume": true, "abort": true, "permission": true, "skill_catalog": true}
	caps := make([]adapter.Capability, 0, len(adapter.CapabilityNames))
	for _, name := range adapter.CapabilityNames {
		c := adapter.Capability{Name: name, Status: adapter.CapabilityUnsupported}
		if a.detected && native[name] {
			c.Status = adapter.CapabilityNative
		}
		caps = append(caps, c)
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
