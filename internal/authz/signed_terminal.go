package authz

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"strconv"
	"strings"

	"github.com/yubi233/agent-sessions/packages/protocol"
)

// TerminalSignature 是 v0.6 签名认证请求的 additive 字段。
// P0 冻结契约；P1 起由 Relay 在签名模式启用后强制校验。
type TerminalSignature struct {
	ProtocolVersion int    `json:"protocol_version"`
	KeyID           string `json:"key_id"`
	TimestampMS     int64  `json:"timestamp_ms"`
	Nonce           string `json:"nonce"`
	BodyHash        string `json:"body_hash"`
	Signature       string `json:"signature"`
}

// HashBody 计算请求体 SHA-256，用于 canonical bytes，禁止在日志/报告中回显原 body。
func HashBody(body []byte) string {
	sum := sha256.Sum256(body)
	return hex.EncodeToString(sum[:])
}

// CanonicalBytes 按 ADR-012 冻结顺序构造待签名字节。
// 任何端都不允许自行拼接或调换字段；协议版本、device_id、method、path、
// timestamp、nonce、body hash 与 key id 之间只使用 ASCII '|' 分隔。
func CanonicalBytes(protocolVersion int, deviceID, method, path string, timestampMS int64, nonce, bodyHash, keyID string) []byte {
	parts := []string{
		strconv.Itoa(protocolVersion),
		deviceID,
		method,
		path,
		strconv.FormatInt(timestampMS, 10),
		nonce,
		bodyHash,
		keyID,
	}
	return []byte(strings.Join(parts, "|"))
}

// SignTerminalRequest 使用 Terminal Ed25519 私钥对 canonical bytes 签名。
// 返回 base64 raw URL 风格签名；私钥长度或格式错误时返回稳定错误。
func SignTerminalRequest(priv ed25519.PrivateKey, sig TerminalSignature, deviceID, method, path string) (string, error) {
	if len(priv) != ed25519.PrivateKeySize {
		return "", protocol.NewError(protocol.ErrSignatureInvalid, "terminal private key size invalid")
	}
	canonical := CanonicalBytes(
		sig.ProtocolVersion, deviceID, method, path,
		sig.TimestampMS, sig.Nonce, sig.BodyHash, sig.KeyID,
	)
	return base64.RawStdEncoding.EncodeToString(ed25519.Sign(priv, canonical)), nil
}

// VerifyTerminalRequest 校验签名、公钥长度和 base64 格式。
// 这里只验证密码学签名；设备归属、active 状态、时间窗口和 nonce 一次性由上层调用方结合存储校验。
func VerifyTerminalRequest(pub ed25519.PublicKey, sig TerminalSignature, deviceID, method, path string) error {
	if len(pub) != ed25519.PublicKeySize {
		return protocol.NewError(protocol.ErrSignatureInvalid, "terminal public key size invalid")
	}
	raw, err := base64.RawStdEncoding.DecodeString(sig.Signature)
	if err != nil {
		return protocol.NewError(protocol.ErrSignatureInvalid, "terminal signature base64 invalid")
	}
	canonical := CanonicalBytes(
		sig.ProtocolVersion, deviceID, method, path,
		sig.TimestampMS, sig.Nonce, sig.BodyHash, sig.KeyID,
	)
	if !ed25519.Verify(pub, canonical, raw) {
		return protocol.NewError(protocol.ErrSignatureInvalid, "terminal signature verification failed")
	}
	return nil
}

// FormatTerminalError 仅用于给测试和诊断返回稳定错误，不打印签名或 body 原文。
func FormatTerminalError(code, message string) error {
	return fmt.Errorf("%s: %s", code, message)
}
