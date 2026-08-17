package daemon

import (
	"context"
	"errors"
	"fmt"
	"os/exec"
	"strings"
	"sync"
	"time"
)

// 进程监督器的稳定错误。调用者只能据此决定重试或显示状态，不能解析底层 exec 文本。
var (
	ErrProcessAlreadyRunning = errors.New("provider process already running")
	ErrProcessNotRunning     = errors.New("provider process not running")
)

// ProcessExitState 是受控 Provider 子进程的脱敏终态。它不携带 stdout/stderr 或命令参数，
// 防止 Provider 正文、路径或凭据进入 Daemon 日志和 Relay 报告。
type ProcessExitState string

const (
	ProcessExited           ProcessExitState = "exited"
	ProcessFailed           ProcessExitState = "failed"
	ProcessTerminated       ProcessExitState = "terminated"
	ProcessKilled           ProcessExitState = "killed"
	ProcessDeadlineExceeded ProcessExitState = "deadline_exceeded"
)

// ProcessExit 是等待或终止子进程后可安全记录的最小结果。
type ProcessExit struct {
	ID       string
	PID      int
	State    ProcessExitState
	ExitCode int
}

// ProcessSpec 描述 Daemon 明确拥有的一个 Provider 子进程。Path/Args 始终以参数数组传入，
// Supervisor 从不调用 shell。Env 非 nil 时是子进程的完整环境，调用者应只注入所需变量。
type ProcessSpec struct {
	Path        string
	Args        []string
	Dir         string
	Env         []string
	GracePeriod time.Duration
}

// ProcessSupervisor 管理 Daemon 明确创建的 Provider 进程树。它不接管用户已有的服务进程，
// 因而不会误杀由桌面 OpenCode 或其他工具启动的共享服务。
type ProcessSupervisor struct {
	mu        sync.Mutex
	processes map[string]*ManagedProcess
}

// NewProcessSupervisor 构造空监督器。每个 Daemon 运行时实例应独占一个 Supervisor。
func NewProcessSupervisor() *ProcessSupervisor {
	return &ProcessSupervisor{processes: map[string]*ManagedProcess{}}
}

// Start 以不经过 shell 的方式启动并登记一个 Provider 子进程。同一 id 在存活期间只能启动一次，
// 避免重复 delivery 或重试意外创建多个 Provider 实例。
func (s *ProcessSupervisor) Start(ctx context.Context, id string, spec ProcessSpec) (*ManagedProcess, error) {
	if s == nil {
		return nil, errors.New("provider process supervisor unavailable")
	}
	id = strings.TrimSpace(id)
	if id == "" {
		return nil, errors.New("provider process id required")
	}
	path := strings.TrimSpace(spec.Path)
	if path == "" {
		return nil, errors.New("provider process path required")
	}

	// 从重复检查到登记保持同一把锁，避免两个并发 delivery 都在检查后各自启动一个进程。
	s.mu.Lock()
	if _, exists := s.processes[id]; exists {
		s.mu.Unlock()
		return nil, fmt.Errorf("%w: id=%s", ErrProcessAlreadyRunning, id)
	}
	cmd := exec.Command(path, append([]string(nil), spec.Args...)...)
	cmd.Dir = spec.Dir
	if spec.Env != nil {
		cmd.Env = append([]string(nil), spec.Env...)
	}
	// POSIX 平台使用独立 process group；平台回退实现在 build-tag 文件中，禁止在此处拼 shell。
	configureProcessTree(cmd)
	if err := cmd.Start(); err != nil {
		s.mu.Unlock()
		return nil, fmt.Errorf("start provider process: %w", err)
	}

	process := &ManagedProcess{
		supervisor: s,
		id:         id,
		cmd:        cmd,
		grace:      normalizedProcessGrace(spec.GracePeriod),
		done:       make(chan struct{}),
	}
	// cmd.Start 后到登记前没有等待协程；因此不会出现快速退出后被误登记的窗口。
	s.processes[id] = process
	s.mu.Unlock()
	go process.watch(ctx)
	return process, nil
}

// IsRunning 只表示该 id 仍由当前 Daemon 明确拥有，不用于探测或接管外部 Provider 进程。
func (s *ProcessSupervisor) IsRunning(id string) bool {
	if s == nil {
		return false
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	_, ok := s.processes[id]
	return ok
}

// Close 终止本 Daemon 运行期内仍由本 Supervisor 拥有的全部进程。调用方提供的 ctx 控制
// 清理上限；到期后每个 ManagedProcess 仍会发送强制终止，避免遗留子进程树。
func (s *ProcessSupervisor) Close(ctx context.Context) error {
	if s == nil {
		return nil
	}
	s.mu.Lock()
	processes := make([]*ManagedProcess, 0, len(s.processes))
	for _, process := range s.processes {
		processes = append(processes, process)
	}
	s.mu.Unlock()

	var errs []error
	for _, process := range processes {
		if _, err := process.Terminate(ctx); err != nil && !errors.Is(err, ErrProcessNotRunning) {
			errs = append(errs, err)
		}
	}
	return errors.Join(errs...)
}

func (s *ProcessSupervisor) remove(id string, process *ManagedProcess) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.processes[id] == process {
		delete(s.processes, id)
	}
}

// ManagedProcess 是一次由 Daemon 直接创建的 Provider 子进程。它的终止操作可安全重入：
// 已结束的进程会返回同一终态，不会再次发送信号或启动新的实例。
type ManagedProcess struct {
	supervisor *ProcessSupervisor
	id         string
	cmd        *exec.Cmd
	grace      time.Duration

	mu                sync.Mutex
	done              chan struct{}
	exit              ProcessExit
	finished          bool
	terminationIntent ProcessExitState
	stopMu            sync.Mutex
}

