package store

import (
	"database/sql"
	"fmt"
	"net/url"
	"regexp"
	"strings"

	// 使用纯 Go SQLite 驱动，保证 Relay 和 Daemon 无需 CGO 或外部数据库服务。
	_ "modernc.org/sqlite"
)

// 编号迁移。只允许 additive 变更；删除列必须另开兼容窗口。
var migrations = []string{
	`PRAGMA foreign_keys = ON;`,
	`CREATE TABLE IF NOT EXISTS schema_migrations (
		version INTEGER PRIMARY KEY,
		applied_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
	);`,
	`CREATE TABLE IF NOT EXISTS accounts (
		id TEXT PRIMARY KEY,
		email TEXT NOT NULL UNIQUE,
		password_hash BLOB NOT NULL,
		created_at INTEGER NOT NULL
	);`,
	`CREATE TABLE IF NOT EXISTS devices (
		id TEXT PRIMARY KEY,
		account_id TEXT NOT NULL,
		role TEXT NOT NULL,
		status TEXT NOT NULL,
		display_name TEXT NOT NULL,
		platform TEXT,
		identity_public_key TEXT NOT NULL,
		encryption_public_key TEXT NOT NULL,
		last_seen_unix_ms INTEGER NOT NULL DEFAULT 0,
		FOREIGN KEY(account_id) REFERENCES accounts(id)
	);`,
	`CREATE TABLE IF NOT EXISTS token_families (
		id TEXT PRIMARY KEY,
		account_id TEXT NOT NULL,
		device_id TEXT,
		refresh_hash TEXT NOT NULL,
		revoked INTEGER NOT NULL DEFAULT 0,
		created_at INTEGER NOT NULL,
		FOREIGN KEY(account_id) REFERENCES accounts(id)
	);`,
	`CREATE TABLE IF NOT EXISTS access_tokens (
		token TEXT PRIMARY KEY,
		account_id TEXT NOT NULL,
		device_id TEXT,
		role TEXT NOT NULL,
		expires_at INTEGER NOT NULL
	);`,
	`CREATE TABLE IF NOT EXISTS pairing_requests (
		id TEXT PRIMARY KEY,
		account_id TEXT NOT NULL,
		role TEXT NOT NULL,
		status TEXT NOT NULL,
		display_name TEXT NOT NULL,
		identity_public_key TEXT NOT NULL,
		encryption_public_key TEXT NOT NULL,
		platform TEXT,
		expires_at INTEGER NOT NULL,
		FOREIGN KEY(account_id) REFERENCES accounts(id)
	);`,
	`CREATE TABLE IF NOT EXISTS terminals (
		id TEXT PRIMARY KEY,
		device_id TEXT NOT NULL UNIQUE,
		account_id TEXT NOT NULL,
		hostname TEXT,
		platform TEXT,
		status TEXT NOT NULL,
		last_seen_unix_ms INTEGER NOT NULL DEFAULT 0,
		FOREIGN KEY(device_id) REFERENCES devices(id)
	);`,
	`CREATE TABLE IF NOT EXISTS projects (
		id TEXT PRIMARY KEY,
		account_id TEXT NOT NULL,
		fingerprint TEXT NOT NULL,
		encrypted_name TEXT,
		FOREIGN KEY(account_id) REFERENCES accounts(id)
	);`,
	`CREATE TABLE IF NOT EXISTS workspaces (
		id TEXT PRIMARY KEY,
		project_id TEXT NOT NULL,
		terminal_id TEXT NOT NULL,
		canonical_root TEXT NOT NULL,
		branch TEXT,
		status TEXT NOT NULL,
		FOREIGN KEY(project_id) REFERENCES projects(id)
	);`,
	`CREATE TABLE IF NOT EXISTS sessions (
		id TEXT PRIMARY KEY,
		workspace_id TEXT NOT NULL,
		account_id TEXT NOT NULL,
		status TEXT NOT NULL,
		provider TEXT NOT NULL,
		last_seq INTEGER NOT NULL DEFAULT 0,
		current_instance_id TEXT,
		FOREIGN KEY(workspace_id) REFERENCES workspaces(id)
	);`,
	`CREATE TABLE IF NOT EXISTS session_instances (
		id TEXT PRIMARY KEY,
		session_id TEXT NOT NULL,
		lease_epoch INTEGER NOT NULL,
		status TEXT NOT NULL,
		wake_result TEXT,
		FOREIGN KEY(session_id) REFERENCES sessions(id)
	);`,
	`CREATE TABLE IF NOT EXISTS session_events (
		session_id TEXT NOT NULL,
		event_seq INTEGER NOT NULL,
		event_type TEXT NOT NULL,
		envelope_json TEXT NOT NULL,
		created_at_unix_ms INTEGER NOT NULL DEFAULT 0,
		PRIMARY KEY(session_id, event_seq)
	);`,
	`CREATE TABLE IF NOT EXISTS commands (
		id TEXT PRIMARY KEY,
		account_id TEXT NOT NULL,
		session_id TEXT,
		kind TEXT NOT NULL,
		status TEXT NOT NULL,
		scope_hash TEXT NOT NULL,
		idempotency_key TEXT NOT NULL,
		lease_epoch INTEGER,
		target_instance_id TEXT,
		ciphertext_json TEXT,
		UNIQUE(scope_hash, idempotency_key)
	);`,
	`CREATE TABLE IF NOT EXISTS control_leases (
		session_id TEXT PRIMARY KEY,
		device_id TEXT NOT NULL,
		epoch INTEGER NOT NULL,
		instance_id TEXT
	);`,
	`CREATE TABLE IF NOT EXISTS outbox (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		kind TEXT NOT NULL,
		payload_json TEXT NOT NULL,
		status TEXT NOT NULL,
		attempts INTEGER NOT NULL DEFAULT 0
	);`,
	// v0.6 P2：outbox 增加指数退避列。旧库升级只加列；'done' 为历史 delivered 语义别名。
	`ALTER TABLE outbox ADD COLUMN next_attempt_at_unix_ms INTEGER NOT NULL DEFAULT 0;`,
	`CREATE TABLE IF NOT EXISTS audit_events (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		account_id TEXT,
		action TEXT NOT NULL,
		metadata_json TEXT NOT NULL
	);`,
	// 设备 DEK 包装：服务器只存密文包装与元数据，不存会话正文或明文密钥。
	`CREATE TABLE IF NOT EXISTS device_key_wraps (
		dek_id TEXT NOT NULL,
		recipient_device_id TEXT NOT NULL,
		sender_device_id TEXT NOT NULL,
		wrapped_dek BLOB NOT NULL,
		created_at INTEGER NOT NULL,
		PRIMARY KEY(dek_id, recipient_device_id)
	);`,
	// 恢复码只存哈希，错误次数受限于冷却窗口。
	`CREATE TABLE IF NOT EXISTS recovery_codes (
		account_id TEXT PRIMARY KEY,
		code_hash TEXT NOT NULL,
		failed_attempts INTEGER NOT NULL DEFAULT 0,
		locked_until INTEGER NOT NULL DEFAULT 0,
		created_at INTEGER NOT NULL
	);`,
	// 同一账号内同一身份公钥只可绑定一台设备；空公钥仅允许尚未 bootstrap 的初始 owner。
	`CREATE UNIQUE INDEX IF NOT EXISTS devices_account_identity_public_key
		 ON devices(account_id, identity_public_key)
		 WHERE identity_public_key <> '';`,
	// refresh family 必须保存签发时的角色，轮换时不能依赖设备查找而把 Admin/Web 降权或误提权。
	`ALTER TABLE token_families ADD COLUMN role TEXT NOT NULL DEFAULT 'web';`,
	// 附件正文、文件名和解密信息均不进入 Relay；仅保留密文块、白名单 MIME/大小和会话归属。
	`CREATE TABLE IF NOT EXISTS attachments (
		id TEXT PRIMARY KEY,
		session_id TEXT NOT NULL,
		account_id TEXT NOT NULL,
		mime_type TEXT NOT NULL,
		byte_size INTEGER NOT NULL,
		compression TEXT NOT NULL,
		total_chunks INTEGER NOT NULL,
		metadata_ciphertext BLOB NOT NULL,
		created_by_device_id TEXT NOT NULL,
		lease_epoch INTEGER NOT NULL,
		status TEXT NOT NULL,
		complete_idempotency_key TEXT,
		FOREIGN KEY(session_id) REFERENCES sessions(id)
	);`,
	`CREATE TABLE IF NOT EXISTS attachment_chunks (
		attachment_id TEXT NOT NULL,
		chunk_index INTEGER NOT NULL,
		idempotency_key TEXT NOT NULL,
		ciphertext BLOB NOT NULL,
		ciphertext_sha256 TEXT NOT NULL,
		PRIMARY KEY(attachment_id, chunk_index),
		UNIQUE(attachment_id, idempotency_key),
		FOREIGN KEY(attachment_id) REFERENCES attachments(id)
	);`,
	// Delegation 只保存父子索引与客户端加密 envelope。任务书和结果摘要均不允许以明文进入 Relay。
	`CREATE TABLE IF NOT EXISTS delegations (
		id TEXT PRIMARY KEY,
		account_id TEXT NOT NULL,
		parent_session_id TEXT NOT NULL,
		child_session_id TEXT,
		target_provider TEXT NOT NULL,
		status TEXT NOT NULL,
		task_envelope_json TEXT NOT NULL,
		task_envelope_sha256 TEXT NOT NULL,
		summary_envelope_json TEXT NOT NULL,
		summary_envelope_sha256 TEXT NOT NULL,
		idempotency_key TEXT NOT NULL,
		parent_lease_epoch INTEGER NOT NULL,
		created_by_device_id TEXT NOT NULL,
		created_at_unix_ms INTEGER NOT NULL,
		updated_at_unix_ms INTEGER NOT NULL,
		UNIQUE(parent_session_id, idempotency_key),
		FOREIGN KEY(parent_session_id) REFERENCES sessions(id),
		FOREIGN KEY(child_session_id) REFERENCES sessions(id)
	);`,
	`CREATE INDEX IF NOT EXISTS delegations_parent_session_idx
		ON delegations(parent_session_id, updated_at_unix_ms DESC);`,
	// P2 Daemon-Relay 命令流。所有变更均为 additive，旧客户端创建的未绑定
	// Workspace/Command 可以继续读取，但不会被投递给任意 Terminal。
	`ALTER TABLE terminals ADD COLUMN protocol_version INTEGER NOT NULL DEFAULT 0;`,
	`ALTER TABLE terminals ADD COLUMN daemon_version TEXT NOT NULL DEFAULT '';`,
	`ALTER TABLE terminals ADD COLUMN capabilities_json TEXT NOT NULL DEFAULT '[]';`,
	`ALTER TABLE terminals ADD COLUMN last_heartbeat_unix_ms INTEGER NOT NULL DEFAULT 0;`,
	`ALTER TABLE commands ADD COLUMN target_terminal_id TEXT NOT NULL DEFAULT '';`,
	`CREATE TABLE IF NOT EXISTS daemon_command_deliveries (
		terminal_id TEXT NOT NULL,
		delivery_seq INTEGER NOT NULL,
		command_id TEXT NOT NULL UNIQUE,
		ack_kind TEXT NOT NULL DEFAULT '',
		result_status TEXT NOT NULL DEFAULT '',
		error_code TEXT NOT NULL DEFAULT '',
		created_at_unix_ms INTEGER NOT NULL,
		updated_at_unix_ms INTEGER NOT NULL,
		PRIMARY KEY(terminal_id, delivery_seq),
		FOREIGN KEY(terminal_id) REFERENCES terminals(id),
		FOREIGN KEY(command_id) REFERENCES commands(id)
	);`,
	`CREATE INDEX IF NOT EXISTS daemon_deliveries_terminal_pending_idx
		ON daemon_command_deliveries(terminal_id, delivery_seq);`,
	`CREATE TABLE IF NOT EXISTS daemon_event_receipts (
		event_id TEXT PRIMARY KEY,
		terminal_id TEXT NOT NULL,
		command_id TEXT NOT NULL,
		session_id TEXT NOT NULL,
		event_seq INTEGER NOT NULL DEFAULT 0,
		created_at_unix_ms INTEGER NOT NULL,
		FOREIGN KEY(terminal_id) REFERENCES terminals(id),
		FOREIGN KEY(command_id) REFERENCES commands(id),
		FOREIGN KEY(session_id) REFERENCES sessions(id)
	);`,
	`CREATE INDEX IF NOT EXISTS daemon_event_receipts_command_idx
		ON daemon_event_receipts(command_id, event_seq);`,
	// v0.7 workspace.create 专用回执。canonical_root 只供 Relay 完成登记，
	// 不复用普通 command result，避免路径意外进入客户端/日志投影。
	`CREATE TABLE IF NOT EXISTS workspace_command_results (
		command_id TEXT PRIMARY KEY,
		account_id TEXT NOT NULL,
		workspace_id TEXT NOT NULL,
		canonical_root TEXT NOT NULL DEFAULT '',
		status TEXT NOT NULL,
		error_code TEXT NOT NULL DEFAULT '',
		created_at_unix_ms INTEGER NOT NULL,
		FOREIGN KEY(command_id) REFERENCES commands(id)
	);`,
	`CREATE INDEX IF NOT EXISTS workspace_command_results_account_idx
		ON workspace_command_results(account_id, workspace_id);`,
	// P3 usage（ADR-010）：Relay 只保留白名单整数计数与 UTC 日桶，不保存 prompt、
	// 回复、工具参数、路径、费用或精确事件时间。usage_key_hash 唯一约束保证
	// Daemon 断线 outbox 重复上传返回同一 canonical receipt，不重复累加。
	`CREATE TABLE IF NOT EXISTS usage_events (
		usage_key_hash TEXT PRIMARY KEY,
		account_id TEXT NOT NULL,
		terminal_id TEXT NOT NULL,
		provider TEXT NOT NULL,
		utc_day TEXT NOT NULL,
		input_tokens INTEGER NOT NULL,
		output_tokens INTEGER NOT NULL,
		cache_read_tokens INTEGER NOT NULL DEFAULT 0,
		cache_write_tokens INTEGER NOT NULL DEFAULT 0,
		schema_version INTEGER NOT NULL DEFAULT 1,
		created_at_unix_ms INTEGER NOT NULL,
		FOREIGN KEY(account_id) REFERENCES accounts(id),
		FOREIGN KEY(terminal_id) REFERENCES terminals(id)
	);`,
	`CREATE INDEX IF NOT EXISTS usage_events_account_day_idx
		ON usage_events(account_id, utc_day, provider);`,
	// 账号 SSE 需要跨会话且不会复用的恢复 cursor。session_events.event_seq 只在 session
	// 范围内单调，不能直接放进 Last-Event-ID；本表以独立自增 cursor 记录同一事务内已持久化
	// 的事件。旧库按稳定顺序回填，后续 AppendEvent 会同步写入。
	`CREATE TABLE IF NOT EXISTS account_event_log (
		cursor INTEGER PRIMARY KEY AUTOINCREMENT,
		session_id TEXT NOT NULL,
		event_seq INTEGER NOT NULL,
		UNIQUE(session_id, event_seq),
		FOREIGN KEY(session_id, event_seq) REFERENCES session_events(session_id, event_seq)
	);`,
	`INSERT OR IGNORE INTO account_event_log(session_id, event_seq)
		SELECT session_id, event_seq FROM session_events ORDER BY session_id, event_seq;`,
	`CREATE INDEX IF NOT EXISTS account_event_log_session_cursor_idx
		ON account_event_log(session_id, cursor);`,
	// P4-D Web 只读响应只保存浏览器临时公钥可解的 envelope；不能为调试便利新增明文缓存。
	`ALTER TABLE commands ADD COLUMN readonly_response_envelope_json TEXT NOT NULL DEFAULT '';`,
	// v0.5 feedback/fork/model/timing：所有字段均为白名单元数据。Relay 不保存消息正文、
	// prompt、回复、工具参数或 Provider 私有 payload；fork 只创建控制面 child Session，
	// Provider seed/执行仍需 Daemon/Adapter 后续授权。
	`ALTER TABLE sessions ADD COLUMN parent_session_id TEXT NOT NULL DEFAULT '';`,
	`ALTER TABLE sessions ADD COLUMN forked_from_message_id TEXT NOT NULL DEFAULT '';`,
	`ALTER TABLE sessions ADD COLUMN fork_idempotency_key TEXT NOT NULL DEFAULT '';`,
	`ALTER TABLE sessions ADD COLUMN model TEXT NOT NULL DEFAULT '';`,
	`CREATE UNIQUE INDEX IF NOT EXISTS sessions_parent_fork_key_idx
		ON sessions(parent_session_id, fork_idempotency_key)
		WHERE parent_session_id <> '' AND fork_idempotency_key <> '';`,
	`CREATE TABLE IF NOT EXISTS message_feedback (
		account_id TEXT NOT NULL,
		session_id TEXT NOT NULL,
		message_id TEXT NOT NULL,
		rating TEXT NOT NULL,
		note TEXT,
		version INTEGER NOT NULL,
		updated_by_device_id TEXT NOT NULL,
		updated_at_unix_ms INTEGER NOT NULL,
		PRIMARY KEY(session_id, message_id),
		FOREIGN KEY(session_id) REFERENCES sessions(id)
	);`,
	`CREATE INDEX IF NOT EXISTS message_feedback_account_session_idx
		ON message_feedback(account_id, session_id, updated_at_unix_ms DESC);`,
	`ALTER TABLE usage_events ADD COLUMN session_id TEXT NOT NULL DEFAULT '';`,
	`ALTER TABLE usage_events ADD COLUMN model TEXT NOT NULL DEFAULT '';`,
	`ALTER TABLE usage_events ADD COLUMN ttft_ms INTEGER;`,
	`ALTER TABLE usage_events ADD COLUMN decode_throughput REAL;`,
	`CREATE INDEX IF NOT EXISTS usage_events_session_idx
		ON usage_events(account_id, session_id, created_at_unix_ms DESC)
		WHERE session_id <> '';`,
	// v0.6 Terminal 签名 nonce 一次性状态。Relay 重启后仍能查重；过期记录由消费时顺带清理。
	`CREATE TABLE IF NOT EXISTS terminal_auth_nonces (
		key_id TEXT NOT NULL,
		nonce TEXT NOT NULL,
		expires_at_unix_ms INTEGER NOT NULL,
		created_at_unix_ms INTEGER NOT NULL,
		PRIMARY KEY(key_id, nonce)
	);`,
	`CREATE INDEX IF NOT EXISTS terminal_auth_nonces_expiry_idx
		ON terminal_auth_nonces(expires_at_unix_ms);`,
	// v0.6 P1 hello 一次性 challenge：绑定设备、限时有效、只能消费一次。
	// challenge 与 nonce 一样持久化在 SQLite，Relay 重启后未完成/已完成的挑战都不能被重复使用。
	`CREATE TABLE IF NOT EXISTS terminal_auth_challenges (
		challenge TEXT PRIMARY KEY,
		device_id TEXT NOT NULL,
		expires_at_unix_ms INTEGER NOT NULL,
		created_at_unix_ms INTEGER NOT NULL,
		consumed_at_unix_ms INTEGER NOT NULL DEFAULT 0
	);`,
	`CREATE INDEX IF NOT EXISTS terminal_auth_challenges_expiry_idx
		ON terminal_auth_challenges(expires_at_unix_ms);`,
	// v0.6 P1 设备签名公钥登记与轮换：key_id 是签名 canonical bytes 的 key id。
	// active 密钥可验签；轮换窗口内同一设备最多两个 active key（双读），
	// 新 key 首次成功签名后其余 active key 收口为 retired（一写）。
	`CREATE TABLE IF NOT EXISTS terminal_identity_keys (
		key_id TEXT PRIMARY KEY,
		device_id TEXT NOT NULL,
		account_id TEXT NOT NULL,
		public_key TEXT NOT NULL,
		status TEXT NOT NULL DEFAULT 'active',
		created_at_unix_ms INTEGER NOT NULL,
		retired_at_unix_ms INTEGER NOT NULL DEFAULT 0
	);`,
	`CREATE INDEX IF NOT EXISTS terminal_identity_keys_device_idx
		ON terminal_identity_keys(device_id, status);`,
	// 会话归档：保留全部密文事件与关联数据，仅从默认会话列表隐藏。
	`ALTER TABLE sessions ADD COLUMN archived_at_unix_ms INTEGER NOT NULL DEFAULT 0;`,
	// 会话活动时间只保存状态机活动的时间戳，供 stale-running 对账使用；不保存正文。
	`ALTER TABLE sessions ADD COLUMN last_activity_at_unix_ms INTEGER NOT NULL DEFAULT 0;`,
	// v0.8.1：历史 Workspace 一律保守标记为 managed；只有 Daemon 同步回执可以升级为 dsh。
	`ALTER TABLE workspaces ADD COLUMN origin TEXT NOT NULL DEFAULT 'managed';`,
	// display_name 是从 Daemon 扫描项目 basename 派生的安全投影，绝不保存完整 root。
	`ALTER TABLE workspaces ADD COLUMN display_name TEXT NOT NULL DEFAULT '';`,
	// v0.8.5：会话级 permission mode 目录（mode id 快照 + available modes JSON），
	// 由 Daemon 上行同步（Relay 不解析/不校验 mode 语义，只存快照供 controls 下发）。
	`ALTER TABLE sessions ADD COLUMN permission_mode TEXT NOT NULL DEFAULT '';`,
	`ALTER TABLE sessions ADD COLUMN available_permission_modes TEXT NOT NULL DEFAULT '[]';`,
	// v0.8.5：会话实际 joined 的 DSH agent preset id（由 Daemon 上行同步，只读投影）。
	`ALTER TABLE sessions ADD COLUMN agent_preset_id TEXT NOT NULL DEFAULT '';`,
}

