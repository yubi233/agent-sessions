package relay

// V092-03 / V092-04 集成回归：执行侧 Provider 事实经 hello/heartbeat 落库后，
// /v1/capabilities 必须按"谁在声明可用"给出唯一且可解释的事实来源。
//
// 对应迭代计划 §7 T2 裁决与 §5 覆盖矩阵：
//   - V092-03：Relay 自身探测失败时采用在线 Terminal 的执行侧事实（云端形态）；
//   - V092-04：会话视图的模型目录与执行侧一致（云端 DSH 模型选择器可用）。
//
// 口径：local_test=true、fixture_data=true；不启动真实 Provider、不发送 prompt。
// Relay 进程自身的 dsh Detect 在本环境必然失败（桥路径不存在），这正是云端形态的
// 等价复现——因此断言"事实来源 = terminal"而不是"来源 = relay"。

import (
	"net/http"
	"testing"

	"github.com/yubi233/agent-sessions/internal/adapter/dsh"
)

// v092ForceRelayCannotExecuteDSH 复现云端 Relay 形态：Relay 进程内 dsh Detect 必然
// 失败（scratch 单二进制，无 node / 无 DSH 检出）。本机开发环境里桥路径是存在的，
// 若不显式打断，Relay 会按"规则 1：自己能跑就以自己为准"采用本进程事实，
// 从而测不到执行侧事实源这条链路。
func v092ForceRelayCannotExecuteDSH(t *testing.T) {
	t.Helper()
	t.Setenv(dsh.EnvBin, "/nonexistent/v092-relay-bridge.js")
}

// v092CapabilitiesView 读取 /v1/capabilities 并返回按 kind 索引的视图。
type v092ProviderView struct {
	Kind         string `json:"kind"`
	Version      string `json:"version"`
	Available    bool   `json:"available"`
	FactsSource  string `json:"facts_source"`
	Capabilities []struct {
		Name        string   `json:"name"`
		Status      string   `json:"status"`
		Reason      string   `json:"reason"`
		Default     string   `json:"default"`
		Options     []string `json:"options"`
		ModelGroups []struct {
			ID     string `json:"id"`
			Models []struct {
				Value string `json:"value"`
			} `json:"models"`
		} `json:"model_groups"`
	} `json:"capabilities"`
}

func v092FetchProviders(t *testing.T, env *testEnv, token string) map[string]v092ProviderView {
	t.Helper()
	response := env.do(t, http.MethodGet, "/v1/capabilities", nil, token)
	if response.Code != http.StatusOK {
		t.Fatalf("capabilities status=%d body=%s", response.Code, response.Body.String())
	}
	var view struct {
		Providers []v092ProviderView `json:"providers"`
	}
	decodeW1(t, response.Body.Bytes(), &view)
	out := make(map[string]v092ProviderView, len(view.Providers))
	for _, provider := range view.Providers {
		out[provider.Kind] = provider
	}
	return out
}

// v092DshFactPayload 构造一条"执行侧可用"的 dsh 事实（含模型目录）。
func v092DshFactPayload(available bool, reason string) map[string]any {
	fact := map[string]any{
		"kind":                "dsh",
		"available":           available,
		"observed_at_unix_ms": 1_800_000_000_000,
	}
	if available {
		fact["version"] = "0.0.1"
		fact["default_model"] = "deepseek-v4"
		fact["model_groups"] = []map[string]any{{
			"id": "openai", "name": "OpenAI",
			"models": []map[string]any{{
				"provider": "openai", "value": "deepseek-v4", "id": "deepseek-v4", "name": "DeepSeek V4",
			}},
		}}
	} else if reason != "" {
		fact["reason"] = reason
	}
	return fact
}

