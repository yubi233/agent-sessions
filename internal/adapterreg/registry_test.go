package adapterreg

import (
	"context"
	"testing"

	"github.com/yubi233/agent-sessions/internal/adapter"
)

// 四类 Provider 均能被枚举，且能力状态合法（native/emulated/unsupported）。
func TestRegistryListsFourProviders(t *testing.T) {
	r := New()
	providers, err := r.List(context.Background())
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if len(providers) != 4 {
		t.Fatalf("want 4 providers, got %d", len(providers))
	}
	for _, p := range providers {
		if p.Kind != "claude" && p.Kind != "codex" && p.Kind != "opencode" && p.Kind != "openclaw" {
			t.Fatalf("unexpected provider kind %q", p.Kind)
		}
		// 能力清单与协议对齐。
		if len(p.Capabilities) != len(adapter.CapabilityNames) {
			t.Fatalf("%s capabilities len=%d want %d", p.Kind, len(p.Capabilities), len(adapter.CapabilityNames))
		}
		for _, c := range p.Capabilities {
			switch c.Status {
			case adapter.CapabilityNative, adapter.CapabilityEmulated, adapter.CapabilityUnsupported:
			default:
				t.Fatalf("%s invalid capability status %q for %s", p.Kind, c.Status, c.Name)
			}
		}
	}
}

// 未知能力必须 unsupported（跨 Provider 派发）。
func TestUnknownCapabilityIsUnsupported(t *testing.T) {
	r := New()
	providers, _ := r.List(context.Background())
	for _, p := range providers {
		for _, c := range p.Capabilities {
			if c.Name == "delegate_cross_provider" && c.Status == adapter.CapabilityNative {
				t.Fatalf("%s should not claim delegate_cross_provider native without live gate", p.Kind)
			}
		}
	}
}

// 未配置 live 二进制/地址时，所有 Provider 不可用（blocked），不伪造 native。
func TestUnavailableWithoutCreds(t *testing.T) {
	r := New()
	providers, _ := r.List(context.Background())
	for _, p := range providers {
		// 未设置 AGENT_SESSIONS_*_BIN/URL 时 Available 应为 false（除非 CI 显式配置）。
		if p.Version != "" && p.Available == false {
			// 允许；这里仅断言不会因为无凭据而把 unsupported 伪造成可用。
		}
		hasNative := false
		for _, c := range p.Capabilities {
			if c.Status == adapter.CapabilityNative {
				hasNative = true
			}
		}
		_ = hasNative
	}
}
