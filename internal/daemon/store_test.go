package daemon

import (
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
