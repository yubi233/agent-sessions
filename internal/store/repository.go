// Package store 是 SQLite 权威存储：编号迁移、事务与仓储实现。
// 业务规则不在此层；密码/令牌/正文不得以明文写入。
package store

import (
	"context"
	"time"
)

// Repository 是 domain 层的持久化端口。由 store 实现，测试可替换为内存实现。
type Repository interface {
	// 账号
	CreateAccount(ctx context.Context, id, email string, passwordHash []byte, createdAt time.Time) error
	CountAccounts(ctx context.Context) (int, error)
	AccountByEmail(ctx context.Context, email string) (AccountRow, error)
	AccountByID(ctx context.Context, id string) (AccountRow, error)

	// 设备
	CreateDevice(ctx context.Context, d DeviceRow) error
	DeviceByID(ctx context.Context, id string) (DeviceRow, error)
	ListDevices(ctx context.Context, accountID string) ([]DeviceRow, error)
	SetDeviceStatus(ctx context.Context, id, status string) error
	UpdateBootstrapDevice(ctx context.Context, d DeviceRow) (bool, error)

	// 令牌 family 与 access token
	CreateTokenFamily(ctx context.Context, tf TokenFamilyRow) error
	TokenFamilyByID(ctx context.Context, id string) (TokenFamilyRow, error)
	TokenFamilyByRefreshHash(ctx context.Context, hash string) (TokenFamilyRow, error)
	// RotateTokenFamilyRefreshHash 仅在当前哈希、未撤销和未过期时轮换 refresh。
	// 返回 false 表示令牌已轮换、撤销、过期或绑定设备已失效，调用方必须重新判定原因。
	RotateTokenFamilyRefreshHash(ctx context.Context, id, currentHash, nextHash string, notBefore time.Time) (bool, error)
	RevokeTokenFamily(ctx context.Context, id string) error
	// RevokeTokenFamilyIfCurrent 以账号和当前哈希条件撤销，避免用 family ID 误伤其他会话。
	RevokeTokenFamilyIfCurrent(ctx context.Context, id, accountID, refreshHash string) (bool, error)
	PutAccessToken(ctx context.Context, at AccessTokenRow) error
	AccessTokenByValue(ctx context.Context, token string) (AccessTokenRow, error)
	DeleteAccessToken(ctx context.Context, token string) error

	// 配对
	CreatePairingRequest(ctx context.Context, p PairingRow) error
	PairingByID(ctx context.Context, id string) (PairingRow, error)
	SetPairingStatus(ctx context.Context, id, status string) error
	SetPairingStatusIfCurrent(ctx context.Context, id, currentStatus, nextStatus string) (bool, error)

	// DEK 包装
	PutKeyWrap(ctx context.Context, kw KeyWrapRow) error
	ListKeyWraps(ctx context.Context, dekID string) ([]KeyWrapRow, error)

	// 恢复码
	UpsertRecoveryCode(ctx context.Context, rc RecoveryRow) error
	RecoveryByAccount(ctx context.Context, accountID string) (RecoveryRow, error)
	ConsumeRecoveryCode(ctx context.Context, accountID, codeHash string, now time.Time) (bool, error)

	// 审计（脱敏元数据，不写正文）
	AppendAudit(ctx context.Context, accountID, action, metadataJSON string) error

	// ---- 实时会话与同步（P1） ----

	// 设备在线标记（presence 由进程内管理，DB 只做持久化最后在线时间）
	TouchDeviceLastSeen(ctx context.Context, deviceID string, unixMS int64) error

	// Terminal
	CreateTerminal(ctx context.Context, t TerminalRow) error
	TerminalByID(ctx context.Context, id string) (TerminalRow, error)
	TerminalByDeviceID(ctx context.Context, deviceID string) (TerminalRow, error)
	ListTerminals(ctx context.Context, accountID string) ([]TerminalRow, error)
	TouchTerminal(ctx context.Context, id string, unixMS int64) error
	// UpsertDaemonTerminal 只更新 Daemon 声明的白名单元数据；工作区绝对路径和 Provider 正文不允许写入 Relay。
	UpsertDaemonTerminal(ctx context.Context, t TerminalRow) error

	// Project / Workspace
	CreateProject(ctx context.Context, p ProjectRow) error
	ListProjects(ctx context.Context, accountID string) ([]ProjectRow, error)
	CreateWorkspace(ctx context.Context, w WorkspaceRow) error
	WorkspaceByID(ctx context.Context, id string) (WorkspaceRow, error)
	ListWorkspaces(ctx context.Context, accountID string) ([]WorkspaceRow, error)

	// Session 与 SessionInstance
	CreateSession(ctx context.Context, s SessionRow) error
	SessionByID(ctx context.Context, id string) (SessionRow, error)
	ListSessions(ctx context.Context, accountID string) ([]SessionRow, error)
	SetSessionStatus(ctx context.Context, id, status string) error
	SetSessionLastSeq(ctx context.Context, id string, lastSeq int64) error
	SetSessionInstance(ctx context.Context, id, instanceID string) error
	CreateInstance(ctx context.Context, i InstanceRow) error
	InstanceByID(ctx context.Context, id string) (InstanceRow, error)

	// 会话事件：append 使用 MAX(event_seq)+1，保证并发下 seq 单调不重复，返回分配的 seq
	AppendEvent(ctx context.Context, e SessionEventRow) (int64, error)
	ListEventsAfter(ctx context.Context, sessionID string, afterSeq int64) ([]SessionEventRow, error)

	// 命令（idempotency 在应用层用 (scope_hash,idempotency_key) 校验）
	CreateCommand(ctx context.Context, c CommandRow) error
	CommandByID(ctx context.Context, id string) (CommandRow, error)
	CommandByScopeKey(ctx context.Context, scopeHash, idempotencyKey string) (CommandRow, error)
	UpdateCommandStatus(ctx context.Context, id, status string) error
	ListCommands(ctx context.Context, sessionID string) ([]CommandRow, error)

	// Daemon 专用投递记录。账号级 outbox 不承担终端命令流，避免客户端 SSE 与 Daemon SSE 混用。
	CreateDaemonDelivery(ctx context.Context, d DaemonDeliveryRow) (DaemonDeliveryRow, error)
	DaemonDeliveryByCommandID(ctx context.Context, commandID string) (DaemonDeliveryRow, error)
	ListDaemonDeliveriesAfter(ctx context.Context, terminalID string, afterDeliverySeq int64) ([]DaemonDeliveryRow, error)
	UpdateDaemonDelivery(ctx context.Context, d DaemonDeliveryRow) error

	// Daemon canonical event 使用 event_id 去重；事件正文仍只以客户端密文 envelope 进入 session_events。
	DaemonEventReceiptByID(ctx context.Context, eventID string) (DaemonEventReceiptRow, error)
	CreateDaemonEventReceipt(ctx context.Context, r DaemonEventReceiptRow) error
	SetDaemonEventReceiptSeq(ctx context.Context, eventID string, eventSeq int64) error

	// Delegation：父子 Session 图只存密文 envelope 与白名单索引，Relay 不解密任务书或摘要。
	CreateDelegation(ctx context.Context, d DelegationRow) error
	DelegationByID(ctx context.Context, id string) (DelegationRow, error)
	DelegationByParentKey(ctx context.Context, parentSessionID, idempotencyKey string) (DelegationRow, error)
	ListDelegationsByParent(ctx context.Context, parentSessionID string) ([]DelegationRow, error)
	UpdateDelegation(ctx context.Context, id, status, childSessionID string, updatedAtUnixMS int64) error

	// ControlLease（fencing epoch 由应用层在事务内比较）
	AcquireLease(ctx context.Context, l LeaseRow) error
	LeaseBySession(ctx context.Context, sessionID string) (LeaseRow, error)
	ReleaseLease(ctx context.Context, sessionID string) error

	// 附件：Relay 只存密文 chunk 与最小白名单元数据，不读取文件名或正文。
	CreateAttachment(ctx context.Context, a AttachmentRow) error
	AttachmentByID(ctx context.Context, id string) (AttachmentRow, error)
	CreateAttachmentChunk(ctx context.Context, c AttachmentChunkRow) error
	AttachmentChunkByIndex(ctx context.Context, attachmentID string, chunkIndex int) (AttachmentChunkRow, error)
	AttachmentChunkByIdempotency(ctx context.Context, attachmentID, idempotencyKey string) (AttachmentChunkRow, error)
	CountAttachmentChunks(ctx context.Context, attachmentID string) (int, error)
	CompleteAttachment(ctx context.Context, attachmentID, idempotencyKey string) (bool, error)

	// Outbox
	EnqueueOutbox(ctx context.Context, o OutboxRow) error
	ClaimOutbox(ctx context.Context, id int64) (OutboxRow, error)
	MarkOutboxDone(ctx context.Context, id int64) error
	MarkOutboxFailed(ctx context.Context, id int64, attempts int) error
	ListPendingOutbox(ctx context.Context, limit int) ([]OutboxRow, error)

	// 事务：domain 层需要原子提交时使用
	WithTx(ctx context.Context, fn func(ctx context.Context, tx Repository) error) error
}

