package dsh

import (
	"encoding/json"
	"testing"

	"github.com/yubi233/agent-sessions/internal/adapter"
)

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
