package daemon

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/yubi233/agent-sessions/internal/adapter"
)

func localDevEvent(t *testing.T, eventType adapter.EventType, payload map[string]any) string {
	t.Helper()
	encoder := NewLocalDevEventEncoder()
	envelope, err := encoder.Encode("sess-1", adapter.Event{Type: eventType, Seq: 1, Payload: payload})
	if err != nil {
		t.Fatalf("encode %s: %v", eventType, err)
	}
	return envelope
}

// 本地开发编码器只把可展示事件映射为 fixture 时间线词汇；遥测与流式增量不进入时间线。
func TestLocalDevEventEncoderMapsWhitelistedEvents(t *testing.T) {
	user := localDevEvent(t, adapter.EventUserMessage, map[string]any{
		"instance_id": "ses-x", "text": "请计算 1+1。",
	})
	if !strings.Contains(user, `"kind":"user_message"`) || !strings.Contains(user, "请计算 1+1。") {
		t.Fatalf("user fixture = %s", user)
	}

	completed := localDevEvent(t, adapter.EventMessageCompleted, map[string]any{
		"instance_id": "ses-x", "text": "1+1等于2。",
	})
	var payload map[string]any
	if err := json.Unmarshal([]byte(completed), &payload); err != nil {
		t.Fatalf("envelope not json: %v", err)
	}
	// Relay 的 normalizeDaemonCipherEnvelope 要求六个协议字段齐全；缺失会被 400 拒收。
	for _, key := range []string{"alg", "key_id", "nonce", "ciphertext", "aad_hash", "payload_version"} {
		if _, ok := payload[key]; !ok {
			t.Fatalf("envelope missing protocol field %q: %v", key, payload)
		}
	}
	if payload["alg"] != "local-dev-fixture" {
		t.Fatalf("envelope must carry honest local-dev marker, alg = %v", payload["alg"])
	}
	fixture, ok := payload["fixture_payload"].(map[string]any)
	if !ok {
		t.Fatalf("envelope missing fixture_payload: %v", payload)
	}
	if fixture["kind"] != "assistant_message" || fixture["text"] != "1+1等于2。" || fixture["streaming"] != false {
		t.Fatalf("assistant fixture = %v", fixture)
	}
	if fixture["copy_text"] != "1+1等于2。" {
		t.Fatalf("copy_text = %v", fixture["copy_text"])
	}

	toolRunning := localDevEvent(t, adapter.EventToolCall, map[string]any{
		"tool_name": "read", "input": `{"path":"a.go"}`,
	})
	if !strings.Contains(toolRunning, `"tool_status":"运行中"`) || !strings.Contains(toolRunning, `"label":"read"`) {
		t.Fatalf("tool call fixture = %s", toolRunning)
	}
	toolDone := localDevEvent(t, adapter.EventToolResult, map[string]any{
		"tool_name": "read", "output": "ok", "state": "completed",
	})
	if !strings.Contains(toolDone, `"tool_status":"已完成"`) || !strings.Contains(toolDone, `"tool_output":"ok"`) {
		t.Fatalf("tool result fixture = %s", toolDone)
	}
	toolAborted := localDevEvent(t, adapter.EventToolResult, map[string]any{
		"tool_name": "read", "output": "", "state": "aborted",
	})
	if !strings.Contains(toolAborted, `"tool_status":"已中断"`) {
		t.Fatalf("tool aborted fixture = %s", toolAborted)
	}
	sessionErr := localDevEvent(t, adapter.EventSessionError, map[string]any{
		"message": "provider 超时",
	})
	if !strings.Contains(sessionErr, `"kind":"system_notice"`) || !strings.Contains(sessionErr, "provider 超时") {
		t.Fatalf("session error fixture = %s", sessionErr)
	}
}

