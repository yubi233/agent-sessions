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
	RecoveryByCodeHash(ctx context.Context, codeHash string) (RecoveryRow, error)
	ConsumeRecoveryCode(ctx context.Context, accountID, codeHash string, now time.Time) (bool, error)

	// 审计（脱敏元数据，不写正文）
	AppendAudit(ctx context.Context, accountID, action, metadataJSON string) error
	// ListAudit 分页读取账号的脱敏审计元数据；Admin 只读，不接触会话正文。
	ListAudit(ctx context.Context, accountID string, limit, offset int) ([]AuditRow, error)

	// ---- 实时会话与同步（P1） ----

	// 设备在线标记（presence 由进程内管理，DB 只做持久化最后在线时间）
	TouchDeviceLastSeen(ctx context.Context, deviceID string, unixMS int64) error

	// Terminal
	CreateTerminal(ctx context.Context, t TerminalRow) error
	TerminalByID(ctx context.Context, id string) (TerminalRow, error)
	TerminalByDeviceID(ctx context.Context, deviceID string) (TerminalRow, error)
	ListTerminals(ctx context.Context, accountID string) ([]TerminalRow, error)
	TouchTerminal(ctx context.Context, id string, unixMS int64) error
	// TouchTerminalPresence 幂等推进 Terminal 活性（v0.9.1 C1）：
	//   - last_heartbeat 只前进不倒退（乱序/重复心跳不能把活性拉回过去）；
	//   - prevAvailability（调用方用服务端时钟对本心跳到达前状态的时间投影）与
	//     nextState 不同时，presence_revision 单调 +1，同时把 status 置回 online
	//     （legacy 列保持既有语义）并把持久投影推进到 nextState。
	// 返回最新 revision 与「本次调用是否发生投影变化」，供 presence invalidation
	// 按 revision 去重、单次发布（计划 §3.3）。
	// providerFactsJSON 为 nil 表示本次心跳未携带 Provider 事实（保持既有快照），
	// 非 nil 时整体替换（v0.9.2 P1 执行侧事实源）。
	TouchTerminalPresence(ctx context.Context, terminalID string, nowUnixMS int64, prevAvailability string, nextState string, providerFactsJSON *string) (revision int64, changed bool, err error)
	// ListPresenceSweepCandidates 列出「需要过期投影转换」的 Terminal（只返回会
	// 发生真实转换的行，避免已转换行饿死有界批次）：持久投影 online 且退出 suspect
	// 窗，或持久投影 unknown 且过了 offline deadline。按 last_heartbeat 升序、
	// 最多 limit 条（v0.9.1 P1）。
	ListPresenceSweepCandidates(ctx context.Context, suspectBeforeUnixMS, deadlineBeforeUnixMS int64, limit int) ([]TerminalRow, error)
	// PersistPresenceProjection 原子推进持久投影（不推进活性、不改 last_heartbeat）；
	// setStatus 非空时同步 legacy status 列（offline 写 'offline'，unknown 保持不动）。
	PersistPresenceProjection(ctx context.Context, terminalID string, nextState string, setStatus string) (revision int64, changed bool, err error)
	// UpsertDaemonTerminal 只更新 Daemon 声明的白名单元数据；工作区绝对路径和 Provider 正文不允许写入 Relay。
	UpsertDaemonTerminal(ctx context.Context, t TerminalRow) error

	// Project / Workspace
	CreateProject(ctx context.Context, p ProjectRow) error
	ListProjects(ctx context.Context, accountID string) ([]ProjectRow, error)
	CreateWorkspace(ctx context.Context, w WorkspaceRow) error
	// UpdateWorkspaceDSHMetadata 只由同步回执把已确认的同一 identity 升级为 DSH 投影。
	// 它不改 canonical root 或 home Terminal，避免展示元数据反向改变权限边界。
	UpdateWorkspaceDSHMetadata(ctx context.Context, id, displayName string) error
	WorkspaceByID(ctx context.Context, id string) (WorkspaceRow, error)
	ListWorkspaces(ctx context.Context, accountID string) ([]WorkspaceRow, error)

	// Session 与 SessionInstance
	CreateSession(ctx context.Context, s SessionRow) error
	SessionByID(ctx context.Context, id string) (SessionRow, error)
	ListSessions(ctx context.Context, accountID string) ([]SessionRow, error)
	ListArchivedSessions(ctx context.Context, accountID string) ([]SessionRow, error)
	ListRunningSessions(ctx context.Context, accountID string) ([]SessionRow, error)
	ArchiveSession(ctx context.Context, id string, archivedAtUnixMS int64) error
	UnarchiveSession(ctx context.Context, id string) error
	SetSessionStatus(ctx context.Context, id, status string) error
	SetSessionStatusAt(ctx context.Context, id, status string, activityAtUnixMS int64) error
	// SetSessionStatusKeepActivity 只翻转状态不改活动时间；历史收口/清扫专用。
	SetSessionStatusKeepActivity(ctx context.Context, id, status string) error
	SetSessionLastSeq(ctx context.Context, id string, lastSeq int64) error
	SetSessionInstance(ctx context.Context, id, instanceID string) error
	SetSessionModel(ctx context.Context, id, model string) error
	// SetSessionPermissionModes 保存会话级 permission mode 快照（v0.8.5 §3.4）。
	// modesJSON 必须是合法 JSON 数组（由调用方序列化）；Relay 只存快照不下发明文。
	SetSessionPermissionModes(ctx context.Context, id, modeID, modesJSON string) error
	// SetSessionAgentPreset 保存会话 joined 的 DSH agent preset id 快照（v0.8.5 §3.8）。
	SetSessionAgentPreset(ctx context.Context, id, presetID string) error
	// SetSessionContentDEK 记录会话内容 DEK 的 opaque id（ADR-016）；空串清除。
	SetSessionContentDEK(ctx context.Context, id, dekID string) error
	SessionByParentForkKey(ctx context.Context, parentSessionID, idempotencyKey string) (SessionRow, error)
	CreateInstance(ctx context.Context, i InstanceRow) error
	InstanceByID(ctx context.Context, id string) (InstanceRow, error)

	// 会话事件：event_seq 只在单个会话内单调；account_event_cursor 是账号 SSE 恢复使用的
	// 跨会话全局顺序。两者不能相互替代。
	AppendEvent(ctx context.Context, e SessionEventRow) (int64, error)
	ListEventsAfter(ctx context.Context, sessionID string, afterSeq int64) ([]SessionEventRow, error)
	ListAccountEventsAfter(ctx context.Context, accountID string, afterCursor int64) ([]SessionEventRow, error)

	// 命令（idempotency 在应用层用 (scope_hash,idempotency_key) 校验）
	CreateCommand(ctx context.Context, c CommandRow) error
	CommandByID(ctx context.Context, id string) (CommandRow, error)
	CommandByScopeKey(ctx context.Context, scopeHash, idempotencyKey string) (CommandRow, error)
	// ReleaseCommandIdempotencyKey 归档已终态命令的幂等键，使下一次独立操作可创建新命令。
	// 调用方必须在事务内确认该命令允许重试，且 newKey 保持同一 scope 内唯一。
	ReleaseCommandIdempotencyKey(ctx context.Context, id, newKey string) error
	UpdateCommandStatus(ctx context.Context, id, status string) error
	// ExpireStaleCommands 把会话内 lease_epoch 低于新 epoch 且仍未终态（accepted/running）
	// 的命令收敛为 expired，返回受影响行数。必须在 AcquireLease 的同一事务内调用，
	// 保证"旧控制权失效"与"新 epoch 生效"原子可见。
	ExpireStaleCommands(ctx context.Context, sessionID string, belowEpoch int64) (int64, error)
	// SetCommandReadResponse 只保存 Web 临时公钥可解的 response envelope；调用方不得传入文件、代码或 diff 明文。
	SetCommandReadResponse(ctx context.Context, id, envelopeJSON string) error
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

	// workspace.create 的结果单独保存，避免 canonical_root 进入普通 command result/客户端投影。
	UpsertWorkspaceCommandResult(ctx context.Context, result WorkspaceCommandResultRow) error
	WorkspaceCommandResultByCommandID(ctx context.Context, commandID string) (WorkspaceCommandResultRow, error)

	// Delegation：父子 Session 图只存密文 envelope 与白名单索引，Relay 不解密任务书或摘要。
	CreateDelegation(ctx context.Context, d DelegationRow) error
	DelegationByID(ctx context.Context, id string) (DelegationRow, error)
	DelegationByParentKey(ctx context.Context, parentSessionID, idempotencyKey string) (DelegationRow, error)
	ListDelegationsByParent(ctx context.Context, parentSessionID string) ([]DelegationRow, error)
	UpdateDelegation(ctx context.Context, id, status, childSessionID string, updatedAtUnixMS int64) error

	// Message feedback：Relay 只保存消息级白名单反馈，不保存消息正文或 Provider payload。
	ListMessageFeedback(ctx context.Context, sessionID string) ([]MessageFeedbackRow, error)
	MessageFeedbackByMessage(ctx context.Context, sessionID, messageID string) (MessageFeedbackRow, error)
	CreateMessageFeedback(ctx context.Context, row MessageFeedbackRow) error
	UpdateMessageFeedback(ctx context.Context, row MessageFeedbackRow, expectedVersion int64) (bool, error)
	DeleteMessageFeedback(ctx context.Context, sessionID, messageID string, expectedVersion int64) (bool, error)

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
	// ListAttachmentChunks 按块序返回附件全部密文块（v0.8.5 §3.3 Daemon 读取端点用）。
	ListAttachmentChunks(ctx context.Context, attachmentID string) ([]AttachmentChunkRow, error)
	CountAttachmentChunks(ctx context.Context, attachmentID string) (int, error)
	CompleteAttachment(ctx context.Context, attachmentID, idempotencyKey string) (bool, error)

	// Terminal 签名一次性 nonce：插入成功表示首次使用；重复 nonce 返回稳定错误。
	// nowUnixMS 用于过期清理阈值；expiresAtUnixMS 是新 nonce 的保留截止时间。
	ConsumeTerminalAuthNonce(ctx context.Context, keyID, nonce string, nowUnixMS, expiresAtUnixMS int64) error

	// ---- Terminal 签名认证（v0.6 P1） ----

	// hello 一次性 challenge：签发后绑定设备；消费必须恰好一次，跨重启仍可查重。
	CreateTerminalAuthChallenge(ctx context.Context, c TerminalAuthChallengeRow) error
	// ConsumeTerminalAuthChallenge 把未过期且未消费的 challenge 置为已消费；
	// 返回 false 表示不存在、已过期或已被消费，调用方必须按重放拒绝。
	ConsumeTerminalAuthChallenge(ctx context.Context, deviceID, challenge string, nowUnixMS int64) (bool, error)
	// DeleteExpiredTerminalAuthChallenges 清理已过期的 challenge 行，防止表无限增长。
	DeleteExpiredTerminalAuthChallenges(ctx context.Context, nowUnixMS int64) error

	// 设备签名公钥登记：key_id 唯一；轮换窗口内同一设备最多两个 active key。
	CreateTerminalIdentityKey(ctx context.Context, k TerminalIdentityKeyRow) error
	TerminalIdentityKeyByID(ctx context.Context, keyID string) (TerminalIdentityKeyRow, error)
	ListTerminalIdentityKeys(ctx context.Context, deviceID string) ([]TerminalIdentityKeyRow, error)
	CountActiveTerminalIdentityKeys(ctx context.Context, deviceID string) (int, error)
	// RetireOtherTerminalIdentityKeys 在轮换收口时把设备上除 keepKeyID 外的 active key 全部 retired。
	RetireOtherTerminalIdentityKeys(ctx context.Context, deviceID, keepKeyID string, nowUnixMS int64) error
	// RetireTerminalIdentityKey 撤销单个 key（设备撤销或 owner 主动吊销）；返回 false 表示不存在。
	RetireTerminalIdentityKey(ctx context.Context, keyID string, nowUnixMS int64) (bool, error)

	// Outbox：pending → delivered/failed 的状态机由领域层驱动；failed 行保留并可恢复。
	EnqueueOutbox(ctx context.Context, o OutboxRow) error
	ClaimOutbox(ctx context.Context, id int64) (OutboxRow, error)
	MarkOutboxDone(ctx context.Context, id int64) error
	MarkOutboxFailed(ctx context.Context, id int64, attempts int) error
	ListPendingOutbox(ctx context.Context, limit int) ([]OutboxRow, error)
	// RequeueFailedOutbox 把 failed 行复位为 pending 并清零退避（人工/自动恢复入口）。
	RequeueFailedOutbox(ctx context.Context) (int64, error)
	// CountOutboxByStatus 返回 outbox 各状态的行数投影，用于不含正文的可观测性指标。
	CountOutboxByStatus(ctx context.Context) (pending, failed, delivered int64, err error)

	// RelayGeneration 读取持久化的 relay_generation（v0.8.9 P1 / V089-01）。
	// 值在首次建库时生成并持久（同库稳定/重建必变/备份随文件走）；
	// 元数据缺失时返回空串（旧库漂移由 Open 的 ensureRelayGeneration 兜底）。
	RelayGeneration(ctx context.Context) (string, error)

	// Usage（ADR-010）：usage_key_hash 唯一约束去重；聚合只读白名单整数计数。
	// UpsertUsageEvent 返回 false 表示该 usage key 已存在（重复上传，不重复累加）。
	UpsertUsageEvent(ctx context.Context, u UsageEventRow) (bool, error)
	// AggregateUsage 返回账号在 [startDay, endDay]（含两端）UTC 日桶内按 Provider 的聚合。
	AggregateUsage(ctx context.Context, accountID, startDay, endDay string) ([]UsageDayAggregateRow, error)
	// SessionUsageSummary 返回单会话白名单用量和最新模型/计时投影。
	SessionUsageSummary(ctx context.Context, accountID, sessionID string) (SessionUsageSummaryRow, error)

	// 事务：domain 层需要原子提交时使用
	WithTx(ctx context.Context, fn func(ctx context.Context, tx Repository) error) error
}

