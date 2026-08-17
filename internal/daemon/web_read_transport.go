package daemon

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdh"
	"crypto/hkdf"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"

	contentcrypto "github.com/yubi233/agent-sessions/packages/crypto"
)

const (
	// WebReadPrivateKeyEnvironment 是 Daemon 专用于 Web 只读 transport 的 X25519 私钥。
	// 它必须与 Terminal 配对时登记的 encryption_public_key 对应，且只可存在于 Daemon 进程环境。
	WebReadPrivateKeyEnvironment = "AGENT_SESSIONS_WEB_READ_PRIVATE_KEY_B64"
	webReadAlgorithm             = "v1-x25519-hkdfsha256-aes256gcm"
	webReadPayloadVersion        = 1
)

// WebReadRequest 是浏览器密封的最小只读意图。路径和 snapshot token 绝不以该结构的明文
// 离开 Daemon；Relay 只持久化其 envelope。
type WebReadRequest struct {
	Path          string `json:"path,omitempty"`
	SnapshotToken string `json:"snapshot_token,omitempty"`
	Offset        int    `json:"offset,omitempty"`
	Limit         int    `json:"limit,omitempty"`
}

// webReadRequestEnvelope 包含浏览器一次性临时公钥和请求密文。临时私钥只由当前页面保留，刷新后
// 无法再解开同一次响应，避免浏览器持久化内容密钥。
type webReadRequestEnvelope struct {
	Alg                string `json:"alg"`
	PayloadVersion     int    `json:"payload_version"`
	EphemeralPublicKey string `json:"ephemeral_public_key"`
	Nonce              string `json:"nonce"`
	Ciphertext         string `json:"ciphertext"`
	AADHash            string `json:"aad_hash"`
}

// WebReadResponseEnvelope 是 Daemon 回传的密文结果。Relay 只校验 JSON 形状并保存该 envelope，
// 不具备浏览器临时私钥，因而不能解密文件、代码或 diff。
type WebReadResponseEnvelope struct {
	Alg            string `json:"alg"`
	PayloadVersion int    `json:"payload_version"`
	Nonce          string `json:"nonce"`
	Ciphertext     string `json:"ciphertext"`
	AADHash        string `json:"aad_hash"`
}

// webReadResponsePayload 的版本和 kind 被密封，防止 Relay 或调用端替换不同只读操作的结果。
type webReadResponsePayload struct {
	Version int    `json:"version"`
	Kind    string `json:"kind"`
	Result  any    `json:"result"`
}

// WebReadTransport 是 Daemon 内的浏览器只读请求终点。它不访问 Store 或 Relay；调用方必须先
// 通过已确认 Workspace、Session 和 Terminal fence，再调用它解封或加密。
type WebReadTransport struct {
	privateKey  *ecdh.PrivateKey
	nonceReader io.Reader
}

// NewWebReadTransport 用 raw X25519 私钥创建 transport。输入会复制到 ecdh key 内部，调用方
// 可在构建完成后清除临时字节切片。
func NewWebReadTransport(privateKey []byte) (*WebReadTransport, error) {
	if len(privateKey) != 32 {
		return nil, fmt.Errorf("web read X25519 private key 必须为 32 字节，当前为 %d", len(privateKey))
	}
	key, err := contentcrypto.ParseX25519Private(append([]byte(nil), privateKey...))
	if err != nil {
		return nil, fmt.Errorf("解析 web read X25519 private key: %w", err)
	}
	return &WebReadTransport{privateKey: key, nonceReader: rand.Reader}, nil
}

// LoadWebReadTransportFromEnv 加载可选的本机只读 transport 私钥。未配置保持能力关闭；配置了
// 非法值必须拒绝启动，不能静默宣称已经支持 Web 文件读取。
func LoadWebReadTransportFromEnv(getenv func(string) string) (*WebReadTransport, error) {
	if getenv == nil {
		return nil, errors.New("web read environment reader missing")
	}
	raw := strings.TrimSpace(getenv(WebReadPrivateKeyEnvironment))
	if raw == "" {
		return nil, nil
	}
	decoded, err := decodeWebReadKey(raw)
	if err != nil {
		return nil, fmt.Errorf("%s 格式非法: %w", WebReadPrivateKeyEnvironment, err)
	}
	defer zeroBytes(decoded)
	return NewWebReadTransport(decoded)
}