// (V083-10) user_question → question_request 词汇映射：request_id 关联 + questions
// 数组透传（intent/detail 完整保留）；缺 request_id 不产生事件。
func TestLocalDevEventEncoderMapsUserQuestion(t *testing.T) {
	question := localDevEvent(t, adapter.EventUserQuestion, map[string]any{
		"instance_id": "ses-x",
		"request_id":  "q-1",
		"questions": []any{map[string]any{
			"id": "p1", "title": "审核计划", "type": "single-select",
			"options": []any{"Approve", "Keep planning"},
			"intent":  map[string]any{"kind": "plan-review", "approve": "Approve"},
			"detailMarkdown": "# 计划",
		}},
	})
	var payload map[string]any
	if err := json.Unmarshal([]byte(question), &payload); err != nil {
		t.Fatalf("envelope not json: %v", err)
	}
	fixture, ok := payload["fixture_payload"].(map[string]any)
	if !ok {
		t.Fatalf("envelope missing fixture_payload: %v", payload)
	}
	if fixture["kind"] != "question_request" || fixture["request_id"] != "q-1" {
		t.Fatalf("question fixture = %v", fixture)
	}
	questions, ok := fixture["questions"].([]any)
	if !ok || len(questions) != 1 {
		t.Fatalf("questions 数组应透传: %v", fixture)
	}
	first, _ := questions[0].(map[string]any)
	intent, _ := first["intent"].(map[string]any)
	if first["id"] != "p1" || intent["kind"] != "plan-review" || intent["approve"] != "Approve" {
		t.Fatalf("question intent/detail 应完整保留: %v", first)
	}
	if _, hasDetail := first["detailMarkdown"]; !hasDetail {
		t.Fatalf("detail 不得静默丢失: %v", first)
	}
	// 缺 request_id：不产生事件（返回空 envelope）。
	encoder := NewLocalDevEventEncoder()
	empty, err := encoder.Encode("ses-x", adapter.Event{
		Type:    adapter.EventUserQuestion,
		Payload: map[string]any{"instance_id": "ses-x"},
	})
	if err != nil || empty != "" {
		t.Fatalf("缺 request_id 应返回空 envelope: %q, %v", empty, err)
	}
}

func TestLocalDevEventEncoderSkipsNoiseEvents(t *testing.T) {
	for _, eventType := range []adapter.EventType{
		adapter.EventTurnStarted, adapter.EventUsage,
	} {
		envelope := localDevEvent(t, eventType, map[string]any{"text": "x"})
		if envelope != "" {
			t.Fatalf("%s must be skipped, got %s", eventType, envelope)
		}
	}
	// message_delta 已改为流式映射（见 TestLocalDevEventEncoderStreamsDeltaAccumulation），
	// 空白增量仍不产出时间线事件。
	{
		encoder := NewLocalDevEventEncoder()
		envelope, err := encoder.Encode("sess-1", adapter.Event{
			Type: adapter.EventMessageDelta, Seq: 1,
			Payload: map[string]any{"text": "  ", "message_id": "msg-1"},
		})
		if err != nil || envelope != "" {
			t.Fatalf("blank delta must be skipped, got %q err=%v", envelope, err)
		}
	}
	completed := localDevEvent(t, adapter.EventMessageCompleted, map[string]any{"text": "   "})
	if completed != "" {
		t.Fatalf("blank text must be skipped, got %s", completed)
	}

	turnDone := localDevEvent(t, adapter.EventTurnCompleted, map[string]any{
		"instance_id": "ses-x", "stop_reason": "end_turn",
	})
	var turnFixture struct {
		FixturePayload map[string]any `json:"fixture_payload"`
	}
	if err := json.Unmarshal([]byte(turnDone), &turnFixture); err != nil {
		t.Fatalf("turn.completed envelope not json: %v", err)
	}
	if turnFixture.FixturePayload["completed_turn"] != true ||
		turnFixture.FixturePayload["kind"] != "assistant_message" {
		t.Fatalf("turn.completed fixture = %v", turnFixture.FixturePayload)
	}
}

func TestLocalDevEventEncoderRejectsMissingSessionID(t *testing.T) {
	encoder := NewLocalDevEventEncoder()
	if _, err := encoder.Encode("  ", adapter.Event{Type: adapter.EventMessageCompleted, Seq: 1}); err == nil {
		t.Fatal("missing session id must fail")
	}
}

