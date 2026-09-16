package domain

// v0.9.2 P1（迭代计划 §3.2 C1，T2 已裁决）：执行侧 Provider 事实。
//
// 事实源原则（P0 实测结论，报告 e2e-verify/reports/2026-09-16T04-36-52-300Z/V092-ATTRIB/）：
//   - DSH 会话的**真实执行者**是持有所属工作区的 Daemon（它才 spawn DSH ACP 桥）；
//   - Relay 进程的 provider Detect 只代表 Relay 自己能否执行该 Provider——
//     云端 Relay 镜像为 scratch 单二进制（无 node / 无 DSH 检出），它的探测必然失败；
//   - 因此 Relay **无权**代表执行侧宣布 DSH 不可用，也**无权**把执行侧的失败伪造成可用。
//
// 本文件把"谁在声明可用"变成可传递、可测试的领域事实：
//   - 每个 Provider 的可用性都有唯一来源（relay 本进程 / terminal 执行侧）；
//   - Relay 自身探测成功时优先采信自己的结果（例如 localdev 同机形态）；
//   - Relay 自身探测失败时，采信同一账号下**在线**且上报该 Provider 可用的 Terminal 事实；
//   - 两边都没有可用事实时保持 fail-closed（不猜测、不回退到编译期白名单）。
//
// 安全边界：事实只包含版本、失败原因、模型目录安全元数据；不含凭据、路径、
// 会话正文或 Provider 配置。

import (
	"context"
	"sort"
	"strings"
	"time"

	"github.com/yubi233/agent-sessions/internal/adapter"
	"github.com/yubi233/agent-sessions/internal/adapterreg"
)

// ProviderFactSource 标记一条 Provider 可用性事实的来源（additive 字段的取值域）。
const (
	// FactSourceRelay 表示事实来自 Relay 进程自身的 Detect（Relay 能真实执行该 Provider）。
	FactSourceRelay = "relay"
	// FactSourceTerminal 表示事实来自执行侧 Terminal（Daemon）的上报。
	FactSourceTerminal = "terminal"
	// FactSourceUnavailable 表示两侧都没有可用事实，保持 fail-closed。
	FactSourceUnavailable = "unavailable"
)

// ProviderFactModel 是执行侧上报的单个模型条目的安全元数据。
// value 是 ACP opaque 选择值，客户端必须原样回传（不得猜测、不得改写）。
type ProviderFactModel struct {
	Provider            string   `json:"provider,omitempty"`
	Value               string   `json:"value"`
	ID                  string   `json:"id,omitempty"`
	Name                string   `json:"name,omitempty"`
	ContextWindowTokens int64    `json:"context_window_tokens,omitempty"`
	Reasoning           bool     `json:"reasoning,omitempty"`
	Efforts             []string `json:"efforts,omitempty"`
}

// ProviderFactGroup 是"渠道 → 模型"目录分组（与 ACP 目录同构）。
type ProviderFactGroup struct {
	ID     string              `json:"id"`
	Name   string              `json:"name,omitempty"`
	Models []ProviderFactModel `json:"models,omitempty"`
}

// ProviderFact 是执行侧对某个 Provider 的运行时事实快照。
type ProviderFact struct {
	Kind string `json:"kind"`
	// Available 表示执行侧此刻能否真实建立该 Provider 的会话。
	Available bool   `json:"available"`
	Version   string `json:"version,omitempty"`
	// Reason 是执行侧给出的中文失败原因（原样转达，不由 Relay 加工或猜测）。
	Reason string `json:"reason,omitempty"`
	// DefaultModel 是执行侧声明的默认模型引用（须存在于 ModelGroups 中）。
	DefaultModel string `json:"default_model,omitempty"`
	// ObservedAtUnixMS 是执行侧观测时间（毫秒），用于判断事实新鲜度。
	ObservedAtUnixMS int64               `json:"observed_at_unix_ms,omitempty"`
	ModelGroups      []ProviderFactGroup `json:"model_groups,omitempty"`
}

