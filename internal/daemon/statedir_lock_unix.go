//go:build !windows

package daemon

// Unix 平台的 state-dir 独占锁实现（flock）。
//
// flock 的语义正合所需：锁随**打开的文件描述符**存在，进程退出（正常或被 kill）
// 时内核自动释放，因此不会留下"陈旧锁"这种需要人工介入的状态。

import (
	"fmt"
	"os"
	"strconv"
	"syscall"
)

// tryLockFile 尝试非阻塞独占锁。
//   - 返回 holder == "" 且 err == nil：加锁成功；
//   - 返回 holder != "" 且 err == nil：未加锁，holder 是持有者 pid（尽力而为，
//     读不到时返回 "unknown"）；
//   - err != nil：锁语义本身失败（按环境问题处理）。
func tryLockFile(file *os.File) (string, error) {
	if err := syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		if err == syscall.EWOULDBLOCK {
			return readLockHolder(file), nil
		}
		return "", fmt.Errorf("获取 state-dir 锁: %w", err)
	}
	// 加锁成功后写入本进程 pid，便于后续实例报告持有者。
	_ = file.Truncate(0)
	_, _ = file.WriteAt([]byte(strconv.Itoa(os.Getpid())), 0)
	return "", nil
}

// unlockFile 释放 flock（幂等）。
func unlockFile(file *os.File) {
	_ = syscall.Flock(int(file.Fd()), syscall.LOCK_UN)
}

// readLockHolder 读取锁文件里记录的持有者 pid（尽力而为，不视为错误）。
func readLockHolder(file *os.File) string {
	buf := make([]byte, 32)
	n, err := file.ReadAt(buf, 0)
	if err != nil && n == 0 {
		return "unknown"
	}
	value := string(buf[:n])
	if value == "" {
		return "unknown"
	}
	return value
}
