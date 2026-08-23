package dsh

import (
	"context"
	"os"
	"testing"
	"time"

	"github.com/yubi233/agent-sessions/internal/adapter"
)

// 真实子进程集成测试（单独文件）：与 e2e-verify/real/dsh-acp-smoke.mjs 同口径，
// 门控 AGENT_SESSIONS_DSH_LIVE=1 才运行，默认跳过（不依赖 DSH 检出树的存在）。
// 全程不发送 prompt（不触发模型调用、不联网），只验证真实桥的
// Detect/Start/Abort/Dispose 生命周期与能力矩阵。
func TestLiveBridgeLifecycle(t *testing.T) {
	if os.Getenv("AGENT_SESSIONS_DSH_LIVE") != "1" {
		t.Skip("AGENT_SESSIONS_DSH_LIVE != 1：跳过真实子进程集成测试")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	a := New()
	caps, err := a.Detect(ctx)
	if err != nil {
		t.Fatalf("Detect: %v", err)
	}
	if caps.Version == "" {
		t.Fatalf("live 桥握手后 Version 必须非空: %#v", caps)
	}
	// 能力矩阵抽查：start/abort/kill native；resume unsupported 带原因；permission emulated。
	byName := map[string]adapter.Capability{}
	for _, cp := range caps.Capabilities {
		byName[cp.Name] = cp
	}
	if byName["start"].Status != adapter.CapabilityNative {
		t.Fatalf("start status = %q, want native", byName["start"].Status)
	}
	if byName["abort"].Status != adapter.CapabilityNative {
		t.Fatalf("abort status = %q, want native", byName["abort"].Status)
	}
	if byName["kill"].Status != adapter.CapabilityNative {
		t.Fatalf("kill status = %q, want native（per-session 进程组所有权）", byName["kill"].Status)
	}
	if byName["resume"].Status != adapter.CapabilityUnsupported || byName["resume"].Reason == "" {
		t.Fatalf("resume 必须 unsupported 且带原因: %#v", byName["resume"])
	}
	if byName["permission"].Status != adapter.CapabilityEmulated {
		t.Fatalf("permission status = %q, want emulated", byName["permission"].Status)
	}

	h, err := a.Start(ctx, adapter.StartRequest{WorkspaceRoot: t.TempDir()})
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	defer func() { _ = h.Dispose(context.Background()) }()
	idh, ok := h.(adapter.InstanceIDHandle)
	if !ok {
		t.Fatal("Start 必须返回 InstanceIDHandle")
	}
	if idh.InstanceID() == "" {
		t.Fatal("live sessionId 必须非空")
	}

	// 对空闲会话发 cancel：桥容错（P0 口径：进程存活、无应答帧）。
	if err := h.Abort(context.Background()); err != nil {
		t.Fatalf("对空闲会话 Abort 必须容错: %v", err)
	}

	// Dispose 关桥后事件通道应自然关闭。
	if err := h.Dispose(context.Background()); err != nil {
		t.Fatalf("Dispose: %v", err)
	}
	select {
	case _, open := <-h.Events():
		if open {
			t.Fatal("Dispose 后事件通道必须关闭")
		}
	case <-time.After(10 * time.Second):
		t.Fatal("事件通道未在 Dispose 后关闭")
	}
}
