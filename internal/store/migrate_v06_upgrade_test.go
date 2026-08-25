package store

import (
	"context"
	"database/sql"
	"path/filepath"
	"testing"
	"time"
)

// v0.6MigrationAddedStatements 是本迭代在 migrations 尾部追加的语句数：
// terminal_auth_challenges 表+索引、terminal_identity_keys 表+索引、outbox 退避列。
const v06MigrationAddedStatements = 5

// TestMigrateV06LegacyUpgradePreservesData 演练"上一版本数据库升级"：
// 以不含 v0.6 迁移的旧 schema 建库并写入历史数据，然后执行完整迁移。
// 断言：新表/新列出现；历史账号/设备/命令/outbox 行原样保留；'done' 别名计入 delivered。
func TestMigrateV06LegacyUpgradePreservesData(t *testing.T) {
	path := filepath.Join(t.TempDir(), "relay-upgrade.db")

	// 用旧版迁移集在全新库上建出"上一版本"数据库。
	legacyCount := len(migrations) - v06MigrationAddedStatements
	if legacyCount <= 0 || legacyCount >= len(migrations) {
		t.Fatalf("migration split invalid: %d/%d", legacyCount, len(migrations))
	}
	legacyDB, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatalf("open legacy db: %v", err)
	}
	if err := migrateWith(legacyDB, migrations[:legacyCount]); err != nil {
		t.Fatalf("build legacy schema: %v", err)
	}

	ctx := context.Background()
	now := time.Now()
	repo := NewRepository(legacyDB)
	if err := repo.CreateAccount(ctx, "acct-legacy", "legacy@test.dev", []byte("h"), now); err != nil {
		t.Fatalf("seed account: %v", err)
	}
	if err := repo.CreateDevice(ctx, DeviceRow{
		ID: "dev-legacy", AccountID: "acct-legacy", Role: "terminal", Status: "active",
		DisplayName: "legacy", Platform: "macos",
		IdentityPublicKey: "k", EncryptionPublicKey: "e", LastSeenUnixMS: now.UnixMilli(),
	}); err != nil {
		t.Fatalf("seed device: %v", err)
	}
	if err := repo.CreateCommand(ctx, CommandRow{
		ID: "cmd-legacy", AccountID: "acct-legacy", SessionID: "", Kind: "session.start",
		Status: "succeeded", ScopeHash: "scope", IdempotencyKey: "key-legacy",
	}); err != nil {
		t.Fatalf("seed command: %v", err)
	}
	if err := repo.EnqueueOutbox(ctx, OutboxRow{Kind: "command.updated", PayloadJSON: `{"command_id":"cmd-legacy"}`, Status: "done"}); err != nil {
		t.Fatalf("seed legacy outbox done row: %v", err)
	}
	// 模拟版本切换：旧进程关闭，新进程以完整迁移集打开同一文件。
	if err := legacyDB.Close(); err != nil {
		t.Fatalf("close legacy db: %v", err)
	}

	db, err := Open(path)
	if err != nil {
		t.Fatalf("upgrade migration failed: %v", err)
	}
	repo = NewRepository(db)

	// 新表存在且可用：挑战与登记密钥端口可直接读写。
	challengeRepo := repo
	if err := challengeRepo.CreateTerminalAuthChallenge(ctx, TerminalAuthChallengeRow{
		Challenge: "ch-upgrade", DeviceID: "dev-legacy",
		ExpiresAtUnixMS: now.Add(time.Minute).UnixMilli(), CreatedAtUnixMS: now.UnixMilli(),
	}); err != nil {
		t.Fatalf("new challenge table unusable after upgrade: %v", err)
	}
	consumed, err := repo.ConsumeTerminalAuthChallenge(ctx, "dev-legacy", "ch-upgrade", now.UnixMilli())
	if err != nil || !consumed {
		t.Fatalf("challenge consume after upgrade: %v consumed=%v", err, consumed)
	}
	if err := repo.CreateTerminalIdentityKey(ctx, TerminalIdentityKeyRow{
		KeyID: "tkey-upgrade", DeviceID: "dev-legacy", AccountID: "acct-legacy",
		PublicKey: "pub", Status: "active", CreatedAtUnixMS: now.UnixMilli(),
	}); err != nil {
		t.Fatalf("new identity key table unusable after upgrade: %v", err)
	}

	// 历史数据原样保留。
	device, err := repo.DeviceByID(ctx, "dev-legacy")
	if err != nil || device.Status != "active" {
		t.Fatalf("legacy device lost or altered: %+v err=%v", device, err)
	}
	cmd, err := repo.CommandByID(ctx, "cmd-legacy")
	if err != nil || cmd.Status != "succeeded" {
		t.Fatalf("legacy command lost or altered: %+v err=%v", cmd, err)
	}

	// 'done' 是历史 delivered 别名，升级后仍被可观测性投影识别。
	pending, failed, delivered, err := repo.CountOutboxByStatus(ctx)
	if err != nil {
		t.Fatalf("count outbox: %v", err)
	}
	if pending != 0 || failed != 0 || delivered != 1 {
		t.Fatalf("outbox counts pending=%d failed=%d delivered=%d want 0/0/1", pending, failed, delivered)
	}

	// 迁移幂等：重复执行不再变更任何状态。
	if err := Migrate(db); err != nil {
		t.Fatalf("second migration must be idempotent: %v", err)
	}
	_ = db.Close()
}
