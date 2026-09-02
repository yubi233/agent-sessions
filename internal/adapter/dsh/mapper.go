package dsh

import (
	"encoding/json"

	"github.com/yubi233/agent-sessions/internal/adapter"
)

// updateBody 是 session/update 通知中 update 字段的白名单投影：
// 只解析映射 canonical 事件所需的字段，桥私有 metadata 一律不进公共协议。
// tool_call / tool_call_update 变体所需的工具帧字段（toolCallId/status/kind/title/
// rawInput/content）也在此声明；解析失败的字段留空，由各变体校验丢弃。
type updateBody struct {
	SessionUpdate string          `json:"sessionUpdate"`
	Content       json.RawMessage `json:"content"`
	MessageID     string          `json:"messageId"`
	Usage         json.RawMessage `json:"usage"`
	ContextWindow int64           `json:"contextWindow"`
	// 工具帧字段（tools.ts acpToolCallFrameFor / acpToolResultFrameFor 投影）。
	ToolCallID string          `json:"toolCallId"`
	Status     string          `json:"status"`
	Kind       string          `json:"kind"`
	Title      string          `json:"title"`
	RawInput   json.RawMessage `json:"rawInput"`
}

type usageUpdate struct {
	InputTokens      int64 `json:"inputTokens"`
	OutputTokens     int64 `json:"outputTokens"`
	CacheReadTokens  int64 `json:"cacheReadTokens"`
	CacheWriteTokens int64 `json:"cacheWriteTokens"`
}

// contentBlock 是 ACP content 块的最小投影（目前只消费 text 块）。
type contentBlock struct {
	Type string `json:"type"`
	Text string `json:"text"`
}

