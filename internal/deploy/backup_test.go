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
	// 写入账号与事件，制造可恢复数据。
	if err := db.QueryRow(`INSERT INTO accounts(id,email,password_hash,created_at) VALUES('a','a@b',x'00',1)`).Err(); err != nil {
		t.Fatalf("insert account: %v", err)
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
