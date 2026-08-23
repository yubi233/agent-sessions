package daemon

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"strings"

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
type LocalDevEventEncoder struct{}

// NewLocalDevEventEncoder 构造本地开发事件编码器。无状态，按值实现 EventEncoder。
func NewLocalDevEventEncoder() LocalDevEventEncoder { return LocalDevEventEncoder{} }

// Encode 映射单条事件；返回空 envelope 且无错误表示该事件类型不进入账号时间线。
//
// 输出满足 Relay 的协议形状门（normalizeDaemonCipherEnvelope 要求 alg/key_id/nonce/
// ciphertext/aad_hash/payload_version 齐全），同时内嵌客户端可渲染的 fixture_payload。
// alg 固定为 "local-dev-fixture"，明确标记这是本地开发明文路径而非真实 E2EE。
func (e LocalDevEventEncoder) Encode(sessionID string, event adapter.Event) (string, error) {
	if strings.TrimSpace(sessionID) == "" {
		return "", errors.New("canonical event 缺少 session ID")
	}
	payload, ok := localDevFixturePayload(event)
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
func localDevFixturePayload(event adapter.Event) (map[string]any, bool) {
	switch event.Type {
	case adapter.EventMessageCompleted:
		text, _ := event.Payload["text"].(string)
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
	case adapter.EventToolCall:
		name := nonEmptyOr(event.Payload["tool_name"], "工具")
		input, _ := event.Payload["input"].(string)
		return map[string]any{
			"kind":        "tool_activity",
			"label":       name,
			"tool_status": "运行中",
			"tool_input":  input,
		}, true
	case adapter.EventToolResult:
		name := nonEmptyOr(event.Payload["tool_name"], "工具")
		output, _ := event.Payload["output"].(string)
		state, _ := event.Payload["state"].(string)
		status := "已完成"
		if state == "error" || state == "aborted" {
			status = "已中断"
		}
		return map[string]any{
			"kind":        "tool_activity",
			"label":       name,
			"tool_status": status,
			"tool_output": output,
		}, true
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
		// turn_started/message_delta/usage 等不进入本地开发时间线。
		return nil, false
	}
}

func nonEmptyOr(value any, fallback string) string {
	if text, ok := value.(string); ok && strings.TrimSpace(text) != "" {
		return text
	}
	return fallback
}
