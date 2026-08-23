package domain

import (
	"context"
	"crypto/subtle"
	"database/sql"
	"errors"
	"strings"
	"time"

	"github.com/yubi233/agent-sessions/internal/authz"
	"github.com/yubi233/agent-sessions/internal/id"
	"github.com/yubi233/agent-sessions/internal/store"
)

// AuthService 处理账号登录、刷新令牌轮换与注销。
// 密码只校验账号，不派生正文密钥；refresh 只存哈希并轮换，reuse 触发撤销 family。
type AuthService struct {
	repo store.Repository
	now  func() time.Time
}

// NewAuthService 构造认证服务。
func NewAuthService(repo store.Repository) *AuthService {
	return &AuthService{repo: repo, now: time.Now}
}

// Register 只创建单租户实例的首个账号，后续设备必须走 owner 配对或恢复码。
// 检查和插入在同一 SQLite 事务内，避免并发首注册绕过 bootstrap 门禁。
func (s *AuthService) Register(ctx context.Context, email, password string) (string, error) {
	accountID := id.New("acct")
	err := s.repo.WithTx(ctx, func(ctx context.Context, tx store.Repository) error {
		return s.registerAccountInRepo(ctx, tx, accountID, email, password)
	})
	if err != nil {
		return "", err
	}
	return accountID, nil
}

// RegisterInitialOwner 把首账号、无公钥 owner bootstrap 记录和首个设备令牌放在同一事务。
// 任何一步（尤其是 token 落库）失败都会回滚，避免实例被锁在“已注册但客户端拿不到首个 owner 会话”的中间状态。
func (s *AuthService) RegisterInitialOwner(ctx context.Context, email, password string, bootstrap Device) (Device, TokenPair, error) {
	accountID := id.New("acct")
	owner := Device{
		ID:          id.New("dev"),
		AccountID:   accountID,
		Role:        RoleAndroidOwner,
		Status:      DeviceActive,
		DisplayName: bootstrap.DisplayName,
		Platform:    bootstrap.Platform,
	}
	if owner.DisplayName == "" || owner.Platform == "" {
		return Device{}, TokenPair{}, ErrPairingAlreadyHandled
	}

	var tokens TokenPair
	err := s.repo.WithTx(ctx, func(ctx context.Context, tx store.Repository) error {
		if err := s.registerAccountInRepo(ctx, tx, accountID, email, password); err != nil {
			return err
		}
		if err := tx.CreateDevice(ctx, toDeviceRow(owner)); err != nil {
			return err
		}
		issued, err := s.issuePairWithRepo(ctx, tx, accountID, owner.ID, owner.Role)
		if err != nil {
			return err
		}
		tokens = issued
		return tx.AppendAudit(ctx, accountID, "device.bootstrap_owner", `{"role":"android_owner"}`)
	})
	if err != nil {
		return Device{}, TokenPair{}, err
	}
	return owner, tokens, nil
}

// BootstrapInitialOwnerDevice 是 Android/Happy 主路径：首台移动设备用本机公钥直接初始化 owner，
// 不要求用户先创建账号密码。账号仍作为服务端租户边界存在，但不暴露为 Android 登录墙。
func (s *AuthService) BootstrapInitialOwnerDevice(ctx context.Context, bootstrap Device) (Device, TokenPair, error) {
	if err := validateDeviceKeys(bootstrap); err != nil {
		return Device{}, TokenPair{}, err
	}
	accountID := id.New("acct")
	owner := Device{
		ID:                  id.New("dev"),
		AccountID:           accountID,
		Role:                RoleAndroidOwner,
		Status:              DeviceActive,
		DisplayName:         bootstrap.DisplayName,
		Platform:            bootstrap.Platform,
		IdentityPublicKey:   bootstrap.IdentityPublicKey,
		EncryptionPublicKey: bootstrap.EncryptionPublicKey,
	}
	if owner.DisplayName == "" || owner.Platform == "" {
		return Device{}, TokenPair{}, ErrPairingAlreadyHandled
	}

	var tokens TokenPair
	err := s.repo.WithTx(ctx, func(ctx context.Context, tx store.Repository) error {
		count, err := tx.CountAccounts(ctx)
		if err != nil {
			return err
		}
		if count > 0 {
			return ErrRegistrationClosed
		}
		// 不可登录的内部账号：用于保持既有单租户授权/审计边界，不作为移动端凭据。
		if err := tx.CreateAccount(
			ctx,
			accountID,
			accountID+"@local.agent-sessions.invalid",
			authz.HashPassword(authz.RandomToken()),
			s.now(),
		); err != nil {
			return err
		}
		if err := tx.CreateDevice(ctx, toDeviceRow(owner)); err != nil {
			return err
		}
		issued, err := s.issuePairWithRepo(ctx, tx, accountID, owner.ID, owner.Role)
		if err != nil {
			return err
		}
		tokens = issued
		return tx.AppendAudit(ctx, accountID, "device.bootstrap_owner", `{"role":"android_owner","mode":"device"}`)
	})
	if err != nil {
		return Device{}, TokenPair{}, err
	}
	return owner, tokens, nil
}

