package dsh

// v0.8.2 P0 一致性守护测试：固化模型/默认模型/档位目录与能力清单漂移检测。
// YAML 解析只存在于本测试文件（计划 §8：测试内使用，生产路径零新依赖），
// 以仓库 cordis.yml 为唯一配置真相源，禁止测试内复制第二份模型清单。

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/yubi233/agent-sessions/internal/adapter"
	"github.com/yubi233/agent-sessions/packages/protocol"
)

// TestCordisRosterMatchesKnownModels 断言仓库 cordis.yml acp-agent 段与 dshKnownModels
// roster 双向一致；Default 与 cordis 默认模型一致且 ∈ Options。
func TestCordisRosterMatchesKnownModels(t *testing.T) {
	acp := cordisSection(t, "acp-agent")
	defaultModel := sectionScalar(acp, "model")
	if defaultModel != dshDefaultModel {
		t.Fatalf("Default 漂移: cordis.yml model=%q, dshDefaultModel=%q", defaultModel, dshDefaultModel)
	}
	routed := sectionModelProviders(acp)
	if len(routed) == 0 {
		t.Fatal("cordis.yml acp-agent.modelProviders 缺失或为空")
	}
	roster := map[string]bool{}
	for _, m := range dshKnownModels {
		roster[m] = true
	}
	for _, model := range dshKnownModels {
		if _, ok := routed[model]; !ok {
			t.Fatalf("roster 漂移: dshKnownModels 含 %q 但 cordis.yml modelProviders 不可路由", model)
		}
	}
	for model := range routed {
		if !roster[model] {
			t.Fatalf("roster 漂移: cordis.yml modelProviders 含 %q 但 dshKnownModels 缺失（同步 adapter.go）", model)
		}
	}
	if !roster[dshDefaultModel] {
		t.Fatalf("Default %q 不在 Options 中", dshDefaultModel)
	}
}

// TestEffortSelectDirectoryTruth 断言 effort 目录真值：
// 只有至少一个可路由模型公布档位时才允许 effort_select native；否则必须 unsupported。
// 目录真值来自 cordis.yml llm 段 reasoningEfforts 声明（P1 起同步 adapter.go dshKnownEfforts）。
func TestEffortSelectDirectoryTruth(t *testing.T) {
	declared := cordisDeclaredEfforts(t)
	// 当前契约：无档位声明时矩阵保持 unsupported，禁止空目录冒充 native。
	caps := successMatrix("test")
	for _, c := range caps.Capabilities {
		if c.Name != "effort_select" {
			continue
		}
		if len(declared) > 0 {
			t.Logf("桥已声明档位模型 %v（P1 需同步 dshKnownEfforts 并升 native）", declared)
			if c.Status == adapter.CapabilityUnsupported {
				t.Fatalf("模型已公布档位但 effort_select 仍 unsupported: %v", declared)
			}
			return
		}
		if c.Status != adapter.CapabilityUnsupported {
			t.Fatalf("无模型公布档位却宣称 %s（目录为空不得冒充 native）: %v", c.Status, c)
		}
		return
	}
}

// TestCapabilityListsDoNotDiverge 断言 SPI 与公共协议能力清单逐项一致（v0.8.2 修复漂移）。
func TestCapabilityListsDoNotDiverge(t *testing.T) {
	spi := map[string]bool{}
	for _, name := range adapter.CapabilityNames {
		spi[name] = true
	}
	proto := map[string]bool{}
	for _, name := range protocol.CapabilityNames {
		proto[name] = true
	}
	for name := range spi {
		if !proto[name] {
			t.Fatalf("能力清单漂移: SPI 含 %q 但 packages/protocol/types.go 缺失", name)
		}
	}
	for name := range proto {
		if !spi[name] {
			t.Fatalf("能力清单漂移: packages/protocol/types.go 含 %q 但 SPI 缺失", name)
		}
	}
}

// ---- cordis.yml 提取器（测试专用，只解析本仓库规整的两空格缩进 YAML 子集） ----

// cordisPath 从包 cwd 上溯定位仓库根 cordis.yml。
func cordisPath(t *testing.T) string {
	t.Helper()
	dir, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	for {
		candidate := filepath.Join(dir, "cordis.yml")
		if _, err := os.Stat(candidate); err == nil {
			return candidate
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			break
		}
		dir = parent
	}
	t.Fatal("未找到仓库 cordis.yml（在仓库根运行 go test ./internal/adapter/dsh/）")
	return ""
}

