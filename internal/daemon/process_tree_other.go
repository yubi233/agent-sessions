//go:build !darwin && !linux

package daemon

import (
	"errors"
	"os"
	"os/exec"
)

// 非 Darwin/Linux 平台没有本阶段可用的跨子孙进程组 API。此回退只终止 Daemon 直接拥有的
// 子进程，且绝不尝试枚举或接管外部进程；发布到该平台前必须补充对应的 job/process-group 实现。
func configureProcessTree(cmd *exec.Cmd) {}

func terminateProcessTree(cmd *exec.Cmd) error {
	if cmd == nil || cmd.Process == nil {
		return os.ErrProcessDone
	}
	return cmd.Process.Kill()
}

func killProcessTree(cmd *exec.Cmd) error { return terminateProcessTree(cmd) }

func processNoLongerRunning(err error) bool { return errors.Is(err, os.ErrProcessDone) }
