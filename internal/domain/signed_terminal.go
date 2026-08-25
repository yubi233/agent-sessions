package domain

import (
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"crypto/subtle"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/yubi233/agent-sessions/internal/authz"
	"github.com/yubi233/agent-sessions/internal/store"
	"github.com/yubi233/agent-sessions/packages/protocol"
)

const (
	// terminalAuthTimeWindow 是签名时间戳允许的时钟偏差。
	terminalAuthTimeWindow = 5 * time.Minute
	// terminalAuthNonceTTL 是 nonce 在 SQLite 中的保留窗口。
	terminalAuthNonceTTL = 5 * time.Minute
	// terminalAuthChallengeTTL 是 hello challenge 的有效窗口；过期挑战不可消费。
	terminalAuthChallengeTTL = 5 * time.Minute
	// maxActiveTerminalIdentityKeys 限制轮换双读窗口：同一设备最多"旧 + 新"两把 active 密钥。
	maxActiveTerminalIdentityKeys = 2
	// daemonHelloCanonicalPath 是 hello 在 canonical bytes 中使用的请求路径；
	// 只有该路径的签名 nonce 允许使用一次性 challenge。
	daemonHelloCanonicalPath = "/v1/daemon/hello"
)

// TerminalAuthChallenge 是 GET /v1/daemon/challenge 返回的一次性挑战投影。
// challenge 本身不是密钥，可以出现在响应中；但只能被同设备的 signed hello 消费一次。
type TerminalAuthChallenge struct {
	Challenge       string `json:"challenge"`
	ExpiresAtUnixMS int64  `json:"expires_at_unix_ms"`
}

// SetTerminalSignatureRequired 切换 ADR-012 的 N/N-1 兼容窗口进度：
// false 为 optional（bearer + 签名双轨），true 为 required（窗口结束，bearer 一律 UPGRADE_REQUIRED）。
func (s *DaemonService) SetTerminalSignatureRequired(required bool) {
	s.signatureRequired = required
}

// IssueTerminalAuthChallenge 为已配对且仍 active 的 Terminal 签发 hello challenge。
// challenge 绑定当前设备并持久化到 SQLite，Relay 重启后未完成/已完成的挑战都不能重复使用。
func (s *DaemonService) IssueTerminalAuthChallenge(ctx context.Context, accountID, deviceID string) (TerminalAuthChallenge, error) {
	device, err := s.repo.DeviceByID(ctx, deviceID)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return TerminalAuthChallenge{}, ErrScopeDenied
		}
		return TerminalAuthChallenge{}, err
	}
	if device.AccountID != accountID || device.Role != RoleTerminal {
		return TerminalAuthChallenge{}, ErrScopeDenied
	}
	if device.Status != DeviceActive {
		return TerminalAuthChallenge{}, protocol.NewError(protocol.ErrDeviceRevoked, "terminal device not active")
	}

	now := s.now()
	// 顺带清理过期挑战，防止表无限增长；清理失败不阻塞签发。
	_ = s.repo.DeleteExpiredTerminalAuthChallenges(ctx, now.UnixMilli())

	challenge := TerminalAuthChallenge{
		Challenge:       authz.RandomToken(),
		ExpiresAtUnixMS: now.Add(terminalAuthChallengeTTL).UnixMilli(),
	}
	if err := s.repo.CreateTerminalAuthChallenge(ctx, store.TerminalAuthChallengeRow{
		Challenge:       challenge.Challenge,
		DeviceID:        deviceID,
		ExpiresAtUnixMS: challenge.ExpiresAtUnixMS,
		CreatedAtUnixMS: now.UnixMilli(),
	}); err != nil {
		return TerminalAuthChallenge{}, err
	}
	return challenge, nil
}

