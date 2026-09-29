package domain

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"database/sql"
	"errors"
	"fmt"
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
	// OwnerPairingEnabled 是 owner 配对加入的总开关（v0.10.0，ADR-017；
	// env AGENT_SESSIONS_OWNER_PAIRING，默认 off）。关闭时创建端点返回稳定错误。
	OwnerPairingEnabled bool
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

// CompleteOwnerBootstrap 仅允许当前初始 owner 写入一次设备公钥。
// 注册阶段创建的是无密钥的本地 bootstrap 记录；完成后不允许通过该接口换钥。
func (s *PairingService) CompleteOwnerBootstrap(ctx context.Context, owner AuthSubject, d Device) (Device, error) {
	if !owner.IsOwner() || owner.DeviceID == "" {
		return Device{}, ErrOwnerRequired
	}
	if err := validateDeviceKeys(d); err != nil {
		return Device{}, err
	}
	current, err := s.repo.DeviceByID(ctx, owner.DeviceID)
	if err != nil {
		return Device{}, ErrPairingNotFound
	}
	if current.AccountID != owner.AccountID || current.Role != RoleAndroidOwner || current.Status != DeviceActive {
		return Device{}, ErrOwnerRequired
	}
	// 同一把公钥的重试安全返回已有设备；不同公钥必须走显式密钥轮换流程。
	if current.IdentityPublicKey != "" || current.EncryptionPublicKey != "" {
		if current.IdentityPublicKey == d.IdentityPublicKey && current.EncryptionPublicKey == d.EncryptionPublicKey {
			return fromDeviceRow(current), nil
		}
		return Device{}, ErrBootstrapCompleted
	}
	updated, err := s.repo.UpdateBootstrapDevice(ctx, store.DeviceRow{
		ID: owner.DeviceID, AccountID: owner.AccountID, Role: RoleAndroidOwner, Status: DeviceActive,
		DisplayName: d.DisplayName, Platform: d.Platform,
		IdentityPublicKey: d.IdentityPublicKey, EncryptionPublicKey: d.EncryptionPublicKey,
	})
	if err != nil {
		return Device{}, err
	}
	if !updated {
		return Device{}, ErrBootstrapCompleted
	}
	_ = s.repo.AppendAudit(ctx, owner.AccountID, "device.bootstrap_completed", `{"device_id":"`+owner.DeviceID+`"}`)
	return s.deviceByID(ctx, owner.DeviceID)
}

// CreatePairingRequest 由待配对设备发起，返回请求 ID（供 QR/短码展示）。
func (s *PairingService) CreatePairingRequest(ctx context.Context, accountID string, d Device) (PairingRequest, error) {
	if !isPairableRole(d.Role) || validateDeviceKeys(d) != nil {
		return PairingRequest{}, ErrPairingAlreadyHandled
	}
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
// 条件状态更新先原子认领 pending 请求，避免两个 owner 重试并发创建两台同钥设备。
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
	if p.AccountID != owner.AccountID {
		return Device{}, ErrOwnerRequired
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
		claimed, err := tx.SetPairingStatusIfCurrent(ctx, pairingID, PairingPending, PairingApproved)
		if err != nil {
			return err
		}
		if !claimed {
			return ErrPairingAlreadyHandled
		}
		// 同 identity 已有设备则复用（OWN-06 云端实证：同机撤销后重新配对
		// 会以同一 identity 公钥再入，直接 CreateDevice 撞
		// devices_account_identity_public_key 唯一索引 → 500）。批准是现役
		// owner 的显式信任决策：active 幂等返回；revoked 原地复激活并撤销其
		// 旧令牌族（设备行/审计/投影保留）。均为同事务，与状态认领原子。
		reused := false
		rows, derr := tx.ListDevices(ctx, p.AccountID)
		if derr != nil {
			return derr
		}
		for _, row := range rows {
			if row.IdentityPublicKey != p.IdentityPublicKey {
				continue
			}
			if row.Status == DeviceActive {
				dev = fromDeviceRow(row)
			} else {
				if err := tx.ReactivateDevice(ctx, row.ID, dev.DisplayName, dev.Platform); err != nil {
					return err
				}
				if err := tx.RevokeTokenFamiliesByDevice(ctx, row.ID); err != nil {
					return err
				}
				row.Status = DeviceActive
				row.DisplayName = dev.DisplayName
				row.Platform = dev.Platform
				dev = fromDeviceRow(row)
			}
			reused = true
			break
		}
		if !reused {
			if err := tx.CreateDevice(ctx, toDeviceRow(dev)); err != nil {
				return err
			}
		}
		// owner 配对（ADR-017）：批准即签发令牌对写入 claim 列，新设备凭
		// pairing_id 领取；不撤销任何既有设备（多 owner 并存的硬不变量）。
		if p.Role == RoleAndroidOwner {
			return s.approveOwnerPairingInTx(ctx, tx, p.AccountID, pairingID, dev.ID)
		}
		return nil
	})
	if errors.Is(err, ErrPairingAlreadyHandled) {
		// 并发批准的输家读取赢家提交的设备，维持重复批准的幂等响应。
		latest, latestErr := s.repo.PairingByID(ctx, pairingID)
		if latestErr == nil && latest.Status == PairingApproved {
			return s.deviceByKeys(ctx, latest.AccountID, latest.IdentityPublicKey)
		}
	}
	if err != nil {
		return Device{}, err
	}
	_ = s.repo.AppendAudit(ctx, owner.AccountID, "device.approved", `{"device_id":"`+dev.ID+`"}`)
	return dev, nil
}

