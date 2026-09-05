package daemon

// 附件密文 Open（v0.8.8 P1 / 迭代计划 v0.8.8 §9.1 冻结契约）：
// Daemon 从 Relay §3.3 端点拉回附件密文投影后，用本机会话 DEK 按 mobile
// _sealDraft 的对称组合解密出明文字节。本文件是「mobile Seal ↔ daemon Open」
// 契约的 daemon 侧唯一实现，任何一侧改动都必须先修订计划 §9.1。
//
// 红线：明文只经内存（供 runner 复算 sha256/尺寸后转 image block），绝不写
// 日志、事件 payload、报告或错误文本；所有失败路径只返回脱敏错误。

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/yubi233/agent-sessions/packages/crypto"
)

// attachmentMetadataAADScope / attachmentChunkAADScope 与 mobile
// attachment_picker._sealEnvelope 的 scope 字段逐字对齐；AAD 的 event_type
// 就取这两个常量，任何漂移都会导致 aad_hash 校验失败（fail-closed）。
const (
	attachmentMetadataAADScope = "attachment:metadata"
	attachmentChunkAADScope    = "attachment:chunk"
)

// attachmentEnvelopeMaxBytes 是单个上传块（序列化后的 JSON envelope）的解码上限：
// 与 Relay 上传侧 maxAttachmentChunkCiphertextBytes(512KiB) 同量级，防止畸形超大块
// 在 daemon 侧无界解码。
const attachmentEnvelopeMaxBytes = 512 * 1024

// errSessionDEKUnavailable 是本机会话 DEK 缺失的统一失败哨兵：调用方
// （RelayLoop.fetchAndOpenAttachment）不感知具体原因文本，runner 收口时按
// CommandErrorCode 归一为协议稳定错误码，避免内部细节进公共协议。
var errSessionDEKUnavailable = errors.New("会话附件密钥不可用")

// loadSessionDEK 从本机 local_state 读取会话内容 DEK（SessionDEKManager 在会话
// 首启时生成并持久化，键前缀 sessionDEKLocalStateKey，base64 RawStdEncoding）。
// DEK 缺失/损坏一律 fail-closed：附件发送必须失败而不是退化为占位行为。
func loadSessionDEK(store *Store, sessionID string) ([]byte, error) {
	if store == nil {
		return nil, errors.New("附件解密出口未就绪（本机状态缺失）")
	}
	raw, err := store.Get(sessionDEKLocalStateKey + sessionID)
	if err != nil || len(raw) == 0 {
		return nil, errSessionDEKUnavailable
	}
	dek, err := base64.RawStdEncoding.DecodeString(raw)
	if err != nil || len(dek) < 32 {
		return nil, errors.New("会话附件密钥损坏，附件保持禁用")
	}
	return dek, nil
}

// openAttachmentChunk 解开单个附件块（JSON envelope → AAD 校验 → AES-256-GCM
// → chunk sha256 复算）。AAD 组合与 mobile Seal 逐字段对齐：
//
//	entity_id=sessionId, event_type="attachment:chunk",
//	protocol_version=1, event_seq=块序号, key_id=envelope.key_id
//
// crypto.Open 内部会把 aad.KeyID 重置为 envelope 自带的 key_id 再校验 aad_hash，
// 因此调用方无需（也不应）自行猜测 keyID。
func openAttachmentChunk(dek []byte, sessionID string, chunkIndex int, chunkCiphertext []byte) ([]byte, error) {
	if len(chunkCiphertext) == 0 {
		return nil, fmt.Errorf("附件块 %d 为空", chunkIndex)
	}
	if len(chunkCiphertext) > attachmentEnvelopeMaxBytes {
		return nil, fmt.Errorf("附件块 %d 超出尺寸上限", chunkIndex)
	}
	var env crypto.Envelope
	if err := json.Unmarshal(chunkCiphertext, &env); err != nil {
		return nil, fmt.Errorf("附件块 %d envelope 形状不符", chunkIndex)
	}
	aad := crypto.AAD{
		EntityID:        sessionID,
		EventType:       attachmentChunkAADScope,
		ProtocolVersion: 1,
		EventSeq:        int64(chunkIndex),
	}
	plain, err := crypto.Open(dek, env, aad)
	if err != nil {
		return nil, fmt.Errorf("附件块 %d 解密失败", chunkIndex)
	}
	return plain, nil
}

// verifyChunkSHA256 对解密后的明文块复算 sha256 并与 Relay 存储登记值恒等比对
// （大小写不敏感）。登记值缺失时跳过块级校验——整附件级校验由 runner 按 refs
// 携带的 sha256/size_bytes 复算兜底，两层校验语义与 V085-04 一致。
func verifyChunkSHA256(plain []byte, registeredHex string, chunkIndex int) error {
	registered := strings.TrimSpace(registeredHex)
	if registered == "" {
		return nil
	}
	sum := sha256.Sum256(plain)
	if !strings.EqualFold(registered, hex.EncodeToString(sum[:])) {
		return fmt.Errorf("附件块 %d 哈希不符", chunkIndex)
	}
	return nil
}

// openAttachmentProjection 按 §9.1 冻结契约把密文投影解为明文字节：
// 逐块解密（块序即 AAD event_seq）→ 逐块 sha256 复算 → 按存储顺序拼接。
// 任何一块失败都整批失败（无部分解密输出），与 runner 的整批收口语义对齐。
// 明文拼接结果只存在于调用方内存中，本函数不做任何落盘或日志动作。
func openAttachmentProjection(dek []byte, sessionID string, proj AttachmentFetchProjection) ([]byte, error) {
	if len(proj.Chunks) == 0 {
		return nil, errors.New("附件密文投影无分块")
	}
	if len(proj.ChunkSHA256) > 0 && len(proj.ChunkSHA256) != len(proj.Chunks) {
		return nil, errors.New("附件块哈希登记数量不符")
	}
	parts := make([][]byte, 0, len(proj.Chunks))
	total := 0
	for i, chunkCiphertext := range proj.Chunks {
		plain, err := openAttachmentChunk(dek, sessionID, i, chunkCiphertext)
		if err != nil {
			return nil, err
		}
		if err := verifyChunkSHA256(plain, proj.ChunkSHA256[i], i); err != nil {
			return nil, err
		}
		parts = append(parts, plain)
		total += len(plain)
	}
	if proj.ByteSize > 0 && int64(total) != proj.ByteSize {
		return nil, fmt.Errorf("附件明文尺寸不符（登记 %d 实得 %d）", proj.ByteSize, total)
	}
	plaintext := make([]byte, 0, total)
	for _, part := range parts {
		plaintext = append(plaintext, part...)
	}
	return plaintext, nil
}