// UsageEventRow 是 usage_events 表的行投影。字段全部为白名单整数或归属标识，
// 不包含 prompt、回复、费用、精确时间或会话正文。
type UsageEventRow struct {
	UsageKeyHash        string
	AccountID           string
	TerminalID          string
	SessionID           string
	Provider            string
	Model               string
	UTCDay              string
	InputTokens         int64
	OutputTokens        int64
	CacheReadTokens     int64
	CacheWriteTokens    int64
	ContextWindowTokens int64
	TTFTMS              *int64
	DecodeThroughput    *float64
	SchemaVersion       int64
	CreatedAtUnixMS     int64
}

// UsageDayAggregateRow 是账号某 UTC 日桶内单个 Provider 的聚合投影。
type UsageDayAggregateRow struct {
	Provider         string
	UTCDay           string
	InputTokens      int64
	OutputTokens     int64
	CacheReadTokens  int64
	CacheWriteTokens int64
}

// SessionUsageSummaryRow 是单会话 composer stats 的白名单聚合投影。
type SessionUsageSummaryRow struct {
	InputTokens         int64
	OutputTokens        int64
	CacheReadTokens     int64
	CacheWriteTokens    int64
	ContextWindowTokens int64
	Model               string
	TTFTMS              *int64
	DecodeThroughput    *float64
	HasData             bool
}

