package codex

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/yubi233/agent-sessions/internal/adapter"
)

// ADPT-CODEX-01：探测到 CLI 不能替代尚未实现的 app-server JSON-RPC transport 证据。
func TestDetectInstalledCLIStaysFailClosed(t *testing.T) {
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
	assertAllUnsupported(t, caps, "codex", "codex-cli 9.9.9")

	if _, err := a.Start(context.Background(), adapter.StartRequest{WorkspaceRoot: t.TempDir()}); err == nil {
		t.Fatal("Start must fail while app-server JSON-RPC transport is unavailable")
	}
	resumed, err := a.Resume(context.Background(), adapter.ResumeRequest{InstanceID: "codex-fixture"})
	if err != nil {
		t.Fatalf("resume: %v", err)
	}
	if resumed.Result != adapter.WakeUnsupported {
		t.Fatalf("resume result = %q, want %q", resumed.Result, adapter.WakeUnsupported)
	}
}

// assertAllUnsupported 校验能力清单完整，且每一项都明确给出禁用原因。
func assertAllUnsupported(t *testing.T, caps adapter.Capabilities, provider, version string) {
	t.Helper()
	if caps.Provider != provider || caps.Version != version {
		t.Fatalf("provider/version = %q/%q, want %q/%q", caps.Provider, caps.Version, provider, version)
	}
	if len(caps.Capabilities) != len(adapter.CapabilityNames) {
		t.Fatalf("capabilities len = %d, want %d", len(caps.Capabilities), len(adapter.CapabilityNames))
	}
	for _, capability := range caps.Capabilities {
		if capability.Status != adapter.CapabilityUnsupported {
			t.Fatalf("%s status = %q, want unsupported", capability.Name, capability.Status)
		}
		if capability.Reason == "" {
			t.Fatalf("%s must explain why transport is unavailable", capability.Name)
		}
	}
}
