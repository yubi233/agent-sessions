package daemon

// v0.9.2 P1（迭代计划 §3.2 C1，T2 裁决）：Daemon 侧的**执行侧 Provider 事实采集器**。
//
// 职责：把"本机现在到底能不能真实跑起 DSH 会话"变成可上报的事实，并随
// hello/heartbeat 交给 Relay，使手机看到的能力与**执行该会话的机器**一致。
//
// 为什么不能每次心跳都探测：Adapter.Detect 的失败路径会 spawn 桥子进程做真实
// ACP 握手（有真实成本）。因此本采集器采用"缓存 + TTL 刷新"：
//   - 缓存命中期间上报上次快照（含观测时间，Relay/客户端可判断新鲜度）；
//   - TTL 到期后由**后台**刷新，心跳路径永远不阻塞在探测上；
//   - 刷新失败不抛出到主循环：失败本身也是事实（available=false + 中文原因），
//     会随下一次心跳上报，用户因此能看到"执行侧现在不可用"及其原因。
//
// 安全：快照只含版本、失败原因与模型目录安全元数据；不含凭据、路径、正文。

import (
	"context"
	"sort"
	"sync"
	"time"

	"github.com/yubi233/agent-sessions/internal/adapter"
	"github.com/yubi233/agent-sessions/internal/adapterreg"
)

// ProviderFactPayload 是执行侧事实的 wire 形状（与 Relay OpenAPI ProviderFact 对齐）。
// 字段必须是导出的：它直接参与 hello/heartbeat 的 JSON 编码与终端签名 body hash。
type ProviderFactPayload struct {
	Kind             string                      `json:"kind"`
	Available        bool                        `json:"available"`
	Version          string                      `json:"version,omitempty"`
	Reason           string                      `json:"reason,omitempty"`
	DefaultModel     string                      `json:"default_model,omitempty"`
	ObservedAtUnixMS int64                       `json:"observed_at_unix_ms,omitempty"`
	ModelGroups      []ProviderModelGroupPayload `json:"model_groups,omitempty"`
}

// ProviderModelGroupPayload 是"渠道 → 模型"目录分组。
type ProviderModelGroupPayload struct {
	ID     string                     `json:"id"`
	Name   string                     `json:"name,omitempty"`
	Models []ProviderModelFactPayload `json:"models,omitempty"`
}

// ProviderModelFactPayload 是单个模型条目的安全元数据。
type ProviderModelFactPayload struct {
	Provider            string   `json:"provider,omitempty"`
	Value               string   `json:"value"`
	ID                  string   `json:"id,omitempty"`
	Name                string   `json:"name,omitempty"`
	ContextWindowTokens int64    `json:"context_window_tokens,omitempty"`
	Reasoning           bool     `json:"reasoning,omitempty"`
	Efforts             []string `json:"efforts,omitempty"`
}

// defaultProviderFactTTL 是事实快照的默认刷新周期。
// 取值理由：足够短以让"装好 node / 修好桥路径"这类环境修复在一分钟内对手机生效，
// 又足够长以避免把真实握手摊到每次心跳上（心跳间隔 15s）。
const defaultProviderFactTTL = 60 * time.Second

// providerFactProbeTimeout 是单轮采集的整体超时（三种 Provider 串行 Detect）。
const providerFactProbeTimeout = 45 * time.Second

// ProviderFactCollector 缓存执行侧 Provider 事实并受 TTL 控制刷新。
type ProviderFactCollector struct {
	registry *adapterreg.Registry
	ttl      time.Duration
	now      func() time.Time

	mu       sync.Mutex
	facts    []ProviderFactPayload
	observed time.Time
	// pending 保证同一时刻最多一个后台刷新在跑（single-flight）。
	pending bool
}

// NewProviderFactCollector 构造采集器。registry 为 nil 时退化为"无事实"
// （调用方仍未配置 Registry 时不伪造任何可用性）。
func NewProviderFactCollector(registry *adapterreg.Registry) *ProviderFactCollector {
	return &ProviderFactCollector{
		registry: registry,
		ttl:      defaultProviderFactTTL,
		now:      time.Now,
	}
}

// Snapshot 返回当前缓存快照并（必要时）触发一次后台刷新。
// 该方法**永不阻塞**调用方：首次调用时快照可能为空（"尚未观测"），
// 空快照不会被上报（nil 表示未上报），因此不会把"未知"误传成"不可用"。
func (c *ProviderFactCollector) Snapshot(ctx context.Context) []ProviderFactPayload {
	if c == nil || c.registry == nil {
		return nil
	}
	c.mu.Lock()
	facts := c.facts
	observed := c.observed
	c.mu.Unlock()

	if time.Since(observed) >= c.ttl && c.beginRefresh() {
		// 后台刷新：脱离请求上下文，避免心跳取消导致探测半途而废。
		go func() {
			defer c.endRefresh()
			probeCtx, cancel := context.WithTimeout(context.Background(), providerFactProbeTimeout)
			defer cancel()
			_ = c.Refresh(probeCtx)
		}()
	}
	if len(facts) == 0 {
		return nil
	}
	return facts
}