// OpenRequest 解开 browser -> Daemon 请求。AAD 绑定 request/session/workspace/terminal/kind，
// 任一 Relay 元数据被替换都会造成认证失败。
func (t *WebReadTransport) OpenRequest(command RelayCommand) (WebReadRequest, *ecdh.PublicKey, error) {
	if t == nil || t.privateKey == nil {
		return WebReadRequest{}, nil, errors.New("web read transport unavailable")
	}
	if !isReadOnlyCommandKind(command.Kind) || !validWebReadRequestID(command.CommandID) {
		return WebReadRequest{}, nil, errors.New("invalid web read command metadata")
	}
	var envelope webReadRequestEnvelope
	if err := json.Unmarshal([]byte(command.PayloadJSON), &envelope); err != nil {
		return WebReadRequest{}, nil, errors.New("malformed web read request envelope")
	}
	if envelope.Alg != webReadAlgorithm || envelope.PayloadVersion != webReadPayloadVersion {
		return WebReadRequest{}, nil, errors.New("unsupported web read request envelope")
	}
	publicRaw, err := decodeWebReadKey(envelope.EphemeralPublicKey)
	if err != nil {
		return WebReadRequest{}, nil, errors.New("invalid web read ephemeral public key")
	}
	clientPublic, err := ecdh.X25519().NewPublicKey(publicRaw)
	zeroBytes(publicRaw)
	if err != nil {
		return WebReadRequest{}, nil, errors.New("invalid web read ephemeral public key")
	}
	shared, err := t.privateKey.ECDH(clientPublic)
	if err != nil {
		return WebReadRequest{}, nil, errors.New("derive web read request secret")
	}
	defer zeroBytes(shared)
	plaintext, err := openWebReadPayload(shared, "request", webReadAAD(command, "request"), envelope.Nonce, envelope.Ciphertext, envelope.AADHash)
	if err != nil {
		return WebReadRequest{}, nil, errors.New("web read request authentication failed")
	}
	var request WebReadRequest
	if err := json.Unmarshal(plaintext, &request); err != nil {
		return WebReadRequest{}, nil, errors.New("malformed web read request payload")
	}
	if request.Offset < 0 || request.Limit < 0 || request.Limit > 500 {
		return WebReadRequest{}, nil, errors.New("invalid web read pagination")
	}
	request.Path = strings.TrimSpace(request.Path)
	request.SnapshotToken = strings.TrimSpace(request.SnapshotToken)
	return request, clientPublic, nil
}

// SealResponse 使用同一次请求的临时公钥封装读取结果。结果永远不进入普通 canonical event
// 或 account SSE data，避免现有只读时间线在没有临时私钥时意外保存内容。
func (t *WebReadTransport) SealResponse(command RelayCommand, clientPublic *ecdh.PublicKey, result any) (WebReadResponseEnvelope, error) {
	if t == nil || t.privateKey == nil || clientPublic == nil {
		return WebReadResponseEnvelope{}, errors.New("web read transport unavailable")
	}
	shared, err := t.privateKey.ECDH(clientPublic)
	if err != nil {
		return WebReadResponseEnvelope{}, errors.New("derive web read response secret")
	}
	defer zeroBytes(shared)
	plaintext, err := json.Marshal(webReadResponsePayload{Version: webReadPayloadVersion, Kind: command.Kind, Result: result})
	if err != nil {
		return WebReadResponseEnvelope{}, fmt.Errorf("serialize web read response: %w", err)
	}
	nonce := make([]byte, 12)
	if _, err := io.ReadFull(t.nonceSource(), nonce); err != nil {
		return WebReadResponseEnvelope{}, fmt.Errorf("generate web read response nonce: %w", err)
	}
	return sealWebReadPayload(shared, "response", webReadAAD(command, "response"), nonce, plaintext)
}

func (t *WebReadTransport) nonceSource() io.Reader {
	if t != nil && t.nonceReader != nil {
		return t.nonceReader
	}
	return rand.Reader
}