// GetPairing 仅向当前 Android owner 返回配对请求。
// 请求中含待配对设备的公开身份/加密密钥，普通同账号只读 token 不能读取。
func (s *PairingService) GetPairing(ctx context.Context, owner AuthSubject, pairingID string) (PairingRequest, error) {
	if !owner.IsOwner() {
		return PairingRequest{}, ErrOwnerRequired
	}
	p, err := s.repo.PairingByID(ctx, pairingID)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return PairingRequest{}, ErrPairingNotFound
		}
		return PairingRequest{}, err
	}
	if p.AccountID != owner.AccountID {
		return PairingRequest{}, ErrOwnerRequired
	}
	return fromPairingRow(p), nil
}

// CancelPairing 仅允许 owner 取消待处理请求，防止同账号只读 token 干扰设备配对。
func (s *PairingService) CancelPairing(ctx context.Context, owner AuthSubject, pairingID string) error {
	if !owner.IsOwner() {
		return ErrOwnerRequired
	}
	p, err := s.repo.PairingByID(ctx, pairingID)
	if err != nil {
		return ErrPairingNotFound
	}
	if p.AccountID != owner.AccountID {
		return ErrOwnerRequired
	}
	if p.Status != PairingPending {
		return ErrPairingAlreadyHandled
	}
	// 与批准使用同一条 pending 条件转移，取消/批准并发时只有一个操作能获胜。
	cancelled, err := s.repo.SetPairingStatusIfCurrent(ctx, pairingID, PairingPending, PairingCancelled)
	if err != nil {
		return err
	}
	if !cancelled {
		return ErrPairingAlreadyHandled
	}
	return nil
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
	if dev.ID == owner.DeviceID && dev.Role == RoleAndroidOwner {
		// 当前 owner 撤销自身会丢失唯一 key-admin，必须显式走恢复码链路。
		return ErrLastOwner
	}
	if dev.Role == RoleAndroidOwner && dev.Status == DeviceActive {
		devices, listErr := s.repo.ListDevices(ctx, owner.AccountID)
		if listErr != nil {
			return listErr
		}
		activeOwners := 0
		for _, candidate := range devices {
			if candidate.Role == RoleAndroidOwner && candidate.Status == DeviceActive {
				activeOwners++
			}
		}
		if activeOwners <= 1 {
			return ErrLastOwner
		}
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
	sender, err := s.repo.DeviceByID(ctx, senderDeviceID)
	if err != nil {
		return ErrPairingNotFound
	}
	if sender.Status != DeviceActive {
		return ErrDeviceRevoked
	}
	dev, err := s.repo.DeviceByID(ctx, recipientDeviceID)
	if err != nil {
		return ErrPairingNotFound
	}
	if dev.AccountID != sender.AccountID {
		return ErrOwnerRequired
	}
	if dev.Status != DeviceActive {
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
	_ = s.repo.AppendAudit(ctx, accountID, "recovery_code.generated", `{"delivery":"caller_once"}`)
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
	if subtle.ConstantTimeCompare([]byte(authz.HashToken(code)), []byte(rc.CodeHash)) == 1 {
		// 成功：重置失败计数。
		_ = s.repo.UpsertRecoveryCode(ctx, store.RecoveryRow{AccountID: accountID, CodeHash: rc.CodeHash, CreatedAt: s.now()})
		return nil
	}
	if err := s.recordRecoveryFailure(ctx, rc); err != nil {
		return err
	}
	if rc.FailedAttempts+1 >= recoveryMaxAttempts {
		return ErrRecoveryLocked
	}
	return ErrRecoveryInvalid
}

// recoveryRestoreOutcome 把可提交的恢复失败（计数/冷却）和需要回滚的持久化失败分开表达。
// businessErr 不直接从 WithTx 返回，否则已更新的失败计数会被 SQLite 回滚。
type recoveryRestoreOutcome struct {
	device      Device
	businessErr error
}

// RestoreOwnerWithRecoveryCode 用恢复码创建新的 Android owner，并原子消费该恢复码。
// 单独调用时它保证设备变更一致；完整 HTTP 恢复另由 AuthService 在同一事务内签发 token。
func (s *PairingService) RestoreOwnerWithRecoveryCode(ctx context.Context, email, code string, d Device) (Device, error) {
	if err := validateDeviceKeys(d); err != nil {
		return Device{}, err
	}
	var outcome recoveryRestoreOutcome
	err := s.repo.WithTx(ctx, func(ctx context.Context, tx store.Repository) error {
		var restoreErr error
		outcome, restoreErr = s.restoreOwnerInTx(ctx, tx, email, code, d)
		return restoreErr
	})
	if err != nil {
		return Device{}, err
	}
	if outcome.businessErr != nil {
		return Device{}, outcome.businessErr
	}
	return outcome.device, nil
}

// restoreOwnerInTx 仅使用调用方提供的事务 repository，供独立恢复和“恢复+token 签发”复合用例复用。
// 身份与加密公钥只进入设备表，审计记录仅保存设备 ID 等白名单元数据。
func (s *PairingService) restoreOwnerInTx(ctx context.Context, repo store.Repository, email, code string, d Device) (recoveryRestoreOutcome, error) {
	account, err := repo.AccountByEmail(ctx, email)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return recoveryRestoreOutcome{businessErr: ErrRecoveryInvalid}, nil
		}
		return recoveryRestoreOutcome{}, err
	}
	rc, err := repo.RecoveryByAccount(ctx, account.ID)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return recoveryRestoreOutcome{businessErr: ErrRecoveryInvalid}, nil
		}
		return recoveryRestoreOutcome{}, err
	}
	return s.restoreOwnerForRecoveryRowInTx(ctx, repo, rc, code, true, d)
}

