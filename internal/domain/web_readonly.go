package domain

import (
	"context"
	"crypto/ecdh"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"strings"

	"github.com/yubi233/agent-sessions/internal/store"
	"github.com/yubi233/agent-sessions/packages/protocol"
)

const (
	// WebReadEnvelopeAlgorithm 是 Web 和 Daemon 都公开识别的 envelope 算法标签；它不是密钥，
	// 也不能替代 Daemon 对 AAD、临时公钥和 ciphertext 的认证。
	WebReadEnvelopeAlgorithm = "v1-x25519-hkdfsha256-aes256gcm"
	maxWebReadEnvelopeBytes  = 2 << 20
)

// WebReadTransportInfo 是浏览器密封请求所需的最小公开资料。Terminal 公钥是配对时已存的
// 公钥；只对当前账号且该会话实际绑定的 Terminal 返回，不能由浏览器指定 terminal ID。
type WebReadTransportInfo struct {
	TerminalID          string
	WorkspaceID         string
	EncryptionPublicKey string
	Algorithm           string
}

// WebReadCommandInput 是浏览器提交的密文只读意图。RequestID 由浏览器随机生成并进入 AAD，
// 既是响应关联键，也是幂等键；Relay 不解析 envelope 内的路径和 snapshot token。
type WebReadCommandInput struct {
	AccountID    string
	Role         string
	SessionID    string
	RequestID    string
	Kind         string
	EnvelopeJSON string
}

// WebReadCommandResult 是 Web 可轮询的白名单状态。ResponseEnvelope 只有在 Daemon 成功完成后
// 返回，Relay 仍无法解开其中内容。
type WebReadCommandResult struct {
	RequestID            string
	Kind                 string
	Status               string
	ErrorCode            string
	ResponseEnvelopeJSON string
}

// WebReadTransportForSession 返回当前会话绑定、在线且声明安全能力的 Terminal 公钥。它不创建
// 命令，也不触碰 Workspace 根；浏览器下一步提交时会再次验证相同关系，避免读后写 TOCTOU。
func (s *SessionService) WebReadTransportForSession(ctx context.Context, accountID, role, sessionID string) (WebReadTransportInfo, error) {
	if role != RoleWeb {
		return WebReadTransportInfo{}, ErrReadOnlyDevice
	}
	session, err := s.GetSession(ctx, sessionID)
	if err != nil {
		return WebReadTransportInfo{}, err
	}
	if session.AccountID != accountID {
		return WebReadTransportInfo{}, ErrScopeDenied
	}
	terminal, publicKey, err := s.webReadTarget(ctx, accountID, sessionID)
	if err != nil {
		return WebReadTransportInfo{}, err
	}
	return WebReadTransportInfo{TerminalID: terminal.ID, WorkspaceID: session.WorkspaceID, EncryptionPublicKey: publicKey, Algorithm: WebReadEnvelopeAlgorithm}, nil
}

// SubmitWebReadCommand 是唯一允许 Web 创建的持久化命令。它完全独立于 Android write lease：
// 只允许固定的文件/Git kind，lease_epoch 固定为 0，并且 target Terminal 永远从 Session Workspace
// 推导，不能由浏览器传入或覆盖。
func (s *SessionService) SubmitWebReadCommand(ctx context.Context, in WebReadCommandInput) (store.CommandRow, error) {
	if in.Role != RoleWeb || !isWebReadOnlyKind(in.Kind) || !validWebReadRequestID(in.RequestID) {
		return store.CommandRow{}, ErrReadOnlyDevice
	}
	if len(in.EnvelopeJSON) == 0 || len(in.EnvelopeJSON) > maxWebReadEnvelopeBytes || !validWebReadEnvelope(in.EnvelopeJSON) {
		return store.CommandRow{}, protocol.NewError(protocol.ErrInvalidRequest, "invalid web read envelope")
	}

	scopeHash := hashScope(in.AccountID, in.SessionID)
	command := store.CommandRow{
		ID: in.RequestID, AccountID: in.AccountID, SessionID: in.SessionID, Kind: in.Kind,
		Status: CommandAccepted, ScopeHash: scopeHash, IdempotencyKey: in.RequestID,
		// 0 明确标识该命令不是 Android 控制操作；Daemon 只对这种值跳过 write lease fence。
		LeaseEpoch: 0, CiphertextJSON: in.EnvelopeJSON,
	}
	var out store.CommandRow
	err := s.repo.WithTx(ctx, func(ctx context.Context, tx store.Repository) error {
		if existing, err := tx.CommandByID(ctx, in.RequestID); err == nil {
			if existing.AccountID == in.AccountID && existing.SessionID == in.SessionID && existing.Kind == in.Kind && existing.LeaseEpoch == 0 {
				out = existing
				return nil
			}
			return ErrIdempotencyUsed
		} else if !errors.Is(err, sql.ErrNoRows) {
			return err
		}
		terminal, _, err := s.webReadTargetWithRepo(ctx, tx, in.AccountID, in.SessionID)
		if err != nil {
			return err
		}
		command.TargetTerminalID = terminal.ID
		if err := tx.CreateCommand(ctx, command); err != nil {
			return err
		}
		if _, err := tx.CreateDaemonDelivery(ctx, store.DaemonDeliveryRow{
			TerminalID: terminal.ID, CommandID: command.ID, CreatedAtUnixMS: s.now().UnixMilli(),
		}); err != nil {
			return err
		}
		return tx.EnqueueOutbox(ctx, store.OutboxRow{Kind: "command.updated", PayloadJSON: `{"command_id":"` + command.ID + `"}`, Status: "pending"})
	})
	if err != nil {
		return store.CommandRow{}, err
	}
	if out.ID != "" {
		return out, nil
	}
	return command, nil
}