// AuditRow 是 audit_events 表的脱敏投影。metadata_json 只允许白名单字段。
type AuditRow struct {
	ID           int64
	Action       string
	MetadataJSON string
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
	ID               string
	DeviceID         string
	AccountID        string
	Hostname         string
	Platform         string
	Status           string
	LastSeenUnixMS   int64
	ProtocolVersion  int
	DaemonVersion    string
	CapabilitiesJSON string
	// ProviderFactsJSON 是执行侧上报的 Provider 运行时事实（v0.9.2 P1，additive）。
	// 空串表示旧 Daemon 未上报；内容只含版本、失败原因与模型目录安全元数据。
	ProviderFactsJSON   string
	LastHeartbeatUnixMS int64
	// PresenceRevision 是 availability 投影的单调版本号（v0.9.1 C1，additive）。
	// 只在投影真实变化时 +1；客户端与 SSE invalidation 以它做去重与丢帧补偿。
	PresenceRevision int64
	// PresenceProjectedState 是最近一次持久化的 availability 投影（空串表示
	// 升级前的存量行，首次投影时按 legacy status 列初始化）。
	PresenceProjectedState string
}

// ProjectRow 是 projects 表的行投影。
type ProjectRow struct {
	ID            string
	AccountID     string
	Fingerprint   string
	EncryptedName string
}