// registerAccountInRepo 是首账号门禁的事务内实现，供简单注册和完整 owner 注册共用。
func (s *AuthService) registerAccountInRepo(ctx context.Context, repo store.Repository, accountID, email, password string) error {
	count, err := repo.CountAccounts(ctx)
	if err != nil {
		return err
	}
	if count > 0 {
		if _, err := repo.AccountByEmail(ctx, email); err == nil {
			return ErrAccountExists
		} else if !errors.Is(err, sql.ErrNoRows) {
			return err
		}
		return ErrRegistrationClosed
	}
	return repo.CreateAccount(ctx, accountID, email, authz.HashPassword(password), s.now())
}

// Login 校验密码并签发只读 access + refresh 令牌对。
// Android 写 token 只能由注册、恢复码或已有 refresh 轮换取得；密码和可枚举的 device_id
// 都不能证明持有 Keystore 中的设备私钥，因此不能作为恢复 Android 写身份的依据。
func (s *AuthService) Login(ctx context.Context, email, password, deviceID, requestedRole string) (TokenPair, error) {
	acct, err := s.repo.AccountByEmail(ctx, email)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return TokenPair{}, ErrInvalidCredentials
		}
		return TokenPair{}, err
	}
	if !authz.VerifyPassword(acct.PasswordHash, password) {
		return TokenPair{}, ErrInvalidCredentials
	}

	// deviceID 只在旧客户端请求中被忽略，绝不用于提升权限或恢复 owner token。
	_ = deviceID
	// Web/Admin 只读登录不绑定可写设备，不能藉由请求字段取得 owner 权限。
	switch requestedRole {
	case "", RoleWeb, RoleAdmin:
		role := requestedRole
		if role == "" {
			role = RoleWeb
		}
		return s.issuePair(ctx, acct.ID, "", role)
	default:
		// 不接受客户端直接声明 android/android_owner、terminal 或任意未知角色。
		return TokenPair{}, ErrUnauthenticated
	}
}

// Refresh 轮换刷新令牌；检测 reuse 时撤销整个 family。
// 令牌格式 familyID.secret，familyID 用于定位 family，secret 参与哈希比对。
func (s *AuthService) Refresh(ctx context.Context, refreshToken string) (TokenPair, error) {
	familyID, secret, ok := splitRefreshToken(refreshToken)
	if !ok {
		return TokenPair{}, ErrUnauthenticated
	}
	tf, err := s.repo.TokenFamilyByID(ctx, familyID)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return TokenPair{}, ErrUnauthenticated
		}
		return TokenPair{}, err
	}
	if tf.Revoked {
		return TokenPair{}, ErrUnauthenticated
	}
	if !tf.CreatedAt.Add(authz.RefreshTTL).After(s.now()) {
		// 过期 family 不能继续轮换；立即撤销避免同一条过期记录被反复探测。
		_ = s.repo.RevokeTokenFamily(ctx, tf.ID)
		return TokenPair{}, ErrUnauthenticated
	}
	if tf.DeviceID != "" {
		if _, err := s.activeDevice(ctx, tf.AccountID, tf.DeviceID); err != nil {
			_ = s.repo.RevokeTokenFamily(ctx, tf.ID)
			return TokenPair{}, err
		}
	}
	// 恒定时间比较当前 secret 哈希；不匹配即 reuse。
	currentHash := authz.HashToken(secret)
	if subtle.ConstantTimeCompare([]byte(tf.RefreshHash), []byte(currentHash)) != 1 {
		_ = s.repo.RevokeTokenFamily(ctx, familyID)
		_ = s.repo.AppendAudit(ctx, tf.AccountID, "token.reuse_detected", `{}`)
		return TokenPair{}, ErrTokenReused
	}
	return s.rotate(ctx, tf, currentHash)
}