// TerminalFact 是执行侧事实与"哪个 Terminal 在声明"的绑定。
// 绑定 Terminal 是必要的：客户端需要知道该 Provider 由哪台执行侧承载，
// 后续把命令路由到同一 Terminal 才不会出现"看到可用、发出去失败"。
type TerminalFact struct {
	TerminalID    string
	Hostname      string
	ObservedAtMS  int64
	ProviderFacts []ProviderFact
}

// ProviderFactFromCapabilities 把适配器的能力矩阵转换为执行侧事实。
// 只保留安全元数据：不含 Options 全量、ModelDetails 之外的任何内部字段。
func ProviderFactFromCapabilities(kind string, caps adapter.Capabilities, observedAt time.Time) ProviderFact {
	fact := ProviderFact{
		Kind:             kind,
		Available:        strings.TrimSpace(caps.Version) != "",
		Version:          strings.TrimSpace(caps.Version),
		ObservedAtUnixMS: observedAt.UnixMilli(),
	}
	if !fact.Available {
		// fail-closed：沿用适配器给出的中文原因；缺失时给稳定兜底文案，
		// 保证移动端永远能解释"为什么不可用"。
		fact.Reason = firstCapabilityReason(caps)
	}
	for _, capability := range caps.Capabilities {
		if capability.Name != "model_select" {
			continue
		}
		fact.DefaultModel = strings.TrimSpace(capability.Default)
		fact.ModelGroups = factGroupsFromCapability(capability)
	}
	return fact
}

// firstCapabilityReason 取矩阵中第一条非空原因（fail-closed 矩阵每条的 reasons 相同）。
func firstCapabilityReason(caps adapter.Capabilities) string {
	for _, capability := range caps.Capabilities {
		if reason := strings.TrimSpace(capability.Reason); reason != "" {
			return reason
		}
	}
	return "执行侧未提供可用事实。"
}