const (
	// WorkspaceOriginManaged 是既有受管工作区的保守默认值。
	WorkspaceOriginManaged = "managed"
	// WorkspaceOriginDSH 表示由受控 DSH 扫描确认的工作区。
	WorkspaceOriginDSH = "dsh"
)

// WorkspaceRow 是 workspaces 表的行投影。
type WorkspaceRow struct {
	ID            string
	ProjectID     string
	TerminalID    string
	CanonicalRoot string
	Branch        string
	Status        string
	// Origin 和 DisplayName 是可公开的安全投影；CanonicalRoot 永远不能映射到 HTTP view。
	Origin      string
	DisplayName string
}

// SessionRow 是 sessions 表的行投影。
type SessionRow struct {
	ID                  string
	WorkspaceID         string
	AccountID           string
	Status              string
	Provider            string
	Model               string
	LastSeq             int64
	CurrentInstanceID   string
	ParentSessionID     string
	ForkedFromMessageID string
	ForkIdempotencyKey  string
	ArchivedAtUnixMS    int64
	// LastActivityAtUnixMS 是 Relay 最近一次可审计状态/事件活动时间；它只用于
	// stale-running 恢复判定，不携带或推导会话正文。
	LastActivityAtUnixMS int64
	// PermissionMode 与 AvailablePermissionModesJSON 是会话级 mode 快照（v0.8.5 §3.4）：
	// 由 Daemon 上行同步，只含 mode id/名称等非敏感元数据；空串/[] 表示尚无快照。
	PermissionMode               string
	AvailablePermissionModesJSON string
	// AgentPresetID 是会话实际 joined 的 DSH agent preset（v0.8.5 §3.8，只读投影）。
	AgentPresetID string
	// ContentDEKID 是会话内容 DEK 的 opaque id（v0.8.5 §3.2 / ADR-016）；空串表示
	// 尚无内容密钥（附件 fail-closed）。wrapped blob 在 device_key_wraps 表，不在此列。
	ContentDEKID string
	// DisplayName 是会话展示标题（v0.9.4：DSH 导入时从本地会话标题/首条用户消息
	// 提取的脱敏元数据）；空串表示无标题，客户端按 id 短码回退。
	DisplayName string
}

