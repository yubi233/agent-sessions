package daemon

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"strings"
	"sync"

	"github.com/yubi233/agent-sessions/internal/adapter"
)

// LocalDevPlaintextEnv 是 restart.sh 本地开发栈显式开启明文事件编码的开关。
// 它只允许在本地开发拓扑出现：与生产 E2EE 事件密钥互斥，同时配置会拒绝启动。
const LocalDevPlaintextEnv = "AGENT_SESSIONS_EVENT_LOCAL_DEV_PLAINTEXT"

// LocalDevEventEncoder 把 canonical Provider event 映射为客户端 fixture 时间线词汇
// （envelope.fixture_payload），供 restart.sh 本地开发栈在未部署 E2EE 密钥分发前看到
// 助手回复。它与命令链路既有的 fixture_payload 明文语义对称：
//
//   - 生产语义不变：未设置开关时 Daemon 继续扣留事件（fail-closed）；
//   - 只做 canonical payload → display-safe 字段的白名单映射，不透传任意字段；
//   - message_delta 不映射：客户端尚无流式合并，逐 delta 入时间线只会制造噪音；
//     本地开发以 message_completed 的完整文本为准。
//
// LocalDevEventEncoder 按 provider 事件顺序被调用，持有会话级流式缓冲：
// message_delta 追加并回发 streaming=true 的全量已收文本，message_completed
// 以权威全文替换，turn_completed 清账。缓冲只保留文本长度内的已收内容。
type LocalDevEventEncoder struct {
	mu      sync.Mutex
	streams map[string]string
}

// NewLocalDevEventEncoder 构造本地开发事件编码器。
func NewLocalDevEventEncoder() *LocalDevEventEncoder {
	return &LocalDevEventEncoder{streams: map[string]string{}}
}

// streamKey 以会话 + 消息 ID 隔离缓冲：同一回合可能有多条 assistant 消息。
func localDevStreamKey(sessionID, messageID string) string {
	return sessionID + "\x00" + messageID
}

// Encode 映射单条事件；返回空 envelope 且无错误表示该事件类型不进入账号时间线。
//
// 输出满足 Relay 的协议形状门（normalizeDaemonCipherEnvelope 要求 alg/key_id/nonce/
// ciphertext/aad_hash/payload_version 齐全），同时内嵌客户端可渲染的 fixture_payload。
// alg 固定为 "local-dev-fixture"，明确标记这是本地开发明文路径而非真实 E2EE。
func (e *LocalDevEventEncoder) Encode(sessionID string, event adapter.Event) (string, error) {
	if strings.TrimSpace(sessionID) == "" {
		return "", errors.New("canonical event 缺少 session ID")
	}
	payload, ok := e.localDevFixturePayload(sessionID, event)
	if !ok {
		return "", nil
	}
	inner, err := json.Marshal(map[string]any{"fixture_payload": payload})
	if err != nil {
		return "", err
	}
	envelope := map[string]any{
		"alg":             "local-dev-fixture",
		"key_id":          "local-dev",
		"nonce":           "local-dev",
		"ciphertext":      base64.StdEncoding.EncodeToString(inner),
		"aad_hash":        "local-dev",
		"payload_version": 1,
		"fixture_payload": payload,
	}
	raw, err := json.Marshal(envelope)
	if err != nil {
		return "", err
	}
	return string(raw), nil
}

