package dsh

// V092-02 / V092-05 DSH 适配器进程内探测契约（v0.9.2 P0 归因 + P1 受控重探测）。
//
// 背景（P0 实测，报告 e2e-verify/reports/2026-09-16T04-36-52-300Z/V092-ATTRIB/）：
//   L1：能力事实源位于**进程内**适配器。同一份 dsh.Adapter 代码在云端 Relay 容器
//       （scratch 单二进制，无 node / 无 DSH 检出）必然 fail-closed，而执行侧
//       Daemon 进程正常。移动端消费的 /v1/capabilities 来自 Relay 进程，故误判。
//   L3：首次握手结果被永久缓存，环境修复后同进程内不可自愈，只能重启进程。
//
// P1 修复（C2/§3.2 冻结契约）：Detect 增加**受控重探测**——
//   失败才重探、冷却窗口约束、并发 single-flight、成功快照仍零成本命中。
//   本文件的缓存类用例因此从"记录 L3 现状"反转为"钉扎 C2 契约"。
//
// 对应项目文档 docs/zh/项目文档.md「PC Daemon」与「统一能力模型」章节。

import (
	"context"
	"errors"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/yubi233/agent-sessions/internal/adapter"
)

// v092NoNodeFactory 返回"云端 Relay 形态"的传输工厂：spawn 必然失败（无 node）。
func v092NoNodeFactory() (BridgeTransport, error) {
	return nil, errors.New(`未找到 node 运行时: exec: "node": executable file not found in $PATH`)
}

// v092HealthyFactory 返回可正常握手的假桥（等价"环境已修复"）。
func v092HealthyFactory(t *testing.T, sessionID string) func() (BridgeTransport, error) {
	t.Helper()
	return func() (BridgeTransport, error) {
		fb := newFakeBridge()
		fb.script = respondByMethod(t, sessionID)
		return fb, nil
	}
}

// (L1) 进程内事实源：同一份 Adapter 代码的可用性完全由持有它的进程环境决定。
// 子场景 = 云端 Relay 形态（传输层无法 spawn）：Detect 不返回错误，而是给出
// fail-closed 矩阵（Version 空 + 全 unsupported + 可解释中文原因）。
func TestV092DetectIsPerProcessFact(t *testing.T) {
	a := NewWithTransport(v092NoNodeFactory)
	caps, err := a.Detect(context.Background())
	if err != nil {
		t.Fatalf("Detect 不应返回错误（fail-closed 走能力矩阵）: %v", err)
	}
	if caps.Provider != "dsh" || caps.Version != "" {
		t.Fatalf("不可用时 Provider=dsh 且 Version 必须留空: %#v", caps)
	}
	if len(caps.Capabilities) == 0 {
		t.Fatal("fail-closed 矩阵必须逐条列出能力与原因")
	}
	for _, c := range caps.Capabilities {
		if c.Status != adapter.CapabilityUnsupported {
			t.Fatalf("不可用时 %s 必须 unsupported，got %q", c.Name, c.Status)
		}
		if strings.TrimSpace(c.Reason) == "" {
			t.Fatalf("fail-closed 必须带可解释的中文原因: %#v", c)
		}
	}
	// 原因必须可传导（移动端"Provider 当前不可用"背后的可诊断事实）。
	if !strings.Contains(caps.Capabilities[0].Reason, "node") {
		t.Fatalf("原因应保留可诊断细节: %q", caps.Capabilities[0].Reason)
	}
}

