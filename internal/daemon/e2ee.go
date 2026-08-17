package daemon

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"

	"github.com/yubi233/agent-sessions/internal/adapter"
	contentcrypto "github.com/yubi233/agent-sessions/packages/crypto"
)

const (
	// EventDEKEnvironment 是生产 Daemon 获取事件内容密钥的唯一环境变量。
	// 密钥只在进程内短暂保留，绝不能写进 SQLite、Relay、日志或报告。
	EventDEKEnvironment = "AGENT_SESSIONS_EVENT_DEK_B64"
	// EventKeyIDEnvironment 标识当前 DEK 的轮换版本；它会被绑定进 AAD。
	EventKeyIDEnvironment = "AGENT_SESSIONS_EVENT_KEY_ID"

	eventPayloadVersion = 1
)

// eventEnvelopePayload 是 AES-GCM 明文的版本化公共结构。Relay 只能持久化其密文；
// 解密方依据 version 选择解析器，避免未来字段扩展误读为旧格式。
type eventEnvelopePayload struct {
	Version int           `json:"version"`
	Event   adapter.Event `json:"event"`
}

// E2EEEventEncoder 是生产 canonical Provider event 的本机加密边界。它只保存在 Daemon
// 进程内，不能被 Store、RelayClient 或日志直接访问。
type E2EEEventEncoder struct {
	dek         []byte
	keyID       string
	nonceReader io.Reader
}

// NewE2EEEventEncoder 校验进程内传入的 32 字节 DEK 与非敏感 key ID。
// key ID 使用受限字符集，避免将换行或控制字符扩散到错误、指标或审计字段。
func NewE2EEEventEncoder(dek []byte, keyID string) (*E2EEEventEncoder, error) {
	if len(dek) != 32 {
		return nil, fmt.Errorf("event DEK 必须为 32 字节，当前为 %d", len(dek))
	}
	if !validEventKeyID(keyID) {
		return nil, errors.New("event key ID 缺失或格式非法")
	}
	// 复制输入，防止调用方后续复用或擦除切片时改变正在运行的 encoder。
	ownedDEK := append([]byte(nil), dek...)
	return &E2EEEventEncoder{dek: ownedDEK, keyID: keyID, nonceReader: rand.Reader}, nil
}

// LoadE2EEEventEncoderFromEnv 从 Daemon 进程环境加载生产事件密钥。
// 两项均未配置时返回 nil，保留既有事件扣留语义；只配置一项或格式错误会阻止启动，
// 不能把操作者的配置错误悄悄降级为无加密上传。
func LoadE2EEEventEncoderFromEnv(getenv func(string) string) (*E2EEEventEncoder, error) {
	if getenv == nil {
		return nil, errors.New("event encryption environment reader missing")
	}
	encodedDEK := strings.TrimSpace(getenv(EventDEKEnvironment))
	keyID := strings.TrimSpace(getenv(EventKeyIDEnvironment))
	if encodedDEK == "" && keyID == "" {
		return nil, nil
	}
	if encodedDEK == "" || keyID == "" {
		return nil, fmt.Errorf("%s 与 %s 必须同时配置", EventDEKEnvironment, EventKeyIDEnvironment)
	}

	dek, err := decodeEventDEK(encodedDEK)
	if err != nil {
		return nil, fmt.Errorf("%s 格式非法: %w", EventDEKEnvironment, err)
	}
	return NewE2EEEventEncoder(dek, keyID)
}

// Encode 将完整 canonical event 序列化后密封。AAD 同时固定会话、Relay 投影事件类型、
// 协议版本、canonical 序列与 key ID，防止密文被替换到另一个会话、类型或序号。
func (e *E2EEEventEncoder) Encode(sessionID string, event adapter.Event) (string, error) {
	if e == nil || len(e.dek) != 32 || !validEventKeyID(e.keyID) {
		return "", errors.New("production event encoder unavailable")
	}
	if strings.TrimSpace(sessionID) == "" {
		return "", errors.New("canonical event 缺少 session ID")
	}
	if strings.TrimSpace(string(event.Type)) == "" || event.Seq <= 0 {
		return "", errors.New("canonical event 类型或序号非法")
	}

	plaintext, err := json.Marshal(eventEnvelopePayload{Version: eventPayloadVersion, Event: event})
	if err != nil {
		return "", fmt.Errorf("序列化 canonical event: %w", err)
	}
	nonce := make([]byte, 12)
	if _, err := io.ReadFull(e.nonceSource(), nonce); err != nil {
		return "", fmt.Errorf("生成 event nonce: %w", err)
	}
	envelope, err := contentcrypto.Seal(e.dek, e.keyID, eventPayloadVersion, contentcrypto.AAD{
		EntityID:        sessionID,
		EventType:       relayEventType(event.Type),
		ProtocolVersion: daemonProtocolVersion,
		EventSeq:        event.Seq,
		KeyID:           e.keyID,
	}, plaintext, nonce)
	if err != nil {
		return "", fmt.Errorf("加密 canonical event: %w", err)
	}
	raw, err := json.Marshal(envelope)
	if err != nil {
		return "", fmt.Errorf("序列化 event envelope: %w", err)
	}
	return string(raw), nil
}

// Destroy 在 Daemon 退出时覆盖进程内密钥副本。Go 运行时不提供绝对的内存清除保证，
// 但这里避免正常退出路径继续保留可引用的 DEK。
func (e *E2EEEventEncoder) Destroy() {
	if e == nil {
		return
	}
	for i := range e.dek {
		e.dek[i] = 0
	}
	e.dek = nil
}

func (e *E2EEEventEncoder) nonceSource() io.Reader {
	if e != nil && e.nonceReader != nil {
		return e.nonceReader
	}
	return rand.Reader
}

func decodeEventDEK(value string) ([]byte, error) {
	// 兼容常见的带 padding 与 Raw base64 表示；两者都只允许标准 Base64 字母表。
	decoded, err := base64.RawStdEncoding.DecodeString(value)
	if err != nil {
		decoded, err = base64.StdEncoding.DecodeString(value)
	}
	if err != nil {
		return nil, errors.New("必须是 base64 编码")
	}
	if len(decoded) != 32 {
		return nil, fmt.Errorf("解码后必须为 32 字节，当前为 %d", len(decoded))
	}
	return decoded, nil
}

func validEventKeyID(value string) bool {
	if len(value) == 0 || len(value) > 128 {
		return false
	}
	for _, r := range value {
		asciiLetter := r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z'
		asciiDigit := r >= '0' && r <= '9'
		if !asciiLetter && !asciiDigit && r != '.' && r != '-' && r != '_' && r != ':' {
			return false
		}
	}
	return true
}
