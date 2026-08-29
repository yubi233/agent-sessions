package store

import (
	"database/sql"
	"path/filepath"
	"testing"

	_ "modernc.org/sqlite"
)

// 存量库可能经由历史 ensure/编号插入路径提前具备追加列，而 schema_migrations 版本
// 停在更早编号（真实案例：relay.db 停在 60，sessions 已有 archived_at_unix_ms 与
// last_activity_at_unix_ms，迁移 61 报 duplicate column）。Migrate 必须把已满足的
// ADD COLUMN 迁移按已应用登记后跳过，不能中断升级，更不能丢数据。
func TestMigrateToleratesPreExistingAddColumn(t *testing.T) {
	path := filepath.Join(t.TempDir(), "relay-preexisting-column.db")
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	// 用到迁移 60 为止的旧迁移集建出"存量库"，再手工补上与迁移 61/62 同名的列，
	// 复刻历史路径"加列未登记"的漂移状态。
	legacyCount := 61
	if legacyCount >= len(migrations) {
		t.Fatalf("migration split invalid: %d/%d", legacyCount, len(migrations))
	}
	if err := migrateWith(db, migrations[:legacyCount]); err != nil {
		t.Fatalf("build legacy schema: %v", err)
	}
	for _, column := range []string{
		`ALTER TABLE sessions ADD COLUMN archived_at_unix_ms INTEGER NOT NULL DEFAULT 0`,
		`ALTER TABLE sessions ADD COLUMN last_activity_at_unix_ms INTEGER NOT NULL DEFAULT 0`,
	} {
		if _, err := db.Exec(column); err != nil {
			t.Fatalf("simulate drifted column: %v", err)
		}
	}

	if err := Migrate(db); err != nil {
		t.Fatalf("migrate must tolerate pre-existing add-column state: %v", err)
	}

	var applied int
	if err := db.QueryRow(`SELECT COUNT(1) FROM schema_migrations`).Scan(&applied); err != nil {
		t.Fatal(err)
	}
	if applied != len(migrations) {
		t.Fatalf("schema_migrations rows = %d, want %d", applied, len(migrations))
	}
	// 每列仍然只有一份：跳过路径不得重复执行或改写既有列。
	for _, probe := range []string{"archived_at_unix_ms", "last_activity_at_unix_ms"} {
		var copies int
		if err := db.QueryRow(
			`SELECT COUNT(1) FROM pragma_table_info('sessions') WHERE name=?`, probe,
		).Scan(&copies); err != nil {
			t.Fatal(err)
		}
		if copies != 1 {
			t.Fatalf("column %s copies = %d, want 1", probe, copies)
		}
	}
	// 幂等：重复迁移不再变更任何状态。
	if err := Migrate(db); err != nil {
		t.Fatalf("second migration must be idempotent: %v", err)
	}
}
