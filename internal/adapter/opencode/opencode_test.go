package opencode

import (
	"context"
	"errors"
	"os"
	"testing"

	"github.com/yubi233/agent-sessions/internal/adapter"
)

// ADPT-OPENCODE-01：配置地址不是 transport 已实现的证据；能力矩阵必须和 Start/Resume 行为一致。
func TestConfiguredAdapterFailsClosedBeforeTransportIsImplemented(t *testing.T) {
	t.Setenv(EnvURL, "http://127.0.0.1:4096")
	a := New()

	caps, err := a.Detect(context.Background())
	if err != nil {
		t.Fatalf("detect: %v", err)
	}
	if caps.Version != "" {
		t.Fatalf("version = %q, want empty before transport discovery", caps.Version)
	}
	if len(caps.Capabilities) != len(adapter.CapabilityNames) {
		t.Fatalf("capabilities len = %d, want %d", len(caps.Capabilities), len(adapter.CapabilityNames))
	}
	for _, capability := range caps.Capabilities {
		if capability.Status != adapter.CapabilityUnsupported {
			t.Fatalf("%s status = %q, want unsupported", capability.Name, capability.Status)
		}
		if capability.Reason == "" {
			t.Fatalf("%s must explain its unavailable transport", capability.Name)
		}
	}

	if _, err := a.Start(context.Background(), adapter.StartRequest{}); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("start error = %v, want os.ErrNotExist", err)
	}
	resume, err := a.Resume(context.Background(), adapter.ResumeRequest{})
	if err != nil {
		t.Fatalf("resume: %v", err)
	}
	if resume.Result != adapter.WakeUnsupported {
		t.Fatalf("resume result = %q, want %q", resume.Result, adapter.WakeUnsupported)
	}
}