// AccountRow 是 accounts 表的行投影。
type AccountRow struct {
	ID           string
	Email        string
	PasswordHash []byte
	CreatedAt    time.Time
}

// DeviceRow 是 devices 表的行投影。
type DeviceRow struct {
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

// TokenFamilyRow 是 token_families 表的行投影。
type TokenFamilyRow struct {
	ID          string
	AccountID   string
	DeviceID    string
	Role        string
	RefreshHash string
	Revoked     bool
	CreatedAt   time.Time
}

// AccessTokenRow 是 access_tokens 表的行投影。
type AccessTokenRow struct {
	Token     string
	AccountID string
	DeviceID  string
	Role      string
	ExpiresAt time.Time
}

// PairingRow 是 pairing_requests 表的行投影。
type PairingRow struct {
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

// KeyWrapRow 是 device_key_wraps 表的行投影。
type KeyWrapRow struct {
	DEKID             string
	RecipientDeviceID string
	SenderDeviceID    string
	WrappedDEK        []byte
	CreatedAt         time.Time
}

// RecoveryRow 是 recovery_codes 表的行投影。
type RecoveryRow struct {
	AccountID      string
	CodeHash       string
	FailedAttempts int
	LockedUntil    time.Time
	CreatedAt      time.Time
}

// TerminalRow 是 terminals 表的行投影。
type TerminalRow struct {
	ID                  string
	DeviceID            string
	AccountID           string
	Hostname            string
	Platform            string
	Status              string
	LastSeenUnixMS      int64
	ProtocolVersion     int
	DaemonVersion       string
	CapabilitiesJSON    string
	LastHeartbeatUnixMS int64
}

// ProjectRow 是 projects 表的行投影。
type ProjectRow struct {
	ID            string
	AccountID     string
	Fingerprint   string
	EncryptedName string
}

// WorkspaceRow 是 workspaces 表的行投影。
type WorkspaceRow struct {
	ID            string
	ProjectID     string
	TerminalID    string
	CanonicalRoot string
	Branch        string
	Status        string
}

// SessionRow 是 sessions 表的行投影。
type SessionRow struct {
	ID                string
	WorkspaceID       string
	AccountID         string
	Status            string
	Provider          string
	LastSeq           int64
	CurrentInstanceID string
}

// InstanceRow 是 session_instances 表的行投影。
type InstanceRow struct {
	ID         string
	SessionID  string
	LeaseEpoch int64
	Status     string
	WakeResult string
}

// SessionEventRow 是 session_events 表的行投影。envelope 只存密文/脱敏 JSON。
type SessionEventRow struct {
	SessionID    string
	EventSeq     int64
	EventType    string
	EnvelopeJSON string
}

// CommandRow 是 commands 表的行投影。
type CommandRow struct {
	ID               string
	AccountID        string
	SessionID        string
	Kind             string
	Status           string
	ScopeHash        string
	IdempotencyKey   string
	LeaseEpoch       int64
	TargetInstanceID string
	TargetTerminalID string
	CiphertextJSON   string
}

// DaemonDeliveryRow 是一个仅属于目标 Terminal 的至少一次投递记录。
// delivery_seq 只在同一 terminal 内单调递增，SSE 恢复不得复用账号事件序号。
type DaemonDeliveryRow struct {
	TerminalID      string
	DeliverySeq     int64
	CommandID       string
	AckKind         string
	ResultStatus    string
	ErrorCode       string
	CreatedAtUnixMS int64
	UpdatedAtUnixMS int64
}

// DaemonEventReceiptRow 记录 event_id 与 Relay 分配的 canonical event_seq，
// 使 Daemon 重试不会重复追加会话事件。
type DaemonEventReceiptRow struct {
	EventID         string
	TerminalID      string
	CommandID       string
	SessionID       string
	EventSeq        int64
	CreatedAtUnixMS int64
}

// DelegationRow 是父子 Session 图的最小持久化投影。两个 envelope 都是客户端密文，
// 仅哈希、状态和关系允许被 Relay 查询、审计和投影给只读端。
type DelegationRow struct {
	ID                    string
	AccountID             string
	ParentSessionID       string
	ChildSessionID        string
	TargetProvider        string
	Status                string
	TaskEnvelopeJSON      string
	TaskEnvelopeSHA256    string
	SummaryEnvelopeJSON   string
	SummaryEnvelopeSHA256 string
	IdempotencyKey        string
	ParentLeaseEpoch      int64
	CreatedByDeviceID     string
	CreatedAtUnixMS       int64
	UpdatedAtUnixMS       int64
}

// LeaseRow 是 control_leases 表的行投影。
type LeaseRow struct {
	SessionID  string
	DeviceID   string
	Epoch      int64
	InstanceID string
}

// AttachmentRow 是附件的最小元数据。display name 位于 MetadataCiphertext，服务端不会解析。
type AttachmentRow struct {
	ID                     string
	SessionID              string
	AccountID              string
	MimeType               string
	ByteSize               int64
	Compression            string
	TotalChunks            int
	MetadataCiphertext     []byte
	CreatedByDeviceID      string
	LeaseEpoch             int64
	Status                 string
	CompleteIdempotencyKey string
}

// AttachmentChunkRow 仅保存单个密文块和哈希，用于顺序、重复提交与冲突检查。
type AttachmentChunkRow struct {
	AttachmentID     string
	ChunkIndex       int
	IdempotencyKey   string
	Ciphertext       []byte
	CiphertextSHA256 string
}

// OutboxRow 是 outbox 表的行投影。
type OutboxRow struct {
	ID          int64
	Kind        string
	PayloadJSON string
	Status      string
	Attempts    int
}
