package adapter_test

import (
	"context"
	"testing"

	"github.com/yubi233/agent-sessions/internal/adapter"
	"github.com/yubi233/agent-sessions/internal/adapter/claude"
	"github.com/yubi233/agent-sessions/internal/adapter/codex"
	"github.com/yubi233/agent-sessions/internal/adapter/openclaw"
	"github.com/yubi233/agent-sessions/internal/adapter/opencode"
)

// TestProviderCapabilitiesFailClosedWithoutTransport 统一保护四类 v0.4 Provider：
// 安装状态、URL 或历史 smoke 都不能替代当前 transport/凭据，未配置时必须完整 fail-closed。
func TestProviderCapabilitiesFailClosedWithoutTransport(t *testing.T) {
	t.Setenv(claude.EnvBin, "")
	t.Setenv(codex.EnvBin, "")
	t.Setenv(openclaw.EnvURL, "")
	t.Setenv(opencode.EnvURL, "")
	t.Setenv(opencode.EnvPassword, "")

	providers := []struct {
		name    string
		adapter adapter.Adapter
	}{
		{name: "claude", adapter: claude.New()},
		{name: "codex", adapter: codex.New()},
		{name: "opencode", adapter: opencode.New()},
		{name: "openclaw", adapter: openclaw.New()},
	}
	for _, provider := range providers {
		t.Run(provider.name, func(t *testing.T) {
			caps, err := provider.adapter.Detect(t.Context())
			if err != nil {
				t.Fatalf("Detect: %v", err)
			}
			assertCompleteUnsupportedMatrix(t, caps, provider.name)

			if _, err := provider.adapter.Start(t.Context(), adapter.StartRequest{WorkspaceRoot: t.TempDir()}); err == nil {
				t.Fatal("未配置 transport 时 Start 必须拒绝")
			}
			resumed, err := provider.adapter.Resume(context.Background(), adapter.ResumeRequest{InstanceID: "missing-instance"})
			if err != nil {
				t.Fatalf("Resume: %v", err)
			}
			if resumed.Result != adapter.WakeUnsupported || resumed.InstanceID != "" {
				t.Fatalf("Resume=%+v, want unsupported without instance id", resumed)
			}
		})
	}
}

// assertCompleteUnsupportedMatrix 校验客户端会消费到完整、可解释的能力矩阵；
// 缺项、重复项、未知状态或空原因都可能让 UI 错误开放写入口。
func assertCompleteUnsupportedMatrix(t *testing.T, caps adapter.Capabilities, provider string) {
	t.Helper()
	if caps.Provider != provider || caps.Version != "" {
		t.Fatalf("provider/version=%q/%q, want %q with no version", caps.Provider, caps.Version, provider)
	}
	if len(caps.Capabilities) != len(adapter.CapabilityNames) {
		t.Fatalf("capability count=%d, want %d", len(caps.Capabilities), len(adapter.CapabilityNames))
	}
	seen := make(map[string]bool, len(caps.Capabilities))
	for _, capability := range caps.Capabilities {
		if seen[capability.Name] {
			t.Fatalf("duplicate capability %q", capability.Name)
		}
		seen[capability.Name] = true
		if capability.Status != adapter.CapabilityUnsupported || capability.Reason == "" {
			t.Fatalf("capability %q=%q/%q, want unsupported with reason", capability.Name, capability.Status, capability.Reason)
		}
	}
	for _, name := range adapter.CapabilityNames {
		if !seen[name] {
			t.Fatalf("missing capability %q", name)
		}
	}
}
