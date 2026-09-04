// V086-01（B 组）：事件泵消费 modes_changed 内部标记 → 调 syncModeInfo 把
// 句柄最新 mode 目录重上行 Relay（modeInfoSink 收到）；标记事件本身不进
// canonical 时间线（事件出口不得出现 modes_changed）。
package daemon

import (
	"context"
	"sync"
	"testing"
	"time"

	"github.com/yubi233/agent-sessions/internal/adapter"
)

func TestV086ModesChangedMarkerTriggersModeInfoSync(t *testing.T) {
	_, runner, fake := newRunnerFixture(t, "opencode")
	if err := runner.ConsumeCommand(context.Background(), Command{
		Kind:        "session.start",
		PayloadJSON: `{"session_id":"s1","workspace_root":"/tmp/ws","provider":"opencode"}`,
	}); err != nil {
		t.Fatalf("start: %v", err)
	}
	h := fake.lastHandle()

	synced := make(chan adapter.SessionModeInfo, 4)
	runner.SetModeInfoSink(func(sessionID string, info adapter.SessionModeInfo, agentPreset string) {
		if sessionID == "s1" {
			synced <- info
		}
	})

	var sinkMu sync.Mutex
	var sinkEvents []adapter.Event
	runner.SetEventSink(func(sessionID string, event adapter.Event) {
		if sessionID != "s1" {
			return
		}
		sinkMu.Lock()
		defer sinkMu.Unlock()
		sinkEvents = append(sinkEvents, event)
	})

	h.mu.Lock()
	h.modesInfo = adapter.SessionModeInfo{
		CurrentModeID: "workspace-write",
		AvailableModes: []adapter.SessionMode{
			{ID: "workspace-write", Name: "Workspace write"},
			{ID: "danger-full-access", Name: "Danger full access"},
		},
	}
	h.mu.Unlock()
	h.emit(adapter.Event{Type: adapter.EventModesChanged,
		Payload: map[string]any{"instance_id": "s1", "current_mode": "workspace-write"}})

	select {
	case info := <-synced:
		if info.CurrentModeID != "workspace-write" || len(info.AvailableModes) != 2 {
			t.Fatalf("上行目录 = %+v", info)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("modes_changed 标记未触发 mode 目录重上行")
	}

	// 标记事件不进 canonical 时间线：事件出口不出现 modes_changed。
	time.Sleep(100 * time.Millisecond)
	sinkMu.Lock()
	defer sinkMu.Unlock()
	for _, event := range sinkEvents {
		if event.Type == adapter.EventModesChanged {
			t.Fatal("modes_changed 是内部标记，不得进入 canonical 事件出口")
		}
	}
}
