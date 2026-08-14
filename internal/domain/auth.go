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

// Register 创建账号（单租户自托管的首个账号 bootstrap 使用，不开放公开注册）。
func (s *AuthService) Register(ctx context.Context, email, password string) (string, error) {
	if _, err := s.repo.AccountByEmail(ctx, email); err == nil {
		return "", ErrAccountExists
	} else if !errors.Is(err, sql.ErrNoRows) {
		return "", err
	}
	accountID := id.New("acct")
	err := s.repo.CreateAccount(ctx, accountID, email, authz.HashPassword(password), s.now())
	if err != nil {
		return "", err
	}
	return accountID, nil
}

// Login 校验密码并签发 access + refresh 令牌对。
func (s *AuthService) Login(ctx context.Context, email, password, deviceID, role string) (TokenPair, error) {
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
	return s.issuePair(ctx, acct.ID, deviceID, role)
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
	// 恒定时间比较当前 secret 哈希；不匹配即 reuse。
	if subtle.ConstantTimeCompare([]byte(tf.RefreshHash), []byte(authz.HashToken(secret))) != 1 {
		_ = s.repo.RevokeTokenFamily(ctx, familyID)
		_ = s.repo.AppendAudit(ctx, tf.AccountID, "token.reuse_detected", `{}`)
		return TokenPair{}, ErrTokenReused
	}
	return s.rotate(ctx, tf)
}

// Logout 撤销刷新 family，使旧 refresh 立即失效。
func (s *AuthService) Logout(ctx context.Context, refreshToken string) error {
	familyID, _, ok := splitRefreshToken(refreshToken)
	if !ok {
		return nil
	}
	return s.repo.RevokeTokenFamily(ctx, familyID)
}

func (s *AuthService) issuePair(ctx context.Context, accountID, deviceID, role string) (TokenPair, error) {
	familyID := id.New("tf")
	secret := authz.RandomToken()
	refresh := familyID + "." + secret
	if err := s.repo.CreateTokenFamily(ctx, store.TokenFamilyRow{
		ID: familyID, AccountID: accountID, DeviceID: deviceID,
		RefreshHash: authz.HashToken(secret), CreatedAt: s.now(),
	}); err != nil {
		return TokenPair{}, err
	}
	return s.persistAccess(ctx, accountID, deviceID, role, refresh)
}

func (s *AuthService) rotate(ctx context.Context, tf store.TokenFamilyRow) (TokenPair, error) {
	secret := authz.RandomToken()
	refresh := tf.ID + "." + secret
	if err := s.repo.UpdateTokenFamilyRefreshHash(ctx, tf.ID, authz.HashToken(secret)); err != nil {
		return TokenPair{}, err
	}
	return s.persistAccess(ctx, tf.AccountID, tf.DeviceID, "", refresh)
}

// persistAccess 写 access token 并返回完整令牌对。role 为空时沿用 family 所属设备的角色。
func (s *AuthService) persistAccess(ctx context.Context, accountID, deviceID, role, refresh string) (TokenPair, error) {
	if role == "" {
		dev, err := s.repo.DeviceByID(ctx, deviceID)
		if err == nil {
			role = dev.Role
		} else {
			role = RoleWeb
		}
	}
	access := authz.RandomToken()
	now := s.now()
	if err := s.repo.PutAccessToken(ctx, store.AccessTokenRow{
		Token: access, AccountID: accountID, DeviceID: deviceID,
		Role: role, ExpiresAt: now.Add(authz.AccessTTL),
	}); err != nil {
		return TokenPair{}, err
	}
	return TokenPair{
		AccountID:    accountID,
		AccessToken:  access,
		RefreshToken: refresh,
		AccessTTL:    authz.AccessTTL,
		RefreshTTL:   authz.RefreshTTL,
	}, nil
}

func splitRefreshToken(token string) (familyID, secret string, ok bool) {
	i := strings.IndexByte(token, '.')
	if i <= 0 || i == len(token)-1 {
		return "", "", false
	}
	return token[:i], token[i+1:], true
}