// IssueForDevice 在恢复码成功后为服务端刚创建的设备签发令牌。
// 该方法重新校验设备归属和状态，不能通过调用方传入角色提升权限。
func (s *AuthService) IssueForDevice(ctx context.Context, accountID, deviceID string) (TokenPair, error) {
	dev, err := s.activeDevice(ctx, accountID, deviceID)
	if err != nil {
		return TokenPair{}, err
	}
	return s.issuePair(ctx, accountID, dev.ID, dev.Role)
}

// RestoreOwnerWithRecoveryCode 将恢复码消费、旧 Android 撤销、新 owner 创建和 token 签发作为一个提交单元。
// 恢复码校验失败仍提交失败次数；其他错误（例如 token 持久化失败）必须回滚所有安全状态变更。
func (s *AuthService) RestoreOwnerWithRecoveryCode(ctx context.Context, pairing *PairingService, email, code string, d Device) (Device, TokenPair, error) {
	if err := validateDeviceKeys(d); err != nil {
		return Device{}, TokenPair{}, err
	}

	var outcome recoveryRestoreOutcome
	var tokens TokenPair
	err := s.repo.WithTx(ctx, func(ctx context.Context, tx store.Repository) error {
		var restoreErr error
		if strings.TrimSpace(email) == "" {
			outcome, restoreErr = pairing.restoreOwnerByCodeHashInTx(ctx, tx, code, d)
		} else {
			outcome, restoreErr = pairing.restoreOwnerInTx(ctx, tx, email, code, d)
		}
		if restoreErr != nil {
			return restoreErr
		}
		if outcome.businessErr != nil {
			// 返回 nil 以提交失败计数/冷却窗口；具体业务错误在事务提交后返回给调用方。
			return nil
		}
		issued, err := s.issuePairWithRepo(ctx, tx, outcome.device.AccountID, outcome.device.ID, outcome.device.Role)
		if err != nil {
			return err
		}
		tokens = issued
		return nil
	})
	if err != nil {
		return Device{}, TokenPair{}, err
	}
	if outcome.businessErr != nil {
		return Device{}, TokenPair{}, outcome.businessErr
	}
	return outcome.device, tokens, nil
}

// Logout 仅撤销当前认证账号持有的精确 refresh，不能只凭 family ID 伤害其他账号会话。
func (s *AuthService) Logout(ctx context.Context, accountID, refreshToken string) error {
	familyID, _, ok := splitRefreshToken(refreshToken)
	if !ok {
		return ErrUnauthenticated
	}
	_, secret, _ := splitRefreshToken(refreshToken)
	revoked, err := s.repo.RevokeTokenFamilyIfCurrent(ctx, familyID, accountID, authz.HashToken(secret))
	if err != nil {
		return err
	}
	if !revoked {
		return ErrUnauthenticated
	}
	return nil
}

func (s *AuthService) issuePair(ctx context.Context, accountID, deviceID, role string) (TokenPair, error) {
	return s.issuePairWithRepo(ctx, s.repo, accountID, deviceID, role)
}

// issuePairWithRepo 允许复合用例在同一个 SQLite 事务里同时写 refresh family 和 access token。
func (s *AuthService) issuePairWithRepo(ctx context.Context, repo store.Repository, accountID, deviceID, role string) (TokenPair, error) {
	familyID := id.New("tf")
	secret := authz.RandomToken()
	refresh := familyID + "." + secret
	if err := repo.CreateTokenFamily(ctx, store.TokenFamilyRow{
		ID: familyID, AccountID: accountID, DeviceID: deviceID,
		Role: role, RefreshHash: authz.HashToken(secret), CreatedAt: s.now(),
	}); err != nil {
		return TokenPair{}, err
	}
	return s.persistAccessWithRepo(ctx, repo, accountID, deviceID, role, refresh)
}

