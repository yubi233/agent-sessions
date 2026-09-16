package dsh

// V092-02 Daemon 进程内 Detect 复核（v0.9.2 §4「P0 实测归因」）。
//
// 归因目标（§1.2 四层）：
//   L1：能力事实源位于**进程内**适配器。Detect 的成败由持有该适配器的进程
//       决定——Relay 容器为 scratch 单二进制（无 node、无 DSH 检出）时，
//       同一份代码在云端 Relay 必然 fail-closed，而本机 Daemon 侧正常。
//   L3：首次握手结果被永久缓存（adapter.go handshakeDone），失败后不可恢复：
//       环境修复（装上 node / 修好桥路径）也不会让既有进程重新可用，
//       只能重启进程。这正是"手机显示 Provider 当前不可用后一直不恢复"的机制。
//
// 本文件只做归因取证与回归钉扎，不改变产品行为；受控重探测（C2/V092-05）
// 在 P1 落地时把 TestV092DetectCacheLocksFailureUntilRestart 从"记录现状"
// 反转为"修复后必须可恢复"。
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

// (L1) 进程内事实源：同一份 dsh.Adapter 代码的 Detect 结果完全由该进程的环境决定。
// 子场景 1 = 云端 Relay 形态（无 node / 无桥检出 → 传输层无法 spawn）：
// Detect 不返回错误，而是给出 fail-closed 矩阵（Version 空 + 全 unsupported + 中文原因）。
func TestV092DetectIsPerProcessFact(t *testing.T) {
	a := NewWithTransport(func() (BridgeTransport, error) {
		return nil, errors.New(`未找到 node 运行时: exec: "node": executable file not found in $PATH`)
	})
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
	// 原因必须可传导（移动端展示"Provider 当前不可用"背后的可诊断事实）。
	if !strings.Contains(caps.Capabilities[0].Reason, "node") {
		t.Fatalf("原因应保留可诊断细节: %q", caps.Capabilities[0].Reason)
	}
}

// (L3-a) 缓存死锁（传输层失败形态）：spawn 失败（云端 scratch 容器无 node）后
// handshakeDone 置位，此后不再重探；即使桥已恢复可用，同一进程内仍永久 fail-closed。
func TestV092DetectCacheLocksFailureUntilRestart(t *testing.T) {
	failing := true
	var spawns int
	a := NewWithTransport(func() (BridgeTransport, error) {
		spawns++
		if failing {
			return nil, errors.New(`未找到 node 运行时: exec: "node": executable file not found in $PATH`)
		}
		fb := newFakeBridge()
		fb.script = respondByMethod(t, "v092-healed")
		return fb, nil
	})
	first, err := a.Detect(context.Background())
	if err != nil {
		t.Fatalf("Detect: %v", err)
	}
	if first.Version != "" {
		t.Fatalf("首次失败必须 fail-closed: %#v", first)
	}
	if spawns != 1 {
		t.Fatalf("首次 Detect 应尝试一次 spawn，spawns=%d", spawns)
	}

	// "环境修复"：装上 node / 修好桥路径。同一适配器实例必须仍然不可用（L3）。
	failing = false
	second, err := a.Detect(context.Background())
	if err != nil {
		t.Fatalf("第二次 Detect: %v", err)
	}
	if second.Version != "" {
		t.Fatalf("现状应仍被缓存锁死（L3 缺陷）；P1 实现受控重探测后本断言需反转: %#v", second)
	}
	if spawns != 1 {
		t.Fatalf("失败缓存命中时不得重新 spawn，spawns=%d（want 1）", spawns)
	}
	// 关键用户影响：同一进程内，后续所有 Detect 都返回首次失败原因，
	// 移动端因此持续显示"Provider 当前不可用"，只有重启进程才能恢复。
	if second.Capabilities[0].Reason != first.Capabilities[0].Reason {
		t.Fatalf("缓存必须原样返回首次失败原因: %q vs %q",
			second.Capabilities[0].Reason, first.Capabilities[0].Reason)
	}
}

// (L3-b) 缓存死锁（握手失败形态）：传输可创建但握手报错（桥存在但版本/协议异常）。
// 与 L3-a 同构：失败被永久缓存。
func TestV092DetectCacheLocksHandshakeFailure(t *testing.T) {
	failing := true
	a := NewWithTransport(func() (BridgeTransport, error) {
		fb := newFakeBridge()
		if failing {
			// initialize 无应答（桥存在但不应答/协议不匹配）：等价握手失败。
			// 用调用方 deadline 收敛等待，不阻塞 30s 默认握手超时。
			fb.script = func(*fakeBridge, map[string]any) {}
			return fb, nil
		}
		fb.script = respondByMethod(t, "v092-handshake-healed")
		return fb, nil
	})
	shortCtx, cancelShort := context.WithTimeout(context.Background(), 300*time.Millisecond)
	first, err := a.Detect(shortCtx)
	cancelShort()
	if err != nil {
		t.Fatalf("Detect: %v", err)
	}
	if first.Version != "" {
		t.Fatalf("握手失败必须 fail-closed: %#v", first)
	}
	failing = false
	second, err := a.Detect(context.Background())
	if err != nil {
		t.Fatalf("第二次 Detect: %v", err)
	}
	if second.Version != "" {
		t.Fatalf("握手失败同样被永久缓存（L3）；P1 受控重探测落地后本断言需反转: %#v", second)
	}
}

// (对照) 成功握手后同样被缓存：第二次 Detect 不重新 spawn（握手有成本，C2 明确
// 禁止无条件每请求重探）。该用例与上面互为边界，避免 P1 实现改成"每次都重探"。
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
}

// (live) 执行侧真实桥复核：门控 AGENT_SESSIONS_DSH_LIVE=1。
// 与 TestLiveBridgeLifecycle 同口径，额外记录模型目录规模，供 P0 归因报告引用。
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
