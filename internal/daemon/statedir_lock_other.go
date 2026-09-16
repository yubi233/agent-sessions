//go:build windows

package daemon

// 非 Unix 平台的 state-dir 锁占位实现。
//
// Windows 上 flock 不可用；这里保持"永不阻止启动"的既有行为，避免在未验证的
// 平台上引入新的失败模式。平台特定的互斥（LockFileEx）留待有实际需求时实现，
// 并在实现前保持行为不变。

import "os"

func tryLockFile(*os.File) (string, error) { return "", nil }

func unlockFile(*os.File) {}
