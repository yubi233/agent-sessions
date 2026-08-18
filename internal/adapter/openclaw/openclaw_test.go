package openclaw

import (
	"context"
	"testing"

	"github.com/yubi233/agent-sessions/internal/adapter"
)

// ADPT-OPENCLAW-01：配置 URL 不能替代 Gateway 握手、设备授权和 transport 证据。
func TestDetectConfiguredURLStaysFailClosed(t *testing.T) {
	t.Setenv(EnvURL, "ws://127.0.0.1:65535")

	a := New()
	caps, err := a.Detect(context.Background())
	if err != nil {
		t.Fatalf("detect: %v", err)
	}
	if caps.Provider != "openclaw" || caps.Version != "" {
		t.Fatalf("provider/version = %q/%q, want openclaw with no verified version", caps.Provider, caps.Version)
	}
	if len(caps.Capabilities) != len(adapter.CapabilityNames) {
		t.Fatalf("capabilities len = %d, want %d", len(caps.Capabilities), len(adapter.CapabilityNames))
	}
	for _, capability := range caps.Capabilities {
		if capability.Status != adapter.CapabilityUnsupported {
			t.Fatalf("%s status = %q, want unsupported", capability.Name, capability.Status)
		}
		if capability.Reason == "" {
			t.Fatalf("%s must explain why Gateway is unavailable", capability.Name)
		}
	}

	if _, err := a.Start(context.Background(), adapter.StartRequest{WorkspaceRoot: t.TempDir()}); err == nil {
		t.Fatal("Start must fail while Gateway transport is unavailable")
	}
	resumed, err := a.Resume(context.Background(), adapter.ResumeRequest{InstanceID: "openclaw-fixture"})
	if err != nil {
		t.Fatalf("resume: %v", err)
	}
	if resumed.Result != adapter.WakeUnsupported {
		t.Fatalf("resume result = %q, want %q", resumed.Result, adapter.WakeUnsupported)
	}
}
