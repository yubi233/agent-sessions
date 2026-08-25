package store

import (
	"context"
	"path/filepath"
	"testing"

	"github.com/yubi233/agent-sessions/packages/protocol"
)

// TestTerminalAuthNonceSurvivesRestart 验证 nonce 一次性状态写入 SQLite，
// Relay 重启后同一 nonce 仍被拒绝，不依赖进程内内存。
func TestTerminalAuthNonceSurvivesRestart(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "relay.db")
	db, err := Open(path)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	if err := NewRepository(db).ConsumeTerminalAuthNonce(ctx, "key-restart", "nonce-restart", 2000); err != nil {
		t.Fatalf("first consume: %v", err)
	}
	// 使用相同到期时间验证旧 nonce 不会被“过期清理”误删。
	if err := db.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}

	db2, err := Open(path)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	defer db2.Close()
	repo := NewRepository(db2)
	err = repo.ConsumeTerminalAuthNonce(ctx, "key-restart", "nonce-restart", 2000)
	if err == nil {
		t.Fatal("reuse after restart must fail")
	}
	apiErr, ok := err.(protocol.APIError)
	if !ok || apiErr.Code != protocol.ErrNonceReused {
		t.Fatalf("reuse after restart error=%T %v, want NONCE_REUSED", err, err)
	}
}