// RegisterTerminalIdentityKey 由 owner 登记一把 Terminal Ed25519 身份公钥，进入轮换双读窗口。
// 同一公钥重复登记幂等返回既有 key；已 retired 的公钥禁止复用；active 数量达到上限后必须先完成收口。
func (s *DaemonService) RegisterTerminalIdentityKey(ctx context.Context, accountID, targetDeviceID, publicKeyEncoded string) (store.TerminalIdentityKeyRow, error) {
	publicKeyEncoded = strings.TrimSpace(publicKeyEncoded)
	if publicKeyEncoded == "" {
		return store.TerminalIdentityKeyRow{}, protocol.NewError(protocol.ErrInvalidRequest, "identity_public_key required")
	}
	if _, err := decodeEd25519PublicKey(publicKeyEncoded); err != nil {
		return store.TerminalIdentityKeyRow{}, protocol.NewError(protocol.ErrInvalidRequest, "identity_public_key is not a valid ed25519 public key")
	}
	device, err := s.repo.DeviceByID(ctx, targetDeviceID)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return store.TerminalIdentityKeyRow{}, ErrScopeDenied
		}
		return store.TerminalIdentityKeyRow{}, err
	}
	if device.AccountID != accountID || device.Role != RoleTerminal {
		return store.TerminalIdentityKeyRow{}, ErrScopeDenied
	}
	if device.Status != DeviceActive {
		return store.TerminalIdentityKeyRow{}, protocol.NewError(protocol.ErrDeviceRevoked, "terminal device not active")
	}

	existing, err := s.repo.ListTerminalIdentityKeys(ctx, targetDeviceID)
	if err != nil {
		return store.TerminalIdentityKeyRow{}, err
	}
	for _, row := range existing {
		if row.PublicKey != publicKeyEncoded {
			continue
		}
		if row.Status == "active" {
			// 幂等登记：同一公钥已在双读窗口内则直接返回既有 key_id。
			return row, nil
		}
		// 已撤销的密钥材料可能已经泄漏，重新启用会绕过撤销语义。
		return store.TerminalIdentityKeyRow{}, protocol.NewError(protocol.ErrInvalidRequest, "retired identity key must not be reused")
	}
	activeCount := 0
	for _, row := range existing {
		if row.Status == "active" {
			activeCount++
		}
	}
	if activeCount >= maxActiveTerminalIdentityKeys {
		return store.TerminalIdentityKeyRow{}, protocol.NewError(protocol.ErrInvalidRequest, "terminal identity key rotation window is full")
	}

	row := store.TerminalIdentityKeyRow{
		KeyID:           deriveRegisteredKeyID(publicKeyEncoded),
		DeviceID:        targetDeviceID,
		AccountID:       accountID,
		PublicKey:       publicKeyEncoded,
		Status:          "active",
		CreatedAtUnixMS: s.now().UnixMilli(),
	}
	if err := s.repo.CreateTerminalIdentityKey(ctx, row); err != nil {
		return store.TerminalIdentityKeyRow{}, err
	}
	_ = s.repo.AppendAudit(ctx, accountID, "terminal.identity_key_registered",
		`{"device_id":"`+targetDeviceID+`","key_id":"`+row.KeyID+`"}`)
	return row, nil
}

// ListTerminalIdentityKeys 返回设备登记密钥的白名单审计视图；owner 只能查看自己账号的 Terminal。
func (s *DaemonService) ListTerminalIdentityKeys(ctx context.Context, accountID, targetDeviceID string) ([]store.TerminalIdentityKeyRow, error) {
	device, err := s.repo.DeviceByID(ctx, targetDeviceID)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, ErrScopeDenied
		}
		return nil, err
	}
	if device.AccountID != accountID || device.Role != RoleTerminal {
		return nil, ErrScopeDenied
	}
	return s.repo.ListTerminalIdentityKeys(ctx, targetDeviceID)
}

// RevokeTerminalIdentityKey 立即撤销单把登记密钥。撤销即时生效：
// 后续使用该 key 的签名一律 KEY_UNKNOWN_OR_REVOKED，不影响设备上其他密钥。
func (s *DaemonService) RevokeTerminalIdentityKey(ctx context.Context, accountID, targetDeviceID, keyID string) error {
	row, err := s.repo.TerminalIdentityKeyByID(ctx, keyID)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return ErrScopeDenied
		}
		return err
	}
	if row.AccountID != accountID || row.DeviceID != targetDeviceID {
		return ErrScopeDenied
	}
	retired, err := s.repo.RetireTerminalIdentityKey(ctx, keyID, s.now().UnixMilli())
	if err != nil {
		return err
	}
	if retired {
		_ = s.repo.AppendAudit(ctx, accountID, "terminal.identity_key_revoked",
			`{"device_id":"`+targetDeviceID+`","key_id":"`+keyID+`"}`)
	}
	return nil
}

