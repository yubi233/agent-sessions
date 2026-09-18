package daemon

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"

	"github.com/yubi233/agent-sessions/internal/adapter"
	contentcrypto "github.com/yubi233/agent-sessions/packages/crypto"
)

// V094-28（P0 隔离冻结）：生产事件编码器的加密 payload 形状必须冻结。
// snapshot DTO 层新增的 command_id 关联投影属于传输层事实，
// 绝不允许进入 canonical event 加密载荷（eventEnvelopePayload），
// 也不允许改变 AAD/envelope 契约。该测试保证 UI 关联改造与生产加密边界隔离。
func TestV094EventEnvelopePayloadShapeFrozen(t *testing.T) {
	dek := testEventDEK()
	encoder, err := NewE2EEEventEncoder(dek, "event-key-2026-08")
	if err != nil {
		t.Fatal(err)
	}
	defer encoder.Destroy()
	event := adapter.Event{
		Type: adapter.EventUserMessage,
		Seq:  3,
		Payload: map[string]any{
			"text":        "V094 隔离往返正文",
			"instance_id": "ses-v094",
		},
	}
	raw, err := encoder.Encode("sess-v094-isolation", event)
	if err != nil {
		t.Fatalf("encode: %v", err)
	}

	var envelope contentcrypto.Envelope
	if err := json.Unmarshal([]byte(raw), &envelope); err != nil {
		t.Fatalf("decode envelope: %v", err)
	}
	plaintext, err := contentcrypto.Open(dek, envelope, eventAAD("sess-v094-isolation", event))
	if err != nil {
		t.Fatalf("open with frozen AAD: %v", err)
	}
	// 冻结加密载荷顶层形状：只允许 version + event 两个键。
	var payload map[string]json.RawMessage
	if err := json.Unmarshal(plaintext, &payload); err != nil {
		t.Fatalf("decode payload: %v", err)
	}
	if len(payload) != 2 {
		t.Fatalf("eventEnvelopePayload 顶层键数=%d，want 2（version+event）: %v", len(payload), payload)
	}
	if _, ok := payload["version"]; !ok {
		t.Fatal("payload 缺少 version")
	}
	if _, ok := payload["event"]; !ok {
		t.Fatal("payload 缺少 event")
	}
	// 传输层关联字段不得渗入加密载荷。
	for _, forbidden := range []string{"command_id", "client_message_id", "submission_id"} {
		if bytes.Contains(plaintext, []byte(forbidden)) {
			t.Fatalf("加密载荷不允许出现传输层关联字段 %q", forbidden)
		}
	}

	// canonical event 完整往返。
	var decoded eventEnvelopePayload
	if err := json.Unmarshal(plaintext, &decoded); err != nil {
		t.Fatalf("decode eventEnvelopePayload: %v", err)
	}
	if decoded.Event.Type != event.Type || decoded.Event.Seq != event.Seq || decoded.Event.Payload["text"] != event.Payload["text"] {
		t.Fatalf("canonical event 往返不一致: %+v vs %+v", decoded.Event, event)
	}
}

// V094-28（P0 隔离冻结）：localdev fixture 编码器的 payload 白名单不携带
// 消息事务关联字段——命令/事件关联由 receipt（传输层）提供，
// fixture_payload 保持与生产语义对称的纯展示词汇，不为 UI 改造新增明文元数据。
func TestV094LocalDevEncoderPayloadExcludesAssociationFields(t *testing.T) {
	encoder := NewLocalDevEventEncoder()
	raw, err := encoder.Encode("sess-v094-localdev", adapter.Event{
		Type: adapter.EventUserMessage,
		Seq:  1,
		Payload: map[string]any{
			"instance_id": "ses-v094-localdev",
			"text":        "localdev 隔离检查",
			// 恶意/误用输入：即使 canonical payload 带上关联字段也不得透传。
			"command_id":        "cmd-should-not-leak",
			"client_message_id": "cmid-should-not-leak",
		},
	})
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	if raw == "" {
		t.Fatal("user message 必须进入 localdev 时间线")
	}
	if strings.Contains(raw, "cmd-should-not-leak") || strings.Contains(raw, "cmid-should-not-leak") {
		t.Fatalf("localdev fixture payload 泄漏关联字段: %s", raw)
	}
	// 正文白名单字段保持可用（客户端渲染不受影响）。
	if !strings.Contains(raw, "localdev 隔离检查") {
		t.Fatalf("localdev fixture 丢失用户正文: %s", raw)
	}
}