// GetWebReadCommand 只允许原账号的 web token 查询命令状态；成功响应的 ciphertext 仍必须由
// 当前页面临时私钥解封。刷新、重新登录或其他浏览器实例都没有该私钥。
func (s *SessionService) GetWebReadCommand(ctx context.Context, accountID, role, sessionID, requestID string) (WebReadCommandResult, error) {
	if role != RoleWeb || !validWebReadRequestID(requestID) {
		return WebReadCommandResult{}, ErrReadOnlyDevice
	}
	command, err := s.repo.CommandByID(ctx, requestID)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return WebReadCommandResult{}, store.ErrNotFound
		}
		return WebReadCommandResult{}, err
	}
	if command.AccountID != accountID || command.SessionID != sessionID || !isWebReadCommand(command) {
		return WebReadCommandResult{}, ErrScopeDenied
	}
	result := WebReadCommandResult{RequestID: command.ID, Kind: command.Kind, Status: command.Status}
	if delivery, err := s.repo.DaemonDeliveryByCommandID(ctx, command.ID); err == nil {
		result.ErrorCode = delivery.ErrorCode
	} else if !errors.Is(err, sql.ErrNoRows) {
		return WebReadCommandResult{}, err
	}
	if command.Status == CommandSucceeded {
		result.ResponseEnvelopeJSON = command.ReadResponseEnvelopeJSON
	}
	return result, nil
}

func (s *SessionService) webReadTarget(ctx context.Context, accountID, sessionID string) (store.TerminalRow, string, error) {
	return s.webReadTargetWithRepo(ctx, s.repo, accountID, sessionID)
}

func (s *SessionService) webReadTargetWithRepo(ctx context.Context, repo store.Repository, accountID, sessionID string) (store.TerminalRow, string, error) {
	session, err := repo.SessionByID(ctx, sessionID)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return store.TerminalRow{}, "", ErrSessionNotFound
		}
		return store.TerminalRow{}, "", err
	}
	if session.AccountID != accountID {
		return store.TerminalRow{}, "", ErrScopeDenied
	}
	workspace, err := repo.WorkspaceByID(ctx, session.WorkspaceID)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return store.TerminalRow{}, "", ErrWorkspaceNotFound
		}
		return store.TerminalRow{}, "", err
	}
	if workspace.TerminalID == "" {
		return store.TerminalRow{}, "", ErrTerminalOffline
	}
	terminal, err := repo.TerminalByID(ctx, workspace.TerminalID)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return store.TerminalRow{}, "", ErrTerminalOffline
		}
		return store.TerminalRow{}, "", err
	}
	if terminal.AccountID != accountID || terminal.Status != "online" || !terminalAllowsWebRead(terminal.CapabilitiesJSON) {
		return store.TerminalRow{}, "", ErrTerminalOffline
	}
	device, err := repo.DeviceByID(ctx, terminal.DeviceID)
	if err != nil {
		return store.TerminalRow{}, "", err
	}
	if device.AccountID != accountID || device.Role != RoleTerminal || device.Status != DeviceActive || !validX25519PublicKey(device.EncryptionPublicKey) {
		return store.TerminalRow{}, "", ErrScopeDenied
	}
	return terminal, device.EncryptionPublicKey, nil
}

func isWebReadCommand(command store.CommandRow) bool {
	return command.LeaseEpoch == 0 && isWebReadOnlyKind(command.Kind)
}

