package store

import (
	"database/sql"
	"path/filepath"
	"testing"

	_ "modernc.org/sqlite"
)

// v0.9.1 P0（V091 契约 C1）：terminals presence additive 迁移回归。
// 存量库升级路径：旧库（迁移列表不含 presence 列）带上存量 Terminal 行原位升级后，
//   - 新列以零值出现（presence_revision=0、presence_projected_state=”）；
//   - last_heartbeat_unix_ms / last_seen_unix_ms 原值保留（计划 §1.3：不删除 last_seen，
//     不做破坏性迁移）；
//   - 空投影的存量行由领域层 legacy 初始化口径解释（status 列 + heartbeat 事实），
//     首拍心跳不会被误判为重复变化之外的多余 revision。
func TestMigratePresenceColumnsAdditivePreservesLegacyRows(t *testing.T) {
	path := filepath.Join(t.TempDir(), "relay-presence-migrate.db")

	// 第一步：用不含末尾两条 presence 迁移的旧列表建库，并写入"存量"Terminal 行。
	legacyMigrations := migrations[:len(migrations)-2]
	{
		db, err := sql.Open("sqlite", path)
		if err != nil {
			t.Fatal(err)
		}
		if err := migrateWith(db, legacyMigrations); err != nil {
			t.Fatalf("build legacy schema: %v", err)
		}
		// 旧迁移集已含 last_heartbeat_unix_ms（v0.6 P2 引入），构造一次真实存量行。
		if _, err := db.Exec(
			`INSERT INTO terminals(id,device_id,account_id,hostname,platform,status,last_seen_unix_ms,
			   protocol_version,daemon_version,capabilities_json,last_heartbeat_unix_ms)
			 VALUES('term_legacy','dev_legacy','acct_legacy','legacy-host','test','online',
			   1700000000000, 1, 'legacy', '[]', 1700000001000)`); err != nil {
			t.Fatalf("seed legacy terminal: %v", err)
		}
		if err := db.Close(); err != nil {
			t.Fatal(err)
		}
	}

	// 第二步：用完整新迁移列表打开同一文件 —— additive 升级必须成功且保留行。
	db, err := Open(path)
	if err != nil {
		t.Fatalf("reopen with presence migrations: %v", err)
	}
	defer db.Close()

	var revision int64
	var projected string
	var lastSeenMS, lastHeartbeatMS int64
	if err := db.QueryRow(
		`SELECT presence_revision, presence_projected_state, last_seen_unix_ms, last_heartbeat_unix_ms
		 FROM terminals WHERE id='term_legacy'`).Scan(&revision, &projected, &lastSeenMS, &lastHeartbeatMS); err != nil {
		t.Fatalf("read migrated legacy row: %v", err)
	}
	if revision != 0 || projected != "" {
		t.Fatalf("legacy row presence columns=(%d,%q), want (0,\"\")", revision, projected)
	}
	if lastSeenMS != 1700000000000 || lastHeartbeatMS != 1700000001000 {
		t.Fatalf("legacy timestamps rewritten: last_seen=%d last_heartbeat=%d", lastSeenMS, lastHeartbeatMS)
	}
}
