package domain

import (
	"context"
	"database/sql"
	"errors"
	"time"

	"github.com/yubi233/agent-sessions/internal/authz"
	"github.com/yubi233/agent-sessions/internal/id"
	"github.com/yubi233/agent-sessions/internal/store"
)

// 恢复码限次与冷却窗口。超过限制后锁定，保护 owner 恢复入口。
const (
	recoveryMaxAttempts = 5
	recoveryCooldown    = 5 * time.Minute
)

// PairingService 处理设备配对、owner 批准、撤销与恢复码。
// 服务器只保存公钥与密文包装；第一个 Android 设备自动成为 owner。
type PairingService struct {
	repo store.Repository
	now  func() time.Time
}

// NewPairingService 构造配对服务。
func NewPairingService(repo store.Repository) *PairingService {
	return &PairingService{repo: repo, now: time.Now}
}

// BootstrapOwner 创建首个 Android owner 设备。要求账号尚无任何设备。
func (s *PairingService) BootstrapOwner(ctx context.Context, accountID string, d Device) (Device, error) {
	existing, err := s.repo.ListDevices(ctx, accountID)
	if err != nil {
		return Device{}, err
	}
	if len(existing) > 0 {
		return Device{}, ErrOwnerRequired
	}
	dev := d
	dev.ID = id.New("dev")
	dev.AccountID = accountID
	dev.Role = RoleAndroidOwner
	dev.Status = DeviceActive
	if err := s.repo.CreateDevice(ctx, toDeviceRow(dev)); err != nil {
		return Device{}, err
	}
	_ = s.repo.AppendAudit(ctx, accountID, "device.bootstrap_owner", `{"role":"android_owner"}`)
	return dev, nil
}

// CreatePairingRequest 由待配对设备发起，返回请求 ID（供 QR/短码展示）。
func (s *PairingService) CreatePairingRequest(ctx context.Context, accountID string, d Device) (PairingRequest, error) {
	p := PairingRequest{
		ID:                  id.New("pair"),
		AccountID:           accountID,
		Role:                d.Role,
		Status:              PairingPending,
		DisplayName:         d.DisplayName,
		IdentityPublicKey:   d.IdentityPublicKey,
		EncryptionPublicKey: d.EncryptionPublicKey,
		Platform:            d.Platform,
		ExpiresAt:           s.now().Add(10 * time.Minute),
	}
	if err := s.repo.CreatePairingRequest(ctx, toPairingRow(p)); err != nil {
		return PairingRequest{}, err
	}
	return p, nil
}

// ApprovePairing 由 owner 批准配对请求，创建授权设备；重复批准幂等返回原结果。
func (s *PairingService) ApprovePairing(ctx context.Context, owner AuthSubject, pairingID string) (Device, error) {
	if !owner.IsOwner() {
		return Device{}, ErrOwnerRequired
	}
	p, err := s.repo.PairingByID(ctx, pairingID)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return Device{}, ErrPairingNotFound
		}
		return Device{}, err
	}
	switch p.Status {
	case PairingApproved:
		// 幂等：已批准则返回已存在设备。
		dev, derr := s.deviceByKeys(ctx, p.AccountID, p.IdentityPublicKey)
		if derr != nil {
			return Device{}, derr
		}
		return dev, nil
	case PairingCancelled:
		return Device{}, ErrPairingAlreadyHandled
	case PairingPending:
	default:
		return Device{}, ErrPairingAlreadyHandled
	}
	if s.now().After(p.ExpiresAt) {
		_ = s.repo.SetPairingStatus(ctx, pairingID, PairingExpired)
		return Device{}, ErrPairingExpired
	}
	dev := Device{
		ID:                  id.New("dev"),
		AccountID:           p.AccountID,
		Role:                p.Role,
		Status:              DeviceActive,
		DisplayName:         p.DisplayName,
		Platform:            p.Platform,
		IdentityPublicKey:   p.IdentityPublicKey,
		EncryptionPublicKey: p.EncryptionPublicKey,
	}
	err = s.repo.WithTx(ctx, func(ctx context.Context, tx store.Repository) error {
		if err := tx.CreateDevice(ctx, toDeviceRow(dev)); err != nil {
			return err
		}
		return tx.SetPairingStatus(ctx, pairingID, PairingApproved)
	})
	if err != nil {
		return Device{}, err
	}
	_ = s.repo.AppendAudit(ctx, owner.AccountID, "device.approved", `{"device_id":"`+dev.ID+`"}`)
	return dev, nil
}

// CancelPairing 取消待处理的配对请求。
func (s *PairingService) CancelPairing(ctx context.Context, accountID, pairingID string) error {
	p, err := s.repo.PairingByID(ctx, pairingID)
	if err != nil {
		return ErrPairingNotFound
	}
	if p.AccountID != accountID {
		return ErrOwnerRequired
	}
	if p.Status != PairingPending {
		return ErrPairingAlreadyHandled
	}
	return s.repo.SetPairingStatus(ctx, pairingID, PairingCancelled)
}