// Open 打开 SQLite 并执行迁移。WAL + 外键是权威存储的固定配置。
func Open(path string) (*sql.DB, error) {
	dsn, err := relaySQLiteDSN(path)
	if err != nil {
		return nil, err
	}
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, err
	}
	// journal_mode 是文件级设置；busy_timeout、foreign_keys 与 BEGIN IMMEDIATE 则由 DSN
	// 注入每一条池连接。后者不能只在首条连接执行 PRAGMA，否则并发 HTTP 请求新开连接时会
	// 回退到 SQLite 默认的无等待 deferred transaction，产生 SQLITE_BUSY_SNAPSHOT。
	if _, err := db.Exec(`PRAGMA journal_mode=WAL;`); err != nil {
		db.Close()
		return nil, err
	}
	if err := Migrate(db); err != nil {
		db.Close()
		return nil, err
	}
	if err := ensureUsageContextWindowColumn(db); err != nil {
		db.Close()
		return nil, err
	}
	if err := ensureArchivedAtColumn(db); err != nil {
		db.Close()
		return nil, err
	}
	if err := ensureLastActivityColumn(db); err != nil {
		db.Close()
		return nil, err
	}
	if err := ensureWorkspaceOriginColumn(db); err != nil {
		db.Close()
		return nil, err
	}
	if err := ensureWorkspaceDisplayNameColumn(db); err != nil {
		db.Close()
		return nil, err
	}
	if err := ensureSessionEventTerminalStatusColumn(db); err != nil {
		db.Close()
		return nil, err
	}
	if err := ensureSessionEventCreatedAtColumn(db); err != nil {
		db.Close()
		return nil, err
	}
	if err := ensureSessionPermissionModeColumns(db); err != nil {
		db.Close()
		return nil, err
	}
	if err := ensureSessionContentDEKColumn(db); err != nil {
		db.Close()
		return nil, err
	}
	return db, nil
}

