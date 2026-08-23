package codex

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/yubi233/agent-sessions/internal/adapter"
)

// W2 更新：探测到 CLI 且 start/resume/abort 已有 ADPT-CODEX-02 golden trace 契约后，
// 这三项升级 native；其余能力（审批/skills/model/effort 等）在 W3 证明前必须保持 unsupported。
// 同时 Start/Resume 在没有真实 app-server 协议对端时仍必须失败（fixture CLI 不回 JSON-RPC）。
func TestDetectInstalledCLINativeForContractedCapabilities(t *testing.T) {
	bin := filepath.Join(t.TempDir(), "codex-fixture")
	if err := os.WriteFile(bin, []byte("#!/bin/sh\necho 'codex-cli 9.9.9'\n"), 0o700); err != nil {
		t.Fatalf("write fixture CLI: %v", err)
	}
	t.Setenv(EnvBin, bin)

	a := New()
	if !a.Available() {
		t.Fatal("fixture CLI should be detected")
	}
	caps, err := a.Detect(context.Background())
	if err != nil {
		t.Fatalf("detect: %v", err)
	}
	assertCapabilityMatrix(t, caps, "codex", "codex-cli 9.9.9")

	if _, err := a.Start(context.Background(), adapter.StartRequest{WorkspaceRoot: t.TempDir()}); err == nil {
		t.Fatal("Start must fail without a real app-server JSON-RPC peer")
	}
	resumed, err := a.Resume(context.Background(), adapter.ResumeRequest{InstanceID: "codex-fixture"})
	if err != nil {
		t.Fatalf("resume: %v", err)
	}
	if resumed.Result != adapter.WakeUnsupported {
		t.Fatalf("resume result = %q, want %q", resumed.Result, adapter.WakeUnsupported)
	}
}

// assertCapabilityMatrix 校验能力清单完整、契约已证明项为 native、其余 unsupported 且给出原因。
func assertCapabilityMatrix(t *testing.T, caps adapter.Capabilities, provider, version string) {
	t.Helper()
	if caps.Provider != provider || caps.Version != version {
		t.Fatalf("provider/version = %q/%q, want %q/%q", caps.Provider, caps.Version, provider, version)
	}
	native := map[string]bool{"start": true, "resume": true, "abort": true, "permission": true, "plan": true, "goal": true, "skill_catalog": true, "model_select": true, "effort_select": true}
	for _, capability := range caps.Capabilities {
		if native[capability.Name] {
			if capability.Status != adapter.CapabilityNative {
				t.Fatalf("%s status = %q, want native（ADPT-CODEX-02 契约已覆盖）", capability.Name, capability.Status)
			}
			continue
		}
		if capability.Status != adapter.CapabilityUnsupported {
			t.Fatalf("%s status = %q, want unsupported", capability.Name, capability.Status)
		}
		if capability.Reason == "" {
			t.Fatalf("%s must explain why it is disabled", capability.Name)
		}
	}
}

// Feature flag（AGENT_SESSIONS_CODEX_ENABLE）缺省必须关闭；显式非空才开启。
func TestEnabledFromEnvDefaultsOff(t *testing.T) {
	if EnabledFromEnv(nil) {
		t.Fatal("nil getenv must be disabled")
	}
	if EnabledFromEnv(func(string) string { return "" }) {
		t.Fatal("unset flag must default off")
	}
	if !EnabledFromEnv(func(key string) string {
		if key == EnvEnabled {
			return "1"
		}
		return ""
	}) {
		t.Fatal("explicit flag must enable")
	}
}