// cordisLines 返回去注释/空行的行（保留原始缩进）。
func cordisLines(t *testing.T) []string {
	t.Helper()
	raw, err := os.ReadFile(cordisPath(t))
	if err != nil {
		t.Fatalf("读取 cordis.yml: %v", err)
	}
	var out []string
	for _, line := range strings.Split(string(raw), "\n") {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" || strings.HasPrefix(trimmed, "#") {
			continue
		}
		out = append(out, line)
	}
	return out
}

// cordisSection 提取顶层 "- id: <name>" 起的连续行（到下一个同缩进 - id 前）。
func cordisSection(t *testing.T, name string) []string {
	t.Helper()
	lines := cordisLines(t)
	start := -1
	for i, line := range lines {
		if strings.HasPrefix(strings.TrimSpace(line), "- id: "+name) && indentOf(line) == 0 {
			start = i
			break
		}
	}
	if start < 0 {
		t.Fatalf("cordis.yml 缺少顶层段 - id: %s", name)
	}
	var out []string
	for _, line := range lines[start+1:] {
		if indentOf(line) == 0 {
			break
		}
		out = append(out, line)
	}
	return out
}

func indentOf(line string) int {
	return len(line) - len(strings.TrimLeft(line, " "))
}

// sectionScalar 取段内任意缩进 "key: value" 的标量（含 !!js 表达式原样返回）。
func sectionScalar(section []string, key string) string {
	prefix := key + ":"
	for _, line := range section {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, prefix) && !strings.HasPrefix(trimmed, "- ") {
			// 忽略以 - id: 开头的行；key: 必须位于行首且为键（排除 - 列表项内的 key）。
			return strings.TrimSpace(strings.TrimPrefix(trimmed, prefix))
		}
	}
	return ""
}

// sectionModelProviders 取 acp-agent.modelProviders 的 "<model>: <provider>" 映射。
// modelProviders 子项缩进为 6；遇到缩进 <6 的非注释行（如 persona: 顶级键）即结束。
func sectionModelProviders(section []string) map[string]string {
	out := map[string]string{}
	inProviders := false
	for _, line := range section {
		trimmed := strings.TrimSpace(line)
		ind := indentOf(line)
		if strings.HasPrefix(trimmed, "modelProviders:") {
			inProviders = true
			continue
		}
		if !inProviders {
			continue
		}
		if strings.HasPrefix(trimmed, "#") || trimmed == "" {
			continue
		}
		if ind < 6 {
			// 缩进回退到 modelProviders 外层（persona 等同级键）→ 结束收集。
			break
		}
		parts := strings.SplitN(trimmed, ":", 2)
		if len(parts) != 2 {
			continue
		}
		k := strings.TrimSpace(parts[0])
		v := strings.TrimSpace(parts[1])
		if k != "" && v != "" && !strings.Contains(k, " ") {
			out[k] = v
		}
	}
	return out
}

// cordisDeclaredEfforts 收集 llm 段 config.providers.<p>.models[*].reasoningEfforts 的键。
func cordisDeclaredEfforts(t *testing.T) map[string][]string {
	t.Helper()
	llm := cordisSection(t, "llm")
	declared := map[string][]string{}
	// 行级扫描：- id: <model> 后跟 reasoningEfforts 块（缩进 12+），键为档位。
	modelID := ""
	inEfforts := false
	for _, line := range llm {
		trimmed := strings.TrimSpace(line)
		ind := indentOf(line)
		if strings.HasPrefix(trimmed, "- id: ") && ind >= 8 {
			modelID = strings.TrimSpace(strings.TrimPrefix(trimmed, "- id: "))
			inEfforts = false
			continue
		}
		if strings.HasPrefix(trimmed, "reasoningEfforts:") && modelID != "" {
			inEfforts = true
			continue
		}
		if inEfforts {
			if ind < 14 && !strings.HasPrefix(trimmed, "- ") {
				inEfforts = false
				continue
			}
			if strings.HasPrefix(trimmed, "- ") {
				effort := strings.TrimSpace(strings.TrimPrefix(trimmed, "- "))
				effort = strings.TrimSpace(strings.SplitN(effort, ":", 2)[0])
				declared[modelID] = append(declared[modelID], effort)
			}
		}
	}
	return declared
}

var _ = regexp.MustCompile
