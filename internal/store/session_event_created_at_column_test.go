package store

import (
	"database/sql"
	"path/filepath"
	"testing"

	_ "modernc.org/sqlite"
)

// V085-19：session_events.created_at_unix_ms 是追加式时间列。历史上编号迁移可能因
// 中段插入被全部登记但从未执行；Open 必须用存在性守卫补齐该列（默认 0 = 历史时间未知），
// 且重复打开幂等，不得改写旧行或回填当前时间。
func TestOpenEnsuresSessionEventCreatedAtColumnOnDriftedDatabase(t *testing.T) {
	path := filepath.Join(t.TempDir(), "relay.db")
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`CREATE TABLE session_events (
		session_id TEXT NOT NULL,
		event_seq INTEGER NOT NULL,
		event_type TEXT NOT NULL,
		envelope_json TEXT NOT NULL,
		PRIMARY KEY(session_id, event_seq)
	)`); err != nil {
		_ = db.Close()
		t.Fatalf("create legacy session_events: %v", err)
	}
	// 旧库事件行：时间未知（无 created_at 列）。
	if _, err := db.Exec(`INSERT INTO session_events(session_id,event_seq,event_type,envelope_json) VALUES(?,?,?,?)`,
		"s-legacy", 1, "message.completed", `{"fixture_payload":{}}`); err != nil {
		_ = db.Close()
		t.Fatalf("seed legacy event: %v", err)
	}
	// Open 的 additive 守卫也引用 usage_events；漂移库必须提供该表。
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
	// 模拟错位存量库：版本全部登记，但加列语句从未执行。
	for version := range migrations {
		if _, err := db.Exec(`INSERT INTO schema_migrations(version) VALUES(?)`, version); err != nil {
			_ = db.Close()
			t.Fatalf("mark migration %d applied: %v", version, err)
		}
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}

	opened, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatalf("open drifted database: %v", err)
	}
	if err := Migrate(opened); err != nil {
		_ = opened.Close()
		t.Fatalf("migrate drifted database: %v", err)
	}
	if err := ensureSessionEventCreatedAtColumn(opened); err != nil {
		_ = opened.Close()
		t.Fatalf("ensure session_events created_at column: %v", err)
	}
	assertSessionEventCreatedAtColumn(t, opened, 1)
	// 旧行保持 0（历史时间未知），守卫不得回填当前时间。
	var stored int64
	if err := opened.QueryRow(`SELECT created_at_unix_ms FROM session_events WHERE session_id=?`, "s-legacy").Scan(&stored); err != nil {
		t.Fatalf("read legacy event time: %v", err)
	}
	if stored != 0 {
		t.Fatalf("legacy event time=%d, want 0 (unknown history)", stored)
	}
	// 幂等：再次打开不报 duplicate column。
	if err := opened.Close(); err != nil {
		t.Fatal(err)
	}
	opened, err = sql.Open("sqlite", path)
	if err != nil {
		t.Fatalf("reopen repaired database: %v", err)
	}
	defer opened.Close()
	if err := ensureSessionEventCreatedAtColumn(opened); err != nil {
		t.Fatalf("second ensure must stay idempotent: %v", err)
	}
	assertSessionEventCreatedAtColumn(t, opened, 1)
}

// 新库（Open 全量迁移）也必须包含该列。
func TestOpenFreshDatabaseHasSessionEventCreatedAtColumn(t *testing.T) {
	db, err := Open(filepath.Join(t.TempDir(), "relay.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	assertSessionEventCreatedAtColumn(t, db, 1)
}

func assertSessionEventCreatedAtColumn(t *testing.T, db *sql.DB, want int) {
	t.Helper()
	var count int
	if err := db.QueryRow(`SELECT COUNT(1) FROM pragma_table_info('session_events') WHERE name=?`, "created_at_unix_ms").Scan(&count); err != nil {
		t.Fatal(err)
	}
	if count != want {
		t.Fatalf("session_events.created_at_unix_ms present=%d, want %d", count, want)
	}
}