// factGroupsFromCapability 复制模型目录，避免调用方修改适配器缓存快照。
func factGroupsFromCapability(capability adapter.Capability) []ProviderFactGroup {
	if len(capability.ModelGroups) == 0 {
		return nil
	}
	groups := make([]ProviderFactGroup, 0, len(capability.ModelGroups))
	for _, group := range capability.ModelGroups {
		converted := ProviderFactGroup{ID: group.ID, Name: group.Name}
		for _, model := range group.Models {
			converted.Models = append(converted.Models, ProviderFactModel{
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

// ProviderFactsFromRegistry 采集 Relay 本进程对全部 Provider 的事实（诊断与合并用）。
func ProviderFactsFromRegistry(registry *adapterreg.Registry) []ProviderFact {
	if registry == nil {
		return nil
	}
	caps, err := registry.List(context.Background())
	if err != nil {
		return nil
	}
	out := make([]ProviderFact, 0, len(caps))
	for _, provider := range caps {
		out = append(out, ProviderFactFromCapabilities(provider.Kind, adapter.Capabilities{
			Provider:     provider.Kind,
			Version:      provider.Version,
			Capabilities: provider.Capabilities,
		}, time.Now()))
	}
	return out
}

// LookupProviderFact 按 kind 取事实；未上报返回 ok=false。
func LookupProviderFact(facts []ProviderFact, kind string) (ProviderFact, bool) {
	trimmed := strings.TrimSpace(kind)
	for _, fact := range facts {
		if strings.TrimSpace(fact.Kind) == trimmed {
			return fact, true
		}
	}
	return ProviderFact{}, false
}

// mergeResult 是合并后的单条 Provider 结论：能力矩阵 + 事实来源。
type mergeResult struct {
	Provider adapterreg.Provider
	Source   string
}

// factToCapabilities 把执行侧事实复原为能力矩阵。
//
// 关键安全语义：执行侧声明**不可用**时，整条 Provider 一律 fail-closed
// （available=false、全部能力 unsupported、带执行侧原因），绝不用 Relay 的
// 任何结果把它伪造成可用。
func factToCapabilities(fact ProviderFact) (adapterreg.Provider, string) {
	if !fact.Available {
		reason := strings.TrimSpace(fact.Reason)
		if reason == "" {
			reason = "执行侧未提供可用事实。"
		}
		return adapterreg.Provider{
			Kind:         fact.Kind,
			Version:      "",
			Available:    false,
			Capabilities: failClosedCapabilities(reason),
		}, FactSourceUnavailable
	}
	capabilities := make([]adapter.Capability, 0, len(adapter.CapabilityNames))
	for _, name := range adapter.CapabilityNames {
		capability := adapter.Capability{Name: name, Status: adapter.CapabilityNative}
		if name == "model_select" {
			capability.ModelGroups = capabilitiesModelGroups(fact.ModelGroups)
			capability.Default = fact.DefaultModel
			capability.Options = modelSelectOptions(fact.ModelGroups)
		}
		capabilities = append(capabilities, capability)
	}
	return adapterreg.Provider{
		Kind:         fact.Kind,
		Version:      fact.Version,
		Available:    true,
		Capabilities: capabilities,
	}, FactSourceTerminal
}

// capabilitiesModelGroups 把执行侧目录复原为适配器目录结构。
func capabilitiesModelGroups(groups []ProviderFactGroup) []adapter.ModelCapabilityGroup {
	if len(groups) == 0 {
		return nil
	}
	out := make([]adapter.ModelCapabilityGroup, 0, len(groups))
	for _, group := range groups {
		converted := adapter.ModelCapabilityGroup{ID: group.ID, Name: group.Name}
		for _, model := range group.Models {
			converted.Models = append(converted.Models, adapter.ModelCapabilityModel{
				Provider:            model.Provider,
				Value:               model.Value,
				ID:                  model.ID,
				Name:                model.Name,
				ContextWindowTokens: model.ContextWindowTokens,
				Reasoning:           model.Reasoning,
				Efforts:             append([]string(nil), model.Efforts...),
			})
		}
		out = append(out, converted)
	}
	return out
}

// modelSelectOptions 展平模型引用列表（与 DSH 适配器 successMatrix 口径一致：
// model_select 的 Options 是可选模型引用集合，Default 必须落在其中）。
func modelSelectOptions(groups []ProviderFactGroup) []string {
	var options []string
	for _, group := range groups {
		for _, model := range group.Models {
			if value := strings.TrimSpace(model.Value); value != "" {
				options = append(options, value)
			}
		}
	}
	return options
}

// failClosedCapabilities 构造全 unsupported 矩阵（与 DSH 适配器 fail-closed 口径一致）。
func failClosedCapabilities(reason string) []adapter.Capability {
	capabilities := make([]adapter.Capability, 0, len(adapter.CapabilityNames))
	for _, name := range adapter.CapabilityNames {
		capabilities = append(capabilities, adapter.Capability{
			Name:   name,
			Status: adapter.CapabilityUnsupported,
			Reason: reason,
		})
	}
	return capabilities
}

// MergeProviderFacts 按"执行侧事实源"规则合并 Relay 自探测结果与终端上报事实。
//
// 规则（对每个 Provider 独立判定，T2 裁决口径）：
//  1. Relay 自身探测成功（Version 非空）→ 采用 Relay 事实，来源标记 relay。
//  2. Relay 自身探测失败或缺失 → 在**在线**终端的上报事实中按"观测时间最新优先，
//     其次 TerminalID 稳定排序"选第一条该 Provider 可用的事实，来源标记 terminal。
//  3. 两侧都没有可用事实 → 保留 Relay 的 fail-closed 结果，来源标记 unavailable，
//     并把原因改写为执行侧上报的原因（若存在），使客户端能看到当前事实。
//
// 该函数是纯函数：不做 IO、不读时钟，便于单元测试穷举组合。
func MergeProviderFacts(relayProviders []adapterreg.Provider, terminals []TerminalFact) []adapterreg.Provider {
	// Relay 自探测结果按 kind 建索引（保留原始顺序用于输出排序）。
	selfByKind := make(map[string]adapterreg.Provider, len(relayProviders))
	for _, provider := range relayProviders {
		selfByKind[provider.Kind] = provider
	}

	// 收集执行侧可用事实：kind → 最优事实（最新观测优先）。
	terminalAvailable, terminalReasons, terminalVersion := collectTerminalFacts(terminals)

	// 输出集合 = Relay 已知 Provider ∪ 终端上报 Provider（后者可能 Relay 未注册）。
	kinds := make([]string, 0, len(selfByKind)+len(terminalAvailable))
	seen := map[string]bool{}
	for kind := range selfByKind {
		if !seen[kind] {
			seen[kind] = true
			kinds = append(kinds, kind)
		}
	}
	for kind := range terminalAvailable {
		if !seen[kind] {
			seen[kind] = true
			kinds = append(kinds, kind)
		}
	}
	sort.Strings(kinds)

	merged := make([]adapterreg.Provider, 0, len(kinds))
	for _, kind := range kinds {
		self, hasSelf := selfByKind[kind]
		if hasSelf && strings.TrimSpace(self.Version) != "" {
			// 规则 1：Relay 自己能真实执行 → 以自己为准（例如 localdev 同机形态）。
			merged = append(merged, withSource(self, FactSourceRelay))
			continue
		}
		if fact, ok := terminalAvailable[kind]; ok {
			// 规则 2：执行侧可用 → 采用执行侧事实与目录。
			provider, source := factToCapabilities(fact)
			merged = append(merged, withSource(provider, source))
			continue
		}
		// 规则 3：两侧都没有可用事实 → fail-closed，原因优先采用执行侧上报的当前原因。
		if !hasSelf {
			self = adapterreg.Provider{Kind: kind, Available: false, Capabilities: failClosedCapabilities(terminalReasons[kind])}
		}
		if reason := terminalReasons[kind]; reason != "" && len(self.Capabilities) > 0 && strings.TrimSpace(self.Version) == "" {
			self.Capabilities = failClosedCapabilities(reason)
		}
		if v := terminalVersion[kind]; v != "" && strings.TrimSpace(self.Version) == "" {
			// 执行侧上报了版本但标记不可用时，版本只作为诊断信息保留在 reason 中；
			// 绝不写回 Version（否则 Available 判定会被下游误认为可用）。
			_ = v
		}
		merged = append(merged, withSource(self, FactSourceUnavailable))
	}
	return merged
}

// collectTerminalFacts 汇总执行侧上报事实：对每个 kind 选出最优可用事实，
// 同时记录各 kind 的最新失败原因与版本（诊断信息，不参与可用性判定）。
func collectTerminalFacts(terminals []TerminalFact) (map[string]ProviderFact, map[string]string, map[string]string) {
	available := map[string]ProviderFact{}
	reasons := map[string]string{}
	versions := map[string]string{}
	// 稳定遍历顺序：先按观测时间降序，再按 TerminalID 升序，保证结果与输入顺序无关。
	ordered := append([]TerminalFact(nil), terminals...)
	sort.SliceStable(ordered, func(i, j int) bool {
		if ordered[i].ObservedAtMS != ordered[j].ObservedAtMS {
			return ordered[i].ObservedAtMS > ordered[j].ObservedAtMS
		}
		return ordered[i].TerminalID < ordered[j].TerminalID
	})
	for _, terminal := range ordered {
		for _, fact := range terminal.ProviderFacts {
			kind := strings.TrimSpace(fact.Kind)
			if kind == "" {
				continue
			}
			if fact.Available {
				if _, exists := available[kind]; !exists {
					available[kind] = fact
				}
				continue
			}
			// 失败事实不覆盖可用事实；只用于在"两侧都不可用"时给出当前原因。
			if fact.Reason != "" {
				if _, exists := reasons[kind]; !exists {
					reasons[kind] = fact.Reason
				}
			}
			if fact.Version != "" {
				if _, exists := versions[kind]; !exists {
					versions[kind] = fact.Version
				}
			}
		}
	}
	return available, reasons, versions
}

// withSource 把事实来源写入 Provider 视图（nil 安全）。
func withSource(provider adapterreg.Provider, source string) adapterreg.Provider {
	provider.FactsSource = source
	return provider
}
