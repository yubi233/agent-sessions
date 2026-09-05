package store

// v0.8.9 P1（V089-01）：relay_generation 迁移契约回归。
// 契约（迭代计划 §3.1）：Relay 首次创建数据库时生成随机、不可预测且持久化的
// relay_generation；同一 SQLite 文件重启不变，删除重建必变，备份/恢复随文件走。
// 该字段是 Daemon 识别「Relay DB 已更换」的唯一世代锚点。

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// 同一 SQLite 文件重开（进程重启语义）：世代必须保持不变。
func TestV089RelayGenerationStableAcrossReopen(t *testing.T) {
	path := filepath.Join(t.TempDir(), "relay.db")
	first, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	repo := NewRepository(first)
	generation1, err := repo.RelayGeneration(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if generation1 == "" {
		t.Fatal("首次建库必须生成 relay_generation")
	}
	if err := first.Close(); err != nil {
		t.Fatal(err)
	}

	second, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer second.Close()
	generation2, err := NewRepository(second).RelayGeneration(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if generation1 != generation2 {
		t.Fatalf("同库重开世代必须稳定: %q != %q", generation1, generation2)
	}
}

// 删除重建（reset_default_local_relay_db 语义）：世代必须变化，且值不可预测
// （受控前缀 + 充分长度的随机十六进制）。
func TestV089RelayGenerationChangesAfterDatabaseRebuild(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "relay.db")
	first, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	generation1, err := NewRepository(first).RelayGeneration(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if err := first.Close(); err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(generation1, RelayGenerationPrefix) || len(generation1) < len(RelayGenerationPrefix)+32 {
		t.Fatalf("世代值格式不受控: %q", generation1)
	}

	// 模拟 restart.sh 的 rm -f + 重建。
	if err := recreateFile(path); err != nil {
		t.Fatal(err)
	}
	second, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer second.Close()
	generation2, err := NewRepository(second).RelayGeneration(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if generation1 == generation2 {
		t.Fatalf("删除重建后世代必须变化: %q", generation1)
	}
}

// 备份/恢复随文件走：复制出的库文件必须携带同一世代（deploy backup/restore 可解释性）。
func TestV089RelayGenerationFollowsDatabaseFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "relay.db")
	db, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	generation1, err := NewRepository(db).RelayGeneration(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}

	backupPath := filepath.Join(dir, "relay-backup.db")
	if err := copyFile(path, backupPath); err != nil {
		t.Fatal(err)
	}
	restored, err := Open(backupPath)
	if err != nil {
		t.Fatal(err)
	}
	defer restored.Close()
	generation2, err := NewRepository(restored).RelayGeneration(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if generation1 != generation2 {
		t.Fatalf("备份恢复必须保持世代: %q != %q", generation1, generation2)
	}
}

// 两个独立新建的库世代互不相同（防止跨实例误判为同一世代）。
func TestV089RelayGenerationUniqueAcrossFreshDatabases(t *testing.T) {
	dir := t.TempDir()
	dbA, err := Open(filepath.Join(dir, "a.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer dbA.Close()
	dbB, err := Open(filepath.Join(dir, "b.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer dbB.Close()
	generationA, err := NewRepository(dbA).RelayGeneration(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	generationB, err := NewRepository(dbB).RelayGeneration(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if generationA == generationB {
		t.Fatalf("独立建库的世代不应相同: %q", generationA)
	}
}

// recreateFile 删除并重建一个空文件（等价 restart.sh 的 rm -f 后由 Open 重建 SQLite）。
func recreateFile(path string) error {
	if err := os.Remove(path); err != nil {
		return err
	}
	return os.WriteFile(path, nil, 0o600)
}

// copyFile 以字节复制方式模拟 deploy backup（备份随文件携带全部页与元数据）。
func copyFile(src, dst string) error {
	data, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	return os.WriteFile(dst, data, 0o600)
}
