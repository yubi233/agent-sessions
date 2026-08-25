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
	// now=1000、过期=2000：第二次消费的清理阈值不得误删仍在保留窗口内的 nonce。
	if err := NewRepository(db).ConsumeTerminalAuthNonce(ctx, "key-restart", "nonce-restart", 1000, 2000); err != nil {
		t.Fatalf("first consume: %v", err)
	}
	// 重启后同一 nonce 必须仍可查重，不依赖进程内内存。
	if err := db.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}

	db2, err := Open(path)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	defer db2.Close()
	repo := NewRepository(db2)
	err = repo.ConsumeTerminalAuthNonce(ctx, "key-restart", "nonce-restart", 1001, 2001)
	if err == nil {
		t.Fatal("reuse after restart must fail")
	}
	apiErr, ok := err.(protocol.APIError)
	if !ok || apiErr.Code != protocol.ErrNonceReused {
		t.Fatalf("reuse after restart error=%T %v, want NONCE_REUSED", err, err)
	}
}

// TestTerminalAuthNonceNotPurgedByLaterConsumes 验证过期清理阈值是当前时间：
// 后续请求时钟前进时，仍在重放窗口内的历史 nonce 不得被提前删除（v0.6 回归）。
func TestTerminalAuthNonceNotPurgedByLaterConsumes(t *testing.T) {
	ctx := context.Background()
	db, err := Open(filepath.Join(t.TempDir(), "relay.db"))
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer db.Close()
	repo := NewRepository(db)

	if err := repo.ConsumeTerminalAuthNonce(ctx, "key-purge", "nonce-purge", 1000, 9999); err != nil {
		t.Fatalf("first consume: %v", err)
	}
	// 时钟前进到 1500：新 nonce 的过期时间更大，但清理只允许删除已过期（<1500）的行。
	err = repo.ConsumeTerminalAuthNonce(ctx, "key-purge", "nonce-purge", 1500, 10499)
	if err == nil {
		t.Fatal("in-window nonce must not be purged by later consumes")
	}
	if apiErr, ok := err.(protocol.APIError); !ok || apiErr.Code != protocol.ErrNonceReused {
		t.Fatalf("error=%T %v, want NONCE_REUSED", err, err)
	}
}
