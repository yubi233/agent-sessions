package protocol

import (
	"encoding/json"
	"fmt"
)

// 当前冻结的协议主版本。未知版本必须被拒绝，不得静默降级。
const ProtocolVersion = 1

// 支持的消息类型。hello/challenge 仅用于 WebSocket 首帧协商。
const (
	MessageTypeCommand   = "command"
	MessageTypeEvent     = "event"
	MessageTypePresence  = "presence"
	MessageTypeAck       = "ack"
	MessageTypeHello     = "hello"
	MessageTypeChallenge = "challenge"
)

// Scope 由服务端从认证上下文推导，客户端填写的目标前缀不可信。
type Scope struct {
	TerminalID  string `json:"terminal_id,omitempty"`
	WorkspaceID string `json:"workspace_id,omitempty"`
	SessionID   string `json:"session_id,omitempty"`
}

// Envelope 是 REST 以外所有实时通道的统一信封。
type Envelope struct {
	ProtocolVersion int            `json:"protocol_version"`
	MessageType     string         `json:"message_type"`
	MessageID       string         `json:"message_id"`
	TraceID         string         `json:"trace_id"`
	Scope           *Scope         `json:"scope,omitempty"`
	IssuedByDevice  string         `json:"issued_by_device,omitempty"`
	LeaseEpoch      int64          `json:"lease_epoch,omitempty"`
	IdempotencyKey  string         `json:"idempotency_key,omitempty"`
	DeadlineUnixMS  int64          `json:"deadline_unix_ms,omitempty"`
	PayloadVersion  int            `json:"payload_version"`
	Payload         map[string]any `json:"payload"`
}

// Validate 检查协议版本、必填字段和已知消息类型。
func (e Envelope) Validate() error {
	if e.ProtocolVersion != ProtocolVersion {
		return fmt.Errorf("%s: got %d", ErrProtocolVersionMismatch, e.ProtocolVersion)
	}
	if e.MessageID == "" || e.TraceID == "" {
		return fmt.Errorf("%s: message_id/trace_id required", ErrInvalidRequest)
	}
	if e.PayloadVersion < 1 {
		return fmt.Errorf("%s", ErrUnknownPayloadVersion)
	}
	switch e.MessageType {
	case MessageTypeCommand, MessageTypeEvent, MessageTypePresence, MessageTypeAck, MessageTypeHello, MessageTypeChallenge:
	default:
		return fmt.Errorf("%s: %s", ErrUnknownEvent, e.MessageType)
	}
	if e.Payload == nil {
		return fmt.Errorf("%s: payload required", ErrInvalidRequest)
	}
	return nil
}

// ParseEnvelope 解析并校验 JSON 信封。
func ParseEnvelope(raw []byte) (Envelope, error) {
	var env Envelope
	if err := json.Unmarshal(raw, &env); err != nil {
		return Envelope{}, fmt.Errorf("%s: %w", ErrInvalidRequest, err)
	}
	return env, env.Validate()
}