func ensureSessionEventCreatedAtColumn(db *sql.DB) error {
	return ensureTableColumn(db, "session_events", "created_at_unix_ms", `ALTER TABLE session_events ADD COLUMN created_at_unix_ms INTEGER NOT NULL DEFAULT 0`)
}

// ensureSessionPermissionModeColumns 用存在性检查补齐 sessions.permission_mode 与
// available_permission_modes（v0.8.5 §3.4）。两列都是非敏感 mode id 快照（不含
// 正文/路径），重复执行幂等；错位存量库与编号迁移中断路径都由此守卫兜底。
func ensureSessionPermissionModeColumns(db *sql.DB) error {
	if err := ensureTableColumn(db, "sessions", "permission_mode", `ALTER TABLE sessions ADD COLUMN permission_mode TEXT NOT NULL DEFAULT ''`); err != nil {
		return err
	}
	if err := ensureTableColumn(db, "sessions", "available_permission_modes", `ALTER TABLE sessions ADD COLUMN available_permission_modes TEXT NOT NULL DEFAULT '[]'`); err != nil {
		return err
	}
	return ensureTableColumn(db, "sessions", "agent_preset_id", `ALTER TABLE sessions ADD COLUMN agent_preset_id TEXT NOT NULL DEFAULT ''`)
}