// Refresh 同步执行一次采集并替换缓存（返回错误仅用于诊断，不断言可用性）。
func (c *ProviderFactCollector) Refresh(ctx context.Context) error {
	if c == nil || c.registry == nil {
		return nil
	}
	providers, err := c.registry.List(ctx)
	if err != nil {
		return err
	}
	facts := make([]ProviderFactPayload, 0, len(providers))
	for _, provider := range providers {
		facts = append(facts, providerFactFromRegistry(provider, c.now()))
	}
	// 稳定排序：kind 升序（避免 map 遍历顺序导致签名 body 抖动，便于比对与测试）。
	sort.Slice(facts, func(i, j int) bool { return facts[i].Kind < facts[j].Kind })
	c.mu.Lock()
	c.facts = facts
	c.observed = c.now()
	c.mu.Unlock()
	return nil
}

// beginRefresh 尝试占用刷新权（single-flight）；已有刷新在跑时返回 false。
func (c *ProviderFactCollector) beginRefresh() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.pending {
		return false
	}
	c.pending = true
	return true
}

// endRefresh 释放刷新权。
func (c *ProviderFactCollector) endRefresh() {
	c.mu.Lock()
	c.pending = false
	c.mu.Unlock()
}

// providerFactFromRegistry 把注册表中的一个 Provider 快照转换为上报事实。
func providerFactFromRegistry(provider adapterreg.Provider, observedAt time.Time) ProviderFactPayload {
	fact := ProviderFactPayload{
		Kind:             provider.Kind,
		Available:        provider.Version != "",
		Version:          provider.Version,
		ObservedAtUnixMS: observedAt.UnixMilli(),
	}
	if !fact.Available {
		// fail-closed：沿用适配器给出的中文原因；缺失时给稳定兜底文案，
		// 保证移动端始终能解释"为什么不可用"。
		fact.Reason = firstCapabilityReason(provider.Capabilities)
	}
	for _, capability := range provider.Capabilities {
		if capability.Name != "model_select" {
			continue
		}
		fact.ModelGroups = providerModelGroupsFromCapability(capability)
		// wire 契约：default_model 必须落在 model_groups 内（Relay 端 fail-closed
		// 校验按 Value 精确匹配，违例会拒绝**整条** hello/heartbeat，终端 presence
		// 因此完全无法上线——R16 环境恢复时实测）。适配器目录字段漂移（如只填旧
		// Options/ModelDetails 而未迁 ModelGroups）时在这里降级为“无默认值”：
		// 目录缺失是特性降级，不该升级成可用性事故。
		if hasProviderFactModelValue(fact.ModelGroups, capability.Default) {
			fact.DefaultModel = capability.Default
		}
	}
	return fact
}

// hasProviderFactModelValue 与 Relay 端 providerFactHasModel 同口径：按模型 Value 精确匹配。
func hasProviderFactModelValue(groups []ProviderModelGroupPayload, value string) bool {
	for _, group := range groups {
		for _, model := range group.Models {
			if model.Value == value {
				return true
			}
		}
	}
	return false
}

// firstCapabilityReason 取第一条非空中文原因（fail-closed 矩阵每条原因相同）。
func firstCapabilityReason(capabilities []adapter.Capability) string {
	for _, capability := range capabilities {
		if capability.Reason != "" {
			return capability.Reason
		}
	}
	return "执行侧未提供可用事实。"
}

// providerModelGroupsFromCapability 复制模型目录（只保留安全元数据）。
func providerModelGroupsFromCapability(capability adapter.Capability) []ProviderModelGroupPayload {
	if len(capability.ModelGroups) == 0 {
		return nil
	}
	groups := make([]ProviderModelGroupPayload, 0, len(capability.ModelGroups))
	for _, group := range capability.ModelGroups {
		converted := ProviderModelGroupPayload{ID: group.ID, Name: group.Name}
		for _, model := range group.Models {
			converted.Models = append(converted.Models, ProviderModelFactPayload{
				Provider:            model.Provider,
				Value:               model.Value,
				ID:                  model.ID,
				Name:                model.Name,
				ContextWindowTokens: model.ContextWindowTokens,
				Reasoning:           model.Reasoning,
				Efforts:             append([]string(nil), model.Efforts...),
			})
		}
		groups = append(groups, converted)
	}
	return groups
}
