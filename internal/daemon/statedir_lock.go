package daemon

// v0.9.2 P2/P3（计划 §7 T7，已由 R4 实测升级为"已实证待实现"）：Daemon state-dir 单实例锁。
//
// 为什么需要（实测证据，2026-09-16）：
//   本地验证链路中同一 state-dir 上曾同时存在 3 个 Daemon 进程
//   （一个 go run 包装 + 多个编译产物子进程）。它们共享同一个 Relay 终端身份与
//   delivery_seq 游标，于是：
//     - 同一个命令被多个消费者竞争，落进"非持有实例"的进程；
//     - 命令以 DAEMON_EXECUTION_FAILED 收场，用户侧表现为发送/恢复莫名失败；
//     - 日志出现 "relay command conflicts with durable record"、"SQLITE_BUSY"。
//   清理为单实例后，完全相同的命令一次通过（delivery=26 succeeded）。
//
// 设计口径：
//   - **fail-loud**：已有实例持锁时拒绝启动，给出明确中文原因与持有者 pid，
//     而不是静默启动成第二个消费者（那正是故障来源）；
//   - 可观测：拒绝信息里带状态目录与持有者 pid，用户/回归脚本能直接定位；
//   - 自动释放：锁由进程持有的文件描述符承载，进程退出（含被 kill）即释放，
//     不留需要手工清理的陈旧锁文件；
//   - 可绕过（仅诊断）：AGENT_SESSIONS_DAEMON_ALLOW_MULTI_INSTANCE=1 时跳过检查，
//     供需要临时并行诊断的场景使用，缺省关闭。
//
// 平台语义：Unix 用 flock(LOCK_EX|LOCK_NB)；其它平台由 statedir_lock_other.go
// 提供空实现（返回 no-op 释放），保证跨平台可编译且不改变非 Unix 行为。

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

// EnvAllowMultiInstance 允许跳过单实例检查（仅诊断用途，缺省关闭）。
const EnvAllowMultiInstance = "AGENT_SESSIONS_DAEMON_ALLOW_MULTI_INSTANCE"

// ErrStateDirInUse 表示该 state-dir 已有 Daemon 实例在运行。
var ErrStateDirInUse = errors.New("state-dir 已被另一个 Daemon 实例占用")

// StateDirLock 持有一个 state-dir 的独占锁；Release 幂等。
type StateDirLock struct {
	path string
	file *os.File
}

// StateDirLockPath 返回某个 state-dir 对应的锁文件路径。
//
// 放在系统临时目录（可用 TMPDIR 覆盖）而不是 state-dir 内部：锁需要跨进程可见
// 且与 state-dir 的清理解耦——把锁文件写进 state-dir 会在"删目录重建"的流程里
// 制造"锁文件还在、目录已新"的歧义。文件名用 state-dir 规范路径的哈希，避免
// 路径过长与非法字符。
func StateDirLockPath(stateDir string) string {
	cleaned := filepath.Clean(stateDir)
	if abs, err := filepath.Abs(cleaned); err == nil {
		cleaned = abs
	}
	sum := sha256.Sum256([]byte(cleaned))
	return filepath.Join(os.TempDir(), "agent-sessions-daemon-"+hex.EncodeToString(sum[:8])+".lock")
}

// AcquireStateDirLock 尝试独占 state-dir。
//
// 返回的 err 为 ErrStateDirInUse 时，调用方应当把原因与持有者 pid 一并报给用户
// 并拒绝启动；其它错误按环境问题处理（同样 fail-loud，不静默降级）。
func AcquireStateDirLock(stateDir string) (*StateDirLock, error) {
	if stateDir == "" {
		return nil, errors.New("state-dir 不能为空")
	}
	if v := os.Getenv(EnvAllowMultiInstance); v == "1" || v == "true" {
		return &StateDirLock{}, nil
	}
	path := StateDirLockPath(stateDir)
	file, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, fmt.Errorf("打开 state-dir 锁文件 %s: %w", path, err)
	}
	holder, err := tryLockFile(file)
	if err != nil {
		_ = file.Close()
		return nil, err
	}
	if holder != "" {
		_ = file.Close()
		return nil, fmt.Errorf("%w: %s（state_dir=%s，持有者 pid=%s）。"+
			"请先停止已有 Daemon，或用 AGENT_SESSIONS_DAEMON_ALLOW_MULTI_INSTANCE=1 临时绕过（仅诊断）",
			ErrStateDirInUse, path, filepath.Clean(stateDir), holder)
	}
	return &StateDirLock{path: path, file: file}, nil
}

// Release 释放锁（幂等）。文件不删除：删除会让并发启动的进程各自创建新 inode，
// 失去互斥意义。
func (l *StateDirLock) Release() error {
	if l == nil || l.file == nil {
		return nil
	}
	unlockFile(l.file)
	err := l.file.Close()
	l.file = nil
	return err
}