// ID 返回仅供 Daemon 本机关联的稳定进程所有权键，不进入 Relay/Event payload。
func (p *ManagedProcess) ID() string { return p.id }

// Wait 等待已记录的脱敏终态。ctx 到期不会丢弃后台 wait；进程监督仍持续清理。
func (p *ManagedProcess) Wait(ctx context.Context) (ProcessExit, error) {
	if p == nil {
		return ProcessExit{}, ErrProcessNotRunning
	}
	if ctx == nil {
		ctx = context.Background()
	}
	select {
	case <-p.done:
		p.mu.Lock()
		defer p.mu.Unlock()
		return p.exit, nil
	case <-ctx.Done():
		return ProcessExit{}, ctx.Err()
	}
}

// Terminate 先向受控进程组发送优雅终止；超过 grace 后升级为强制终止。它绝不调用 Provider
// HTTP abort，因为 abort 只表示取消当前 turn，不能证明本机进程树已经退出。
func (p *ManagedProcess) Terminate(ctx context.Context) (ProcessExit, error) {
	return p.stop(ctx, ProcessTerminated, false)
}

// ForceKill 立即强制结束受控进程组。仅明确拥有本机进程树的 Adapter Handle 可以暴露它给
// session.kill；共享服务或远端 HTTP Provider 必须保持不实现该接口。
func (p *ManagedProcess) ForceKill(ctx context.Context) (ProcessExit, error) {
	return p.stop(ctx, ProcessKilled, true)
}

func (p *ManagedProcess) stop(ctx context.Context, intent ProcessExitState, force bool) (ProcessExit, error) {
	if p == nil {
		return ProcessExit{}, ErrProcessNotRunning
	}
	if ctx == nil {
		ctx = context.Background()
	}
	if result, finished := p.resultIfFinished(); finished {
		return result, nil
	}

	p.stopMu.Lock()
	defer p.stopMu.Unlock()
	if result, finished := p.resultIfFinished(); finished {
		return result, nil
	}
	p.setTerminationIntent(intent)

	if force {
		if err := killProcessTree(p.cmd); err != nil && !processNoLongerRunning(err) {
			return ProcessExit{}, fmt.Errorf("force kill provider process: %w", err)
		}
		return p.waitAfterSignal(ctx)
	}
	if err := terminateProcessTree(p.cmd); err != nil && !processNoLongerRunning(err) {
		return ProcessExit{}, fmt.Errorf("terminate provider process: %w", err)
	}

	timer := time.NewTimer(p.grace)
	defer timer.Stop()
	select {
	case <-p.done:
		return p.Wait(context.Background())
	case <-timer.C:
		// grace 到期后必须升级；否则取消 Daemon 时可能残留孙进程。
		if err := killProcessTree(p.cmd); err != nil && !processNoLongerRunning(err) {
			return ProcessExit{}, fmt.Errorf("escalate provider process kill: %w", err)
		}
		return p.waitAfterSignal(ctx)
	case <-ctx.Done():
		// 调用方的等待预算耗尽不能成为遗留进程的理由，仍执行一次强制清理。
		_ = killProcessTree(p.cmd)
		return p.waitAfterSignal(ctx)
	}
}

func (p *ManagedProcess) waitAfterSignal(ctx context.Context) (ProcessExit, error) {
	if result, finished := p.resultIfFinished(); finished {
		return result, nil
	}
	if ctx.Err() == nil {
		return p.Wait(ctx)
	}
	// 已取消的 ctx 不能用于清理等待；使用有限后台预算，保留原始取消错误供调用方分类。
	cleanupCtx, cancel := context.WithTimeout(context.Background(), p.grace+time.Second)
	defer cancel()
	if _, err := p.Wait(cleanupCtx); err != nil {
		return ProcessExit{}, ctx.Err()
	}
	return p.Wait(context.Background())
}

func (p *ManagedProcess) watch(ctx context.Context) {
	if ctx != nil {
		go func() {
			select {
			case <-ctx.Done():
				cleanupCtx, cancel := context.WithTimeout(context.Background(), p.grace+time.Second)
				defer cancel()
				_, _ = p.stop(cleanupCtx, ProcessDeadlineExceeded, false)
			case <-p.done:
			}
		}()
	}

	waitErr := p.cmd.Wait()
	p.finish(waitErr)
}

func (p *ManagedProcess) finish(waitErr error) {
	p.mu.Lock()
	if p.finished {
		p.mu.Unlock()
		return
	}
	state := ProcessExited
	if p.terminationIntent != "" {
		state = p.terminationIntent
	} else if waitErr != nil {
		state = ProcessFailed
	}
	exitCode := 0
	if p.cmd.ProcessState != nil {
		exitCode = p.cmd.ProcessState.ExitCode()
	}
	p.exit = ProcessExit{ID: p.id, PID: p.cmd.Process.Pid, State: state, ExitCode: exitCode}
	p.finished = true
	p.mu.Unlock()
	// 先撤销 Supervisor 所有权，再向 Wait/调用方发布终态。否则调用方可能在收到 done 后立即
	// 提交同一 id 的新进程，却被尚未清理的旧登记错误拒绝。
	p.supervisor.remove(p.id, p)
	close(p.done)
}

func (p *ManagedProcess) resultIfFinished() (ProcessExit, bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.exit, p.finished
}

func (p *ManagedProcess) setTerminationIntent(intent ProcessExitState) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if !p.finished && p.terminationIntent == "" {
		p.terminationIntent = intent
	}
}

func normalizedProcessGrace(grace time.Duration) time.Duration {
	if grace <= 0 {
		return 2 * time.Second
	}
	return grace
}