// ensureSessionContentDEKColumn 补齐 sessions.content_dek_id（v0.8.5 §3.2 / ADR-016）：
// 会话内容 DEK 的 opaque id（非敏感；wrapped blob 在 device_key_wraps 表），
// 无 DEK 会话保持空串（fail-closed）。重复执行幂等。
func ensureSessionContentDEKColumn(db *sql.DB) error {
	return ensureTableColumn(db, "sessions", "content_dek_id", `ALTER TABLE sessions ADD COLUMN content_dek_id TEXT NOT NULL DEFAULT ''`)
}

// ensureArchivedAtColumn 用存在性检查补齐 sessions.archived_at_unix_ms。
// 与 ensureUsageContextWindowColumn 同理：编号迁移中段插入可能导致存量库跳过该列。
func ensureArchivedAtColumn(db *sql.DB) error {
	rows, err := db.Query(`SELECT name FROM pragma_table_info('sessions') WHERE name='archived_at_unix_ms'`)
	if err != nil {
		return err
	}
	defer rows.Close()
	if rows.Next() {
		return rows.Err()
	}
	if err := rows.Err(); err != nil {
		return err
	}
	_, err = db.Exec(`ALTER TABLE sessions ADD COLUMN archived_at_unix_ms INTEGER NOT NULL DEFAULT 0`)
	return err
}

