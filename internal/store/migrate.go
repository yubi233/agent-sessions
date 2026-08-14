package store

import (
	"database/sql"
	"fmt"

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
}

// Open 打开 SQLite 并执行迁移。WAL + 外键是权威存储的固定配置。
func Open(path string) (*sql.DB, error) {
	db, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, err
	}
	if _, err := db.Exec(`PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;`); err != nil {
		db.Close()
		return nil, err
	}
	if err := Migrate(db); err != nil {
		db.Close()
		return nil, err
	}
	return db, nil
}

// Migrate 按编号执行尚未应用的 SQL。
func Migrate(db *sql.DB) error {
	if _, err := db.Exec(`CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP);`); err != nil {
		return err
	}
	for i, stmt := range migrations {
		var n int
		if err := db.QueryRow(`SELECT COUNT(1) FROM schema_migrations WHERE version=?`, i).Scan(&n); err != nil {
			return err
		}
		if n > 0 {
			continue
		}
		if _, err := db.Exec(stmt); err != nil {
			return fmt.Errorf("migration %d: %w", i, err)
		}
		if _, err := db.Exec(`INSERT INTO schema_migrations(version) VALUES(?)`, i); err != nil {
			return err
		}
	}
	return nil
}
