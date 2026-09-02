package daemon

// v0.8.2 P2：relayEventType 是 canonical 事件 → Relay event_type 的唯一映射，
// 漂移会直接导致移动端时间线无法识别事件（如权限请求被误判为 command.updated）。
// 本测试固化全部事件类型映射，新增事件类型必须在此登记。

import (
	"testing"

	"github.com/yubi233/agent-sessions/internal/adapter"
)

func TestRelayEventTypeMapping(t *testing.T) {
	cases := map[adapter.EventType]string{
		adapter.EventTurnStarted:        "turn.started",
		adapter.EventUserMessage:        "user.message",
		adapter.EventMessageDelta:       "message.delta",
		adapter.EventMessageCompleted:   "message.completed",
		adapter.EventTurnCompleted:      "turn.completed",
		adapter.EventToolCall:           "tool.call",
		adapter.EventToolResult:         "tool.result",
		adapter.EventPermissionRequest:  "permission.request",
		adapter.EventPermissionDecision: "permission.decision",
		adapter.EventUsage:              "usage.updated",
		adapter.EventFileChange:         "file.changed",
		// 未映射的受控类型保持 command.updated 兜底（不伪造专用类型）。
		adapter.EventUserQuestion:      "command.updated",
		adapter.EventPlanChanged:       "command.updated",
		adapter.EventGoalChanged:       "command.updated",
		adapter.EventSkillCatalog:      "command.updated",
		adapter.EventDelegationChanged: "command.updated",
	}
	for eventType, want := range cases {
		if got := relayEventType(eventType); got != want {
			t.Fatalf("relayEventType(%q) = %q, want %q", eventType, got, want)
		}
	}
}
