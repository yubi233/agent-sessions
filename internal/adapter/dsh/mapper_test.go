package dsh

import (
	"encoding/json"
	"testing"

	"github.com/yubi233/agent-sessions/internal/adapter"
)

// TestMapUsageUpdateLegacyAndStandardFrames 钉住 usage 帧的两种桥形态：
// 旧桥只带 usage/contextWindow；新桥（v0.8.4 标准 usage_update）额外带
// used/size，且未知字段由 SDK 客户端剥离。mapper 对两种形态都必须产出
// EventUsage，字段逐一透传。
func TestMapUsageUpdateLegacyAndStandardFrames(t *testing.T) {
	cases := []struct {
		name  string
		frame string
	}{
		{
			name: "legacy bridge frame",
			frame: `{
				"sessionUpdate":"usage_update",
				"usage":{"inputTokens":2879,"outputTokens":89,"cacheReadTokens":0,"reasoningTokens":17},
				"contextWindow":65536
			}`,
		},
		{
			name: "standard superset frame (used/size + legacy fields)",
			frame: `{
				"sessionUpdate":"usage_update",
				"used":2968,
				"size":65536,
				"usage":{"inputTokens":2879,"outputTokens":89,"cacheReadTokens":0,"reasoningTokens":17},
				"contextWindow":65536
			}`,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			event, ok, variant := mapSessionUpdate("sess-1", json.RawMessage(tc.frame), nil)
			if !ok || variant != "usage_update" {
				t.Fatalf("map result = %+v ok=%v variant=%q", event, ok, variant)
			}
			if event.Type != adapter.EventUsage {
				t.Fatalf("event type = %q, want usage", event.Type)
			}
			for key, want := range map[string]any{
				"input_tokens":       int64(2879),
				"output_tokens":      int64(89),
				"cache_read_tokens":  int64(0),
				"cache_write_tokens": int64(0),
			} {
				if event.Payload[key] != want {
					t.Fatalf("payload[%q] = %v, want %v", key, event.Payload[key], want)
				}
			}
			if event.Payload["context_window_tokens"] != int64(65536) {
				t.Fatalf("context_window_tokens = %v", event.Payload["context_window_tokens"])
			}
		})
	}
}

// TestMapSessionUpdateIncludesReplayUserMessage 覆盖回放用户消息映射（既有回归）。
func TestMapSessionUpdateIncludesReplayUserMessage(t *testing.T) {
	event, ok, variant := mapSessionUpdate("sess-1", json.RawMessage(`{
    "sessionUpdate":"user_message_chunk",
    "content":{"type":"text","text":"历史问题"}
  }`), nil)
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
  }`), nil)
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
  }`), nil)
	if ok || variant != "tool_call" {
		t.Fatalf("缺 tool_call_id 的打开帧必须丢弃: ok=%v variant=%q", ok, variant)
	}
	// rawInput 若不是 JSON 对象（如裸字符串 "x"），仍不进入事件载荷（保持结构化）。
	event, ok, _ := mapSessionUpdate("sess-1", json.RawMessage(`{
    "sessionUpdate":"tool_call","toolCallId":"c2","kind":"read",
    "rawInput":"{not-json"
  }`), nil)
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
	_, ok, variant = mapSessionUpdate("sess-1", json.RawMessage(`{"sessionUpdate":"tool_call","toolCallId":"c3","rawInput":{"unclosed": }`), nil)
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
  }`), nil)
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
  }`), nil)
	if ok || variant != "tool_call_update" {
		t.Fatalf("缺 tool_call_id 的关闭帧必须丢弃: ok=%v variant=%q", ok, variant)
	}
	// 无 content 的合法关闭帧仍映射（无正文），status=failed。
	event, ok, _ := mapSessionUpdate("sess-1", json.RawMessage(`{
    "sessionUpdate":"tool_call_update","toolCallId":"c3","status":"failed"
  }`), nil)
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
  }`), nil)
	if !ok || event.Type != adapter.EventToolResult {
		t.Fatalf("形状不符关闭帧仍应映射为空正文: %+v", event)
	}
	if _, has := event.Payload["output_text"]; has {
		t.Fatalf("形状不符不得伪造 output_text: %#v", event.Payload)
	}
}

// ————— v0.8.4 流式映射（V084-06，ADR-015 §4/§5） —————

// dshMeta 是构造 session/update 参数级 _meta 的辅助。
func dshMeta(entries map[string]string) map[string]json.RawMessage {
	meta := make(map[string]json.RawMessage, len(entries))
	for key, value := range entries {
		meta[key] = json.RawMessage(value)
	}
	return meta
}

// TestMapTextDeltaMetaToEventMessageDelta 覆盖 text-delta 帧 → EventMessageDelta。
func TestMapTextDeltaMetaToEventMessageDelta(t *testing.T) {
	update := json.RawMessage(`{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"你好"}}`)
	event, ok, variant := mapSessionUpdate("sess-1", update, dshMeta(map[string]string{
		DshChunkMetaKey: `{"kind":"text-delta","turn":1,"step":2,"seq":7}`,
	}))
	if !ok || variant != "agent_message_chunk" {
		t.Fatalf("map ok=%v variant=%q", ok, variant)
	}
	if event.Type != adapter.EventMessageDelta {
		t.Fatalf("event type = %q, want message_delta", event.Type)
	}
	if event.Payload["message_id"] != "t1s2" || event.Payload["text"] != "你好" ||
		event.Payload["instance_id"] != "sess-1" {
		t.Fatalf("payload = %+v", event.Payload)
	}
}

// TestMapEmptyTextDeltaDropped 覆盖空 delta 丢弃计数。
func TestMapEmptyTextDeltaDropped(t *testing.T) {
	update := json.RawMessage(`{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":""}}`)
	if _, ok, _ := mapSessionUpdate("sess-1", update, dshMeta(map[string]string{
		DshChunkMetaKey: `{"kind":"text-delta","turn":1,"step":1,"seq":1}`,
	})); ok {
		t.Fatal("空 delta 应被丢弃")
	}
}