// localDevFixturePayload 只复制白名单字段；tool input/output 沿用 adapter 层已有的截断。
// message_delta 按消息累积并回发 streaming 全量文本，让客户端在 message_completed
// 之前就能看到正在生长的回复；completed 以权威全文替换并清账该消息的缓冲。
func (e *LocalDevEventEncoder) localDevFixturePayload(sessionID string, event adapter.Event) (map[string]any, bool) {
	switch event.Type {
	case adapter.EventMessageDelta:
		chunk, _ := event.Payload["text"].(string)
		messageID, _ := event.Payload["message_id"].(string)
		key := localDevStreamKey(sessionID, messageID)
		e.mu.Lock()
		e.streams[key] = e.streams[key] + chunk
		text := e.streams[key]
		e.mu.Unlock()
		if strings.TrimSpace(text) == "" {
			return nil, false
		}
		return map[string]any{
			"kind":      "assistant_message",
			"label":     "Assistant",
			"text":      text,
			"streaming": true,
		}, true
	case adapter.EventMessageCompleted:
		text, _ := event.Payload["text"].(string)
		messageID, _ := event.Payload["message_id"].(string)
		e.mu.Lock()
		delete(e.streams, localDevStreamKey(sessionID, messageID))
		e.mu.Unlock()
		if strings.TrimSpace(text) == "" {
			return nil, false
		}
		return map[string]any{
			"kind":      "assistant_message",
			"label":     "Assistant",
			"text":      text,
			"streaming": false,
			"copy_text": text,
		}, true
	case adapter.EventTurnCompleted:
		e.mu.Lock()
		for key := range e.streams {
			if strings.HasPrefix(key, sessionID+"\x00") {
				delete(e.streams, key)
			}
		}
		e.mu.Unlock()
		// The marker is intentionally empty: the mobile projection consumes
		// completed_turn to stop generating without rendering a fake message.
		return map[string]any{
			"kind":           "assistant_message",
			"label":          "Assistant",
			"completed_turn": true,
		}, true
	case adapter.EventUserMessage:
		text, _ := event.Payload["text"].(string)
		if strings.TrimSpace(text) == "" {
			return nil, false
		}
		return map[string]any{
			"kind":      "user_message",
			"label":     "你",
			"text":      text,
			"streaming": false,
			"copy_text": text,
		}, true
	case adapter.EventToolCall:
		// 兼容两类 canonical 载荷：
		//   - opencode/codex 风格：tool_name/input（结构化字符串正文）；
		//   - DSH（v0.8.2 mapper）风格：title + raw_input(结构化 JSON) + tool_call_kind。
		// label 优先取 title（桥已生成单行展示标题），其次 tool_name。
		name := nonEmptyOr(event.Payload["title"], nonEmptyOr(event.Payload["tool_name"], "工具"))
		// raw_input 可能是 map（DSH）或字符串（其他 provider）：map 序列化为单行 JSON。
		var input string
		switch v := event.Payload["raw_input"].(type) {
		case string:
			input = v
		default:
			if v != nil {
				if raw, err := json.Marshal(v); err == nil {
					input = string(raw)
				}
			}
		}
		if input == "" {
			input, _ = event.Payload["input"].(string)
		}
		return map[string]any{
			"kind":           "tool_activity",
			"label":          name,
			"tool_status":    "运行中",
			"tool_input":     input,
			"inspect_target": nonEmptyOr(event.Payload["tool_call_id"], ""),
		}, true
	case adapter.EventToolResult:
		// DSH 结果载荷用 output_text/status(completed|failed)，opencode 风格用
		// tool_name/output/state；label 优先取 title/tool_name，保留 tool_call_id。
		name := nonEmptyOr(event.Payload["title"], nonEmptyOr(event.Payload["tool_name"], "工具"))
		output, _ := event.Payload["output"].(string)
		if output == "" {
			output, _ = event.Payload["output_text"].(string)
		}
		state, _ := event.Payload["state"].(string)
		if state == "" {
			state, _ = event.Payload["status"].(string)
		}
		status := "已完成"
		if state == "error" || state == "aborted" || state == "failed" {
			status = "已中断"
		}
		payload := map[string]any{
			"kind":        "tool_activity",
			"label":       name,
			"tool_status": status,
			"tool_output": output,
		}
		if toolCallID := nonEmptyOr(event.Payload["tool_call_id"], ""); toolCallID != "" {
			payload["inspect_target"] = toolCallID
		}
		return payload, true
	case adapter.EventSessionError:
		message, _ := event.Payload["message"].(string)
		if strings.TrimSpace(message) == "" {
			return nil, false
		}
		return map[string]any{
			"kind":  "system_notice",
			"label": "Provider 错误",
			"text":  message,
		}, true
	default:
		// turn_started/usage 等不进入本地开发时间线。
		return nil, false
	}
}

func nonEmptyOr(value any, fallback string) string {
	if text, ok := value.(string); ok && strings.TrimSpace(text) != "" {
		return text
	}
	return fallback
}