// InstanceRow 是 session_instances 表的行投影。
type InstanceRow struct {
	ID         string
	SessionID  string
	LeaseEpoch int64
	Status     string
	WakeResult string
}

// SessionEventRow 是 session_events 表及其账号流游标的联合投影。envelope 只存密文/脱敏 JSON；
// AccountEventCursor 仅用于传输恢复，不能被误作业务事件序号或用于解密。
type SessionEventRow struct {
	SessionID          string
	EventSeq           int64
	AccountEventCursor int64
	EventType          string
	// TerminalStatus 是 turn.completed 的非敏感生命周期投影；其它事件为空。
	// Provider stop_reason 仍只存在 EnvelopeJSON 密文中。
	TerminalStatus string
	EnvelopeJSON   string
	// CreatedAtUnixMS 是事件生成时间；旧事件缺失时为 0。
	CreatedAtUnixMS int64
	// CommandID 是 daemon_event_receipts 关联回投的命令 ID（V094-06 冻结投影）。
	// 仅同一 session 内的事件 receipt 参与 JOIN；旧事件或非命令路径事件为空，
	// 客户端必须按「关联缺失」降级，不得据此猜测消息归属或改写历史。
	CommandID string
}

// CommandRow 是 commands 表的行投影。
type CommandRow struct {
	ID                       string
	AccountID                string
	SessionID                string
	Kind                     string
	Status                   string
	ScopeHash                string
	IdempotencyKey           string
	LeaseEpoch               int64
	TargetInstanceID         string
	TargetTerminalID         string
	CiphertextJSON           string
	ReadResponseEnvelopeJSON string
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

// WorkspaceCommandResultRow 是 workspace.create/workspace.sync_dsh 专用的 daemon 回执。
// canonical_root 只在 Relay 内部用于登记 Workspace，不得由普通命令接口返回。
// 对 workspace.sync_dsh，CanonicalRoot 字段存放 JSON 编码的 workspace_ids 白名单。
type WorkspaceCommandResultRow struct {
	CommandID       string
	AccountID       string
	WorkspaceID     string
	CanonicalRoot   string
	Status          string
	ErrorCode       string
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

// MessageFeedbackRow 是会话消息级反馈 sidecar。message_id 是 Host/Provider 投影出的稳定
// 消息标识；Relay 不校验或保存消息正文。
type MessageFeedbackRow struct {
	AccountID         string
	SessionID         string
	MessageID         string
	Rating            string
	Note              string
	Version           int64
	UpdatedByDeviceID string
	UpdatedAtUnixMS   int64
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
	// NextAttemptAtUnixMS 是指数退避后的最早重试时间；0 表示立即可重试。
	NextAttemptAtUnixMS int64
}

// TerminalAuthChallengeRow 是 terminal_auth_challenges 表的行投影。
// challenge 只保存随机值本身（非密钥），绑定设备且只能被消费一次。
type TerminalAuthChallengeRow struct {
	Challenge       string
	DeviceID        string
	ExpiresAtUnixMS int64
	CreatedAtUnixMS int64
}

// TerminalIdentityKeyRow 是 terminal_identity_keys 表的行投影。
// 只保存 Ed25519 公钥与状态；私钥永远不离开 Terminal 本机。
type TerminalIdentityKeyRow struct {
	KeyID           string
	DeviceID        string
	AccountID       string
	PublicKey       string
	Status          string
	CreatedAtUnixMS int64
	RetiredAtUnixMS int64
}