// Destroy 断开私钥引用。Go 不能对 ecdh.PrivateKey 提供绝对内存擦除保证，但退出时不再让 loop 或
// dispatcher 继续使用该 transport，避免正常关闭路径继续处理浏览器请求。
func (t *WebReadTransport) Destroy() {
	if t != nil {
		t.privateKey = nil
	}
}

type webReadAADPayload struct {
	RequestID   string `json:"request_id"`
	SessionID   string `json:"session_id"`
	WorkspaceID string `json:"workspace_id"`
	TerminalID  string `json:"terminal_id"`
	Kind        string `json:"kind"`
	Direction   string `json:"direction"`
}

func webReadAAD(command RelayCommand, direction string) []byte {
	raw, _ := json.Marshal(webReadAADPayload{
		RequestID: command.CommandID, SessionID: command.SessionID, WorkspaceID: command.WorkspaceID,
		TerminalID: command.TargetTerminalID, Kind: command.Kind, Direction: direction,
	})
	return raw
}

func sealWebReadPayload(shared []byte, direction string, aad, nonce, plaintext []byte) (WebReadResponseEnvelope, error) {
	if len(nonce) != 12 {
		return WebReadResponseEnvelope{}, errors.New("web read nonce must be 12 bytes")
	}
	key, err := deriveWebReadKey(shared, direction)
	if err != nil {
		return WebReadResponseEnvelope{}, err
	}
	defer zeroBytes(key)
	block, err := aes.NewCipher(key)
	if err != nil {
		return WebReadResponseEnvelope{}, err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return WebReadResponseEnvelope{}, err
	}
	sum := sha256.Sum256(aad)
	return WebReadResponseEnvelope{
		Alg: webReadAlgorithm, PayloadVersion: webReadPayloadVersion,
		Nonce:      base64.RawStdEncoding.EncodeToString(nonce),
		Ciphertext: base64.RawStdEncoding.EncodeToString(gcm.Seal(nil, nonce, plaintext, aad)),
		AADHash:    hex.EncodeToString(sum[:]),
	}, nil
}

func openWebReadPayload(shared []byte, direction string, aad []byte, encodedNonce, encodedCiphertext, expectedAADHash string) ([]byte, error) {
	sum := sha256.Sum256(aad)
	if !constantStringEqual(expectedAADHash, hex.EncodeToString(sum[:])) {
		return nil, errors.New("web read aad mismatch")
	}
	nonce, err := base64.RawStdEncoding.DecodeString(encodedNonce)
	if err != nil || len(nonce) != 12 {
		return nil, errors.New("invalid web read nonce")
	}
	ciphertext, err := base64.RawStdEncoding.DecodeString(encodedCiphertext)
	if err != nil {
		return nil, errors.New("invalid web read ciphertext")
	}
	key, err := deriveWebReadKey(shared, direction)
	if err != nil {
		return nil, err
	}
	defer zeroBytes(key)
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	return gcm.Open(nil, nonce, ciphertext, aad)
}

func deriveWebReadKey(shared []byte, direction string) ([]byte, error) {
	return hkdf.Key(sha256.New, shared, []byte("agent-sessions-web-read-v1"), direction, 32)
}

func decodeWebReadKey(value string) ([]byte, error) {
	decoded, err := base64.RawStdEncoding.DecodeString(value)
	if err != nil {
		decoded, err = base64.StdEncoding.DecodeString(value)
	}
	if err != nil || len(decoded) != 32 {
		return nil, errors.New("must be base64 encoded 32-byte X25519 key")
	}
	return decoded, nil
}

func validWebReadRequestID(value string) bool {
	if !strings.HasPrefix(value, "webread_") || len(value) < 24 || len(value) > 128 {
		return false
	}
	for _, r := range value {
		if (r < 'a' || r > 'z') && (r < '0' || r > '9') && r != '_' && r != '-' {
			return false
		}
	}
	return true
}

func constantStringEqual(left, right string) bool {
	if len(left) != len(right) {
		return false
	}
	var diff byte
	for index := range left {
		diff |= left[index] ^ right[index]
	}
	return diff == 0
}

func zeroBytes(value []byte) {
	for index := range value {
		value[index] = 0
	}
}
