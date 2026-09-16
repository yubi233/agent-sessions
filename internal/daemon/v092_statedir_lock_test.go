package daemon

// V092 回归（计划 §7 T7，已由 2026-09-16 实测升级为"已实证待实现"）：
// Daemon state-dir 单实例锁。
//
// 实测缺陷：同一 state-dir 上并存 3 个 Daemon 进程时会共享同一份 Relay 终端身份
// 与 delivery_seq 游标，命令被多个消费者竞争并以 DAEMON_EXECUTION_FAILED 收场；
// 清理为单实例后同样的命令一次通过（delivery=26 succeeded）。
//
// 契约：
//   - 同一 state-dir 的第二个持有者必须被拒绝（fail-loud，而不是静默启动）；
//   - 释放后可再次获取（进程退出自动释放，不留陈旧锁）；
//   - 不同 state-dir 互不影响；
//   - 诊断开关可显式绕过。

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestV092StateDirLockRejectsSecondHolder(t *testing.T) {
	dir := t.TempDir()
	first, err := AcquireStateDirLock(dir)
	if err != nil {
		t.Fatalf("首个实例必须能获取锁: %v", err)
	}
	defer func() { _ = first.Release() }()

	second, err := AcquireStateDirLock(dir)
	if err == nil {
		_ = second.Release()
		t.Fatal("第二个实例必须被拒绝（fail-loud）")
	}
	if !errors.Is(err, ErrStateDirInUse) {
		t.Fatalf("错误必须是 ErrStateDirInUse: %v", err)
	}
	// 拒绝信息必须能让用户定位：含状态目录与持有者 pid。
	if !strings.Contains(err.Error(), filepath.Clean(dir)) {
		t.Fatalf("错误必须包含 state-dir: %v", err)
	}
	if !strings.Contains(err.Error(), "pid=") {
		t.Fatalf("错误必须包含持有者 pid: %v", err)
	}
}

func TestV092StateDirLockReleasesOnRelease(t *testing.T) {
	dir := t.TempDir()
	first, err := AcquireStateDirLock(dir)
	if err != nil {
		t.Fatalf("获取锁: %v", err)
	}
	if err := first.Release(); err != nil {
		t.Fatalf("释放锁: %v", err)
	}
	// 释放后可再次获取：证明锁随描述符释放，不需要人工清理锁文件。
	second, err := AcquireStateDirLock(dir)
	if err != nil {
		t.Fatalf("释放后必须能重新获取: %v", err)
	}
	defer func() { _ = second.Release() }()
	// 幂等：重复释放不报错。
	if err := second.Release(); err != nil {
		t.Fatalf("重复释放必须幂等: %v", err)
	}
}

func TestV092StateDirLockIsPerDirectory(t *testing.T) {
	first, err := AcquireStateDirLock(t.TempDir())
	if err != nil {
		t.Fatalf("第一个目录: %v", err)
	}
	defer func() { _ = first.Release() }()
	second, err := AcquireStateDirLock(t.TempDir())
	if err != nil {
		t.Fatalf("不同 state-dir 必须互不影响: %v", err)
	}
	defer func() { _ = second.Release() }()
}

func TestV092StateDirLockDiagnosticBypass(t *testing.T) {
	dir := t.TempDir()
	t.Setenv(EnvAllowMultiInstance, "1")
	first, err := AcquireStateDirLock(dir)
	if err != nil {
		t.Fatalf("诊断开关下首个实例: %v", err)
	}
	defer func() { _ = first.Release() }()
	// 绕过模式下第二次获取同样成功（no-op 锁），释放安全。
	second, err := AcquireStateDirLock(dir)
	if err != nil {
		t.Fatalf("诊断开关必须允许并存: %v", err)
	}
	if err := second.Release(); err != nil {
		t.Fatalf("no-op 锁释放必须安全: %v", err)
	}
}

func TestV092StateDirLockPathIsHashedAndStable(t *testing.T) {
	dir := t.TempDir()
	path := StateDirLockPath(dir)
	if !strings.HasSuffix(path, ".lock") {
		t.Fatalf("锁文件必须以 .lock 结尾: %s", path)
	}
	if strings.Contains(path, filepath.Base(dir)) {
		t.Fatalf("锁文件名必须是哈希（避免路径过长/非法字符）: %s", path)
	}
	// 同一目录多次计算结果稳定；相对/绝对写法归一。
	if again := StateDirLockPath(dir); again != path {
		t.Fatalf("同一 state-dir 的锁路径必须稳定: %s vs %s", path, again)
	}
	cwd, _ := os.Getwd()
	rel, err := filepath.Rel(cwd, dir)
	if err == nil && !strings.HasPrefix(rel, "..") {
		if StateDirLockPath(rel) != path {
			t.Fatalf("相对路径必须归一到同一锁文件: %s", StateDirLockPath(rel))
		}
	}
}
