package domain

// V092-03 / V092-04 回归：执行侧 Provider 事实的合并规则（v0.9.2 P1，T2 裁决口径）。
//
// 背景（P0 实测）：云端 Relay 是 scratch 单二进制，进程内 DSH Detect 必然
// fail-closed，但真实执行者是账号下的 Daemon。因此移动端看到的能力必须按
// "谁在声明可用"合并，而不是无条件采信 Relay 自己的探测结果。
//
// 规则（本文件逐条钉扎）：
//  1. Relay 自身探测成功 → 以 Relay 为准，来源 relay；
//  2. Relay 自身失败/缺失 + 在线 Terminal 上报可用 → 采用执行侧事实与模型目录，来源 terminal；
//  3. 两侧都没有可用事实 → fail-closed，来源 unavailable，原因优先取执行侧上报的当前原因；
//  4. 执行侧声明**不可用**永远不会被 Relay 的结果伪造成可用。

import (
	"testing"

	"github.com/yubi233/agent-sessions/internal/adapter"
	"github.com/yubi233/agent-sessions/internal/adapterreg"
)

// relayOK 构造"Relay 自己能跑"的 Provider 视图。
func relayOK(kind, version string) adapterreg.Provider {
	return adapterreg.Provider{Kind: kind, Version: version, Available: true, Capabilities: []adapter.Capability{
		{Name: "start", Status: adapter.CapabilityNative},
	}}
}

// relayFail 构造"Relay 自己跑不了"的 Provider 视图（fail-closed 矩阵）。
func relayFail(kind, reason string) adapterreg.Provider {
	return adapterreg.Provider{Kind: kind, Available: false, Capabilities: []adapter.Capability{
		{Name: "start", Status: adapter.CapabilityUnsupported, Reason: reason},
	}}
}

// terminalFact 构造一条执行侧上报事实。
func terminalFact(kind string, available bool, version, reason string) TerminalFact {
	return TerminalFact{
		TerminalID:   "term_fixture",
		ObservedAtMS: 1_800_000_000_000,
		ProviderFacts: []ProviderFact{{
			Kind: kind, Available: available, Version: version, Reason: reason,
			DefaultModel: "deepseek-v4",
			ModelGroups: []ProviderFactGroup{{
				ID: "openai", Name: "OpenAI",
				Models: []ProviderFactModel{{Provider: "openai", Value: "deepseek-v4", ID: "deepseek-v4", Name: "DeepSeek V4"}},
			}},
		}},
	}
}

func providerByName(t *testing.T, providers []adapterreg.Provider, kind string) adapterreg.Provider {
	t.Helper()
	for _, provider := range providers {
		if provider.Kind == kind {
			return provider
		}
	}
	t.Fatalf("合并结果缺少 provider %q: %#v", kind, providers)
	return adapterreg.Provider{}
}

// (规则 1) Relay 自身探测成功时以自己为准，即使执行侧也上报了事实。
func TestV092MergePrefersRelayWhenRelayCanExecute(t *testing.T) {
	merged := MergeProviderFacts(
		[]adapterreg.Provider{relayOK("dsh", "0.0.1")},
		[]TerminalFact{terminalFact("dsh", true, "9.9.9", "")},
	)
	dsh := providerByName(t, merged, "dsh")
	if dsh.FactsSource != FactSourceRelay || !dsh.Available || dsh.Version != "0.0.1" {
		t.Fatalf("Relay 可执行时必须采用本进程事实: %#v", dsh)
	}
}

// (规则 2) 云端形态：Relay 跑不了 DSH，但在线 Terminal 上报可用 →
// 采用执行侧事实与模型目录，并标注来源 terminal。
func TestV092MergeAdoptsTerminalFactsWhenRelayCannotExecute(t *testing.T) {
	const relayReason = `未找到 node 运行时: exec: "node": executable file not found in $PATH`
	merged := MergeProviderFacts(
		[]adapterreg.Provider{relayFail("dsh", relayReason)},
		[]TerminalFact{terminalFact("dsh", true, "0.0.1", "")},
	)
	dsh := providerByName(t, merged, "dsh")
	if dsh.FactsSource != FactSourceTerminal {
		t.Fatalf("必须标注事实来源为 terminal: %#v", dsh)
	}
	if !dsh.Available || dsh.Version != "0.0.1" {
		t.Fatalf("必须采用执行侧可用事实: %#v", dsh)
	}
	// 模型目录必须来自执行侧（云端 DSH 模型选择器的唯一事实源）。
	var modelSelect adapter.Capability
	for _, capability := range dsh.Capabilities {
		if capability.Name == "model_select" {
			modelSelect = capability
		}
	}
	if len(modelSelect.ModelGroups) != 1 || modelSelect.Default != "deepseek-v4" {
		t.Fatalf("模型目录必须来自执行侧: %#v", modelSelect)
	}
	if len(modelSelect.Options) != 1 || modelSelect.Options[0] != "deepseek-v4" {
		t.Fatalf("model_select Options 必须展平执行侧目录: %#v", modelSelect.Options)
	}
	// start 必须在可用事实下恢复为 native，否则移动端仍无法发送。
	for _, capability := range dsh.Capabilities {
		if capability.Name == "start" && capability.Status != adapter.CapabilityNative {
			t.Fatalf("执行侧可用时 start 必须 native: %#v", capability)
		}
	}
}