// message_delta 按会话+消息累积并回发 streaming 全量文本；message_completed 以
// 权威全文替换并清账；turn_completed 清理会话剩余缓冲。客户端据此渲染单一
// 逐字生长的助手气泡，而不是逐 delta 堆叠节点。
func TestLocalDevEventEncoderStreamsDeltaAccumulation(t *testing.T) {
	encoder := NewLocalDevEventEncoder()
	encode := func(eventType adapter.EventType, payload map[string]any) map[string]any {
		t.Helper()
		envelope, err := encoder.Encode("sess-1", adapter.Event{Type: eventType, Seq: 1, Payload: payload})
		if err != nil {
			t.Fatalf("encode %s: %v", eventType, err)
		}
		if envelope == "" {
			t.Fatalf("encode %s: empty envelope", eventType)
		}
		var payloadOut struct {
			FixturePayload map[string]any `json:"fixture_payload"`
		}
		if err := json.Unmarshal([]byte(envelope), &payloadOut); err != nil {
			t.Fatalf("envelope not json: %v", err)
		}
		return payloadOut.FixturePayload
	}

	first := encode(adapter.EventMessageDelta, map[string]any{"text": "1+", "message_id": "m1"})
	if first["streaming"] != true || first["text"] != "1+" {
		t.Fatalf("first delta fixture = %v", first)
	}
	second := encode(adapter.EventMessageDelta, map[string]any{"text": "1=2", "message_id": "m1"})
	if second["streaming"] != true || second["text"] != "1+1=2" {
		t.Fatalf("second delta fixture = %v", second)
	}
	// 另一条 assistant 消息的缓冲相互隔离。
	other := encode(adapter.EventMessageDelta, map[string]any{"text": "other", "message_id": "m2"})
	if other["text"] != "other" {
		t.Fatalf("isolated message fixture = %v", other)
	}
	completed := encode(adapter.EventMessageCompleted, map[string]any{"text": "1+1=2。", "message_id": "m1"})
	if completed["streaming"] != false || completed["text"] != "1+1=2。" {
		t.Fatalf("completed fixture = %v", completed)
	}
	turnDone := encode(adapter.EventTurnCompleted, map[string]any{"instance_id": "sess-1"})
	if turnDone["completed_turn"] != true {
		t.Fatalf("turn fixture = %v", turnDone)
	}
}

// v0.8.2 P2（G1）：DSH mapper 的工具事件载荷（title/raw_input/tool_call_id/output_text/
// status=failed）也必须投影为移动端 tool_activity 时间线词汇，与 opencode 风格同构。
func TestLocalDevEventEncoderMapsDSHToolPayloads(t *testing.T) {
	// tool_call：DSH 风格 title + raw_input(对象) + tool_call_id。
	call := localDevEvent(t, adapter.EventToolCall, map[string]any{
		"instance_id":    "sess-1",
		"tool_call_id":   "call-dsh-1",
		"tool_call_kind": "execute",
		"title":          "bash: ls -la",
		"raw_input":      map[string]any{"command": "ls -la"},
		"status":         "in_progress",
	})
	for _, want := range []string{
		`"kind":"tool_activity"`,
		`"label":"bash: ls -la"`,
		`"tool_status":"运行中"`,
		// raw_input(对象) 序列化为单行 JSON 字符串（tool_input 是字符串字段）。
		`"tool_input":"{\"command\":\"ls -la\"}"`,
		`"inspect_target":"call-dsh-1"`,
	} {
		if !strings.Contains(call, want) {
			t.Fatalf("DSH tool_call fixture 缺少 %s: %s", want, call)
		}
	}
	// tool_result：output_text + status=failed → 已中断；completed → 已完成。
	done := localDevEvent(t, adapter.EventToolResult, map[string]any{
		"instance_id":  "sess-1",
		"tool_call_id": "call-dsh-1",
		"output_text":  "done",
		"status":       "completed",
	})
	if !strings.Contains(done, `"tool_status":"已完成"`) || !strings.Contains(done, `"tool_output":"done"`) {
		t.Fatalf("DSH tool_result(completed) fixture = %s", done)
	}
	failed := localDevEvent(t, adapter.EventToolResult, map[string]any{
		"instance_id":  "sess-1",
		"tool_call_id": "call-dsh-1",
		"status":       "failed",
	})
	if !strings.Contains(failed, `"tool_status":"已中断"`) {
		t.Fatalf("DSH tool_result(failed) fixture = %s", failed)
	}
}