func ensureLastActivityColumn(db *sql.DB) error {
	rows, err := db.Query(`SELECT name FROM pragma_table_info('sessions') WHERE name='last_activity_at_unix_ms'`)
	if err != nil {
		return err
	}
	defer rows.Close()
	if rows.Next() {
		return rows.Err()
	}
	if err := rows.Err(); err != nil {
		return err
	}
	_, err = db.Exec(`ALTER TABLE sessions ADD COLUMN last_activity_at_unix_ms INTEGER NOT NULL DEFAULT 0`)
	return err
}

// ensureWorkspaceOriginColumn 兼容历史 migration 编号漂移，缺失时以 fail-closed 的 managed 补齐。
func ensureWorkspaceOriginColumn(db *sql.DB) error {
	return ensureTableColumn(db, "workspaces", "origin", `ALTER TABLE workspaces ADD COLUMN origin TEXT NOT NULL DEFAULT 'managed'`)
}

// ensureWorkspaceDisplayNameColumn 只补空安全显示名；真实名称只能由后续 DSH 同步回执写入。
func ensureWorkspaceDisplayNameColumn(db *sql.DB) error {
	return ensureTableColumn(db, "workspaces", "display_name", `ALTER TABLE workspaces ADD COLUMN display_name TEXT NOT NULL DEFAULT ''`)
}