// (规则 3) 两侧都不可用：保持 fail-closed，且原因采用执行侧上报的当前原因。
func TestV092MergeKeepsFailClosedWithTerminalReason(t *testing.T) {
	merged := MergeProviderFacts(
		[]adapterreg.Provider{relayFail("dsh", "relay 侧原因")},
		[]TerminalFact{terminalFact("dsh", false, "", "执行侧未找到 node 运行时")},
	)
	dsh := providerByName(t, merged, "dsh")
	if dsh.FactsSource != FactSourceUnavailable || dsh.Available {
		t.Fatalf("两侧不可用时必须 fail-closed: %#v", dsh)
	}
	if dsh.Version != "" {
		t.Fatalf("不可用时 Version 必须留空: %#v", dsh)
	}
	found := false
	for _, capability := range dsh.Capabilities {
		if capability.Status != adapter.CapabilityUnsupported {
			t.Fatalf("不可用时能力必须全部 unsupported: %#v", capability)
		}
		if capability.Reason == "执行侧未找到 node 运行时" {
			found = true
		}
	}
	if !found {
		t.Fatalf("原因必须采用执行侧上报的当前事实: %#v", dsh.Capabilities)
	}
}

// (规则 4 + 安全边界) 执行侧声明不可用，绝不会因为 Relay 的其它结果被伪造成可用；
// 同时执行侧未上报的 Provider 保持 Relay 自身口径。
func TestV092MergeNeverFabricatesAvailability(t *testing.T) {
	merged := MergeProviderFacts(
		[]adapterreg.Provider{relayFail("dsh", "relay 侧失败"), relayOK("codex", "1.2.3")},
		[]TerminalFact{{TerminalID: "term_other", ObservedAtMS: 1, ProviderFacts: []ProviderFact{
			{Kind: "dsh", Available: false, Reason: "执行侧桥不可用"},
		}}},
	)
	dsh := providerByName(t, merged, "dsh")
	if dsh.Available || dsh.FactsSource != FactSourceUnavailable {
		t.Fatalf("执行侧声明不可用时必须 fail-closed: %#v", dsh)
	}
	codex := providerByName(t, merged, "codex")
	if !codex.Available || codex.FactsSource != FactSourceRelay {
		t.Fatalf("执行侧未上报的 Provider 保持 Relay 口径: %#v", codex)
	}
}

// (择优选源) 多台在线 Terminal 上报同一 Provider 时，取观测时间最新的一条，
// 且结果与输入顺序无关（TerminalID 升序作为稳定次序）。
func TestV092MergePicksLatestTerminalFactDeterministically(t *testing.T) {
	older := terminalFact("dsh", true, "0.0.1", "")
	older.TerminalID = "term_a"
	older.ObservedAtMS = 1000
	newer := terminalFact("dsh", true, "0.0.2", "")
	newer.TerminalID = "term_b"
	newer.ObservedAtMS = 2000

	forward := MergeProviderFacts([]adapterreg.Provider{relayFail("dsh", "x")}, []TerminalFact{older, newer})
	backward := MergeProviderFacts([]adapterreg.Provider{relayFail("dsh", "x")}, []TerminalFact{newer, older})
	if got := providerByName(t, forward, "dsh").Version; got != "0.0.2" {
		t.Fatalf("必须采用最新观测事实，got %q", got)
	}
	if forward[0].Version != backward[0].Version {
		t.Fatalf("合并结果必须与输入顺序无关: %q vs %q", forward[0].Version, backward[0].Version)
	}
}

// (诊断) 执行侧上报了 Relay 未注册的 Provider 时也要出现在结果中，
// 并按其自身事实判定可用性。
func TestV092MergeIncludesTerminalOnlyProvider(t *testing.T) {
	merged := MergeProviderFacts(
		[]adapterreg.Provider{relayFail("dsh", "x")},
		[]TerminalFact{terminalFact("newprovider", true, "3.0.0", "")},
	)
	provider := providerByName(t, merged, "newprovider")
	if !provider.Available || provider.FactsSource != FactSourceTerminal {
		t.Fatalf("执行侧独有的 Provider 必须按执行侧事实呈现: %#v", provider)
	}
}