// VerifySignedTerminalRequest 在签名请求到达业务处理前完成设备归属、时间窗口、
// body hash、Ed25519 签名和一次性 nonce 校验。旧 bearer 客户端在 N/N-1 兼容窗口内
// 不携带 signature 时仍继续走原 token 路径；一旦携带签名就必须完整校验，不得部分放行。
// required 模式下（兼容窗口结束）无签名请求返回稳定 UPGRADE_REQUIRED。
func (s *DaemonService) VerifySignedTerminalRequest(ctx context.Context, accountID, deviceID string, sig authz.TerminalSignature, method, path string, body []byte) error {
	if sig.Signature == "" && sig.KeyID == "" {
		// 兼容窗口内旧 bearer 放行；窗口结束必须显式要求升级，不允许静默降级或放行。
		// 复用协议升级哨兵错误，让传输层映射为稳定 426 UPGRADE_REQUIRED。
		if s.signatureRequired {
			return fmt.Errorf("terminal signature authentication required: %w", ErrProtocolUpgradeRequired)
		}
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

	// 解析验签公钥：key id 等于设备 ID 走桥接期内置公钥；否则查登记密钥表（轮换双读）。
	registeredKey := false
	var pub ed25519.PublicKey
	if sig.KeyID == deviceID {
		pub, err = decodeEd25519PublicKey(device.IdentityPublicKey)
		if err != nil {
			return protocol.NewError(protocol.ErrKeyUnknownOrRevoked, "terminal device public key invalid")
		}
	} else {
		row, keyErr := s.repo.TerminalIdentityKeyByID(ctx, sig.KeyID)
		if keyErr != nil {
			if errors.Is(keyErr, sql.ErrNoRows) {
				return protocol.NewError(protocol.ErrKeyUnknownOrRevoked, "terminal identity key unknown")
			}
			return keyErr
		}
		if row.DeviceID != deviceID || row.AccountID != accountID || row.Status != "active" {
			return protocol.NewError(protocol.ErrKeyUnknownOrRevoked, "terminal identity key revoked or not bound to device")
		}
		pub, err = decodeEd25519PublicKey(row.PublicKey)
		if err != nil {
			return protocol.NewError(protocol.ErrKeyUnknownOrRevoked, "terminal identity public key invalid")
		}
		registeredKey = true
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
	if err := authz.VerifyTerminalRequest(pub, sig, deviceID, method, path); err != nil {
		return err
	}

	// 密码学校验通过后才进入一次性状态写入：hello 的 nonce 必须是本设备未消费的 challenge，
	// 其余请求直接消费 nonce。挑战消费、nonce 记录与轮换收口在同一事务内原子提交，
	// 任一步失败都不会留下半消费状态。
	err = s.repo.WithTx(ctx, func(ctx context.Context, tx store.Repository) error {
		if method == "POST" && path == daemonHelloCanonicalPath {
			consumed, challengeErr := tx.ConsumeTerminalAuthChallenge(ctx, deviceID, sig.Nonce, now)
			if challengeErr != nil {
				return challengeErr
			}
			if !consumed {
				return protocol.NewError(protocol.ErrNonceReused, "terminal hello challenge unknown, expired or already used")
			}
		}
		expiresAt := now + terminalAuthNonceTTL.Milliseconds()
		if nonceErr := tx.ConsumeTerminalAuthNonce(ctx, sig.KeyID, sig.Nonce, now, expiresAt); nonceErr != nil {
			return nonceErr
		}
		// 轮换一写收敛：登记密钥首次成功签名后，同设备其余 active 登记密钥立即 retired。
		// 桥接期内置公钥（key_id=device_id）不触发收口，保持 bearer→signature 平滑迁移。
		if registeredKey {
			if retireErr := tx.RetireOtherTerminalIdentityKeys(ctx, deviceID, sig.KeyID, now); retireErr != nil {
				return retireErr
			}
		}
		return nil
	})
	if err != nil {
		return err
	}
	return nil
}

// deriveRegisteredKeyID 从公钥材料确定性派生 key id。同一公钥永远得到同一个 key id，
// 使重复登记可以被识别为幂等操作而不是新密钥。
func deriveRegisteredKeyID(publicKeyEncoded string) string {
	sum := sha256.Sum256([]byte(publicKeyEncoded))
	return "tkey_" + hex.EncodeToString(sum[:8])
}

// decodeEd25519PublicKey 兼容客户端常见 base64/base64url 编码，并校验 Ed25519 公钥长度。
func decodeEd25519PublicKey(encoded string) (ed25519.PublicKey, error) {
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