// (C2-a) 传输层失败后的受控重探：冷却窗口内不重探（防 spawn 风暴），
// 冷却到期后自动重探并恢复能力与模型目录——不再需要重启进程。
func TestV092ReprobeRecoversAfterTransportFailure(t *testing.T) {
	recovered := false
	spawns := 0
	a := NewWithTransport(func() (BridgeTransport, error) {
		spawns++
		if !recovered {
			return v092NoNodeFactory()
		}
		fb := newFakeBridge()
		fb.script = respondByMethod(t, "v092-transport-healed")
		return fb, nil
	})
	// 注入可控时钟：测试不 sleep，直接推进时间越过冷却窗口。
	now := time.Unix(1_800_000_000, 0)
	a.clock = func() time.Time { return now }
	a.reprobeCooldown = 15 * time.Second

	first, err := a.Detect(context.Background())
	if err != nil {
		t.Fatalf("Detect: %v", err)
	}
	if first.Version != "" {
		t.Fatalf("首次失败必须 fail-closed: %#v", first)
	}
	firstReason := first.Capabilities[0].Reason
	if spawns != 1 {
		t.Fatalf("首次 Detect 应尝试一次 spawn，spawns=%d", spawns)
	}

	// "环境修复"（装上 node）：冷却窗口内必须仍然不重探，事实保持稳定。
	recovered = true
	now = now.Add(5 * time.Second)
	second, err := a.Detect(context.Background())
	if err != nil {
		t.Fatalf("冷却期内 Detect: %v", err)
	}
	if second.Version != "" {
		t.Fatalf("冷却窗口内不得重探（应继续返回失败快照）: %#v", second)
	}
	if spawns != 1 {
		t.Fatalf("冷却窗口内不得重新 spawn，spawns=%d（want 1）", spawns)
	}
	if second.Capabilities[0].Reason != firstReason {
		t.Fatalf("冷却窗口内原因必须保持稳定: %q vs %q", second.Capabilities[0].Reason, firstReason)
	}

	// 冷却到期：下一次 Detect 触发重探并恢复。
	now = now.Add(11 * time.Second)
	third, err := a.Detect(context.Background())
	if err != nil {
		t.Fatalf("冷却到期后 Detect: %v", err)
	}
	if third.Version == "" {
		t.Fatalf("冷却到期后必须自愈（无需重启进程），实际仍 fail-closed: %s", third.Capabilities[0].Reason)
	}
	if spawns != 2 {
		t.Fatalf("冷却到期应重探一次，spawns=%d（want 2）", spawns)
	}
	var startOK bool
	for _, c := range third.Capabilities {
		if c.Name == "start" && c.Status == adapter.CapabilityNative {
			startOK = true
		}
	}
	if !startOK {
		t.Fatalf("恢复后 start 必须 native: %#v", third.Capabilities)
	}
	if a.reprobeAttemptCount() != 0 {
		t.Fatalf("成功后重探计数必须复位，got %d", a.reprobeAttemptCount())
	}
}

// (C2-b) 握手失败形态（桥存在但不应答/协议不匹配）同样受控自愈，
// 且**新失败原因实时覆盖旧原因**（用户看到的是当前事实，不是历史陈迹）。
func TestV092ReprobeRecoversAfterHandshakeFailure(t *testing.T) {
	mode := "no-reply"
	a := NewWithTransport(func() (BridgeTransport, error) {
		fb := newFakeBridge()
		switch mode {
		case "no-reply":
			// 桥不应答 initialize：用调用方 deadline 收敛等待（不阻塞 30s 默认超时）。
			fb.script = func(*fakeBridge, map[string]any) {}
		case "gate-rejected":
			fb.script = respondInitializeAgentInfo(t, verifiedBridgeName, "9.9.9")
		default:
			fb.script = respondByMethod(t, "v092-handshake-healed")
		}
		return fb, nil
	})
	now := time.Unix(1_800_000_000, 0)
	a.clock = func() time.Time { return now }
	a.reprobeCooldown = 10 * time.Second

	probe := func() adapter.Capabilities {
		t.Helper()
		shortCtx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
		defer cancel()
		caps, err := a.Detect(shortCtx)
		if err != nil {
			t.Fatalf("Detect: %v", err)
		}
		return caps
	}

	first := probe()
	if first.Version != "" {
		t.Fatalf("握手失败必须 fail-closed: %#v", first)
	}
	// 第二轮：原因类型变化（版本门拒绝）→ 冷却到期后重探必须刷新原因文本。
	mode = "gate-rejected"
	now = now.Add(11 * time.Second)
	second := probe()
	if second.Version != "" {
		t.Fatalf("版本门拒绝仍须 fail-closed: %#v", second)
	}
	if !strings.Contains(second.Capabilities[0].Reason, "9.9.9") {
		t.Fatalf("重探后的新失败原因必须覆盖旧原因: %q", second.Capabilities[0].Reason)
	}
	// 第三轮：真正修复 → 恢复。
	mode = "healthy"
	now = now.Add(11 * time.Second)
	third := probe()
	if third.Version == "" {
		t.Fatalf("修复后必须自愈，实际: %s", third.Capabilities[0].Reason)
	}
}

