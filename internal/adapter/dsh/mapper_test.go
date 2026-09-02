package dsh

import (
	"encoding/json"
	"testing"

	"github.com/yubi233/agent-sessions/internal/adapter"
)

// TestMapSessionUpdateIncludesReplayUserMessage 覆盖回放用户消息映射（既有回归）。
func TestMapSessionUpdateIncludesReplayUserMessage(t *testing.T) {
	event, ok, variant := mapSessionUpdate("sess-1", json.RawMessage(`{
    "sessionUpdate":"user_message_chunk",
    "content":{"type":"text","text":"历史问题"}
  }`))
	if !ok || variant != "user_message_chunk" {
		t.Fatalf("map result = %+v ok=%v variant=%q", event, ok, variant)
	}
	if event.Type != adapter.EventUserMessage || event.Payload["text"] != "历史问题" {
		t.Fatalf("user replay event = %+v", event)
	}
}

// TestMapToolCallToEventToolCall 工具打开帧 → EventToolCall：载荷白名单。
func TestMapToolCallToEventToolCall(t *testing.T) {
	event, ok, variant := mapSessionUpdate("sess-1", json.RawMessage(`{
    "sessionUpdate":"tool_call",
    "toolCallId":"call-1",
    "status":"in_progress",
    "kind":"execute",
    "title":"bash: ls -la",
    "rawInput":{"command":"ls -la","description":"列出文件"}
  }`))
	if !ok || variant != "tool_call" {
		t.Fatalf("map result = %+v ok=%v variant=%q", event, ok, variant)
	}
	if event.Type != adapter.EventToolCall {
		t.Fatalf("event type = %q, want tool_call", event.Type)
	}
	if event.Payload["instance_id"] != "sess-1" || event.Payload["tool_call_id"] != "call-1" ||
		event.Payload["status"] != "in_progress" || event.Payload["tool_call_kind"] != "execute" ||
		event.Payload["title"] != "bash: ls -la" {
		t.Fatalf("tool call payload = %#v", event.Payload)
	}
	// rawInput 只透传合法 JSON 结构（解析为 map）。
	raw, ok := event.Payload["raw_input"].(map[string]any)
	if !ok || raw["command"] != "ls -la" {
		t.Fatalf("raw_input 未按结构化 JSON 透传: %#v", event.Payload["raw_input"])
	}
}

// TestMapToolCallMalformedDropped 畸形/孤儿打开帧（缺 tool_call_id）丢弃并计数；
// 超限畸形 rawInput 也绝不进入事件载荷。
func TestMapToolCallMalformedDropped(t *testing.T) {
	_, ok, variant := mapSessionUpdate("sess-1", json.RawMessage(`{
    "sessionUpdate":"tool_call","kind":"execute"
  }`))
	if ok || variant != "tool_call" {
		t.Fatalf("缺 tool_call_id 的打开帧必须丢弃: ok=%v variant=%q", ok, variant)
	}
	// rawInput 若不是 JSON 对象（如裸字符串 "x"），仍不进入事件载荷（保持结构化）。
	event, ok, _ := mapSessionUpdate("sess-1", json.RawMessage(`{
    "sessionUpdate":"tool_call","toolCallId":"c2","kind":"read",
    "rawInput":"{not-json"
  }`))
	if !ok {
		t.Fatalf("合法打开帧被丢弃")
	}
	raw, has := event.Payload["raw_input"]
	if !has {
		t.Fatalf("合法 rawInput 字符串应保留: %#v", event.Payload)
	}
	if _, isMap := raw.(map[string]any); isMap {
		t.Fatalf("非对象 rawInput 不得解析为对象: %#v", event.Payload["raw_input"])
	}
	// 整个帧是畸形 JSON 文本时按 <malformed> 丢弃（坏帧容错）。
	_, ok, variant = mapSessionUpdate("sess-1", json.RawMessage(`{"sessionUpdate":"tool_call","toolCallId":"c3","rawInput":{"unclosed": }`))
	if ok || variant != "<malformed>" {
		t.Fatalf("畸形 JSON 帧必须按 malformed 丢弃: ok=%v variant=%q", ok, variant)
	}
}

// TestMapToolCallUpdateToEventToolResult 工具关闭帧 → EventToolResult（两层解包文本）。
func TestMapToolCallUpdateToEventToolResult(t *testing.T) {
	event, ok, variant := mapSessionUpdate("sess-1", json.RawMessage(`{
    "sessionUpdate":"tool_call_update",
    "toolCallId":"call-1",
    "status":"completed",
    "content":[{"type":"content","content":{"type":"text","text":"ok"}}]
  }`))
	if !ok || variant != "tool_call_update" {
		t.Fatalf("map result = %+v ok=%v variant=%q", event, ok, variant)
	}
	if event.Type != adapter.EventToolResult {
		t.Fatalf("event type = %q, want tool_result", event.Type)
	}
	if event.Payload["tool_call_id"] != "call-1" || event.Payload["status"] != "completed" ||
		event.Payload["output_text"] != "ok" {
		t.Fatalf("tool result payload = %#v", event.Payload)
	}
}

// TestMapToolCallUpdateMalformedDropped 孤儿关闭帧丢弃；内容形状不符不伪造正文。
func TestMapToolCallUpdateMalformedDropped(t *testing.T) {
	_, ok, variant := mapSessionUpdate("sess-1", json.RawMessage(`{
    "sessionUpdate":"tool_call_update","status":"failed"
  }`))
	if ok || variant != "tool_call_update" {
		t.Fatalf("缺 tool_call_id 的关闭帧必须丢弃: ok=%v variant=%q", ok, variant)
	}
	// 无 content 的合法关闭帧仍映射（无正文），status=failed。
	event, ok, _ := mapSessionUpdate("sess-1", json.RawMessage(`{
    "sessionUpdate":"tool_call_update","toolCallId":"c3","status":"failed"
  }`))
	if !ok || event.Type != adapter.EventToolResult {
		t.Fatalf("无正文关闭帧应映射: %+v", event)
	}
	if _, has := event.Payload["output_text"]; has {
		t.Fatalf("空正文不得伪造 output_text: %#v", event.Payload)
	}
	// content 形状不符（缺外层 content 数组元素结构）同样不产生正文。
	event, ok, _ = mapSessionUpdate("sess-1", json.RawMessage(`{
    "sessionUpdate":"tool_call_update","toolCallId":"c4","status":"completed",
    "content":[{"type":"bogus"}]
  }`))
	if !ok || event.Type != adapter.EventToolResult {
		t.Fatalf("形状不符关闭帧仍应映射为空正文: %+v", event)
	}
	if _, has := event.Payload["output_text"]; has {
		t.Fatalf("形状不符不得伪造 output_text: %#v", event.Payload)
	}
}
