// Package domain 是 Relay 的领域层：与传输/持久化无关的业务规则。
// Gin 只属于 httpapi，*gin.Context 不进入本包；SQL 只属于 store。
package domain

import (
	"errors"
	"time"
)

// 设备角色。会话写权限只授予 android_owner/android；设备管理只授予 android_owner。
const (
	RoleAndroidOwner = "android_owner"
	RoleAndroid      = "android"
	RoleTerminal     = "terminal"
	RoleWeb          = "web"
	RoleAdmin        = "admin"
)

// 设备状态。
const (
	DeviceActive  = "active"
	DeviceRevoked = "revoked"
)

// 配对请求状态。
const (
	PairingPending   = "pending"
	PairingApproved  = "approved"
	PairingCancelled = "cancelled"
	PairingExpired   = "expired"
)

// 领域稳定错误，映射到协议错误码（见 packages/protocol）。
var (
	ErrUnauthenticated       = errors.New("unauthenticated")
	ErrInvalidCredentials    = errors.New("invalid credentials")
	ErrDeviceRevoked         = errors.New("device revoked")
	ErrOwnerRequired         = errors.New("owner required")
	ErrTokenReused           = errors.New("token reused")
	ErrPairingExpired        = errors.New("pairing expired")
	ErrPairingNotFound       = errors.New("pairing not found")
	ErrPairingAlreadyHandled = errors.New("pairing already handled")
	ErrAccountExists         = errors.New("account exists")
	ErrRegistrationClosed    = errors.New("registration closed")
	ErrRecoveryLocked        = errors.New("recovery locked")
	ErrRecoveryInvalid       = errors.New("recovery invalid")
	ErrReadOnlyDevice        = errors.New("read-only device")
	ErrBootstrapCompleted    = errors.New("bootstrap already completed")
	ErrLastOwner             = errors.New("last owner cannot be revoked")
)

// Account 是账号聚合根；密码只用于校验账号，不派生正文密钥。
type Account struct {
	ID           string
	Email        string
	PasswordHash []byte
	CreatedAt    time.Time
}

// Device 是已授权设备；服务器只保存公钥与元数据，不保存私钥。
type Device struct {
	ID                  string
	AccountID           string
	Role                string
	Status              string
	DisplayName         string
	Platform            string
	IdentityPublicKey   string
	EncryptionPublicKey string
	LastSeenUnixMS      int64
}

// PairingRequest 是待 owner 批准的配对请求。
type PairingRequest struct {
	ID                  string
	AccountID           string
	Role                string
	Status              string
	DisplayName         string
	IdentityPublicKey   string
	EncryptionPublicKey string
	Platform            string
	ExpiresAt           time.Time
}

// TokenPair 是登录/刷新产生的访问与刷新令牌。access 为短期 opaque，refresh 只存哈希。
type TokenPair struct {
	AccountID    string        `json:"account_id,omitempty"`
	DeviceID     string        `json:"device_id,omitempty"`
	AccessToken  string        `json:"access_token"`
	RefreshToken string        `json:"refresh_token"`
	ExpiresIn    int64         `json:"expires_in"`
	AccessTTL    time.Duration `json:"-"`
	RefreshTTL   time.Duration `json:"-"`
}

// AuthSubject 是鉴权中间件写入上下文的认证主体。
type AuthSubject struct {
	AccountID string
	DeviceID  string
	Role      string
	DeviceOK  bool // 设备存在且未撤销
}

// CanWrite 判断该角色是否可提交会话写命令。
func (s AuthSubject) CanWrite() bool {
	return s.Role == RoleAndroidOwner || s.Role == RoleAndroid
}

// IsOwner 判断是否 owner 角色。
func (s AuthSubject) IsOwner() bool {
	return s.Role == RoleAndroidOwner
}
