package daemon

// 会话内容密钥（DEK）编排（v0.8.5 §3.2 / ADR-016 §2）：
// Daemon 首次处理会话命令时为该会话生成本机 DEK（local_state 持久，明文不出本机），
// 用临时 X25519 密钥对 wrap 后经 RelayClient 上行 device_key_wraps；owner 设备读取后
// 以设备私钥 unwrap 密封附件。wrapped_dek 载荷格式：sender_pub(32)||nonce(12)||gcm。

import (
	"context"
	"crypto/ecdh"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"strings"

	"github.com/yubi233/agent-sessions/packages/crypto"
)

const (
	// sessionDEKLocalStateKey 是本机会话 DEK 的 local_state 键前缀。
	sessionDEKLocalStateKey = "session-dek:"
)

// SessionDEKManager 负责会话 DEK 的生成、本机持久化与 wrap 上行。
type SessionDEKManager struct {
	store  *Store
	client *RelayClient
}

// NewSessionDEKManager 构造会话 DEK 管理器；client 为 nil 时（本地 fixture 无 Relay）
// EnsureAndPublish 只做本机生成与持久化，跳过 wrap 上行。
func NewSessionDEKManager(store *Store, client *RelayClient) *SessionDEKManager {
	return &SessionDEKManager{store: store, client: client}
}

// EnsureAndPublishDEK 为会话确保本机 DEK 并（首次）wrap 上行到 Relay。
// 已存在 DEK 时幂等返回（不重复 wrap）；本机 DEK 是附件解密的前提，生成后立即
// 持久化——任何失败路径不把明文 DEK 写日志或报告。
func (m *SessionDEKManager) EnsureAndPublishDEK(ctx context.Context, sessionID string) error {
	if m == nil || m.store == nil || strings.TrimSpace(sessionID) == "" {
		return errors.New("session DEK manager 未就绪")
	}
	key := sessionDEKLocalStateKey + sessionID
	if existing, err := m.store.Get(key); err == nil && len(existing) >= 32 {
		return nil // 已存在：幂等
	}
	dek, err := crypto.RandomDEK()
	if err != nil {
		return err
	}
	if err := m.store.Set(key, base64.RawStdEncoding.EncodeToString(dek)); err != nil {
		return err
	}
	// wrap 上行（无 Relay 时跳过，本机 DEK 已就绪供解密）。
	if m.client == nil {
		return nil
	}
	return m.publishWrappedDEK(ctx, sessionID, dek)
}

// fetchOwnerEncryptionKey 从 Relay 取会话 owner 的 encryption_public_key 与设备 id。
func (m *SessionDEKManager) fetchOwnerEncryptionKey(ctx context.Context, sessionID string) (OwnerEncryptionKey, error) {
	return m.client.FetchOwnerEncryptionKey(ctx, sessionID)
}

// publishWrappedDEK 用临时 X25519 密钥对 wrap DEK 并上行。
// wrapped_dek 载荷 = sender_pub(32) || nonce(12) || aes-gcm(dek)，对 Relay 不透明。
func (m *SessionDEKManager) publishWrappedDEK(ctx context.Context, sessionID string, dek []byte) error {
	owner, err := m.fetchOwnerEncryptionKey(ctx, sessionID)
	if err != nil {
		return err
	}
	ownerKeyB64, ownerDeviceID := owner.EncryptionPublicKey, owner.DeviceID
	ownerPubBytes, err := crypto.DecodePublic(ownerKeyB64)
	if err != nil || len(ownerPubBytes) != 32 {
		return errors.New("owner encryption public key 无效")
	}
	ownerPub, err := ecdh.X25519().NewPublicKey(ownerPubBytes)
	if err != nil {
		return err
	}
	sender, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		return err
	}
	nonce, wrapped, err := crypto.WrapDEK(sender, ownerPub, dek)
	if err != nil {
		return err
	}
	// 载荷打包：sender_pub || nonce || ciphertext（UnwrapDEK 需 sender 公钥与 nonce）。
	payload := make([]byte, 0, 32+len(nonce)+len(wrapped))
	payload = append(payload, sender.PublicKey().Bytes()...)
	payload = append(payload, nonce...)
	payload = append(payload, wrapped...)
	return m.client.PublishContentDEK(ctx, sessionID, sessionDEKID(sessionID), payload, ownerDeviceID)
}

// sessionDEKID 派生会话 DEK 的稳定 id（Relay device_key_wraps 主键）。
func sessionDEKID(sessionID string) string {
	return "dek-" + sessionID
}