// V092-03：hello 上报执行侧可用事实 → 能力矩阵采用执行侧事实，来源标注 terminal。
func TestV092CapabilitiesAdoptTerminalFactsAfterHello(t *testing.T) {
	v092ForceRelayCannotExecuteDSH(t)
	env := newTestEnv(t)
	owner := env.registerAs(t, "v092-capabilities@test.dev")
	terminal := env.pairTerminal(t, owner, "v092-capabilities-terminal")

	// 上报前：Relay 自身探测失败，dsh 必须 fail-closed 且来源为 unavailable。
	before := v092FetchProviders(t, env, owner.AccessToken)
	if dsh, ok := before["dsh"]; !ok {
		t.Fatalf("能力矩阵必须包含 dsh: %#v", before)
	} else if dsh.Available || dsh.FactsSource == "terminal" {
		t.Fatalf("上报前不得依据执行侧事实宣布可用: %#v", dsh)
	}

	// 执行侧上报事实（等价云端 Daemon 的 hello）。
	hello := env.do(t, http.MethodPost, "/v1/daemon/hello", map[string]any{
		"protocol_version": 1,
		"daemon_version":   "v092-fixture",
		"hostname":         "v092-host",
		"platform":         "darwin",
		"capabilities":     []string{"start", "send", "resume"},
		"provider_facts":   []map[string]any{v092DshFactPayload(true, "")},
	}, terminal.AccessToken)
	if hello.Code != http.StatusOK {
		t.Fatalf("hello status=%d body=%s", hello.Code, hello.Body.String())
	}

	after := v092FetchProviders(t, env, owner.AccessToken)
	dsh := after["dsh"]
	if !dsh.Available || dsh.Version != "0.0.1" {
		t.Fatalf("必须采用执行侧可用事实: %#v", dsh)
	}
	if dsh.FactsSource != "terminal" {
		t.Fatalf("事实来源必须标注 terminal（客户端据此区分谁在声明可用）: %#v", dsh)
	}
	var startOK bool
	for _, capability := range dsh.Capabilities {
		if capability.Name == "start" && capability.Status == "native" {
			startOK = true
		}
	}
	if !startOK {
		t.Fatalf("执行侧可用时 start 必须可用（否则手机仍无法发送）: %#v", dsh.Capabilities)
	}

	// V092-04：模型目录与执行侧一致。
	for _, capability := range dsh.Capabilities {
		if capability.Name != "model_select" {
			continue
		}
		if capability.Default != "deepseek-v4" {
			t.Fatalf("默认模型必须来自执行侧: %#v", capability)
		}
		if len(capability.Options) != 1 || capability.Options[0] != "deepseek-v4" {
			t.Fatalf("模型选项目录必须来自执行侧: %#v", capability.Options)
		}
		if len(capability.ModelGroups) != 1 || len(capability.ModelGroups[0].Models) != 1 ||
			capability.ModelGroups[0].Models[0].Value != "deepseek-v4" {
			t.Fatalf("模型分组必须来自执行侧: %#v", capability.ModelGroups)
		}
	}
}

// V092-03 边界 A：Terminal 离线后其历史事实不再被采信（避免"看到可发送、发出去失败"）。
func TestV092CapabilitiesIgnoreFactsFromOfflineTerminal(t *testing.T) {
	v092ForceRelayCannotExecuteDSH(t)
	env := newTestEnv(t)
	owner := env.registerAs(t, "v092-offline@test.dev")
	terminal := env.pairTerminal(t, owner, "v092-offline-terminal")
	hello := env.do(t, http.MethodPost, "/v1/daemon/hello", map[string]any{
		"protocol_version": 1, "daemon_version": "v092-fixture", "hostname": "h", "platform": "darwin",
		"capabilities":   []string{"start"},
		"provider_facts": []map[string]any{v092DshFactPayload(true, "")},
	}, terminal.AccessToken)
	if hello.Code != http.StatusOK {
		t.Fatalf("hello status=%d", hello.Code)
	}
	if dsh := v092FetchProviders(t, env, owner.AccessToken)["dsh"]; dsh.FactsSource != "terminal" {
		t.Fatalf("在线时应采用执行侧事实: %#v", dsh)
	}
	// 心跳过期（> offline deadline 60s）后事实不再被采信。
	v091AgeLastHeartbeat(t, env, v092TerminalID(t, env, owner.AccountID), 61_000)
	if dsh := v092FetchProviders(t, env, owner.AccessToken)["dsh"]; dsh.FactsSource == "terminal" || dsh.Available {
		t.Fatalf("离线 Terminal 的历史事实不得被采信: %#v", dsh)
	}
}

