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

// publishWrappedDEK 用临时 X25519 密钥对 wrap DEK 并上行给会话 owner。
// wrapped_dek 载荷 = sender_pub(32) || nonce(12) || aes-gcm(dek)，对 Relay 不透明。
func (m *SessionDEKManager) publishWrappedDEK(ctx context.Context, sessionID string, dek []byte) error {
	owner, err := m.fetchOwnerEncryptionKey(ctx, sessionID)
	if err != nil {
		return err
	}
	return m.publishWrappedDEKFor(ctx, sessionID, dek, owner.EncryptionPublicKey, owner.DeviceID)
}

// publishWrappedDEKFor 是 wrap 上行的通用形态：recipient 为任意 active owner
// 设备（v0.10.0 ADR-017 §6 批量补 wrap 与首 wrap 共用同一条载荷格式）。
func (m *SessionDEKManager) publishWrappedDEKFor(ctx context.Context, sessionID string, dek []byte, recipientPubB64, recipientDeviceID string) error {
	recipientPubBytes, err := crypto.DecodePublic(recipientPubB64)
	if err != nil || len(recipientPubBytes) != 32 {
		return errors.New("recipient encryption public key 无效")
	}
	recipientPub, err := ecdh.X25519().NewPublicKey(recipientPubBytes)
	if err != nil {
		return err
	}
	sender, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		return err
	}
	nonce, wrapped, err := crypto.WrapDEK(sender, recipientPub, dek)
	if err != nil {
		return err
	}
	// 载荷打包：sender_pub || nonce || ciphertext（UnwrapDEK 需 sender 公钥与 nonce）。
	payload := make([]byte, 0, 32+len(nonce)+len(wrapped))
	payload = append(payload, sender.PublicKey().Bytes()...)
	payload = append(payload, nonce...)
	payload = append(payload, wrapped...)
	return m.client.PublishContentDEK(ctx, sessionID, sessionDEKID(sessionID), payload, recipientDeviceID)
}

// ReconcileOwnerDEKWraps 是 owner 配对加入后的 DEK 补 wrap 对账（v0.10.0
// ADR-017 §6）：拉取 Relay 的待补清单，逐会话用本机 DEK 为新设备补 wrap 上行。
// 本机没有该会话 DEK（daemon 未处理过的会话）时跳过——该行留在服务端清单里，
// 不影响其它行；整个调用幂等，补完的行在下一次清单查询中自然消失。
func (m *SessionDEKManager) ReconcileOwnerDEKWraps(ctx context.Context) (int, error) {
	if m == nil || m.store == nil {
		return 0, errors.New("session DEK manager 未就绪")
	}
	if m.client == nil {
		return 0, nil
	}
	pending, err := m.client.FetchPendingDEKWraps(ctx)
	if err != nil {
		return 0, err
	}
	published := 0
	for _, row := range pending {
		if strings.TrimSpace(row.SessionID) == "" || strings.TrimSpace(row.EncryptionPublicKey) == "" {
			continue
		}
		if strings.TrimSpace(row.DEKID) != "" && row.DEKID != sessionDEKID(row.SessionID) {
			// 清单里的 DEK id 与本机派生口径不一致：fail-closed 跳过，不盲目 wrap。
			continue
		}
		existing, err := m.store.Get(sessionDEKLocalStateKey + row.SessionID)
		if err != nil || len(existing) < 32 {
			continue
		}
		dek, err := base64.RawStdEncoding.DecodeString(existing)
		if err != nil || len(dek) < 32 {
			continue
		}
		if err := m.publishWrappedDEKFor(ctx, row.SessionID, dek, row.EncryptionPublicKey, row.DeviceID); err != nil {
			// 单行失败不阻断整批（下个对账周期重试）。
			continue
		}
		published++
	}
	return published, nil
}

// sessionDEKID 派生会话 DEK 的稳定 id（Relay device_key_wraps 主键）。
func sessionDEKID(sessionID string) string {
	return "dek-" + sessionID
}
