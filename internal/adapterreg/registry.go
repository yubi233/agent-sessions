// Package adapterreg 提供四类 Provider 适配器的统一注册表与能力聚合。
// 客户端按能力矩阵渲染入口，不根据 Agent 类型硬编码能力。
package adapterreg

import (
	"context"
	"sort"

	"github.com/yubi233/agent-sessions/internal/adapter"
	"github.com/yubi233/agent-sessions/internal/adapter/claude"
	"github.com/yubi233/agent-sessions/internal/adapter/codex"
	"github.com/yubi233/agent-sessions/internal/adapter/openclaw"
	"github.com/yubi233/agent-sessions/internal/adapter/opencode"
)

// Provider 描述一个可用 Provider 及其能力。
type Provider struct {
	Kind         string               `json:"kind"`
	Version      string               `json:"version"`
	Available    bool                 `json:"available"`
	Capabilities []adapter.Capability `json:"capabilities"`
}

// Registry 聚合四类 Provider。
type Registry struct {
	adapters map[string]adapter.Adapter
}

// New 构造注册表。
func New() *Registry {
	return &Registry{
		adapters: map[string]adapter.Adapter{
			"claude":   claude.New(),
			"codex":    codex.New(),
			"opencode": opencode.New(),
			"openclaw": openclaw.New(),
		},
	}
}

// List 返回全部 Provider 的能力快照（按 kind 排序，稳定输出）。
// 能力矩阵不是静态配置：每次请求都调用各 Adapter 的 Detect 重新探测，
// 与 docs/zh/项目文档.md「8. 统一能力模型」的三态口径保持一致——
// opencode provider 只有在真实 /global/health 探测通过后才写 Version，
// 否则 fail-closed（available=false、全部 unsupported、带中文原因、无 Version）。
func (r *Registry) List(ctx context.Context) ([]Provider, error) {
	out := []Provider{}
	for kind, a := range r.adapters {
		caps, err := a.Detect(ctx)
		if err != nil {
			return nil, err
		}
		p := Provider{Kind: kind, Version: caps.Version}
		if p.Version != "" {
			p.Available = true
		}
		p.Capabilities = caps.Capabilities
		out = append(out, p)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Kind < out[j].Kind })
	return out, nil
}

// KnownKinds 返回支持的 Provider 种类。
func KnownKinds() []string {
	return []string{"claude", "codex", "opencode", "openclaw"}
}