func (s *PairingService) restoreOwnerByCodeHashInTx(ctx context.Context, repo store.Repository, code string, d Device) (recoveryRestoreOutcome, error) {
	rc, err := repo.RecoveryByCodeHash(ctx, authz.HashToken(code))
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return recoveryRestoreOutcome{businessErr: ErrRecoveryInvalid}, nil
		}
		return recoveryRestoreOutcome{}, err
	}
	return s.restoreOwnerForRecoveryRowInTx(ctx, repo, rc, code, false, d)
}

func (s *PairingService) restoreOwnerForRecoveryRowInTx(ctx context.Context, repo store.Repository, rc store.RecoveryRow, code string, checkCode bool, d Device) (recoveryRestoreOutcome, error) {
	if s.now().Before(rc.LockedUntil) {
		return recoveryRestoreOutcome{businessErr: ErrRecoveryLocked}, nil
	}
	// 服务端同样拒绝复用任何历史身份公钥；客户端的新恢复候选只是第一道防线。
	// 先检查再消费恢复码，避免错误请求把旧 Android 全部撤销后才暴露唯一键冲突。
	devices, err := repo.ListDevices(ctx, rc.AccountID)
	if err != nil {
		return recoveryRestoreOutcome{}, err
	}
	for _, existing := range devices {
		if existing.IdentityPublicKey == d.IdentityPublicKey {
			return recoveryRestoreOutcome{businessErr: ErrPairingAlreadyHandled}, nil
		}
	}
	if checkCode && subtle.ConstantTimeCompare([]byte(authz.HashToken(code)), []byte(rc.CodeHash)) != 1 {
		if err := s.recordRecoveryFailureWithRepo(ctx, repo, rc); err != nil {
			return recoveryRestoreOutcome{}, err
		}
		if rc.FailedAttempts+1 >= recoveryMaxAttempts {
			return recoveryRestoreOutcome{businessErr: ErrRecoveryLocked}, nil
		}
		return recoveryRestoreOutcome{businessErr: ErrRecoveryInvalid}, nil
	}
	consumed, err := repo.ConsumeRecoveryCode(ctx, rc.AccountID, authz.HashToken(code), s.now())
	if err != nil {
		return recoveryRestoreOutcome{}, err
	}
	if !consumed {
		return recoveryRestoreOutcome{businessErr: ErrRecoveryInvalid}, nil
	}

	dev := Device{
		ID: id.New("dev"), AccountID: rc.AccountID, Role: RoleAndroidOwner, Status: DeviceActive,
		DisplayName: d.DisplayName, Platform: d.Platform,
		IdentityPublicKey: d.IdentityPublicKey, EncryptionPublicKey: d.EncryptionPublicKey,
	}
	// 恢复码恢复的是唯一 Android key-admin：先撤销旧 Android 写设备。
	// 撤销范围限移动平台（android/ios）：本地开发拓扑的桌面 owner
	// （restart.sh bootstrap，platform=local）与手机共存同一账号，若被一并撤销，
	// 下次 `restart.sh start` 缓存刷新必然 401，自愈逻辑会重置 Relay DB，手机
	// 令牌随之失效——每次重启都强迫恢复码重新接管（2026-09-21 用户报告）。
	// 桌面 owner 私钥仅存本机 0600 state 目录，保留它不扩大移动端风险面。
	// 未知/空 platform 的历史设备保持 fail-safe：仍按 Android 写设备撤销。
	// 旧 bearer/refresh 会在 RequireAuth/Refresh 时按设备状态拒绝，历史密文与 key-wrap 不改写。
	for _, existing := range devices {
		if existing.Status != DeviceActive || (existing.Role != RoleAndroidOwner && existing.Role != RoleAndroid) {
			continue
		}
		if existing.Platform == "local" {
			continue
		}
		if err := repo.SetDeviceStatus(ctx, existing.ID, DeviceRevoked); err != nil {
			return recoveryRestoreOutcome{}, err
		}
	}
	if err := repo.CreateDevice(ctx, toDeviceRow(dev)); err != nil {
		return recoveryRestoreOutcome{}, err
	}
	if err := repo.AppendAudit(ctx, rc.AccountID, "recovery_code.restored_owner", `{"device_id":"`+dev.ID+`"}`); err != nil {
		return recoveryRestoreOutcome{}, err
	}
	return recoveryRestoreOutcome{device: dev}, nil
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

func (s *PairingService) deviceByID(ctx context.Context, deviceID string) (Device, error) {
	row, err := s.repo.DeviceByID(ctx, deviceID)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return Device{}, ErrPairingNotFound
		}
		return Device{}, err
	}
	return fromDeviceRow(row), nil
}