// RevokeDevice 由 owner 撤销设备；撤销后停止新 DEK 包装。
func (s *PairingService) RevokeDevice(ctx context.Context, owner AuthSubject, deviceID string) error {
	if !owner.IsOwner() {
		return ErrOwnerRequired
	}
	dev, err := s.repo.DeviceByID(ctx, deviceID)
	if err != nil {
		return ErrPairingNotFound
	}
	if dev.AccountID != owner.AccountID {
		return ErrOwnerRequired
	}
	if err := s.repo.SetDeviceStatus(ctx, deviceID, DeviceRevoked); err != nil {
		return err
	}
	_ = s.repo.AppendAudit(ctx, owner.AccountID, "device.revoked", `{"device_id":"`+deviceID+`"}`)
	return nil
}

// ListDevices 返回账号下全部设备。
func (s *PairingService) ListDevices(ctx context.Context, accountID string) ([]Device, error) {
	rows, err := s.repo.ListDevices(ctx, accountID)
	if err != nil {
		return nil, err
	}
	out := make([]Device, 0, len(rows))
	for _, r := range rows {
		out = append(out, fromDeviceRow(r))
	}
	return out, nil
}

// WrapDEKForDevice 记录一条 DEK 包装；撤销设备不再接受新包装（SEC-02/PAIR-03）。
func (s *PairingService) WrapDEKForDevice(ctx context.Context, senderDeviceID, dekID, recipientDeviceID string, wrapped []byte) error {
	dev, err := s.repo.DeviceByID(ctx, recipientDeviceID)
	if err != nil {
		return ErrPairingNotFound
	}
	if dev.Status == DeviceRevoked {
		return ErrDeviceRevoked
	}
	return s.repo.PutKeyWrap(ctx, store.KeyWrapRow{
		DEKID: dekID, RecipientDeviceID: recipientDeviceID,
		SenderDeviceID: senderDeviceID, WrappedDEK: wrapped, CreatedAt: s.now(),
	})
}

// GenerateRecoveryCode 生成并返回恢复码明文（仅返回一次），服务器只存哈希。
func (s *PairingService) GenerateRecoveryCode(ctx context.Context, accountID string) (string, error) {
	code := authz.RandomToken()
	err := s.repo.UpsertRecoveryCode(ctx, store.RecoveryRow{
		AccountID: accountID, CodeHash: authz.HashToken(code), CreatedAt: s.now(),
	})
	if err != nil {
		return "", err
	}
	return code, nil
}

// RestoreWithRecoveryCode 校验恢复码；错误次数超限进入冷却（SEC-03）。
func (s *PairingService) RestoreWithRecoveryCode(ctx context.Context, accountID, code string) error {
	rc, err := s.repo.RecoveryByAccount(ctx, accountID)
	if err != nil {
		return ErrRecoveryInvalid
	}
	if s.now().Before(rc.LockedUntil) {
		return ErrRecoveryLocked
	}
	if authz.HashToken(code) == rc.CodeHash {
		// 成功：重置失败计数。
		_ = s.repo.UpsertRecoveryCode(ctx, store.RecoveryRow{AccountID: accountID, CodeHash: rc.CodeHash, CreatedAt: s.now()})
		return nil
	}
	failed := rc.FailedAttempts + 1
	locked := time.Time{}
	if failed >= recoveryMaxAttempts {
		locked = s.now().Add(recoveryCooldown)
	}
	if err := s.repo.UpsertRecoveryCode(ctx, store.RecoveryRow{
		AccountID: accountID, CodeHash: rc.CodeHash,
		FailedAttempts: failed, LockedUntil: locked, CreatedAt: rc.CreatedAt,
	}); err != nil {
		return err
	}
	if !locked.IsZero() {
		return ErrRecoveryLocked
	}
	return ErrRecoveryInvalid
}

func (s *PairingService) deviceByKeys(ctx context.Context, accountID, identityPublicKey string) (Device, error) {
	devs, err := s.repo.ListDevices(ctx, accountID)
	if err != nil {
		return Device{}, err
	}
	for _, d := range devs {
		if d.IdentityPublicKey == identityPublicKey {
			return fromDeviceRow(d), nil
		}
	}
	return Device{}, ErrPairingNotFound
}

func toDeviceRow(d Device) store.DeviceRow {
	return store.DeviceRow{
		ID: d.ID, AccountID: d.AccountID, Role: d.Role, Status: d.Status,
		DisplayName: d.DisplayName, Platform: d.Platform,
		IdentityPublicKey: d.IdentityPublicKey, EncryptionPublicKey: d.EncryptionPublicKey,
		LastSeenUnixMS: d.LastSeenUnixMS,
	}
}

func fromDeviceRow(r store.DeviceRow) Device {
	return Device{
		ID: r.ID, AccountID: r.AccountID, Role: r.Role, Status: r.Status,
		DisplayName: r.DisplayName, Platform: r.Platform,
		IdentityPublicKey: r.IdentityPublicKey, EncryptionPublicKey: r.EncryptionPublicKey,
		LastSeenUnixMS: r.LastSeenUnixMS,
	}
}

func toPairingRow(p PairingRequest) store.PairingRow {
	return store.PairingRow{
		ID: p.ID, AccountID: p.AccountID, Role: p.Role, Status: p.Status,
		DisplayName: p.DisplayName, IdentityPublicKey: p.IdentityPublicKey,
		EncryptionPublicKey: p.EncryptionPublicKey, Platform: p.Platform, ExpiresAt: p.ExpiresAt,
	}
}