// V092-03 边界 B：心跳随行刷新事实（环境变化后无需重连即可纠正表述）。
func TestV092CapabilitiesFollowHeartbeatFactRefresh(t *testing.T) {
	v092ForceRelayCannotExecuteDSH(t)
	env := newTestEnv(t)
	owner := env.registerAs(t, "v092-refresh@test.dev")
	terminal := env.pairTerminal(t, owner, "v092-refresh-terminal")
	hello := env.do(t, http.MethodPost, "/v1/daemon/hello", map[string]any{
		"protocol_version": 1, "daemon_version": "v092-fixture", "hostname": "h", "platform": "darwin",
		"capabilities":   []string{"start"},
		"provider_facts": []map[string]any{v092DshFactPayload(true, "")},
	}, terminal.AccessToken)
	if hello.Code != http.StatusOK {
		t.Fatalf("hello status=%d", hello.Code)
	}
	if dsh := v092FetchProviders(t, env, owner.AccessToken)["dsh"]; !dsh.Available {
		t.Fatalf("初始应为执行侧可用: %#v", dsh)
	}
	// 执行侧退化：桥被删除/环境变化 → 随心跳上报不可用事实与原因。
	heartbeat := env.do(t, http.MethodPost, "/v1/daemon/heartbeat", map[string]any{
		"protocol_version": 1,
		"provider_facts":   []map[string]any{v092DshFactPayload(false, "执行侧未找到 node 运行时")},
	}, terminal.AccessToken)
	if heartbeat.Code != http.StatusOK {
		t.Fatalf("heartbeat status=%d body=%s", heartbeat.Code, heartbeat.Body.String())
	}
	dsh := v092FetchProviders(t, env, owner.AccessToken)["dsh"]
	if dsh.Available {
		t.Fatalf("执行侧声明不可用后不得继续宣布可用: %#v", dsh)
	}
	found := false
	for _, capability := range dsh.Capabilities {
		if capability.Status != "unsupported" {
			t.Fatalf("不可用时能力必须全部 unsupported: %#v", capability)
		}
		if capability.Reason == "执行侧未找到 node 运行时" {
			found = true
		}
	}
	if !found {
		t.Fatalf("必须转达执行侧给出的原因: %#v", dsh.Capabilities)
	}
}

// V092-03 边界 C：越界/非法事实整体拒绝（fail-closed，不静默截断）。
func TestV092HelloRejectsMalformedProviderFacts(t *testing.T) {
	env := newTestEnv(t)
	owner := env.registerAs(t, "v092-invalid@test.dev")
	terminal := env.pairTerminal(t, owner, "v092-invalid-terminal")

	cases := []struct {
		name  string
		facts []map[string]any
	}{
		{"缺少 kind", []map[string]any{{"available": true}}},
		{"默认模型不在目录内", []map[string]any{{
			"kind": "dsh", "available": true, "version": "0.0.1", "default_model": "ghost",
			"model_groups": []map[string]any{{"id": "g", "models": []map[string]any{{"value": "real"}}}},
		}}},
		{"模型缺少 value", []map[string]any{{
			"kind": "dsh", "available": true, "version": "0.0.1",
			"model_groups": []map[string]any{{"id": "g", "models": []map[string]any{{"id": "x"}}}},
		}}},
	}
	for _, tc := range cases {
		response := env.do(t, http.MethodPost, "/v1/daemon/hello", map[string]any{
			"protocol_version": 1, "daemon_version": "v092-fixture", "hostname": "h", "platform": "darwin",
			"capabilities":   []string{"start"},
			"provider_facts": tc.facts,
		}, terminal.AccessToken)
		if response.Code == http.StatusOK {
			t.Fatalf("%s：非法事实必须被拒绝，body=%s", tc.name, response.Body.String())
		}
	}
}

// v092TerminalID 读取账号下唯一 Terminal 的 ID（本文件固定单 Terminal fixture）。
func v092TerminalID(t *testing.T, env *testEnv, accountID string) string {
	t.Helper()
	var id string
	if err := env.db.QueryRow(
		`SELECT id FROM terminals WHERE account_id=?`, accountID).Scan(&id); err != nil {
		t.Fatalf("读取 Terminal: %v", err)
	}
	return id
}

// V092-03 对照：Relay 自己能真实执行该 Provider 时以本进程事实为准
// （localdev 同机形态），不因为执行侧上报了别的版本而改变结论。
func TestV092CapabilitiesPreferRelayWhenRelayCanExecute(t *testing.T) {
	env := newTestEnv(t)
	owner := env.registerAs(t, "v092-relay-owns@test.dev")
	terminal := env.pairTerminal(t, owner, "v092-relay-owns-terminal")
	hello := env.do(t, http.MethodPost, "/v1/daemon/hello", map[string]any{
		"protocol_version": 1, "daemon_version": "v092-fixture", "hostname": "h", "platform": "darwin",
		"capabilities":   []string{"start"},
		"provider_facts": []map[string]any{v092DshFactPayload(true, "")},
	}, terminal.AccessToken)
	if hello.Code != http.StatusOK {
		t.Fatalf("hello status=%d", hello.Code)
	}
	dsh := v092FetchProviders(t, env, owner.AccessToken)["dsh"]
	// 本机存在真实桥时 Relay 自身探测成功；此时来源必须是 relay，
	// 而不是被执行侧上报覆盖（Relay 与执行侧同为可执行方，本进程事实更直接）。
	if dsh.FactsSource == "terminal" {
		t.Fatalf("Relay 自己能执行时不得被执行侧事实覆盖: %#v", dsh)
	}
}