// (C2-c) 边界：成功快照永久零成本命中——重探测不得退化为"每个请求都 spawn 桥"。
func TestV092DetectCacheHitsAreFree(t *testing.T) {
	var spawns int
	a := NewWithTransport(func() (BridgeTransport, error) {
		spawns++
		fb := newFakeBridge()
		fb.script = respondByMethod(t, "v092-hit")
		return fb, nil
	})
	first, _ := a.Detect(context.Background())
	if first.Version == "" {
		t.Fatalf("首次握手应成功: %#v", first)
	}
	spawnsAfterFirst := spawns
	for i := 0; i < 3; i++ {
		if _, err := a.Detect(context.Background()); err != nil {
			t.Fatalf("Detect #%d: %v", i+2, err)
		}
	}
	if spawns != spawnsAfterFirst {
		t.Fatalf("成功缓存不得重复 spawn（spawns %d → %d）", spawnsAfterFirst, spawns)
	}
	if a.reprobeAttemptCount() != 0 {
		t.Fatalf("成功快照路径不得累计重探计数，got %d", a.reprobeAttemptCount())
	}
}

// (C2-d) 冷却配置语义：显式 0 = 不缓存失败（每次重探，诊断用）；
// 非法/空值回退缺省 15s（该开关不具备"关闭安全门"的语义）。
func TestV092ReprobeCooldownEnv(t *testing.T) {
	t.Setenv(EnvReprobeCooldown, "0")
	if got := reprobeCooldownFromEnv(); got != 0 {
		t.Fatalf("显式 0 应关闭失败缓存: %v", got)
	}
	t.Setenv(EnvReprobeCooldown, "2500")
	if got := reprobeCooldownFromEnv(); got != 2500*time.Millisecond {
		t.Fatalf("显式毫秒值应生效: %v", got)
	}
	t.Setenv(EnvReprobeCooldown, "  ")
	if got := reprobeCooldownFromEnv(); got != defaultReprobeCooldown {
		t.Fatalf("空白应回退缺省: %v", got)
	}
	t.Setenv(EnvReprobeCooldown, "-1")
	if got := reprobeCooldownFromEnv(); got != defaultReprobeCooldown {
		t.Fatalf("负值应回退缺省: %v", got)
	}
	t.Setenv(EnvReprobeCooldown, "abc")
	if got := reprobeCooldownFromEnv(); got != defaultReprobeCooldown {
		t.Fatalf("非法值应回退缺省: %v", got)
	}
	os.Unsetenv(EnvReprobeCooldown)
	if got := reprobeCooldownFromEnv(); got != defaultReprobeCooldown {
		t.Fatalf("未设置应使用缺省: %v", got)
	}
}

// (live) 执行侧真实桥复核：门控 AGENT_SESSIONS_DSH_LIVE=1。
// 与 TestLiveBridgeLifecycle 同口径，额外记录模型目录规模，供归因报告引用。
// 环境不可用时明确 fail（不记 passed），保证"执行侧正常"的结论有真实凭据。
func TestV092LiveExecutionSideDetect(t *testing.T) {
	if os.Getenv("AGENT_SESSIONS_DSH_LIVE") != "1" {
		t.Skip("AGENT_SESSIONS_DSH_LIVE != 1：跳过真实桥 Detect 复核")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	a := New()
	caps, err := a.Detect(ctx)
	if err != nil {
		t.Fatalf("Detect: %v", err)
	}
	if caps.Version == "" {
		t.Fatalf("执行侧真实桥必须可用，实际 fail-closed 原因: %s", caps.Capabilities[0].Reason)
	}
	var start adapter.Capability
	modelGroups := 0
	for _, c := range caps.Capabilities {
		if c.Name == "start" {
			start = c
		}
		modelGroups += len(c.ModelGroups)
	}
	if start.Status != adapter.CapabilityNative {
		t.Fatalf("start 必须 native: %#v", start)
	}
	t.Logf("V092_LIVE_SUMMARY provider=dsh version=%s model_groups=%d", caps.Version, modelGroups)
}