// mapSessionUpdate 把 session/update 的 update 字段映射为 canonical 事件（纯函数，可单测）。
// 白名单只放行桥承诺面内的变体；当前桥（acp-demo index.ts）在 session/load
// 回放时提交 user_message_chunk，在助手历史/实时输出时提交 agent_message_chunk。
// agent_message_chunk 在桥侧已等待 assistant/message 的完整 content block 落地，
// 因此映射为 message_completed，而不是原始 token delta；用户回放映射为 user_message。
//
// 工具事件映射（v0.8.2 B 类 #1）：
//   - tool_call        → EventToolCall：携带 tool_call_id/kind/title/raw_input/status；
//     rawInput 只在合法 JSON 时透传（桥已保证畸形输入省略，这里兜底校验）。
//   - tool_call_update → EventToolResult：携带 tool_call_id/status/output_text（两层解包）。
//
// 仍丢弃并计数（ok=false）的变体：agent_thought_chunk/plan/plan_update 等未知变体，
// 以及畸形工具帧（缺 tool_call_id、孤儿 update、非法 JSON、缺结果文本）。
// usage_update 是桥为 usage 投影提供的受控扩展，不携带正文。
// 返回的第三个值是变体名（含解析失败时的占位），供调用方按变体计数。
func mapSessionUpdate(sessionID string, update json.RawMessage) (adapter.Event, bool, string) {
	var body updateBody
	if err := json.Unmarshal(update, &body); err != nil {
		return adapter.Event{}, false, "<malformed>"
	}
	variant := body.SessionUpdate
	switch variant {
	case "usage_update":
		return mapUsageUpdate(sessionID, body)
	case "tool_call":
		return mapToolCall(sessionID, body)
	case "tool_call_update":
		return mapToolCallUpdate(sessionID, body)
	}
	if variant != "agent_message_chunk" && variant != "user_message_chunk" {
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
	eventType := adapter.EventMessageCompleted
	if variant == "user_message_chunk" {
		eventType = adapter.EventUserMessage
	}
	return adapter.Event{
		Type:    eventType,
		Payload: payload,
	}, true, variant
}

// mapUsageUpdate 映射 usage_update 受控扩展（纯函数分离便于单测与后续扩展）。
func mapUsageUpdate(sessionID string, body updateBody) (adapter.Event, bool, string) {
	variant := "usage_update"
	var usage usageUpdate
	if err := json.Unmarshal(body.Usage, &usage); err != nil {
		return adapter.Event{}, false, variant
	}
	if usage.InputTokens < 0 || usage.OutputTokens < 0 ||
		usage.CacheReadTokens < 0 || usage.CacheWriteTokens < 0 ||
		(usage.InputTokens == 0 && usage.OutputTokens == 0 &&
			usage.CacheReadTokens == 0 && usage.CacheWriteTokens == 0) {
		return adapter.Event{}, false, variant
	}
	payload := map[string]any{
		"instance_id":        sessionID,
		"input_tokens":       usage.InputTokens,
		"output_tokens":      usage.OutputTokens,
		"cache_read_tokens":  usage.CacheReadTokens,
		"cache_write_tokens": usage.CacheWriteTokens,
	}
	if body.ContextWindow > 0 {
		payload["context_window_tokens"] = body.ContextWindow
	}
	return adapter.Event{Type: adapter.EventUsage, Payload: payload}, true, variant
}

// mapToolCall 映射 tool_call 打开帧（桥投影恒为 in_progress 状态）。
// 载荷白名单只放行 instance_id/tool_call_id/kind/title/raw_input/status；
// tool_call_id 缺失视为畸形帧丢弃（无法与关闭帧配对）。
func mapToolCall(sessionID string, body updateBody) (adapter.Event, bool, string) {
	variant := "tool_call"
	if body.ToolCallID == "" {
		// 缺少 tool_call_id 的打开帧无法与关闭帧配对，丢弃并计数。
		return adapter.Event{}, false, variant
	}
	payload := map[string]any{
		"instance_id":    sessionID,
		"tool_call_id":   body.ToolCallID,
		"status":         body.Status,
		"tool_call_kind": body.Kind,
	}
	if body.Title != "" {
		payload["title"] = body.Title
	}
	if len(body.RawInput) > 0 && json.Valid(body.RawInput) {
		// rawInput 是结构化 JSON；桥保证畸形输入省略。这里兜底只透传合法 JSON，
		// 避免把畸形或超限输入带进公共事件。
		var raw any
		if err := json.Unmarshal(body.RawInput, &raw); err == nil {
			payload["raw_input"] = raw
		}
	}
	return adapter.Event{Type: adapter.EventToolCall, Payload: payload}, true, variant
}

// mapToolCallUpdate 映射 tool_call_update 关闭帧（completed/failed）。
// 载荷只放行 instance_id/tool_call_id/status/output_text；缺 tool_call_id 视为畸形丢弃。
func mapToolCallUpdate(sessionID string, body updateBody) (adapter.Event, bool, string) {
	variant := "tool_call_update"
	if body.ToolCallID == "" {
		// 孤儿关闭帧（无对应打开帧 id）无法归属，丢弃并计数。
		return adapter.Event{}, false, variant
	}
	payload := map[string]any{
		"instance_id":  sessionID,
		"tool_call_id": body.ToolCallID,
		"status":       body.Status,
	}
	// 结果文本：桥把文本放在 content 数组（[{type:"content",content:{type:"text",text}}]）。
	// 两层解包并保留 ≤2000 字符的桥截断语义；形状不符不产生伪造正文。
	if len(body.Content) > 0 {
		var arr []json.RawMessage
		if err := json.Unmarshal(body.Content, &arr); err == nil && len(arr) > 0 {
			var outer struct {
				Content *struct {
					Type string `json:"type"`
					Text string `json:"text"`
				} `json:"content"`
			}
			if err := json.Unmarshal(arr[0], &outer); err == nil && outer.Content != nil &&
				outer.Content.Type == "text" && outer.Content.Text != "" {
				payload["output_text"] = outer.Content.Text
			}
		}
	}
	return adapter.Event{Type: adapter.EventToolResult, Payload: payload}, true, variant
}