// ensureSessionEventTerminalStatusColumn 为 session_events 补齐非敏感终态投影。
// 该列只保存 idle/stopped（或空值），Provider stop_reason 仍在密文 envelope；
// 使用存在性检查兼容历史上可能跳过列表中段编号的存量库。
func ensureSessionEventTerminalStatusColumn(db *sql.DB) error {
	var tableCount int
	if err := db.QueryRow(`SELECT COUNT(1) FROM sqlite_master WHERE type='table' AND name='session_events'`).Scan(&tableCount); err != nil {
		return err
	}
	// 极简/尚未完成初始化的漂移库可能暂时没有 session_events；基础
	// migrations 会在后续创建它，不能让这个 additive 守卫阻断 Open。
	if tableCount == 0 {
		return nil
	}
	rows, err := db.Query(`SELECT name FROM pragma_table_info('session_events') WHERE name='terminal_status'`)
	if err != nil {
		return err
	}
	defer rows.Close()
	if rows.Next() {
		return rows.Err()
	}
	if err := rows.Err(); err != nil {
		return err
	}
	_, err = db.Exec(`ALTER TABLE session_events ADD COLUMN terminal_status TEXT NOT NULL DEFAULT ''`)
	return err
}

// ensureUsageContextWindowColumn 用存在性检查补齐 usage_events.context_window_tokens。
// 编号迁移按下角标记录已应用版本；历史上一次“列表中段插入”让部分存量库的版本号与
// 语句内容错位，导致追加式编号迁移可能被永久跳过。additive 列改用 pragma 守卫，
// 对新库与任何错位的存量库都幂等收敛（与 daemon 本地库的 ensureColumnIfExists 同口径）。
func ensureUsageContextWindowColumn(db *sql.DB) error {
	rows, err := db.Query(`SELECT name FROM pragma_table_info('usage_events') WHERE name='context_window_tokens'`)
	if err != nil {
		return err
	}
	defer rows.Close()
	if rows.Next() {
		return rows.Err()
	}
	if err := rows.Err(); err != nil {
		return err
	}
	_, err = db.Exec(`ALTER TABLE usage_events ADD COLUMN context_window_tokens INTEGER NOT NULL DEFAULT 0`)
	return err
}

