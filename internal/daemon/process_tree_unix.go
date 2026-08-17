//go:build darwin || linux

package daemon

import (
	"errors"
	"os"
	"os/exec"
	"syscall"
)

// configureProcessTree 让受控 Provider 进入独立进程组。后续负 PID 信号会覆盖其子孙进程，
// 避免只杀父进程后遗留 CLI、语言运行时或模型代理。
func configureProcessTree(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
}

func terminateProcessTree(cmd *exec.Cmd) error {
	return signalProcessGroup(cmd, syscall.SIGTERM)
}

func killProcessTree(cmd *exec.Cmd) error {
	return signalProcessGroup(cmd, syscall.SIGKILL)
}

func signalProcessGroup(cmd *exec.Cmd, signal syscall.Signal) error {
	if cmd == nil || cmd.Process == nil || cmd.Process.Pid <= 0 {
		return os.ErrProcessDone
	}
	return syscall.Kill(-cmd.Process.Pid, signal)
}

func processNoLongerRunning(err error) bool {
	return errors.Is(err, os.ErrProcessDone) || errors.Is(err, syscall.ESRCH)
}