// TestMapCommittedMetaToEventMessageCompleted 覆盖 committed 帧：权威全文 + 同身份
// + provider_message_id/interrupted 标记（客户端据此整体替换，而不是追加）。
func TestMapCommittedMetaToEventMessageCompleted(t *testing.T) {
	update := json.RawMessage(`{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"全文"}}`)
	event, ok, _ := mapSessionUpdate("sess-1", update, dshMeta(map[string]string{
		DshChunkMetaKey: `{"kind":"committed","turn":3,"step":1,"messageId":"msg-9","interrupted":true}`,
	}))
	if !ok || event.Type != adapter.EventMessageCompleted {
		t.Fatalf("event = %+v ok=%v", event, ok)
	}
	if event.Payload["message_id"] != "t3s1" || event.Payload["text"] != "全文" {
		t.Fatalf("payload = %+v", event.Payload)
	}
	if event.Payload["provider_message_id"] != "msg-9" || event.Payload["interrupted"] != true {
		t.Fatalf("payload = %+v", event.Payload)
	}
}

// TestMapLegacyChunkWithoutMetaStaysCompleted 覆盖回滚开关：无 _meta 的旧帧
// 保持 v0.8.3 语义（完整消息 → message_completed）。
func TestMapLegacyChunkWithoutMetaStaysCompleted(t *testing.T) {
	update := json.RawMessage(`{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"旧桥全文"}}`)
	event, ok, _ := mapSessionUpdate("sess-1", update, nil)
	if !ok || event.Type != adapter.EventMessageCompleted || event.Payload["text"] != "旧桥全文" {
		t.Fatalf("legacy event = %+v ok=%v", event, ok)
	}
	// 形状非法的 meta 同样回退旧语义。
	if event, ok, _ := mapSessionUpdate("sess-1", update, dshMeta(map[string]string{
		DshChunkMetaKey: `{"kind":"weird","turn":1}`,
	})); !ok || event.Type != adapter.EventMessageCompleted {
		t.Fatalf("malformed meta event = %+v ok=%v", event, ok)
	}
}

// TestMapThoughtChunkToEventThoughtDelta 覆盖 thought 通道：raw 逐块与 summary
// 摘要帧都映射为 EventThoughtDelta；无 meta/非法 visibility 丢弃计数。
func TestMapThoughtChunkToEventThoughtDelta(t *testing.T) {
	update := json.RawMessage(`{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"推理片段"}}`)
	event, ok, _ := mapSessionUpdate("sess-1", update, dshMeta(map[string]string{
		DshThoughtMetaKey: `{"kind":"thought-delta","turn":1,"step":1,"seq":1,"visibility":"raw"}`,
	}))
	if !ok || event.Type != adapter.EventThoughtDelta {
		t.Fatalf("event = %+v ok=%v", event, ok)
	}
	if event.Payload["text"] != "推理片段" || event.Payload["visibility"] != "raw" ||
		event.Payload["message_id"] != "t1s1" {
		t.Fatalf("payload = %+v", event.Payload)
	}

	summary, ok, _ := mapSessionUpdate("sess-1", update, dshMeta(map[string]string{
		DshThoughtMetaKey: `{"kind":"thought-summary","turn":1,"step":1,"visibility":"summary"}`,
	}))
	if !ok || summary.Payload["summary"] != true || summary.Payload["visibility"] != "summary" {
		t.Fatalf("summary payload = %+v ok=%v", summary.Payload, ok)
	}

	// 无 meta（旧桥/未协商）：丢弃计数，thought 不进任何通道。
	if _, ok, _ := mapSessionUpdate("sess-1", update, nil); ok {
		t.Fatal("无 meta 的 thought 帧应被丢弃")
	}
	// visibility 非白名单：丢弃。
	if _, ok, _ := mapSessionUpdate("sess-1", update, dshMeta(map[string]string{
		DshThoughtMetaKey: `{"kind":"thought-delta","turn":1,"step":1,"seq":1,"visibility":"public"}`,
	})); ok {
		t.Fatal("非法 visibility 的 thought 帧应被丢弃")
	}
}