func (s *AuthService) rotate(ctx context.Context, tf store.TokenFamilyRow, currentHash string) (TokenPair, error) {
	secret := authz.RandomToken()
	refresh := tf.ID + "." + secret
	rotated, err := s.repo.RotateTokenFamilyRefreshHash(
		ctx,
		tf.ID,
		currentHash,
		authz.HashToken(secret),
		s.now().Add(-authz.RefreshTTL),
	)
	if err != nil {
		return TokenPair{}, err
	}
	if !rotated {
		// CAS 失败时重新读取分类：设备撤销/过期保持原有错误，其余均视为 refresh 重放。
		latest, readErr := s.repo.TokenFamilyByID(ctx, tf.ID)
		if readErr != nil || latest.Revoked || !latest.CreatedAt.Add(authz.RefreshTTL).After(s.now()) {
			return TokenPair{}, ErrUnauthenticated
		}
		if latest.DeviceID != "" {
			if _, deviceErr := s.activeDevice(ctx, latest.AccountID, latest.DeviceID); deviceErr != nil {
				_ = s.repo.RevokeTokenFamily(ctx, latest.ID)
				return TokenPair{}, deviceErr
			}
		}
		// 另一并发请求已轮换 hash，原 token 已经成为重放；撤销整个 family 阻断继续扩散。
		_ = s.repo.RevokeTokenFamily(ctx, latest.ID)
		_ = s.repo.AppendAudit(ctx, latest.AccountID, "token.reuse_detected", `{}`)
		return TokenPair{}, ErrTokenReused
	}
	return s.persistAccess(ctx, tf.AccountID, tf.DeviceID, tf.Role, refresh)
}

// persistAccess 写 access token 并返回完整令牌对。role 为空时沿用 family 所属设备的角色。
func (s *AuthService) persistAccess(ctx context.Context, accountID, deviceID, role, refresh string) (TokenPair, error) {
	return s.persistAccessWithRepo(ctx, s.repo, accountID, deviceID, role, refresh)
}

// persistAccessWithRepo 只使用传入 repository，避免事务内意外跳回根连接造成部分提交。
func (s *AuthService) persistAccessWithRepo(ctx context.Context, repo store.Repository, accountID, deviceID, role, refresh string) (TokenPair, error) {
	if role == "" {
		dev, err := repo.DeviceByID(ctx, deviceID)
		if err == nil {
			role = dev.Role
		} else {
			role = RoleWeb
		}
	}
	access := authz.RandomToken()
	now := s.now()
	accessTTL := authz.AccessTTLOf(role)
	if err := repo.PutAccessToken(ctx, store.AccessTokenRow{
		Token: access, AccountID: accountID, DeviceID: deviceID,
		Role: role, ExpiresAt: now.Add(accessTTL),
	}); err != nil {
		return TokenPair{}, err
	}
	return TokenPair{
		AccountID:    accountID,
		DeviceID:     deviceID,
		AccessToken:  access,
		RefreshToken: refresh,
		ExpiresIn:    int64(accessTTL.Seconds()),
		AccessTTL:    accessTTL,
		RefreshTTL:   authz.RefreshTTL,
	}, nil
}

// activeDevice 统一验证 token 绑定设备存在、属于账号且未撤销。
func (s *AuthService) activeDevice(ctx context.Context, accountID, deviceID string) (Device, error) {
	dev, err := s.repo.DeviceByID(ctx, deviceID)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return Device{}, ErrUnauthenticated
		}
		return Device{}, err
	}
	if dev.AccountID != accountID {
		return Device{}, ErrUnauthenticated
	}
	if dev.Status != DeviceActive {
		return Device{}, ErrDeviceRevoked
	}
	return fromDeviceRow(dev), nil
}

func splitRefreshToken(token string) (familyID, secret string, ok bool) {
	i := strings.IndexByte(token, '.')
	if i <= 0 || i == len(token)-1 {
		return "", "", false
	}
	return token[:i], token[i+1:], true
}