func (s *PairingService) recordRecoveryFailure(ctx context.Context, rc store.RecoveryRow) error {
	return s.recordRecoveryFailureWithRepo(ctx, s.repo, rc)
}

func (s *PairingService) recordRecoveryFailureWithRepo(ctx context.Context, repo store.Repository, rc store.RecoveryRow) error {
	failed := rc.FailedAttempts + 1
	locked := time.Time{}
	if failed >= recoveryMaxAttempts {
		locked = s.now().Add(recoveryCooldown)
	}
	return repo.UpsertRecoveryCode(ctx, store.RecoveryRow{
		AccountID: rc.AccountID, CodeHash: rc.CodeHash,
		FailedAttempts: failed, LockedUntil: locked, CreatedAt: rc.CreatedAt,
	})
}

func validateDeviceKeys(d Device) error {
	if d.DisplayName == "" || d.IdentityPublicKey == "" || d.EncryptionPublicKey == "" {
		return ErrPairingAlreadyHandled
	}
	return nil
}

func isPairableRole(role string) bool {
	switch role {
	case RoleAndroid, RoleTerminal, RoleWeb:
		return true
	default:
		return false
	}
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

// PairingRequestFromRow 供传输层把配对行投影为域对象（owner 配对视图需要
// 附加比对码等派生字段）。
func PairingRequestFromRow(r store.PairingRow) PairingRequest {
	return fromPairingRow(r)
}

func fromPairingRow(r store.PairingRow) PairingRequest {
	return PairingRequest{
		ID: r.ID, AccountID: r.AccountID, Role: r.Role, Status: r.Status,
		DisplayName: r.DisplayName, IdentityPublicKey: r.IdentityPublicKey,
		EncryptionPublicKey: r.EncryptionPublicKey, Platform: r.Platform, ExpiresAt: r.ExpiresAt,
	}
}

// ── v0.10.0（ADR-017）：owner 配对加入 ─────────────────────────────────
// 新 Android 设备以第二个 active owner 加入，既有设备零变化（硬不变量）。
// 与恢复码接管的互斥替换语义并存、互不替代。

// OwnerPairingCompareCode 由新设备公钥材料派生 6 位数字比对码。
// 双端可独立计算（新设备持自己的公钥；owner 从配对行读公钥），
// 用于人工核对「批准的确实是眼前的设备」。
func OwnerPairingCompareCode(identityPublicKey, encryptionPublicKey string) string {
	sum := sha256.Sum256([]byte("owner-pairing:" + identityPublicKey + ":" + encryptionPublicKey))
	n := (uint64(sum[0])<<56 | uint64(sum[1])<<48 | uint64(sum[2])<<40 | uint64(sum[3])<<32 |
		uint64(sum[4])<<24 | uint64(sum[5])<<16 | uint64(sum[6])<<8 | uint64(sum[7])) % 1000000
	return fmt.Sprintf("%06d", n)
}

// CreateOwnerPairingRequest 创建 owner 配对请求（ADR-017）。
// 前置：总开关开启（OwnerPairingEnabled，env AGENT_SESSIONS_OWNER_PAIRING）；
// 单账号同时最多 1 个 pending owner 请求；TTL 10 分钟；审计 pairing.created。
// 与既有 terminal 配对共用存储与批准/轮询端点，role 区分语义。
func (s *PairingService) CreateOwnerPairingRequest(ctx context.Context, d Device) (PairingRequest, string, error) {
	if !s.OwnerPairingEnabled {
		return PairingRequest{}, "", ErrOwnerPairingDisabled
	}
	if d.Role != RoleAndroidOwner || validateDeviceKeys(d) != nil || d.DisplayName == "" {
		return PairingRequest{}, "", ErrPairingAlreadyHandled
	}
	pending, err := s.repo.CountPendingOwnerPairings(ctx, d.AccountID)
	if err != nil {
		return PairingRequest{}, "", err
	}
	if pending > 0 {
		return PairingRequest{}, "", ErrOwnerPairingPending
	}
	p := PairingRequest{
		ID:                  id.New("pair"),
		AccountID:           d.AccountID,
		Role:                RoleAndroidOwner,
		Status:              PairingPending,
		DisplayName:         d.DisplayName,
		IdentityPublicKey:   d.IdentityPublicKey,
		EncryptionPublicKey: d.EncryptionPublicKey,
		Platform:            d.Platform,
		ExpiresAt:           s.now().Add(10 * time.Minute),
	}
	if err := s.repo.CreatePairingRequest(ctx, toPairingRow(p)); err != nil {
		return PairingRequest{}, "", err
	}
	_ = s.repo.AppendAudit(ctx, d.AccountID, "pairing.created", `{"role":"android_owner"}`)
	return p, OwnerPairingCompareCode(d.IdentityPublicKey, d.EncryptionPublicKey), nil
}

// OwnerPairingStatus 新设备轮询配对状态；批准后返回待领取的令牌对。
// 令牌在批准事务内签发并存于配对行（claim 列），重复轮询返回同一对。
func (s *PairingService) OwnerPairingStatus(ctx context.Context, pairingID string) (PairingRequest, *TokenPair, error) {
	p, err := s.repo.PairingByID(ctx, pairingID)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return PairingRequest{}, nil, ErrPairingNotFound
		}
		return PairingRequest{}, nil, err
	}
	if p.Role != RoleAndroidOwner {
		return PairingRequest{}, nil, ErrPairingNotFound
	}
	if p.Status == PairingPending && s.now().After(p.ExpiresAt) {
		_ = s.repo.SetPairingStatus(ctx, pairingID, PairingExpired)
		p.Status = PairingExpired
	}
	if p.Status != PairingApproved {
		return fromPairingRow(p), nil, nil
	}
	if p.ClaimAccessToken == "" || p.ClaimRefreshToken == "" {
		return fromPairingRow(p), nil, nil
	}
	tokens := &TokenPair{
		AccountID:    p.AccountID,
		DeviceID:     p.ClaimDeviceID,
		AccessToken:  p.ClaimAccessToken,
		RefreshToken: p.ClaimRefreshToken,
	}
	return fromPairingRow(p), tokens, nil
}

// approveOwnerPairingInTx 在批准事务内为 owner 角色请求签发令牌对并写入
// claim 列（与 terminal 路径的区别：owner 设备的令牌必须可在批准后立即
// 被 pairing_id 领取——新设备此时没有任何其他凭据）。
func (s *PairingService) approveOwnerPairingInTx(ctx context.Context, tx store.Repository, accountID, pairingID, deviceID string) error {
	auth := &AuthService{repo: tx, now: s.now}
	tokens, err := auth.issuePairWithRepo(ctx, tx, accountID, deviceID, RoleAndroidOwner)
	if err != nil {
		return err
	}
	return tx.UpdatePairingClaim(ctx, pairingID, tokens.AccessToken, tokens.RefreshToken, deviceID)
}
