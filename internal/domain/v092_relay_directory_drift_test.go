package domain

// V092 回归（R12 实测坑，必须钉住）：Relay 自探测成功时，**目录整份来自 Relay**。
//
// 背景：本地/自建 Relay 与 Daemon 是同一台机器上的两个进程，各自按自己的配置探测 DSH。
// 若两者传入的 DSH 配置不同（典型：Relay 未设置 AGENT_SESSIONS_DSH_CONFIG，用了适配器
// 缺省配置 examples/acp-agent/cordis.yml），Relay 会公布一份与真正执行命令的 Daemon
// 完全不同的模型目录。按规则 1「Relay 自己能真实执行 → 以自己为准」，客户端就会拿到
// Relay 那份目录，于是出现「模型选择器里选得到的模型发出去就是 unknown model route」。
//
// 这是**设计的取舍**（T2 裁决：Relay 能真实执行时以其为准），因此本测试不是要改语义，
// 而是把语义钉死并留下原因与处置：配置一致是部署约束（统一入口已默认注入同一份
// cordis.yml，见 e2e-verify/lib/relay.mjs 的 startRelay）。若有朝一日要改成「执行侧优先」，
// 本测试会失败——请连带更新 §13.3 的运维约定与统一入口的注入逻辑。
import (
	"testing"

	"github.com/yubi233/agent-sessions/internal/adapter"
	"github.com/yubi233/agent-sessions/internal/adapterreg"
)

func TestV092MergeRelayDirectoryWinsWhenRelayCanExecute(t *testing.T) {
	// Relay 自探测成功，目录里的模型 = 缺省配置那条（deepseek-official 渠道）。
	relayDsh := adapterreg.Provider{
		Kind: "dsh", Version: "0.0.1", Available: true,
		Capabilities: []adapter.Capability{{
			Name: "model_select", Status: adapter.CapabilityNative,
			Default: "dsh:model:deepseek-official:deepseek-v4-pro",
			ModelGroups: []adapter.ModelCapabilityGroup{{
				ID: "deepseek-official", Name: "DeepSeek",
				Models: []adapter.ModelCapabilityModel{{
					Provider: "deepseek-official", Value: "dsh:model:deepseek-official:deepseek-v4-pro",
					ID: "deepseek-v4-pro", Name: "DeepSeek V4 Pro",
				}},
			}},
		}},
	}
	// 执行侧上报的是另一份目录（本仓库 cordis.yml 那条）。
	execFact := TerminalFact{
		TerminalID: "term_fixture", ObservedAtMS: 1_800_000_000_000,
		ProviderFacts: []ProviderFact{{
			Kind: "dsh", Available: true, Version: "0.0.1",
			DefaultModel: "dsh:model:opencode-zen:nemotron-3-ultra-free",
			ModelGroups: []ProviderFactGroup{{
				ID: "opencode-zen", Name: "opencode-zen",
				Models: []ProviderFactModel{{
					Provider: "opencode-zen", Value: "dsh:model:opencode-zen:nemotron-3-ultra-free",
					ID: "nemotron-3-ultra-free", Name: "Nemotron 3 Ultra Free",
				}},
			}},
		}},
	}

	merged := MergeProviderFacts([]adapterreg.Provider{relayDsh}, []TerminalFact{execFact})
	dsh := providerByName(t, merged, "dsh")

	// 断言 1：来源标记为 relay（规则 1）。
	if dsh.FactsSource != FactSourceRelay {
		t.Fatalf("Relay 能执行时来源必须是 relay，got %q", dsh.FactsSource)
	}
	// 断言 2：目录整份来自 Relay（这正是 R12 那个坑的形式）。
	var modelCap *adapter.Capability
	for i := range dsh.Capabilities {
		if dsh.Capabilities[i].Name == "model_select" {
			modelCap = &dsh.Capabilities[i]
		}
	}
	if modelCap == nil {
		t.Fatal("合并结果缺少 model_select 能力")
	}
	if modelCap.Default != "dsh:model:deepseek-official:deepseek-v4-pro" {
		t.Fatalf("默认模型必须来自 Relay 目录，got %q", modelCap.Default)
	}
	for _, group := range modelCap.ModelGroups {
		if group.ID == "opencode-zen" {
			t.Fatal("Relay 能执行时不应混入执行侧目录（本测试钉住该语义；若这是期望变更，请更新 §13.3 与统一入口）")
		}
	}
}
