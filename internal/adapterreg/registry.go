// Package adapterreg 提供五类 Provider 适配器的统一注册表与能力聚合。
// 客户端按能力矩阵渲染入口，不根据 Agent 类型硬编码能力。
package adapterreg

import (
	"context"
	"sort"

	"github.com/yubi233/agent-sessions/internal/adapter"
	"github.com/yubi233/agent-sessions/internal/adapter/claude"
	"github.com/yubi233/agent-sessions/internal/adapter/codex"
	"github.com/yubi233/agent-sessions/internal/adapter/dsh"
	"github.com/yubi233/agent-sessions/internal/adapter/openclaw"
	"github.com/yubi233/agent-sessions/internal/adapter/opencode"
)

// Provider 描述一个可用 Provider 及其能力。
//
// FactsSource 是 v0.9.2 P1（T2 裁决）新增的 additive 字段，回答"谁在声明可用"：
//   - "relay"：Relay 进程自身的 Detect 成功（Relay 确实能执行该 Provider）；
//   - "terminal"：执行侧 Terminal(Daemon) 上报的事实（Relay 自己无法执行，
//     例如云端 scratch 镜像没有 node/DSH 检出）；
//   - "unavailable"：两侧都没有可用事实，保持 fail-closed。
//
// 该字段不改变 available 的语义（仍然只有"能真实建立会话"才为 true），
// 只是让客户端与诊断能区分"Provider 真的不可用"和"本进程看不到执行侧"。
type Provider struct {
	Kind         string               `json:"kind"`
	Version      string               `json:"version"`
	Available    bool                 `json:"available"`
	Capabilities []adapter.Capability `json:"capabilities"`
	FactsSource  string               `json:"facts_source,omitempty"`
}

// Registry 聚合五类 Provider。
type Registry struct {
	adapters map[string]adapter.Adapter
}

// NewWithAdapters 用调用方提供的适配器实例构造注册表（v0.9.2 P1）。
// Daemon 侧需要让"上报给 Relay 的能力事实"与"真正执行命令的适配器"是同一个实例：
// 共享实例意味着两者共用同一份握手缓存与受控重探测状态，既不会重复 spawn 桥进程，
// 也不会出现"上报可用但执行侧不可用"的撕裂。
func NewWithAdapters(adapters map[string]adapter.Adapter) *Registry {
	copied := make(map[string]adapter.Adapter, len(adapters))
	for kind, a := range adapters {
		if a == nil {
			continue
		}
		copied[kind] = a
	}
	return &Registry{adapters: copied}
}

// New 构造注册表。
func New() *Registry {
	return &Registry{
		adapters: map[string]adapter.Adapter{
			"claude":   claude.New(),
			"codex":    codex.New(),
			"dsh":      dsh.New(),
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
	return []string{"claude", "codex", "opencode", "openclaw", "dsh"}
}
