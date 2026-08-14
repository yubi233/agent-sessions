package authz

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"time"

	"golang.org/x/crypto/argon2"
)

// HashPassword 使用 Argon2id，账号密码不派生正文密钥。
func HashPassword(password string) []byte {
	salt := make([]byte, 16)
	_, _ = rand.Read(salt)
	key := argon2.IDKey([]byte(password), salt, 1, 64*1024, 1, 32)
	out := make([]byte, 16+32)
	copy(out[:16], salt)
	copy(out[16:], key)
	return out
}

// VerifyPassword 恒定时间比较。
func VerifyPassword(hash []byte, password string) bool {
	if len(hash) != 48 {
		return false
	}
	key := argon2.IDKey([]byte(password), hash[:16], 1, 64*1024, 1, 32)
	return subtle.ConstantTimeCompare(hash[16:], key) == 1
}

// RandomToken 生成不透明 access/refresh token。
func RandomToken() string {
	b := make([]byte, 32)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

// HashToken 只存哈希，便于撤销与 reuse 检测。
func HashToken(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}

// AccessTTL 与 RefreshTTL 是默认令牌寿命。
const (
	AccessTTL  = 15 * time.Minute
	RefreshTTL = 30 * 24 * time.Hour
)
