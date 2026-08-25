package domain

import (
	"context"
	"crypto/ed25519"
	"crypto/subtle"
	"database/sql"
	"encoding/base64"
	"errors"
	"time"

	"github.com/yubi233/agent-sessions/internal/authz"
	"github.com/yubi233/agent-sessions/packages/protocol"
)

const (
	// terminalAuthTimeWindow 是签名时间戳允许的时钟偏差。
	terminalAuthTimeWindow = 5 * time.Minute
	// terminalAuthNonceTTL 是 nonce 在 SQLite 中的保留窗口。
	terminalAuthNonceTTL = 5 * time.Minute
)

// VerifySignedTerminalRequest 在签名请求到达业务处理前完成设备归属、时间窗口、
// body hash、Ed25519 签名和一次性 nonce 校验。旧 bearer 客户端在 P0/P1 兼容窗口内
// 不携带 signature 时仍继续走原 token 路径；一旦携带签名就必须完整校验，不得部分放行。
func (s *DaemonService) VerifySignedTerminalRequest(ctx context.Context, accountID, deviceID string, sig authz.TerminalSignature, method, path string, body []byte) error {
	if sig.Signature == "" && sig.KeyID == "" {
		return nil
	}
	if sig.Signature == "" || sig.KeyID == "" || sig.Nonce == "" {
		return protocol.NewError(protocol.ErrSignatureRequired, "terminal signature fields required")
	}
	if sig.ProtocolVersion != 0 && sig.ProtocolVersion != 1 {
		return protocol.NewError(protocol.ErrProtocolVersionMismatch, "terminal signature protocol version unsupported")
	}

	device, err := s.repo.DeviceByID(ctx, deviceID)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return protocol.NewError(protocol.ErrKeyUnknownOrRevoked, "terminal device not found")
		}
		return err
	}
	if device.AccountID != accountID || device.Role != RoleTerminal || device.Status != "active" {
		return protocol.NewError(protocol.ErrDeviceRevoked, "terminal device not active or not in account")
	}
	if sig.KeyID != deviceID {
		return protocol.NewError(protocol.ErrKeyUnknownOrRevoked, "terminal key id does not match device")
	}

	now := s.now().UnixMilli()
	delta := now - sig.TimestampMS
	if delta < 0 {
		delta = -delta
	}
	if delta > terminalAuthTimeWindow.Milliseconds() {
		return protocol.NewError(protocol.ErrTimestampExpired, "terminal signature timestamp outside window")
	}
	if subtle.ConstantTimeCompare([]byte(sig.BodyHash), []byte(authz.HashBody(body))) != 1 {
		return protocol.NewError(protocol.ErrSignatureInvalid, "terminal body hash mismatch")
	}

	pub, err := decodeTerminalPublicKey(device.IdentityPublicKey)
	if err != nil {
		return protocol.NewError(protocol.ErrKeyUnknownOrRevoked, "terminal device public key invalid")
	}
	if err := authz.VerifyTerminalRequest(pub, sig, deviceID, method, path); err != nil {
		return err
	}

	expiresAt := now + terminalAuthNonceTTL.Milliseconds()
	if err := s.repo.ConsumeTerminalAuthNonce(ctx, sig.KeyID, sig.Nonce, expiresAt); err != nil {
		return err
	}
	return nil
}

// decodeTerminalPublicKey 兼容客户端常见 base64/base64url 编码，并校验 Ed25519 公钥长度。
func decodeTerminalPublicKey(encoded string) (ed25519.PublicKey, error) {
	if encoded == "" {
		return nil, protocol.NewError(protocol.ErrKeyUnknownOrRevoked, "empty terminal public key")
	}
	encodings := []*base64.Encoding{
		base64.RawURLEncoding,
		base64.URLEncoding,
		base64.RawStdEncoding,
		base64.StdEncoding,
	}
	for _, enc := range encodings {
		raw, err := enc.DecodeString(encoded)
		if err != nil || len(raw) != ed25519.PublicKeySize {
			continue
		}
		return ed25519.PublicKey(raw), nil
	}
	return nil, protocol.NewError(protocol.ErrKeyUnknownOrRevoked, "terminal public key decode failed")
}
