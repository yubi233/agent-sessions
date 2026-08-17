//go:build darwin || linux

package daemon

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

const (
	processHelperEnabled = "AGENT_SESSIONS_PROCESS_HELPER"
	processHelperMode    = "AGENT_SESSIONS_PROCESS_MODE"
	processHelperPIDFile = "AGENT_SESSIONS_PROCESS_CHILD_PID_FILE"
)

// TestProcessSupervisorHelper 是受控子进程测试的唯一入口。它复用当前 go test 二进制，
// 不依赖 shell、真实 Provider、模型、网络或用户工作区。
func TestProcessSupervisorHelper(t *testing.T) {
	if os.Getenv(processHelperEnabled) != "1" {
		return
	}
	switch os.Getenv(processHelperMode) {
	case "exit":
		os.Exit(0)
	case "crash":
		os.Exit(23)
	case "wait":
		waitForTestProcessTermination()
	case "spawn-child":
		pidFile := os.Getenv(processHelperPIDFile)
		if pidFile == "" {
			os.Exit(2)
		}
		child := exec.Command(os.Args[0], "-test.run=^TestProcessSupervisorHelper$", "--")
		child.Env = append(os.Environ(), processHelperEnabled+"=1", processHelperMode+"=wait")
		if err := child.Start(); err != nil {
			os.Exit(3)
		}
		if err := os.WriteFile(pidFile, []byte(strconv.Itoa(child.Process.Pid)), 0o600); err != nil {
			_ = child.Process.Kill()
			os.Exit(4)
		}
		waitForTestProcessTermination()
	default:
		os.Exit(5)
	}
}

// 空 select 会被 Go runtime 识别为测试进程死锁；使用 sleep 循环才能模拟一个可被 SIGTERM/SIGKILL
// 终止、但不会自行退出的真实 Provider 子进程。
func waitForTestProcessTermination() {
	for {
		time.Sleep(time.Hour)
	}
}

func helperProcessSpec(t *testing.T, mode string, extraEnv ...string) ProcessSpec {
	t.Helper()
	env := append([]string{}, os.Environ()...)
	env = append(env, processHelperEnabled+"=1", processHelperMode+"="+mode)
	env = append(env, extraEnv...)
	return ProcessSpec{
		Path:        os.Args[0],
		Args:        []string{"-test.run=^TestProcessSupervisorHelper$", "--"},
		Env:         env,
		GracePeriod: 100 * time.Millisecond,
	}
}

func awaitProcess(t *testing.T, process *ManagedProcess) ProcessExit {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	result, err := process.Wait(ctx)
	if err != nil {
		t.Fatalf("wait process: %v", err)
	}
	return result
}

// DAEMON-PROC-02：正常退出与崩溃必须产生稳定、脱敏终态，并在 Supervisor 中移除所有权登记。
func TestProcessSupervisorClassifiesExitAndCrash(t *testing.T) {
	cases := []struct {
		name      string
		mode      string
		wantState ProcessExitState
		wantCode  int
	}{
		{name: "normal exit", mode: "exit", wantState: ProcessExited, wantCode: 0},
		{name: "crash", mode: "crash", wantState: ProcessFailed, wantCode: 23},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			supervisor := NewProcessSupervisor()
			process, err := supervisor.Start(context.Background(), "proc-"+strings.ReplaceAll(tc.name, " ", "-"), helperProcessSpec(t, tc.mode))
			if err != nil {
				t.Fatalf("start: %v", err)
			}
			result := awaitProcess(t, process)
			if result.State != tc.wantState || result.ExitCode != tc.wantCode {
				t.Fatalf("result=%+v, want state=%s code=%d", result, tc.wantState, tc.wantCode)
			}
			if supervisor.IsRunning(process.ID()) {
				t.Fatalf("completed process %q must be removed from supervisor", process.ID())
			}
		})
	}
}