func ensureTableColumn(db *sql.DB, table, column, alter string) error {
	// 极简漂移库可能尚未建到目标表；由后续编号 migration 创建，不能让兼容守卫抢先失败。
	var tableCount int
	if err := db.QueryRow(`SELECT COUNT(1) FROM sqlite_master WHERE type='table' AND name=?`, table).Scan(&tableCount); err != nil {
		return err
	}
	if tableCount == 0 {
		return nil
	}
	rows, err := db.Query(`SELECT name FROM pragma_table_info('`+table+`') WHERE name=?`, column)
	if err != nil {
		return err
	}
	defer rows.Close()
	if rows.Next() {
		return rows.Err()
	}
	if err := rows.Err(); err != nil {
		return err
	}
	_, err = db.Exec(alter)
	return err
}

const relaySQLiteBusyTimeoutMS = 5000

// relaySQLiteDSN 将连接级安全与并发配置固定在 SQLite 驱动 DSN。Relay 的领域事务普遍是
// “读校验 -> 写状态机”，使用 IMMEDIATE 可在事务开始时串行短暂写者，避免延迟事务在提交前
// 遇到已更新 snapshot 后把用户可重试命令错误地报成内部 500。
func relaySQLiteDSN(path string) (string, error) {
	path = strings.TrimSpace(path)
	if path == "" {
		return "", fmt.Errorf("sqlite path is required")
	}
	if !strings.HasPrefix(path, "file:") {
		path = "file:" + path
	}
	parsed, err := url.Parse(path)
	if err != nil {
		return "", fmt.Errorf("parse sqlite path: %w", err)
	}
	query := parsed.Query()
	query.Set("_busy_timeout", fmt.Sprintf("%d", relaySQLiteBusyTimeoutMS))
	query.Set("_foreign_keys", "on")
	query.Set("_txlock", "immediate")
	parsed.RawQuery = query.Encode()
	return parsed.String(), nil
}

