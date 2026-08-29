package store

import (
	"database/sql"
	"path/filepath"
	"testing"

	_ "modernc.org/sqlite"
)

// 编号迁移发生过中段插入时，存量库可能已经记录了全部 migration version，
// 但实际 schema 仍缺少追加列。Open 必须用存在性守卫补齐会话归档列。
func TestOpenEnsuresArchivedAtColumnOnDriftedDatabase(t *testing.T) {
	path := filepath.Join(t.TempDir(), "relay.db")
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`CREATE TABLE sessions (
		id TEXT PRIMARY KEY,
		workspace_id TEXT NOT NULL,
		account_id TEXT NOT NULL,
		status TEXT NOT NULL,
		provider TEXT NOT NULL,
		last_seq INTEGER NOT NULL DEFAULT 0,
		current_instance_id TEXT
	)`); err != nil {
		_ = db.Close()
		t.Fatalf("create legacy sessions table: %v", err)
	}
	if _, err := db.Exec(`CREATE TABLE usage_events (
		usage_key_hash TEXT PRIMARY KEY,
		account_id TEXT NOT NULL,
		context_window_tokens INTEGER NOT NULL DEFAULT 0
	)`); err != nil {
		_ = db.Close()
		t.Fatalf("create usage_events table: %v", err)
	}
	if _, err := db.Exec(`CREATE TABLE schema_migrations (
		version INTEGER PRIMARY KEY,
		applied_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
	)`); err != nil {
		_ = db.Close()
		t.Fatalf("create migration table: %v", err)
	}
	for version := range migrations {
		if _, err := db.Exec(`INSERT INTO schema_migrations(version) VALUES(?)`, version); err != nil {
			_ = db.Close()
			t.Fatalf("mark migration %d as applied: %v", version, err)
		}
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}

	opened, err := Open(path)
	if err != nil {
		t.Fatalf("open drifted database: %v", err)
	}
	defer opened.Close()
	assertArchivedAtColumn(t, opened, 1)

	// The guard must remain idempotent on subsequent opens.
	if err := opened.Close(); err != nil {
		t.Fatal(err)
	}
	opened, err = Open(path)
	if err != nil {
		t.Fatalf("reopen repaired database: %v", err)
	}
	defer opened.Close()
	assertArchivedAtColumn(t, opened, 1)
}

func assertArchivedAtColumn(t *testing.T, db *sql.DB, want int) {
	t.Helper()
	var count int
	if err := db.QueryRow(`SELECT COUNT(1) FROM pragma_table_info('sessions') WHERE name='archived_at_unix_ms'`).Scan(&count); err != nil {
		t.Fatal(err)
	}
	if count != want {
		t.Fatalf("archived_at_unix_ms present = %d, want %d", count, want)
	}
}
