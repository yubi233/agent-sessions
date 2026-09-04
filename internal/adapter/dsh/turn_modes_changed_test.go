// V086-01（B 组，迭代计划 §3.1）：current_mode_update 变化必须触发内部
// modes_changed 标记事件（事件泵据此把最新 mode 目录重上行 Relay）；
// 同一值重复通知不得重复推（去重）；句柄目录快照保持实时。
package dsh

import (
	"context"
	"testing"
	"time"

	"github.com/yubi233/agent-sessions/internal/adapter"
)

func TestV086CurrentModeUpdateEmitsModesChangedMarker(t *testing.T) {
	const sessionID = "sess-v086-mode"
	fb := newFakeBridge()
	fb.script = respondWithModes(t, sessionID, modeCatalog(), "")
	a := NewWithTransport(func() (BridgeTransport, error) { return fb, nil })
	h, err := a.Start(context.Background(), adapter.StartRequest{WorkspaceRoot: "/tmp/dsh-ws"})
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	t.Cleanup(func() { _ = h.Dispose(context.Background()) })
	modeHandle, ok := h.(adapter.SessionModeHandle)
	if !ok {
		t.Fatalf("handle 未实现 SessionModeHandle")
	}

	pushModeUpdate := func(modeID string) {
		fb.push(t, map[string]any{
			"jsonrpc": "2.0", "method": "session/update",
			"params": map[string]any{
				"sessionId": sessionID,
				"update":    map[string]any{"sessionUpdate": "current_mode_update", "currentModeId": modeID},
			},
		})
	}

	countMarkers := func(timeout time.Duration) int {
		deadline := time.After(timeout)
		count := 0
		for {
			select {
			case <-deadline:
				return count
			case ev, ok := <-h.Events():
				if !ok {
					return count
				}
				if ev.Type == adapter.EventModesChanged {
					count++
				}
			}
		}
	}

	// 初始帧排空窗口内的既有事件，之后变化 → 恰好一个标记事件。
	go func() {
		time.Sleep(50 * time.Millisecond)
		pushModeUpdate("danger-full-access")
	}()
	if n := countMarkers(1 * time.Second); n != 1 {
		t.Fatalf("mode 变化应推出恰好 1 个 modes_changed 标记，得到 %d", n)
	}
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) && modeHandle.Modes().CurrentModeID != "danger-full-access" {
		time.Sleep(10 * time.Millisecond)
	}
	if got := modeHandle.Modes().CurrentModeID; got != "danger-full-access" {
		t.Fatalf("快照未更新: %q", got)
	}

	// 同一值重复通知：快照不变，不再推标记（去重契约）。
	go func() {
		time.Sleep(50 * time.Millisecond)
		pushModeUpdate("danger-full-access")
		pushModeUpdate("danger-full-access")
	}()
	if n := countMarkers(400 * time.Millisecond); n != 0 {
		t.Fatalf("同一值重复通知不得推出标记，得到 %d", n)
	}
}
