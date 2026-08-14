package daemon

import (
	"context"
	"log/slog"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
)

// fakeTransport 记录投递并允许失败。
type fakeTransport struct {
	delivered int32
	fail      atomic.Bool
	got       []Command
}

func (f *fakeTransport) Deliver(ctx context.Context, cmd Command) error {
	if f.fail.Load() {
		return context.DeadlineExceeded
	}
	atomic.AddInt32(&f.delivered, 1)
	f.got = append(f.got, cmd)
	return nil
}

// SYNC-03：离线 outbox 在重连后重放，且不重复远端命令。
func TestSupervisorReplaysOutbox(t *testing.T) {
	s, err := OpenStore(filepath.Join(t.TempDir(), "daemon.db"))
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer s.Close()
	_ = s.EnqueueCommand("req-1", "session.abort", `{}`)
	_ = s.EnqueueCommand("req-2", "session.abort", `{}`)

	transport := &fakeTransport{}
	sup := NewSupervisor(s, transport, slog.New(slog.NewTextHandler(os.Stderr, nil)))
	n := sup.ReplayOnce(context.Background())
	if n != 2 {
		t.Fatalf("want 2 delivered, got %d", n)
	}
	if atomic.LoadInt32(&transport.delivered) != 2 {
		t.Fatalf("transport delivered = %d", transport.delivered)
	}
	// 重放完成后无 pending，再次 ReplayOnce 不重复投递。
	again := sup.ReplayOnce(context.Background())
	if again != 0 {
		t.Fatalf("expected no re-delivery, got %d", again)
	}
	if atomic.LoadInt32(&transport.delivered) != 2 {
		t.Fatalf("re-delivery occurred: %d", transport.delivered)
	}
}

// 离线失败时保留 pending，恢复后重放。
func TestSupervisorRetriesOnOffline(t *testing.T) {
	s, err := OpenStore(filepath.Join(t.TempDir(), "daemon.db"))
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer s.Close()
	_ = s.EnqueueCommand("req-x", "session.send", `{}`)

	transport := &fakeTransport{}
	transport.fail.Store(true)
	sup := NewSupervisor(s, transport, slog.New(slog.NewTextHandler(os.Stderr, nil)))
	if n := sup.ReplayOnce(context.Background()); n != 0 {
		t.Fatalf("offline should deliver 0, got %d", n)
	}
	// 恢复在线后重放。
	transport.fail.Store(false)
	if n := sup.ReplayOnce(context.Background()); n != 1 {
		t.Fatalf("after reconnect want 1 delivered, got %d", n)
	}
}
