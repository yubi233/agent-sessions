package dsh

import (
	"encoding/json"
	"strconv"

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

// dshChunkMeta 是 v0.8.4 流式增量/committed 帧的 namespaced _meta 身份
// （ADR-015 §4；桥侧 com.deepseek.dsh/chunk）。缺失时该帧按 v0.8.3 旧语义
// 处理（完整消息 → message_completed），构成回滚开关的 Go 侧落点。
type dshChunkMeta struct {
	Kind        string `json:"kind"` // text-delta | committed
	Turn        int64  `json:"turn"`
	Step        int64  `json:"step"`
	Seq         int64  `json:"seq"`
	MessageID   string `json:"messageId"`
	Interrupted bool   `json:"interrupted"`
}

// dshThoughtMeta 是 thought 帧的 namespaced _meta（ADR-015 §5；桥侧
// com.deepseek.dsh/thought）。kind 为 thought-delta（raw 逐块）或
// thought-summary（summary 模式的回合级折叠摘要帧）。
type dshThoughtMeta struct {
	Kind       string `json:"kind"`
	Turn       int64  `json:"turn"`
	Step       int64  `json:"step"`
	Seq        int64  `json:"seq"`
	Visibility string `json:"visibility"`
}

// dshTurnStepIdentity 是桥侧 turn/step 推导的稳定消息身份（ADR-015 §4）：
// 增量与 committed 帧使用同一身份，客户端据此以 completed 整体替换临时文本。
func dshTurnStepIdentity(turn, step int64) string {
	return "t" + strconv.FormatInt(turn, 10) + "s" + strconv.FormatInt(step, 10)
}

// parseDshChunkMeta 解析并校验 chunk 身份 meta：kind 必须在冻结集合内，
// turn/step/seq 必须非负；形状非法返回 nil（调用方按旧语义回退）。
func parseDshChunkMeta(raw json.RawMessage) *dshChunkMeta {
	if len(raw) == 0 {
		return nil
	}
	var meta dshChunkMeta
	if err := json.Unmarshal(raw, &meta); err != nil {
		return nil
	}
	if meta.Kind != "text-delta" && meta.Kind != "committed" {
		return nil
	}
	if meta.Turn < 0 || meta.Step < 0 || meta.Seq < 0 {
		return nil
	}
	return &meta
}

// parseDshThoughtMeta 解析并校验 thought 身份 meta；visibility 只接受 raw/summary
// （hidden 模式桥不发送内容帧）；形状非法返回 nil（调用方丢弃计数）。
func parseDshThoughtMeta(raw json.RawMessage) *dshThoughtMeta {
	if len(raw) == 0 {
		return nil
	}
	var meta dshThoughtMeta
	if err := json.Unmarshal(raw, &meta); err != nil {
		return nil
	}
	if meta.Kind != "thought-delta" && meta.Kind != "thought-summary" {
		return nil
	}
	if meta.Visibility != "raw" && meta.Visibility != "summary" {
		return nil
	}
	if meta.Turn < 0 || meta.Step < 0 || meta.Seq < 0 {
		return nil
	}
	return &meta
}

// mapSessionUpdate 把 session/update 的 update 字段映射为 canonical 事件（纯函数，可单测）。
// 白名单只放行桥承诺面内的变体。v0.8.4（ADR-015）起 agent_message_chunk 按帧身份分流：
//   - _meta kind=text-delta  → EventMessageDelta（逐块增量，身份 t<turn>s<step>）；
//   - _meta kind=committed   → EventMessageCompleted（权威全文，客户端整体替换同身份）；
//   - 无 _meta（旧桥/回滚路径）→ EventMessageCompleted（v0.8.3 语义不变）。
//
// agent_thought_chunk 只在带合法 thought _meta 时映射为 EventThoughtDelta
// （独立 thought 通道，绝不并入 assistant answer）；否则丢弃计数（旧桥行为）。
//
// 工具事件映射（v0.8.2 B 类 #1）：
//   - tool_call        → EventToolCall：携带 tool_call_id/kind/title/raw_input/status；
//     rawInput 只在合法 JSON 时透传（桥已保证畸形输入省略，这里兜底校验）。
//   - tool_call_update → EventToolResult：携带 tool_call_id/status/output_text（两层解包）。
//
// 仍丢弃并计数（ok=false）的变体：无 meta 的 agent_thought_chunk/plan/plan_update
// 等未知变体，以及畸形工具帧（缺 tool_call_id、孤儿 update、非法 JSON、缺结果文本）。
// usage_update 自 SDK 0.25.1 起为标准变体（used/size 折算上下文窗口），
// 桥同时兼容携带旧 usage/contextWindow 字段（superset），mapper 只读旧字段。
// 返回的第三个值是变体名（含解析失败时的占位），供调用方按变体计数。
// meta 是 session/update 通知参数级 _meta（键：DshChunkMetaKey/DshThoughtMetaKey）。
func mapSessionUpdate(sessionID string, update json.RawMessage, meta map[string]json.RawMessage) (adapter.Event, bool, string) {
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
	case "agent_thought_chunk":
		return mapThoughtChunk(sessionID, body, meta[DshThoughtMetaKey])
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
	if variant == "user_message_chunk" {
		// 用户回放仍是完整消息（ADR-015 §4：replay 不做增量）。
		payload := map[string]any{
			"instance_id": sessionID,
			"text":        block.Text,
		}
		if body.MessageID != "" {
			payload["message_id"] = body.MessageID
		}
		return adapter.Event{Type: adapter.EventUserMessage, Payload: payload}, true, variant
	}
	// v0.8.4 流式分流：有身份 meta 的帧按 kind 投影，缺失时保持旧 completed 语义。
	if chunkMeta := parseDshChunkMeta(meta[DshChunkMetaKey]); chunkMeta != nil {
		identity := dshTurnStepIdentity(chunkMeta.Turn, chunkMeta.Step)
		if chunkMeta.Kind == "text-delta" {
			if block.Text == "" {
				// 空 delta 不进公共协议（丢弃计数，避免客户端累加无意义帧）。
				return adapter.Event{}, false, variant
			}
			return adapter.Event{
				Type: adapter.EventMessageDelta,
				Payload: map[string]any{
					"instance_id": sessionID,
					"message_id":  identity,
					"text":        block.Text,
				},
			}, true, variant
		}
		// committed：权威全文替换同身份；中断时保留前缀并标记 interrupted。
		payload := map[string]any{
			"instance_id": sessionID,
			"message_id":  identity,
			"text":        block.Text,
		}
		if chunkMeta.MessageID != "" {
			payload["provider_message_id"] = chunkMeta.MessageID
		}
		if chunkMeta.Interrupted {
			payload["interrupted"] = true
		}
		return adapter.Event{Type: adapter.EventMessageCompleted, Payload: payload}, true, variant
	}
	payload := map[string]any{
		"instance_id": sessionID,
		"text":        block.Text,
	}
	if body.MessageID != "" {
		payload["message_id"] = body.MessageID
	}
	return adapter.Event{Type: adapter.EventMessageCompleted, Payload: payload}, true, variant
}

// mapThoughtChunk 把带合法 _meta 的 agent_thought_chunk 映射为 EventThoughtDelta
// （ADR-015 §5：raw 逐块 / summary 折叠摘要）。无 meta 或形状非法时丢弃计数——
// 未协商 thought 通道的旧桥帧不产生事件，thought 与 answer 的分离在映射层兜底。
func mapThoughtChunk(sessionID string, body updateBody, rawMeta json.RawMessage) (adapter.Event, bool, string) {
	variant := "agent_thought_chunk"
	thoughtMeta := parseDshThoughtMeta(rawMeta)
	if thoughtMeta == nil {
		return adapter.Event{}, false, variant
	}
	var block contentBlock
	if err := json.Unmarshal(body.Content, &block); err != nil || block.Type != "text" || block.Text == "" {
		return adapter.Event{}, false, variant
	}
	payload := map[string]any{
		"instance_id": sessionID,
		"message_id":  dshTurnStepIdentity(thoughtMeta.Turn, thoughtMeta.Step),
		"text":        block.Text,
		"visibility":  thoughtMeta.Visibility,
	}
	if thoughtMeta.Kind == "thought-summary" {
		payload["summary"] = true
	}
	return adapter.Event{Type: adapter.EventThoughtDelta, Payload: payload}, true, variant
}

// mapUsageUpdate 映射 usage_update（纯函数分离便于单测与后续扩展）。
// 只解析旧 usage/contextWindow 字段；标准 used/size 与 _meta 不进本映射。
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
