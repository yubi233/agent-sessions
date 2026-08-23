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

func TestLocalDevEventEncoderSkipsNoiseEvents(t *testing.T) {
	for _, eventType := range []adapter.EventType{
		adapter.EventMessageDelta, adapter.EventTurnStarted, adapter.EventUsage,
	} {
		envelope := localDevEvent(t, eventType, map[string]any{"text": "x"})
		if envelope != "" {
			t.Fatalf("%s must be skipped, got %s", eventType, envelope)
		}
	}
	completed := localDevEvent(t, adapter.EventMessageCompleted, map[string]any{"text": "   "})
	if completed != "" {
		t.Fatalf("blank text must be skipped, got %s", completed)
	}
}

func TestLocalDevEventEncoderRejectsMissingSessionID(t *testing.T) {
	encoder := NewLocalDevEventEncoder()
	if _, err := encoder.Encode("  ", adapter.Event{Type: adapter.EventMessageCompleted, Seq: 1}); err == nil {
		t.Fatal("missing session id must fail")
	}
}
