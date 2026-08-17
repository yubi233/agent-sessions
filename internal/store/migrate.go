package store

import (
	"database/sql"
	"fmt"
	"net/url"
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
	return db, nil
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
		if _, err := tx.Exec(stmt); err != nil {
			return rollback(fmt.Errorf("migration %d: %w", i, err))
		}
		if _, err := tx.Exec(`INSERT INTO schema_migrations(version) VALUES(?)`, i); err != nil {
			return rollback(err)
		}
	}
	return tx.Commit()
}
