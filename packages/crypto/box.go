package crypto

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdh"
	"crypto/ed25519"
	"crypto/hkdf"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
)

// 算法版本写入 envelope，便于后续轮换时双读。
const AlgorithmVersion = "v1-aes256gcm-hkdfsha256"

// Envelope 是端到端密文包装。服务器只转发，不解密。
type Envelope struct {
	Alg        string `json:"alg"`
	KeyID      string `json:"key_id"`
	Nonce      string `json:"nonce"`
	Ciphertext string `json:"ciphertext"`
	AADHash    string `json:"aad_hash"`
	PayloadVer int    `json:"payload_version"`
}

// AAD 绑定实体、事件类型、协议版本和序号，防止密文被挪到其他会话。
type AAD struct {
	EntityID        string `json:"entity_id"`
	EventType       string `json:"event_type"`
	ProtocolVersion int    `json:"protocol_version"`
	EventSeq        int64  `json:"event_seq"`
	KeyID           string `json:"key_id"`
}

// DeviceKeys 保存一台设备的身份签名与加密密钥。
type DeviceKeys struct {
	IdentityPrivate ed25519.PrivateKey
	IdentityPublic  ed25519.PublicKey
	EncryptPrivate  *ecdh.PrivateKey
	EncryptPublic   *ecdh.PublicKey
}

func b64(b []byte) string { return base64.RawStdEncoding.EncodeToString(b) }
func mustDecode(s string) []byte {
	raw, err := base64.RawStdEncoding.DecodeString(s)
	if err != nil {
		panic(err)
	}
	return raw
}

// GenerateDeviceKeys 生成 Ed25519 + X25519 设备密钥。
func GenerateDeviceKeys() (DeviceKeys, error) {
	idPub, idPriv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return DeviceKeys{}, err
	}
	curve := ecdh.X25519()
	encPriv, err := curve.GenerateKey(rand.Reader)
	if err != nil {
		return DeviceKeys{}, err
	}
	return DeviceKeys{
		IdentityPrivate: idPriv,
		IdentityPublic:  idPub,
		EncryptPrivate:  encPriv,
		EncryptPublic:   encPriv.PublicKey(),
	}, nil
}

// HashAAD 计算规范化 AAD 的 SHA-256。
func HashAAD(aad AAD) (string, []byte, error) {
	raw, err := json.Marshal(aad)
	if err != nil {
		return "", nil, err
	}
	sum := sha256.Sum256(raw)
	return hex.EncodeToString(sum[:]), raw, nil
}

// DeriveContentKey 用 HKDF-SHA256 从 DEK 派生内容密钥。
func DeriveContentKey(dek []byte, info string) ([]byte, error) {
	return hkdf.Key(sha256.New, dek, []byte("agent-sessions-v1"), info, 32)
}

// Seal 使用 AES-256-GCM 加密正文。nonce 必须 96-bit 且不重复。
func Seal(dek []byte, keyID string, payloadVersion int, aad AAD, plaintext []byte, nonce []byte) (Envelope, error) {
	if len(nonce) != 12 {
		return Envelope{}, errors.New("nonce must be 12 bytes")
	}
	key, err := DeriveContentKey(dek, "content")
	if err != nil {
		return Envelope{}, err
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return Envelope{}, err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return Envelope{}, err
	}
	aad.KeyID = keyID
	hash, aadRaw, err := HashAAD(aad)
	if err != nil {
		return Envelope{}, err
	}
	ct := gcm.Seal(nil, nonce, plaintext, aadRaw)
	return Envelope{
		Alg:        AlgorithmVersion,
		KeyID:      keyID,
		Nonce:      b64(nonce),
		Ciphertext: b64(ct),
		AADHash:    hash,
		PayloadVer: payloadVersion,
	}, nil
}

// Open 解密并校验 AAD。篡改、错误 key 或错误 AAD 必须失败。
func Open(dek []byte, env Envelope, aad AAD) ([]byte, error) {
	if env.Alg != AlgorithmVersion {
		return nil, fmt.Errorf("unsupported alg %s", env.Alg)
	}
	key, err := DeriveContentKey(dek, "content")
	if err != nil {
		return nil, err
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	aad.KeyID = env.KeyID
	hash, aadRaw, err := HashAAD(aad)
	if err != nil {
		return nil, err
	}
	if hash != env.AADHash {
		return nil, errors.New("aad mismatch")
	}
	nonce, err := base64.RawStdEncoding.DecodeString(env.Nonce)
	if err != nil {
		return nil, err
	}
	ct, err := base64.RawStdEncoding.DecodeString(env.Ciphertext)
	if err != nil {
		return nil, err
	}
	return gcm.Open(nil, nonce, ct, aadRaw)
}

// WrapDEK 用接收方 X25519 公钥包装会话 DEK。
func WrapDEK(sender *ecdh.PrivateKey, recipient *ecdh.PublicKey, dek []byte) (nonce, wrapped []byte, err error) {
	shared, err := sender.ECDH(recipient)
	if err != nil {
		return nil, nil, err
	}
	key, err := hkdf.Key(sha256.New, shared, []byte("agent-sessions-wrap"), "dek-wrap", 32)
	if err != nil {
		return nil, nil, err
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, nil, err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, nil, err
	}
	nonce = make([]byte, 12)
	if _, err := io.ReadFull(rand.Reader, nonce); err != nil {
		return nil, nil, err
	}
	return nonce, gcm.Seal(nil, nonce, dek, []byte("dek-wrap-v1")), nil
}

// UnwrapDEK 解开设备 DEK 包装。
func UnwrapDEK(recipient *ecdh.PrivateKey, sender *ecdh.PublicKey, nonce, wrapped []byte) ([]byte, error) {
	shared, err := recipient.ECDH(sender)
	if err != nil {
		return nil, err
	}
	key, err := hkdf.Key(sha256.New, shared, []byte("agent-sessions-wrap"), "dek-wrap", 32)
	if err != nil {
		return nil, err
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	return gcm.Open(nil, nonce, wrapped, []byte("dek-wrap-v1"))
}

// RandomDEK 生成 32 字节会话内容密钥。
func RandomDEK() ([]byte, error) {
	dek := make([]byte, 32)
	_, err := io.ReadFull(rand.Reader, dek)
	return dek, err
}

// EncodePublic 把公钥编码为标准 base64。
func EncodePublic(pub []byte) string { return b64(pub) }

// DecodePublic 解码公钥。
func DecodePublic(s string) ([]byte, error) {
	return base64.RawStdEncoding.DecodeString(s)
}

// MustNonce 仅用于 golden vector 固定 nonce。
func MustNonce(hexStr string) []byte {
	b, err := hex.DecodeString(hexStr)
	if err != nil {
		panic(err)
	}
	return b
}

// ParseX25519Private 从 32 字节种子构造 X25519 私钥。
func ParseX25519Private(raw []byte) (*ecdh.PrivateKey, error) {
	return ecdh.X25519().NewPrivateKey(raw)
}
