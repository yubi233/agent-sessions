package adapterreg

import (
	"context"
	"os"
	"path/filepath"
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

// 未配置 live 二进制/地址时，所有 Provider 不可用，且能力必须带原因地 fail-closed。
func TestUnavailableWithoutConfiguration(t *testing.T) {
	t.Setenv("AGENT_SESSIONS_CLAUDE_BIN", "")
	t.Setenv("AGENT_SESSIONS_CODEX_BIN", "")
	t.Setenv("AGENT_SESSIONS_OPENCODE_URL", "")
	t.Setenv("OPENCODE_SERVER_PASSWORD", "")
	t.Setenv("AGENT_SESSIONS_OPENCLAW_URL", "")

	r := New()
	providers, err := r.List(context.Background())
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	for _, p := range providers {
		if p.Available || p.Version != "" {
			t.Fatalf("%s available/version = %v/%q, want false/empty", p.Kind, p.Available, p.Version)
		}
		for _, c := range p.Capabilities {
			if c.Status != adapter.CapabilityUnsupported {
				t.Fatalf("%s.%s status = %q, want unsupported", p.Kind, c.Name, c.Status)
			}
			if c.Reason == "" {
				t.Fatalf("%s.%s must explain why provider is unavailable", p.Kind, c.Name)
			}
		}
	}
}

// 已探测到 stub CLI 或配置 Gateway URL 时，Registry 也不能把未实现能力升级为 native。
func TestStubProviderRegistrationStaysFailClosed(t *testing.T) {
	bin := filepath.Join(t.TempDir(), "provider-fixture")
	if err := os.WriteFile(bin, []byte("#!/bin/sh\necho 'provider 9.9.9'\n"), 0o700); err != nil {
		t.Fatalf("write fixture CLI: %v", err)
	}
	t.Setenv("AGENT_SESSIONS_CLAUDE_BIN", bin)
	t.Setenv("AGENT_SESSIONS_CODEX_BIN", bin)
	t.Setenv("AGENT_SESSIONS_OPENCODE_URL", "")
	t.Setenv("OPENCODE_SERVER_PASSWORD", "")
	t.Setenv("AGENT_SESSIONS_OPENCLAW_URL", "ws://127.0.0.1:65535")

	providers, err := New().List(context.Background())
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	byKind := make(map[string]Provider, len(providers))
	for _, provider := range providers {
		byKind[provider.Kind] = provider
	}
	for _, kind := range []string{"claude", "codex", "openclaw"} {
		provider := byKind[kind]
		for _, capability := range provider.Capabilities {
			if capability.Status != adapter.CapabilityUnsupported {
				t.Fatalf("%s.%s status = %q, want unsupported", kind, capability.Name, capability.Status)
			}
		}
	}
	if !byKind["claude"].Available || !byKind["codex"].Available {
		t.Fatal("detected CLI versions should remain visible as installed providers")
	}
	if byKind["openclaw"].Available || byKind["openclaw"].Version != "" {
		t.Fatalf("OpenClaw URL without handshake must not be available: %#v", byKind["openclaw"])
	}
}
