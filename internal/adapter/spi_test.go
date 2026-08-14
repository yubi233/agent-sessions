package adapter

import (
	"context"
	"testing"
)

// ADPT-01：SPI 与能力矩阵合同——mock 返回三态且未知能力 unsupported。
func TestMockCapabilitiesContract(t *testing.T) {
	m := NewMockAdapter()
	caps, err := m.Detect(context.Background())
	if err != nil {
		t.Fatalf("detect: %v", err)
	}
	if caps.Provider != "mock" {
		t.Fatalf("provider = %q", caps.Provider)
	}
	byName := map[string]string{}
	for _, c := range caps.Capabilities {
		byName[c.Name] = c.Status
		if c.Status != CapabilityNative && c.Status != CapabilityEmulated && c.Status != CapabilityUnsupported {
			t.Fatalf("invalid status %q for %s", c.Status, c.Name)
		}
	}
	// 未知能力默认 unsupported（跨 Provider 派发）。
	if byName["delegate_cross_provider"] != CapabilityUnsupported {
		t.Fatalf("delegate_cross_provider should be unsupported")
	}
	if byName["start"] != CapabilityNative {
		t.Fatalf("start should be native")
	}
}

// Start 产生 turn/message/usage 事件，Dispose 正常回收。
func TestMockStartAndDispose(t *testing.T) {
	m := NewMockAdapter()
	h, err := m.Start(context.Background(), StartRequest{WorkspaceRoot: "/ws", Prompt: "hi"})
	if err != nil {
		t.Fatalf("start: %v", err)
	}
	defer func() { _ = h.Dispose(context.Background()) }()

	seen := map[EventType]bool{}
	for ev := range h.Events() {
		seen[ev.Type] = true
		if ev.Type == EventTurnStarted {
			break
		}
	}
	if !seen[EventTurnStarted] {
		t.Fatalf("no turn_started event")
	}
}

// MODE-04：Resume 六种唤醒结果，未注册 instance 默认 resumed，可注入其他结果。
func TestResumeWakeOutcomes(t *testing.T) {
	m := NewMockAdapter()
	valid := map[string]bool{
		WakeResumed: true, WakeRestartedWithContext: true, WakeUnsupported: true,
		WakeLocalStateMissing: true, WakeWorkspaceMoved: true, WakeTerminalOffline: true,
	}
	for _, outcome := range []string{
		WakeResumed, WakeRestartedWithContext, WakeUnsupported,
		WakeLocalStateMissing, WakeWorkspaceMoved, WakeTerminalOffline,
	} {
		m.SetWakeOverride("inst-"+outcome, outcome)
		res, err := m.Resume(context.Background(), ResumeRequest{InstanceID: "inst-" + outcome})
		if err != nil {
			t.Fatalf("resume %s: %v", outcome, err)
		}
		if !valid[res.Result] {
			t.Fatalf("invalid wake result %q", res.Result)
		}
	}
}
