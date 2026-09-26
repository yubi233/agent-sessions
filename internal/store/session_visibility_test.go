package store

import (
	"context"
	"database/sql"
	"testing"
	"time"
)

// v0.9.6 分类迁移回归：只有成功导入回执能确证 dsh_import 来源；回执命中且
// 存在真实使用命令（start/resume/send）的会话保持默认可见，其余导入回执命中的
// 会话转入历史候选。普通 managed 会话不受影响。迁移只跑一次，重启不重分类。
func TestSessionClassificationMigration(t *testing.T) {
	db, err := sql.Open("sqlite", t.TempDir()+("/legacy.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })
	// 模拟旧库：sessions 无 origin/visibility，已有导入回执与使用命令。
	if _, err := db.Exec(`
		CREATE TABLE sessions (id TEXT PRIMARY KEY, workspace_id TEXT, account_id TEXT,
			provider TEXT, status TEXT, display_name TEXT);
		CREATE TABLE commands (id TEXT PRIMARY KEY, account_id TEXT, session_id TEXT,
			kind TEXT, status TEXT);
		CREATE TABLE workspace_command_results (command_id TEXT PRIMARY KEY,
			account_id TEXT, workspace_id TEXT, canonical_root TEXT, status TEXT,
			error_code TEXT, created_at_unix_ms INTEGER);
		INSERT INTO sessions VALUES('sess_used','ws','acct','dsh','idle','');
		INSERT INTO sessions VALUES('sess_unused','ws','acct','dsh','idle','');
		INSERT INTO sessions VALUES('sess_native','ws','acct','dsh','idle','');
		INSERT INTO commands VALUES('cmd_imp','acct','','session.import_dsh','succeeded');
		INSERT INTO commands VALUES('cmd_start','acct','sess_used','session.start','succeeded');
		INSERT INTO workspace_command_results VALUES('cmd_imp','acct','ws',
			'{"session_ids":["sess_used","sess_unused"]}','succeeded','',1);
	`); err != nil {
		t.Fatal(err)
	}
	if err := ensureSessionClassificationColumns(db); err != nil {
		t.Fatalf("classification migration: %v", err)
	}
	rows := map[string][2]string{}
	result, err := db.Query(`SELECT id, origin, visibility FROM sessions`)
	if err != nil {
		t.Fatal(err)
	}
	defer result.Close()
	for result.Next() {
		var id, origin, visibility string
		if err := result.Scan(&id, &origin, &visibility); err != nil {
			t.Fatal(err)
		}
		rows[id] = [2]string{origin, visibility}
	}
	if err := result.Err(); err != nil {
		t.Fatal(err)
	}
	if rows["sess_used"] != [2]string{"dsh_import", "default"} {
		t.Fatalf("已使用的历史应保持默认可见: %v", rows["sess_used"])
	}
	if rows["sess_unused"] != [2]string{"dsh_import", "history"} {
		t.Fatalf("未使用的导入应成为历史候选: %v", rows["sess_unused"])
	}
	if rows["sess_native"] != [2]string{"managed", "default"} {
		t.Fatalf("无导入回执的会话不受影响: %v", rows["sess_native"])
	}
	// 幂等：再次执行不改变任何分类。
	if err := ensureSessionClassificationColumns(db); err != nil {
		t.Fatal(err)
	}
	var visibility string
	if err := db.QueryRow(`SELECT visibility FROM sessions WHERE id='sess_unused'`).Scan(&visibility); err != nil {
		t.Fatal(err)
	}
	if visibility != "history" {
		t.Fatalf("二次迁移不得重分类: %s", visibility)
	}
}

// v0.9.6 存储语义回归：ManageSession 只提升 history；副本不可提升。
// UpdateSessionImportProgress 修正事件游标并只前推活动时间。
func TestManageAndUpdateImportProgressStoreSemantics(t *testing.T) {
	db, err := Open(t.TempDir() + "/relay.db")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })
	repo := NewRepository(db)
	ctx := context.Background()
	if err := repo.CreateAccount(ctx, "acct", "t@t", []byte("h"), time.Now()); err != nil {
		t.Fatal(err)
	}
	if err := repo.CreateProject(ctx, ProjectRow{ID: "proj", AccountID: "acct", Fingerprint: "fp"}); err != nil {
		t.Fatal(err)
	}
	if err := repo.CreateWorkspace(ctx, WorkspaceRow{ID: "ws", ProjectID: "proj", CanonicalRoot: "/ws", Status: "active"}); err != nil {
		t.Fatal(err)
	}
	seed := func(id, visibility string) {
		if err := repo.CreateSession(ctx, SessionRow{
			ID: id, WorkspaceID: "ws", AccountID: "acct", Status: "idle",
			Provider: "dsh", Visibility: visibility,
		}); err != nil {
			t.Fatal(err)
		}
	}
	seed("s_hist", SessionVisibilityHistory)
	seed("s_dup", SessionVisibilityDuplicate)
	seed("s_default", SessionVisibilityDefault)

	// s_hist 提升为默认；s_dup 保持隐藏；s_default 本就默认（幂等空操作）。
	for item, expect := range map[string]bool{"s_hist": true, "s_dup": false, "s_default": true} {
		if err := repo.ManageSession(ctx, item); err != nil {
			t.Fatal(err)
		}
		row, err := repo.SessionByID(ctx, item)
		if err != nil {
			t.Fatal(err)
		}
		got := row.Visibility == SessionVisibilityDefault
		if got != expect {
			t.Fatalf("%s promote=%v want %v", item, got, expect)
		}
	}

	// 导入进度：last_seq 收敛到真实事件最大序号；活动时间只前推不回退。
	if _, err := repo.AppendEvent(ctx, SessionEventRow{SessionID: "s_hist", EventType: "user.message", EnvelopeJSON: "{}"}); err != nil {
		t.Fatal(err)
	}
	if _, err := repo.AppendEvent(ctx, SessionEventRow{SessionID: "s_hist", EventType: "message.completed", EnvelopeJSON: "{}"}); err != nil {
		t.Fatal(err)
	}
	if err := repo.UpdateSessionImportProgress(ctx, "s_hist", 1789965000000); err != nil {
		t.Fatal(err)
	}
	row, err := repo.SessionByID(ctx, "s_hist")
	if err != nil {
		t.Fatal(err)
	}
	if row.LastSeq != 2 {
		t.Fatalf("last_seq 应为最大事件序号 2: %d", row.LastSeq)
	}
	if row.LastActivityAtUnixMS != 1789965000000 {
		t.Fatalf("活动时间应取 artifact 时间: %d", row.LastActivityAtUnixMS)
	}
	// 更早的 artifact 时间不得把活动时间往回拨。
	if err := repo.UpdateSessionImportProgress(ctx, "s_hist", 1); err != nil {
		t.Fatal(err)
	}
	row, err = repo.SessionByID(ctx, "s_hist")
	if err != nil {
		t.Fatal(err)
	}
	if row.LastActivityAtUnixMS != 1789965000000 {
		t.Fatalf("活动时间不可回退: %d", row.LastActivityAtUnixMS)
	}
	// 默认列表只含 default（s_hist + s_default）；副本保持隐藏。
	sessions, err := repo.ListSessions(ctx, "acct")
	if err != nil {
		t.Fatal(err)
	}
	if len(sessions) != 2 {
		t.Fatalf("默认列表应为 2（副本隐藏）: %d", len(sessions))
	}
	if err := repo.ArchiveSession(ctx, "s_default", time.Now().UnixMilli()); err != nil {
		t.Fatal(err)
	}
	if sessions, err = repo.ListSessions(ctx, "acct"); err != nil {
		t.Fatal(err)
	} else if len(sessions) != 1 {
		t.Fatalf("归档后默认列表应为 1: %d", len(sessions))
	}
	history, err := repo.ListHistorySessions(ctx, "acct")
	if err != nil {
		t.Fatal(err)
	}
	if len(history) != 0 {
		t.Fatalf("提升后历史列表应为空: %d", len(history))
	}
}
