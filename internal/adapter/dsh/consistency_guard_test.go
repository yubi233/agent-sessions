package dsh

// DSH capability consistency guards.

import (
	"strings"
	"testing"

	"github.com/yubi233/agent-sessions/internal/adapter"
	"github.com/yubi233/agent-sessions/packages/protocol"
)

func TestDynamicACPModelCatalogDrivesCapabilities(t *testing.T) {
	one := adapter.ModelCapabilityModel{Provider: "one", Value: "route-one", ID: "same", Name: "One Same"}
	two := adapter.ModelCapabilityModel{Provider: "two", Value: "route-two", ID: "same", Name: "Two Same", Reasoning: true, Efforts: []string{"low", "high"}}
	caps := successMatrix("test", ModelCatalog{
		Groups:  []adapter.ModelCapabilityGroup{{ID: "one", Name: "One", Models: []adapter.ModelCapabilityModel{one}}, {ID: "two", Name: "Two", Models: []adapter.ModelCapabilityModel{two}}},
		Current: two,
	})
	byName := map[string]adapter.Capability{}
	for _, capability := range caps.Capabilities {
		byName[capability.Name] = capability
	}
	model := byName["model_select"]
	if len(model.ModelGroups) != 2 || len(model.Options) != 2 || model.Default != "route-two" {
		t.Fatalf("ACP dynamic catalog was not preserved: %+v", model)
	}
	if byName["effort_select"].Status != adapter.CapabilityNative {
		t.Fatalf("reasoning efforts must make effort_select native: %+v", byName["effort_select"])
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

// bridgeImplementedACP 是外部 deepseek-harness 仓库 ACP 桥当前已实现的方法清单
// （2026-09-03 核对 packages/acp/acp/src/index.ts，v0.8.3 P1 之后：initialize/
// authenticate/newSession/loadSession/resumeSession/setSessionConfigOption/
// setSessionMode/closeSession/listSessions/deleteSession/unstable_forkSession/
// prompt/cancel；additionalDirectories admission 与图像 admission（content.ts）随
// prompt/initialize 面提供）。
// 该清单是矩阵 unsupported 口径的桥事实锚点：桥侧新增方法时必须同步本清单，
// 否则守护测试会红，防止能力矩阵把未实现能力误报为 native。
var bridgeImplementedACP = map[string]bool{
	"initialize":             true,
	"authenticate":           true,
	"newSession":             true,
	"loadSession":            true,
	"resumeSession":          true,
	"setSessionConfigOption": true,
	"session/set_mode":       true,
	"session/close":          true,
	"session/list":           true,
	"session/delete":         true,
	"session/fork":           true,
	"additionalDirectories":  true,
	"image admission":        true,
	"prompt":                 true,
	"cancel":                 true,
}

// TestBridgeFactMatrixGuard（V082-13/14/15 守护落点；V083-P5 收口修订）断言矩阵
// 与桥事实、gate 证据双向一致：
//  1. deterministic overlay（dsh-v083-overlay.mjs 15/15）通过后 permission_mode/fork
//     升为 native，reason 必须引用 gate 证据，失效旧口径出现即红；
//  2. attachments 的 Relay opaque ref 链路未接通，保持 unsupported（新口径 reason）；
//  3. bridgeImplementedACP 清单与矩阵宣称互为锚点，防止未实现冒充 native。
func TestBridgeFactMatrixGuard(t *testing.T) {
	caps := successMatrix("test")
	byName := map[string]adapter.Capability{}
	for _, c := range caps.Capabilities {
		byName[c.Name] = c
	}
	// P5 升格面：桥已实现 + 全链路回归 + deterministic gate 证据。
	upgraded := []struct {
		acpFace   string
		capName   string
		status    string
		reasonSub string
	}{
		{
			acpFace: "session/set_mode", capName: "permission_mode",
			status: adapter.CapabilityNative, reasonSub: "deterministic overlay",
		},
		{
			acpFace: "session/fork", capName: "fork",
			status: adapter.CapabilityNative, reasonSub: "deterministic overlay",
		},
	}
	for _, item := range upgraded {
		c, ok := byName[item.capName]
		if !ok {
			t.Fatalf("能力矩阵缺少 %q", item.capName)
		}
		if !bridgeImplementedACP[item.acpFace] {
			t.Fatalf("%s 宣称 %s 但桥事实清单未登记 %s（同步 bridgeImplementedACP）", item.capName, item.status, item.acpFace)
		}
		if c.Status != item.status {
			t.Fatalf("P5 gate 通过后 %s 应为 %s，得到 %s", item.capName, item.status, c.Status)
		}
		if !strings.Contains(c.Reason, item.reasonSub) {
			t.Fatalf("%s reason 必须引用 gate 证据: %q", item.capName, c.Reason)
		}
		for _, stale := range []string{"桥配置固定", "链路接入后升格", "未实现"} {
			if strings.Contains(c.Reason, stale) {
				t.Fatalf("%s reason 仍含失效口径 %q: %q", item.capName, stale, c.Reason)
			}
		}
	}

	// attachments：v0.8.8 P1-P4 升格（emulated）——daemon 拉取出口 + 本机 DEK Open
	// 契约（attachment_open.go，迭代计划 §9.1）+ 全链回归（V088-02/03/06）+
	// 端到端（V088-09）。守护锚点：状态锁定 emulated（桥 admission 上限），
	// reason 必须引用套件证据，旧口径不得残留。
	c, ok := byName["attachments"]
	if !ok {
		t.Fatalf("能力矩阵缺少 attachments")
	}
	if !bridgeImplementedACP["image admission"] {
		t.Fatalf("桥事实清单应登记 image admission（P1 起已实现）")
	}
	if c.Status != adapter.CapabilityEmulated {
		t.Fatalf("V088 升格后 attachments 应为 emulated（桥 admission 上限），得到 %s", c.Status)
	}
	if !strings.Contains(c.Reason, "V088-02") || !strings.Contains(c.Reason, "§9.1") {
		t.Fatalf("attachments reason 必须引用 V088 证据与契约锚点: %q", c.Reason)
	}
	for _, stale := range []string{"未接通", "仅接受 text 块", "接入后按 deployment 条件升格"} {
		if strings.Contains(c.Reason, stale) {
			t.Fatalf("attachments reason 残留失效旧口径 %q: %q", stale, c.Reason)
		}
	}

	// file_read / git_read：v0.8.8 P2-P4 升格（native）——应用层只读命令通道
	// （恒声明 + ReadOnlyDispatcher 沙箱 + 移动端真实传输消费者）。守护锚点：
	// 状态锁定 native、reason 引用 V088 证据、桥 ACP fs/* 排除口径必须保留
	// （ADR-014 §9 的两套授权真相边界不因应用层通道升格而失效）。
	for _, item := range []struct {
		capName  string
		evidence string
	}{{"file_read", "V088-08"}, {"git_read", "V088-07"}} {
		rc, ok := byName[item.capName]
		if !ok {
			t.Fatalf("能力矩阵缺少 %q", item.capName)
		}
		if rc.Status != adapter.CapabilityNative {
			t.Fatalf("V088 升格后 %s 应为 native，得到 %s", item.capName, rc.Status)
		}
		if !strings.Contains(rc.Reason, item.evidence) {
			t.Fatalf("%s reason 必须引用 V088 证据: %q", item.capName, rc.Reason)
		}
		if !strings.Contains(rc.Reason, "ADR-014 §9") {
			t.Fatalf("%s reason 必须保留桥 ACP 排除口径（ADR-014 §9）: %q", item.capName, rc.Reason)
		}
		if strings.Contains(rc.Reason, "未实现") {
			t.Fatalf("%s reason 残留失效旧口径: %q", item.capName, rc.Reason)
		}
	}
}