// alterAddColumnRe 识别 "ALTER TABLE t ADD COLUMN c" 形态的迁移语句。
// 表名/列名只接受 \w+（迁移列表是仓库内常量，同时保证 pragma 查询可安全拼接）。
var alterAddColumnRe = regexp.MustCompile(`(?i)^\s*ALTER\s+TABLE\s+["'` + "`" + `]?([A-Za-z0-9_]+)["'` + "`" + `]?\s+ADD\s+COLUMN\s+["'` + "`" + `]?([A-Za-z0-9_]+)`)

// Migrate 按编号执行尚未应用的 SQL。所有 pending migration 在同一 SQLite transaction 内提交：
// 任意一条失败时 schema_migrations 和表结构一起回滚，进程重启可从完整旧状态重新演练。
func Migrate(db *sql.DB) error {
	return migrateWith(db, migrations)
}

// migrateWith 为 Migrate 的可注入实现。生产只传 migrations；迁移回归会传入带故障尾项的列表，
// 验证出现磁盘/SQL 失败时不会留下可被误认为成功的半迁移状态。
func migrateWith(db *sql.DB, statements []string) error {
	if _, err := db.Exec(`CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP);`); err != nil {
		return err
	}
	tx, err := db.Begin()
	if err != nil {
		return err
	}
	rollback := func(cause error) error {
		_ = tx.Rollback()
		return cause
	}
	for i, stmt := range statements {
		var n int
		if err := tx.QueryRow(`SELECT COUNT(1) FROM schema_migrations WHERE version=?`, i).Scan(&n); err != nil {
			return rollback(err)
		}
		if n > 0 {
			continue
		}
		// 存量库可能已经通过历史 ensure/编号插入路径具备同名列（版本号未记录）。
		// 此时该 ADD COLUMN 迁移的意图已满足：登记版本后跳过，避免 duplicate column
		// 中断升级；其余迁移形态不受影响，真实 SQL 错误仍按失败回滚。
		if m := alterAddColumnRe.FindStringSubmatch(stmt); m != nil {
			var existing int
			columnProbe := fmt.Sprintf(
				`SELECT COUNT(1) FROM pragma_table_info('%s') WHERE name='%s'`, m[1], m[2])
			if err := tx.QueryRow(columnProbe).Scan(&existing); err != nil {
				return rollback(err)
			}
			if existing > 0 {
				if _, err := tx.Exec(`INSERT INTO schema_migrations(version) VALUES(?)`, i); err != nil {
					return rollback(err)
				}
				continue
			}
		}
		if _, err := tx.Exec(stmt); err != nil {
			return rollback(fmt.Errorf("migration %d: %w", i, err))
		}
		if _, err := tx.Exec(`INSERT INTO schema_migrations(version) VALUES(?)`, i); err != nil {
			return rollback(err)
		}
	}
	return tx.Commit()
}
