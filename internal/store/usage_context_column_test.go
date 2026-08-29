package store

import (
	"database/sql"
	"testing"

	_ "modernc.org/sqlite"
)

// 编号迁移按下角标记录已应用版本。历史上一次“列表中段插入”曾让部分存量库的
// 版本号与语句内容错位：编号全被标记应用，追加的 additive 列因此永远不会执行。
// ensureUsageContextWindowColumn 是针对该事故的守卫；此回归用内联构造的“错位
// 存量库”验证它对任意旧库都幂等收敛，且新库不受影响。
func TestEnsureUsageContextWindowColumnIdempotent(t *testing.T) {
	t.Run("drifted legacy database gains column", func(t *testing.T) {
		db := openDriftedLegacyDB(t)
		defer db.Close()

		var before int
		if err := db.QueryRow(`SELECT COUNT(1) FROM pragma_table_info('usage_events') WHERE name='context_window_tokens'`).Scan(&before); err != nil {
			t.Fatal(err)
		}
		if before != 0 {
			t.Fatalf("fixture unexpectedly already has the column")
		}

		if err := Migrate(db); err != nil {
			t.Fatalf("migrate on drifted db: %v", err)
		}
		if err := ensureUsageContextWindowColumn(db); err != nil {
			t.Fatalf("ensure column: %v", err)
		}

		assertContextWindowColumn(t, db, 1)

		// 二次执行必须幂等（列已存在时不再 ALTER）。
		if err := ensureUsageContextWindowColumn(db); err != nil {
			t.Fatalf("second ensure must stay idempotent: %v", err)
		}
		assertContextWindowColumn(t, db, 1)
	})

	t.Run("fresh database via Open already has column", func(t *testing.T) {
		path := t.TempDir() + "/fresh.db"
		db, err := Open(path)
		if err != nil {
			t.Fatalf("open fresh db: %v", err)
		}
		defer db.Close()
		assertContextWindowColumn(t, db, 1)
	})
}

func openDriftedLegacyDB(t *testing.T) *sql.DB {
	t.Helper()
	db, err := sql.Open("sqlite", t.TempDir()+"/legacy.db")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })
	if _, err := db.Exec(`PRAGMA journal_mode=WAL;`); err != nil {
		t.Fatal(err)
	}
	// 旧版 usage_events：没有 context_window_tokens。
	if _, err := db.Exec(`CREATE TABLE usage_events (
		usage_key_hash TEXT PRIMARY KEY,
		account_id TEXT NOT NULL,
		input_tokens INTEGER NOT NULL
	)`); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`CREATE TABLE schema_migrations (
		version INTEGER PRIMARY KEY,
		applied_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
	)`); err != nil {
		t.Fatal(err)
	}
	// 模拟错位存量库：版本号一直记到 len(migrations)-1，
	// 但列表内容与历史不一致，追加迁移永不执行。
	for i := 0; i < len(migrations); i++ {
		if _, err := db.Exec(`INSERT INTO schema_migrations(version) VALUES(?)`, i); err != nil {
			t.Fatal(err)
		}
	}
	return db
}

func assertContextWindowColumn(t *testing.T, db *sql.DB, want int) {
	t.Helper()
	var n int
	if err := db.QueryRow(`SELECT COUNT(1) FROM pragma_table_info('usage_events') WHERE name='context_window_tokens'`).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != want {
		t.Fatalf("context_window_tokens present = %d, want %d", n, want)
	}
}
