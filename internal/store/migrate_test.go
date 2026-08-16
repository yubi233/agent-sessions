package store

import (
	"context"
	"database/sql"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestOpenCreatesSQLiteSchema(t *testing.T) {
	db, err := Open(filepath.Join(t.TempDir(), "relay.db"))
	if err != nil {
		t.Fatalf("open sqlite store: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })

	for _, table := range []string{"accounts", "devices", "sessions", "control_leases", "outbox"} {
		var name string
		if err := db.QueryRow(`SELECT name FROM sqlite_master WHERE type='table' AND name=?`, table).Scan(&name); err != nil {
			t.Fatalf("expected table %q: %v", table, err)
		}
	}
}

func TestMigrateIsIdempotent(t *testing.T) {
	db, err := Open(filepath.Join(t.TempDir(), "relay.db"))
	if err != nil {
		t.Fatalf("open sqlite store: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })

	if err := Migrate(db); err != nil {
		t.Fatalf("rerun migrations: %v", err)
	}
}

// RELAY-LEASE-03 / SYNC-05：Relay 的连接池中每条 SQLite 连接都必须启用等待、外键和
// IMMEDIATE 事务策略。只在 Open 后对第一条连接执行 PRAGMA 会让并发 hello/command 在新连接
// 上退回默认 deferred transaction，并可能把可恢复竞争错误映射为 HTTP 500。
func TestOpenAppliesConnectionPragmasAcrossSQLitePool(t *testing.T) {
	db, err := Open(filepath.Join(t.TempDir(), "relay.db"))
	if err != nil {
		t.Fatalf("open sqlite store: %v", err)
	}
	defer db.Close()
	db.SetMaxOpenConns(2)
	ctx := context.Background()
	first, err := db.Conn(ctx)
	if err != nil {
		t.Fatalf("open first sqlite connection: %v", err)
	}
	defer first.Close()
	second, err := db.Conn(ctx)
	if err != nil {
		t.Fatalf("open second sqlite connection: %v", err)
	}
	defer second.Close()
	for index, connection := range []*sql.Conn{first, second} {
		var busyTimeout, foreignKeys int
		if err := connection.QueryRowContext(ctx, `PRAGMA busy_timeout`).Scan(&busyTimeout); err != nil {
			t.Fatalf("connection %d busy_timeout: %v", index, err)
		}
		if err := connection.QueryRowContext(ctx, `PRAGMA foreign_keys`).Scan(&foreignKeys); err != nil {
			t.Fatalf("connection %d foreign_keys: %v", index, err)
		}
		if busyTimeout != relaySQLiteBusyTimeoutMS || foreignKeys != 1 {
			t.Fatalf("connection %d pragmas busy_timeout=%d foreign_keys=%d", index, busyTimeout, foreignKeys)
		}
	}
}

// RELAY-LEASE-03：第一个写事务必须在开始时取得 SQLite 写锁；第二个事务应等待并在提交后
// 继续，而不是先拿 deferred 读快照、随后升级写入时触发 SQLITE_BUSY_SNAPSHOT。
func TestOpenUsesImmediateTransactionsForConcurrentRelayWriters(t *testing.T) {
	db, err := Open(filepath.Join(t.TempDir(), "relay.db"))
	if err != nil {
		t.Fatalf("open sqlite store: %v", err)
	}
	defer db.Close()
	db.SetMaxOpenConns(2)
	ctx := context.Background()
	first, err := db.BeginTx(ctx, nil)
	if err != nil {
		t.Fatalf("begin first transaction: %v", err)
	}
	secondResult := make(chan error, 1)
	go func() {
		second, beginErr := db.BeginTx(ctx, nil)
		if beginErr == nil {
			beginErr = second.Rollback()
		}
		secondResult <- beginErr
	}()
	select {
	case err := <-secondResult:
		_ = first.Rollback()
		t.Fatalf("second transaction returned before first commit: %v", err)
	case <-time.After(50 * time.Millisecond):
	}
	if err := first.Commit(); err != nil {
		t.Fatalf("commit first transaction: %v", err)
	}
	select {
	case err := <-secondResult:
		if err != nil {
			t.Fatalf("second transaction after first commit: %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("second transaction did not resume after first commit")
	}
}

// MIG-02：以 P2 之前的真实 schema 和业务行模拟升级。先注入中途 SQL 失败，再确认 transaction
// 没有留下 protocol 列或 migration version；随后重启并应用正式 migration，旧状态必须仍可读取。
func TestMigrateV04LegacyUpgradeRollbackAndRestartRecovery(t *testing.T) {
	path := filepath.Join(t.TempDir(), "legacy-relay.db")
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`PRAGMA foreign_keys=ON;`); err != nil {
		_ = db.Close()
		t.Fatal(err)
	}
	p2Start := daemonMigrationStart(t)
	if err := migrateWith(db, migrations[:p2Start]); err != nil {
		_ = db.Close()
		t.Fatalf("create pre-P2 schema: %v", err)
	}
	seedLegacyRelayRows(t, db)

	// 让第一条 P2 ALTER 成功、第二条故意失败；整个 pending batch 应回滚。
	failing := append([]string{}, migrations[:p2Start]...)
	failing = append(failing, migrations[p2Start], `THIS IS NOT VALID SQLITE`)
	if err := migrateWith(db, failing); err == nil {
		_ = db.Close()
		t.Fatal("expected injected migration failure")
	}
	if hasColumn(t, db, "terminals", "protocol_version") {
		_ = db.Close()
		t.Fatal("failed migration left protocol_version column behind")
	}
	var applied int
	if err := db.QueryRow(`SELECT COUNT(1) FROM schema_migrations WHERE version>=?`, p2Start).Scan(&applied); err != nil {
		_ = db.Close()
		t.Fatal(err)
	}
	if applied != 0 {
		_ = db.Close()
		t.Fatalf("failed migration recorded %d P2 versions", applied)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}

	// Open 模拟 Relay 重启：正式 P2 migration 应一次性应用，旧命令/lease/event/outbox 不丢失。
	db, err = Open(path)
	if err != nil {
		t.Fatalf("restart upgrade legacy database: %v", err)
	}
	defer db.Close()
	for _, column := range []string{"protocol_version", "daemon_version", "capabilities_json", "last_heartbeat_unix_ms"} {
		if !hasColumn(t, db, "terminals", column) {
			t.Fatalf("terminals missing upgraded column %q", column)
		}
	}
	if !hasColumn(t, db, "commands", "target_terminal_id") {
		t.Fatal("commands missing target_terminal_id after upgrade")
	}
	for _, table := range []string{"daemon_command_deliveries", "daemon_event_receipts"} {
		var name string
		if err := db.QueryRow(`SELECT name FROM sqlite_master WHERE type='table' AND name=?`, table).Scan(&name); err != nil {
			t.Fatalf("missing P2 table %q: %v", table, err)
		}
	}
	var commandID, targetTerminalID string
	if err := db.QueryRow(`SELECT id,target_terminal_id FROM commands WHERE id='cmd-legacy'`).Scan(&commandID, &targetTerminalID); err != nil {
		t.Fatalf("read legacy command after upgrade: %v", err)
	}
	if commandID != "cmd-legacy" || targetTerminalID != "" {
		t.Fatalf("legacy command projection=%q/%q", commandID, targetTerminalID)
	}
	for _, table := range []string{"control_leases", "session_events", "outbox"} {
		var count int
		if err := db.QueryRow(`SELECT COUNT(1) FROM ` + table).Scan(&count); err != nil || count != 1 {
			t.Fatalf("legacy %s count=%d err=%v", table, count, err)
		}
	}
	if err := Migrate(db); err != nil {
		t.Fatalf("repeat upgraded migration: %v", err)
	}
}

func daemonMigrationStart(t *testing.T) int {
	t.Helper()
	for index, statement := range migrations {
		if strings.Contains(statement, "ALTER TABLE terminals ADD COLUMN protocol_version") {
			return index
		}
	}
	t.Fatal("P2 daemon migration start not found")
	return 0
}

func hasColumn(t *testing.T, db *sql.DB, table, column string) bool {
	t.Helper()
	rows, err := db.Query(`PRAGMA table_info(` + table + `)`)
	if err != nil {
		t.Fatalf("table info %s: %v", table, err)
	}
	defer rows.Close()
	for rows.Next() {
		var cid int
		var name, valueType string
		var notNull, primaryKey int
		var defaultValue any
		if err := rows.Scan(&cid, &name, &valueType, &notNull, &defaultValue, &primaryKey); err != nil {
			t.Fatal(err)
		}
		if name == column {
			return true
		}
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	return false
}

func seedLegacyRelayRows(t *testing.T, db *sql.DB) {
	t.Helper()
	statements := []struct {
		query string
		args  []any
	}{
		{`INSERT INTO accounts(id,email,password_hash,created_at) VALUES(?,?,?,?)`, []any{"acct-legacy", "legacy@example.test", []byte("hash"), 1}},
		{`INSERT INTO devices(id,account_id,role,status,display_name,platform,identity_public_key,encryption_public_key,last_seen_unix_ms) VALUES(?,?,?,?,?,?,?,?,?)`, []any{"dev-legacy", "acct-legacy", "owner", "active", "Legacy", "test", "identity", "encryption", 1}},
		{`INSERT INTO terminals(id,device_id,account_id,hostname,platform,status,last_seen_unix_ms) VALUES(?,?,?,?,?,?,?)`, []any{"term-legacy", "dev-legacy", "acct-legacy", "legacy-host", "test", "offline", 1}},
		{`INSERT INTO projects(id,account_id,fingerprint,encrypted_name) VALUES(?,?,?,?)`, []any{"proj-legacy", "acct-legacy", "fingerprint", "cipher"}},
		{`INSERT INTO workspaces(id,project_id,terminal_id,canonical_root,branch,status) VALUES(?,?,?,?,?,?)`, []any{"ws-legacy", "proj-legacy", "term-legacy", "/not-read-by-relay", "main", "active"}},
		{`INSERT INTO sessions(id,workspace_id,account_id,status,provider,last_seq,current_instance_id) VALUES(?,?,?,?,?,?,?)`, []any{"sess-legacy", "ws-legacy", "acct-legacy", "running", "fixture", 1, ""}},
		{`INSERT INTO commands(id,account_id,session_id,kind,status,scope_hash,idempotency_key,lease_epoch,target_instance_id,ciphertext_json) VALUES(?,?,?,?,?,?,?,?,?,?)`, []any{"cmd-legacy", "acct-legacy", "sess-legacy", "session.abort", "accepted", "scope", "legacy-key", 1, "", `{"opaque":true}`}},
		{`INSERT INTO control_leases(session_id,device_id,epoch,instance_id) VALUES(?,?,?,?)`, []any{"sess-legacy", "dev-legacy", 1, ""}},
		{`INSERT INTO session_events(session_id,event_seq,event_type,envelope_json) VALUES(?,?,?,?)`, []any{"sess-legacy", 1, "command.updated", `{"ciphertext":"opaque"}`}},
		{`INSERT INTO outbox(kind,payload_json,status,attempts) VALUES(?,?,?,?)`, []any{"command.updated", `{"command_id":"cmd-legacy"}`, "pending", 0}},
	}
	for _, statement := range statements {
		if _, err := db.Exec(statement.query, statement.args...); err != nil {
			t.Fatalf("seed legacy row: %v", err)
		}
	}
}