func isWebReadOnlyKind(kind string) bool {
	switch kind {
	case "file.tree", "file.read", "code.read", "git.status", "git.changes", "git.diff":
		return true
	}
	return false
}

func terminalAllowsWebRead(raw string) bool {
	var capabilities []string
	if json.Unmarshal([]byte(raw), &capabilities) != nil {
		return false
	}
	seenTransport := false
	seenFile := false
	seenGit := false
	for _, capability := range capabilities {
		switch strings.TrimSpace(capability) {
		case "web_read_transport":
			seenTransport = true
		case "file_read":
			seenFile = true
		case "git_read":
			seenGit = true
		}
	}
	return seenTransport && seenFile && seenGit
}

func validWebReadEnvelope(raw string) bool {
	if !validWebReadEnvelopeObject(raw, "alg", "payload_version", "ephemeral_public_key", "nonce", "ciphertext", "aad_hash") {
		return false
	}
	var envelope struct {
		Alg                string `json:"alg"`
		PayloadVersion     int    `json:"payload_version"`
		EphemeralPublicKey string `json:"ephemeral_public_key"`
		Nonce              string `json:"nonce"`
		Ciphertext         string `json:"ciphertext"`
		AADHash            string `json:"aad_hash"`
	}
	if json.Unmarshal([]byte(raw), &envelope) != nil || envelope.Alg != WebReadEnvelopeAlgorithm || envelope.PayloadVersion != 1 {
		return false
	}
	return validX25519PublicKey(envelope.EphemeralPublicKey) && validWebReadCipherFields(envelope.Nonce, envelope.Ciphertext, envelope.AADHash)
}

// validWebReadEnvelopeObject 拒绝额外键和重复键。Relay 保存原始 JSON；只校验反序列化后的
// struct 会遗漏重复键或未识别字段中夹带的路径、代码和 diff 明文。
func validWebReadEnvelopeObject(raw string, allowed ...string) bool {
	allowedKeys := make(map[string]struct{}, len(allowed))
	for _, key := range allowed {
		allowedKeys[key] = struct{}{}
	}
	decoder := json.NewDecoder(strings.NewReader(raw))
	opening, err := decoder.Token()
	if err != nil {
		return false
	}
	delimiter, ok := opening.(json.Delim)
	if !ok || delimiter != '{' {
		return false
	}
	seen := make(map[string]struct{}, len(allowed))
	for decoder.More() {
		name, err := decoder.Token()
		if err != nil {
			return false
		}
		key, ok := name.(string)
		if !ok {
			return false
		}
		if _, allowed := allowedKeys[key]; !allowed {
			return false
		}
		if _, duplicate := seen[key]; duplicate {
			return false
		}
		seen[key] = struct{}{}
		var discarded json.RawMessage
		if err := decoder.Decode(&discarded); err != nil {
			return false
		}
	}
	closing, err := decoder.Token()
	if err != nil {
		return false
	}
	delimiter, ok = closing.(json.Delim)
	if !ok || delimiter != '}' || len(seen) != len(allowedKeys) {
		return false
	}
	var trailing any
	return decoder.Decode(&trailing) == io.EOF
}

// validWebReadCipherFields 在 Relay 持久化前验证可被 AES-GCM 消费的最小编码形状。认证仍由
// Daemon/浏览器通过 AAD 和 tag 完成；这里不尝试解密，也不接触 plaintext。
func validWebReadCipherFields(nonce, ciphertext, aadHash string) bool {
	nonceBytes, err := decodeWebReadBase64(nonce)
	if err != nil || len(nonceBytes) != 12 {
		return false
	}
	ciphertextBytes, err := decodeWebReadBase64(ciphertext)
	if err != nil || len(ciphertextBytes) < 16 {
		return false
	}
	if len(aadHash) != 64 {
		return false
	}
	_, err = hex.DecodeString(aadHash)
	return err == nil
}

func decodeWebReadBase64(value string) ([]byte, error) {
	decoded, err := base64.RawStdEncoding.DecodeString(value)
	if err == nil {
		return decoded, nil
	}
	return base64.StdEncoding.DecodeString(value)
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

func validX25519PublicKey(value string) bool {
	decoded, err := base64.RawStdEncoding.DecodeString(value)
	if err != nil {
		decoded, err = base64.StdEncoding.DecodeString(value)
	}
	if err != nil || len(decoded) != 32 {
		return false
	}
	_, err = ecdh.X25519().NewPublicKey(decoded)
	return err == nil
}
