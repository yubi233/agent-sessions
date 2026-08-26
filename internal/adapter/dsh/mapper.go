package dsh

import (
	"encoding/json"

	"github.com/yubi233/agent-sessions/internal/adapter"
)

// updateBody 是 session/update 通知中 update 字段的白名单投影：
// 只解析映射 canonical 事件所需的字段，桥私有 metadata 一律不进公共协议。
type updateBody struct {
	SessionUpdate string          `json:"sessionUpdate"`
	Content       json.RawMessage `json:"content"`
	MessageID     string          `json:"messageId"`
}

// contentBlock 是 ACP content 块的最小投影（目前只消费 text 块）。
type contentBlock struct {
	Type string `json:"type"`
	Text string `json:"text"`
}

// mapSessionUpdate 把 session/update 的 update 字段映射为 canonical 事件（纯函数，可单测）。
// 白名单只放行桥承诺面内的变体；当前桥（acp-demo index.ts）只提交
// agent_message_chunk。该帧在桥侧已等待 assistant/message 的完整 content block
// 落地后才发送，因此映射为 message_completed，而不是原始 token delta；这样本地
// 开发编码器与生产时间线都只消费完整助手文本。
// 其余变体（user_message_chunk/agent_thought_chunk/tool_call/tool_call_update/
// plan/plan_update/usage_update 等）与未知变体一律 ok=false，由调用方丢弃并计数，
// 不报错——这与能力矩阵中这些能力的 unsupported 承诺一致。
// 返回的第三个值是变体名（含解析失败时的占位），供调用方按变体计数。
func mapSessionUpdate(sessionID string, update json.RawMessage) (adapter.Event, bool, string) {
	var body updateBody
	if err := json.Unmarshal(update, &body); err != nil {
		return adapter.Event{}, false, "<malformed>"
	}
	variant := body.SessionUpdate
	if variant != "agent_message_chunk" {
		// 白名单外/未知变体：丢弃并计数，不产生事件。
		return adapter.Event{}, false, variant
	}
	var block contentBlock
	if err := json.Unmarshal(body.Content, &block); err != nil {
		return adapter.Event{}, false, variant
	}
	if block.Type != "text" {
		// 非文本块（image 等）无 canonical 对应，同样丢弃并计数。
		return adapter.Event{}, false, variant
	}
	payload := map[string]any{
		"instance_id": sessionID,
		"text":        block.Text,
	}
	if body.MessageID != "" {
		payload["message_id"] = body.MessageID
	}
	return adapter.Event{
		Type:    adapter.EventMessageCompleted,
		Payload: payload,
	}, true, variant
}
