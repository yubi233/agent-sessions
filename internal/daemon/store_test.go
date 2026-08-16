package daemon

import (
	"database/sql"
	"path/filepath"
	"testing"
)

// DAEMON-BOOT-01：本地状态可打开、写入与读取。
func TestStoreSetGet(t *testing.T) {
	s, err := OpenStore(filepath.Join(t.TempDir(), "daemon.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer s.Close()
	if err := s.Set("device_id", "dev-1"); err != nil {
		t.Fatalf("set: %v", err)
	}
	v, err := s.Get("device_id")
	if err != nil || v != "dev-1" {
		t.Fatalf("get = %q err=%v", v, err)
	}
}

// SYNC-03：离线 outbox 幂等——相同 request_id 不重复入队，重放只投递一次。
func TestOutboxIdempotent(t *testing.T) {
	s, err := OpenStore(filepath.Join(t.TempDir(), "daemon.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer s.Close()

	for i := 0; i < 3; i++ {
		if err := s.EnqueueCommand("req-1", "session.abort", `{"x":1}`); err != nil {
			t.Fatalf("enqueue %d: %v", i, err)
		}
	}
	pending, err := s.PendingCommands()
	if err != nil {
		t.Fatalf("pending: %v", err)
	}
	if len(pending) != 1 {
		t.Fatalf("want exactly 1 pending, got %d", len(pending))
	}
	// 投递一次后不再有 pending。
	if err := s.MarkDelivered(pending[0].ID); err != nil {
		t.Fatalf("mark delivered: %v", err)
	}
	again, _ := s.PendingCommands()
	if len(again) != 0 {
		t.Fatalf("want 0 pending after delivery, got %d", len(again))
	}
}

// 独立 request_id 各自入队。
func TestOutboxDistinctRequests(t *testing.T) {
	s, err := OpenStore(filepath.Join(t.TempDir(), "daemon.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer s.Close()
	_ = s.EnqueueCommand("a", "session.send", "{}")
	_ = s.EnqueueCommand("b", "session.send", "{}")
	pending, _ := s.PendingCommands()
	if len(pending) != 2 {
		t.Fatalf("want 2 pending, got %d", len(pending))
	}
}

// SYNC-05：Relay 的至少一次 delivery 以 command_id 去重，cursor 只在命令已落盘后推进。
func TestRelayCommandDeliveryIsDurablyDeduplicated(t *testing.T) {
	s, err := OpenStore(filepath.Join(t.TempDir(), "daemon.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	command := RelayCommand{
		CommandID: "cmd-1", DeliverySeq: 7, SessionID: "sess-1", WorkspaceID: "ws-1", Kind: "session.abort", LeaseEpoch: 1,
		TargetTerminalID: "term-1", PayloadJSON: `{"session_id":"sess-1"}`,
	}
	inserted, err := s.RecordRelayCommand(command)
	if err != nil || !inserted {
		t.Fatalf("first relay delivery inserted=%v err=%v", inserted, err)
	}
	duplicate, err := s.RecordRelayCommand(command)
	if err != nil || duplicate {
		t.Fatalf("duplicate relay delivery inserted=%v err=%v", duplicate, err)
	}
	cursor, err := s.RelayDeliveryCursor()
	if err != nil || cursor != 7 {
		t.Fatalf("delivery cursor=%d err=%v, want 7", cursor, err)
	}
	pending, err := s.PendingRelayCommands()
	if err != nil || len(pending) != 1 || pending[0].CommandID != command.CommandID || pending[0].WorkspaceID != command.WorkspaceID {
		t.Fatalf("pending relay commands=%+v err=%v", pending, err)
	}
	if err := s.MarkRelayCommandStarted(command.CommandID); err != nil {
		t.Fatal(err)
	}
	if err := s.MarkRelayCommandResult(command.CommandID, "succeeded", ""); err != nil {
		t.Fatal(err)
	}
	if remaining, err := s.PendingRelayCommands(); err != nil || len(remaining) != 0 {
		t.Fatalf("completed command still pending=%+v err=%v", remaining, err)
	}
}

// SYNC-05：升级旧 Daemon 本地库时，relay_commands 的新增 workspace_id 必须是 additive，
// 已有命令和游标不能因为 schema 扩展而丢失或令本地库无法启动。
func TestStoreUpgradesLegacyRelayCommandsWithWorkspaceID(t *testing.T) {
	path := filepath.Join(t.TempDir(), "daemon-legacy.db")
	legacy, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatalf("open legacy daemon db: %v", err)
	}
	_, err = legacy.Exec(`CREATE TABLE relay_commands (
		command_id TEXT PRIMARY KEY,
		delivery_seq INTEGER NOT NULL,
		session_id TEXT NOT NULL,
		kind TEXT NOT NULL,
		lease_epoch INTEGER NOT NULL,
		target_instance_id TEXT NOT NULL DEFAULT '',
		target_terminal_id TEXT NOT NULL DEFAULT '',
		payload_json TEXT NOT NULL,
		status TEXT NOT NULL DEFAULT 'received',
		result_status TEXT NOT NULL DEFAULT '',
		error_code TEXT NOT NULL DEFAULT '',
		created_at INTEGER NOT NULL,
		updated_at INTEGER NOT NULL
	)`)
	if err != nil {
		_ = legacy.Close()
		t.Fatalf("create legacy relay_commands: %v", err)
	}
	_, err = legacy.Exec(`INSERT INTO relay_commands(
		command_id,delivery_seq,session_id,kind,lease_epoch,target_instance_id,target_terminal_id,payload_json,status,result_status,error_code,created_at,updated_at
	) VALUES('legacy-command',1,'sess-legacy','session.abort',1,'','term-legacy','{}','received','','',1,1)`)
	if err != nil {
		_ = legacy.Close()
		t.Fatalf("seed legacy relay command: %v", err)
	}
	if err := legacy.Close(); err != nil {
		t.Fatalf("close legacy daemon db: %v", err)
	}

	store, err := OpenStore(path)
	if err != nil {
		t.Fatalf("upgrade legacy daemon db: %v", err)
	}
	defer store.Close()
	var legacyWorkspaceID string
	if err := store.db.QueryRow(`SELECT workspace_id FROM relay_commands WHERE command_id='legacy-command'`).Scan(&legacyWorkspaceID); err != nil {
		t.Fatalf("read migrated legacy command: %v", err)
	}
	if legacyWorkspaceID != "" {
		t.Fatalf("legacy workspace_id=%q want empty default", legacyWorkspaceID)
	}

	command := RelayCommand{
		CommandID: "new-command", DeliverySeq: 2, SessionID: "sess-new", WorkspaceID: "ws-new", Kind: "file.read",
		LeaseEpoch: 1, TargetTerminalID: "term-new", PayloadJSON: `{"ciphertext":{"fixture_payload":{"path":"safe.txt"}}}`,
	}
	inserted, err := store.RecordRelayCommand(command)
	if err != nil || !inserted {
		t.Fatalf("record upgraded command inserted=%v err=%v", inserted, err)
	}
	pending, err := store.PendingRelayCommands()
	if err != nil {
		t.Fatalf("read upgraded commands: %v", err)
	}
	found := false
	for _, candidate := range pending {
		if candidate.CommandID == command.CommandID {
			found = true
			if candidate.WorkspaceID != command.WorkspaceID {
				t.Fatalf("workspace_id=%q want %q", candidate.WorkspaceID, command.WorkspaceID)
			}
		}
	}
	if !found {
		t.Fatal("new relay command was not preserved after legacy upgrade")
	}
}