// DAEMON-PROC-02：同一 ownership id 不允许并发启动；超时会清理实例而非遗留 pending 进程。
func TestProcessSupervisorRejectsDuplicateAndCleansDeadline(t *testing.T) {
	supervisor := NewProcessSupervisor()
	ctx, cancel := context.WithTimeout(context.Background(), 80*time.Millisecond)
	defer cancel()
	process, err := supervisor.Start(ctx, "proc-timeout", helperProcessSpec(t, "wait"))
	if err != nil {
		t.Fatalf("start: %v", err)
	}
	if _, err := supervisor.Start(context.Background(), "proc-timeout", helperProcessSpec(t, "wait")); !errors.Is(err, ErrProcessAlreadyRunning) {
		t.Fatalf("duplicate start error=%v, want ErrProcessAlreadyRunning", err)
	}
	result := awaitProcess(t, process)
	if result.State != ProcessDeadlineExceeded {
		t.Fatalf("deadline result=%+v, want %s", result, ProcessDeadlineExceeded)
	}
	if supervisor.IsRunning("proc-timeout") {
		t.Fatal("deadline process must be removed from supervisor")
	}
}

// DAEMON-PROC-02：强制终止必须覆盖同一 process group 的子孙进程，并且重复 kill 只能返回
// 已收敛的终态，不能再次发信号或创建新进程。
func TestProcessSupervisorForceKillCleansProcessGroupIdempotently(t *testing.T) {
	supervisor := NewProcessSupervisor()
	pidFile := filepath.Join(t.TempDir(), "child.pid")
	process, err := supervisor.Start(context.Background(), "proc-group", helperProcessSpec(t, "spawn-child", processHelperPIDFile+"="+pidFile))
	if err != nil {
		t.Fatalf("start: %v", err)
	}
	childPID := awaitChildPID(t, pidFile)

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	first, err := process.ForceKill(ctx)
	if err != nil {
		t.Fatalf("force kill: %v", err)
	}
	if first.State != ProcessKilled {
		t.Fatalf("first kill result=%+v, want %s", first, ProcessKilled)
	}
	second, err := process.ForceKill(context.Background())
	if err != nil {
		t.Fatalf("duplicate force kill: %v", err)
	}
	if second != first {
		t.Fatalf("duplicate kill result=%+v, want settled result=%+v", second, first)
	}
	waitChildGone(t, childPID)
	if supervisor.IsRunning("proc-group") {
		t.Fatal("killed process must be removed from supervisor")
	}
}

// DAEMON-PROC-02：Daemon 正常关闭只清理本 Supervisor 直接拥有的进程，并为每个实例留下
// terminated 终态。它不枚举或接管用户手工启动的 Provider 服务。
func TestProcessSupervisorCloseTerminatesAllOwnedProcesses(t *testing.T) {
	supervisor := NewProcessSupervisor()
	first, err := supervisor.Start(context.Background(), "proc-close-1", helperProcessSpec(t, "wait"))
	if err != nil {
		t.Fatalf("start first: %v", err)
	}
	second, err := supervisor.Start(context.Background(), "proc-close-2", helperProcessSpec(t, "wait"))
	if err != nil {
		t.Fatalf("start second: %v", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	if err := supervisor.Close(ctx); err != nil {
		t.Fatalf("close supervisor: %v", err)
	}
	for _, process := range []*ManagedProcess{first, second} {
		result := awaitProcess(t, process)
		if result.State != ProcessTerminated {
			t.Fatalf("close result=%+v, want %s", result, ProcessTerminated)
		}
		if supervisor.IsRunning(process.ID()) {
			t.Fatalf("closed process %q must be removed from supervisor", process.ID())
		}
	}
}

func awaitChildPID(t *testing.T, pidFile string) int {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		raw, err := os.ReadFile(pidFile)
		if err == nil {
			pid, parseErr := strconv.Atoi(strings.TrimSpace(string(raw)))
			if parseErr == nil && pid > 0 {
				return pid
			}
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("child pid file was not written: %s", pidFile)
	return 0
}

func waitChildGone(t *testing.T, pid int) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		err := syscall.Kill(pid, 0)
		if errors.Is(err, syscall.ESRCH) {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("child process %d is still alive after group cleanup", pid)
}
