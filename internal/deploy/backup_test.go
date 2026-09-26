package deploy

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/yubi233/agent-sessions/internal/store"
)

// 创建带数据的库，备份后恢复校验完整性（DEPLOY-02/03）。
func TestBackupRestoreIntegrity(t *testing.T) {
	dir := t.TempDir()
	src := filepath.Join(dir, "relay.db")
	db, err := store.Open(src)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	// 写入账号、device、project、workspace 与事件，制造可恢复数据。
	// sessions/workspaces 外键链需要 device/terminal -> workspace -> project -> account。
	if err := db.QueryRow(`INSERT INTO accounts(id,email,password_hash,created_at) VALUES('a','a@b',x'00',1)`).Err(); err != nil {
		t.Fatalf("insert account: %v", err)
	}
	if err := db.QueryRow(`INSERT INTO devices(id,account_id,role,status,display_name,platform,identity_public_key,encryption_public_key,last_seen_unix_ms) VALUES('dev','a','terminal','active','dev','test','identity','encryption',1)`).Err(); err != nil {
		t.Fatalf("insert device: %v", err)
	}
	if err := db.QueryRow(`INSERT INTO terminals(id,device_id,account_id,hostname,platform,status,last_seen_unix_ms) VALUES('t','dev','a','host','test','online',1)`).Err(); err != nil {
		t.Fatalf("insert terminal: %v", err)
	}
	if err := db.QueryRow(`INSERT INTO projects(id,account_id,fingerprint) VALUES('p','a','fp')`).Err(); err != nil {
		t.Fatalf("insert project: %v", err)
	}
	if err := db.QueryRow(`INSERT INTO workspaces(id,project_id,terminal_id,canonical_root,status) VALUES('w','p','t','/ws','active')`).Err(); err != nil {
		t.Fatalf("insert workspace: %v", err)
	}
	if err := db.QueryRow(`INSERT INTO sessions(id,workspace_id,account_id,status,provider,last_seq,current_instance_id) VALUES('s','w','a','running','mock',2,NULL)`).Err(); err != nil {
		t.Fatalf("insert session: %v", err)
	}
	for i := 1; i <= 3; i++ {
		if err := db.QueryRow(`INSERT INTO session_events(session_id,event_seq,event_type,envelope_json) VALUES('s',?, 'e', '{}')`, i).Err(); err != nil {
			t.Fatalf("insert event %d: %v", i, err)
		}
	}
	_ = db.Close()

	dst := filepath.Join(dir, "backup", "relay.db")
	if err := Backup(src, dst); err != nil {
		t.Fatalf("backup: %v", err)
	}
	if err := ValidateSchema(dst); err != nil {
		t.Fatalf("validate schema: %v", err)
	}
	if err := Integrity(dst, true); err != nil {
		t.Fatalf("integrity: %v", err)
	}
}

// 损坏库应被完整性校验捕获。
func TestBackupDetectsCorruption(t *testing.T) {
	dir := t.TempDir()
	bad := filepath.Join(dir, "bad.db")
	if err := writeFile(bad, "this is not a sqlite database at all and is corrupt"); err != nil {
		t.Fatalf("write: %v", err)
	}
	if err := Integrity(bad, false); err == nil {
		t.Fatalf("expected corruption detected")
	}
}

func writeFile(path, content string) error {
	return os.WriteFile(path, []byte(content), 0o600)
}

// v0.9.7 阶段 2.2 回归：event_seq 是会话内局部序号，跨会话必须各自单调。
// 旧校验器跨会话比较（上一会话 116 → 下一会话 1 即误报），本地库含导入回填
// 事件后该误报阻断每日备份。
func TestIntegrityPerSessionSeqMonotonic(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "relay.db")
	db, err := store.Open(path)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer db.Close()
	for _, tc := range []struct {
		session string
		events  int
	}{
		{"sess_a", 116},
		{"sess_b", 1},
		{"sess_c", 40},
	} {
		for seq := 1; seq <= tc.events; seq++ {
			if _, err := db.Exec(
				`INSERT INTO session_events(session_id,event_type,envelope_json,event_seq) VALUES(?,?,?,?)`,
				tc.session, "user.message", "{}", seq,
			); err != nil {
				t.Fatalf("insert %s#%d: %v", tc.session, seq, err)
			}
		}
	}
	if err := Integrity(path, true); err != nil {
		t.Fatalf("多会话各自单调应通过（旧实现跨会话比较在此误报）: %v", err)
	}
	// 说明：UNIQUE(session_id,event_seq) 已在库层保证会话内无重复；校验器的
	// 会话内单调检查是纵深防御，正常库不可能构造出触发它的行。
}
