// Package dsh 实现 DeepSeek Harness（DSH）ACP 桥适配器（第五类 Provider）。
// 传输为 JSON-RPC over stdio（ndjson 帧），每个会话独占一个 dsh-acp-demo 子进程
// （ADR-013 §3 方案 A：per-session 进程，进程组所有权明确）。
package dsh

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"
)

// 环境变量名（与既有 Provider 的 AGENT_SESSIONS_* 前缀口径一致，spec §1 冻结）。
const (
	// EnvBin 覆盖桥可执行脚本路径；未设置时缺省 P0 冒烟核实的路径。
	EnvBin = "AGENT_SESSIONS_DSH_BIN"
	// EnvConfig 覆盖桥的 cordis 配置文件路径；未设置时缺省 P0 冒烟核实的路径。
	EnvConfig = "AGENT_SESSIONS_DSH_CONFIG"
)

// 缺省桥路径（spec 冻结，与 e2e-verify/real/dsh-acp-smoke.mjs --dsh-root 一致）。
const (
	defaultBin    = "/Users/yubi/code/deepseek-harness/packages/examples/acp-demo/lib/bin.js"
	defaultConfig = "/Users/yubi/code/deepseek-harness/examples/acp-agent/cordis.yml"
)

// closeGrace 是受控关闭时等待桥退出的缺省宽限期（spec §1：EOF 触发 dispose，exit 0）；
// 超时后 SIGKILL 整个进程组。dshBinTransport.grace 可按实例覆盖（见该字段），
// 未覆盖时沿用本缺省值，既有调用点语义不变。
const closeGrace = 10 * time.Second

// BridgeTransport 是 DSH ACP 桥的帧级传输接口（注入点）：
// 生产实现 dshBinTransport 负责 spawn/销毁子进程组；契约测试注入内存假桥。
// ForceKill 服务于 session.kill 语义（立即终止，不等宽限）。
type BridgeTransport interface {
	// WriteFrame 把一帧 JSON-RPC 消息序列化为 ndjson 单行写入桥 stdin。
	// 返回错误表示桥已不可写（常为进程已退出）。
	WriteFrame(msg map[string]any) error
	// ReadFrame 阻塞读取桥 stdout 的下一帧（原始字节；可能不是合法 JSON，由调用方容错）。
	// 桥退出（EOF）后返回错误。
	ReadFrame() ([]byte, error)
	// Close 执行受控关闭：关 stdin 触发桥受控 dispose，宽限 10s 后 SIGKILL 进程组。幂等。
	Close() error
	// ForceKill 立即 SIGKILL 整个桥进程组并等待退出。幂等。
	ForceKill() error
}

// binConfig 解析桥路径配置：环境变量优先，未设置时缺省 P0 冒烟核实的路径；
// 显式设置为空视为"未配置"（fail-closed），与既有 Provider 的空值口径一致。
func binConfig() (bin string, config string, err error) {
	bin = defaultBin
	if v, ok := os.LookupEnv(EnvBin); ok {
		if strings.TrimSpace(v) == "" {
			return "", "", fmt.Errorf("%s 显式置空，视为未配置", EnvBin)
		}
		bin = strings.TrimSpace(v)
	}
	config = defaultConfig
	if v, ok := os.LookupEnv(EnvConfig); ok {
		if strings.TrimSpace(v) == "" {
			return "", "", fmt.Errorf("%s 显式置空，视为未配置", EnvConfig)
		}
		config = strings.TrimSpace(v)
	}
	return bin, config, nil
}

// newBinTransport 启动一个 dsh-acp-demo 子进程（每会话一个，Setpgid 独占进程组）。
func newBinTransport() (*dshBinTransport, error) {
	bin, config, err := binConfig()
	if err != nil {
		return nil, err
	}
	node, err := exec.LookPath("node")
	if err != nil {
		return nil, fmt.Errorf("未找到 node 运行时: %w", err)
	}
	// 桥启动目录固定为 DSH 检出根（bin 上溯 5 级），与 P0 冒烟 cwd=--dsh-root 一致：
	// 组合内插件按 DSH 树解析，loadEnv 读取 DSH 根 .env（LLM key 由 DSH 侧承载）。
	runRoot := filepath.Dir(filepath.Dir(filepath.Dir(filepath.Dir(filepath.Dir(bin)))))
	// 每次会话独立的临时持久化目录：把 .sessions / session-query.db 隔离出真实工作区，
	// adr 口径与冒烟脚本 childEnv.DSH_SNAPSHOT_SESSIONS_ROOT 一致。
	persistRoot, err := os.MkdirTemp("", "dsh-bridge-")
	if err != nil {
		return nil, fmt.Errorf("创建桥持久化临时目录: %w", err)
	}
	ring := &diagRing{}
	cmd := exec.Command(node, bin, "-c", config)
	cmd.Dir = runRoot
	// 最小环境注入（ADR-013 §5）：只透传进程生存必需项并显式重定向持久化，
	// scrub 掉其他 Provider 凭据变量；桥自身按设计加载 DSH 根 .env，本仓库不读取不转储。
	cmd.Env = minimalEnv(persistRoot)
	// 独立进程组：Close/ForceKill 可对整个进程树（含子进程）发信号。
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Stderr = ring
	stdin, err := cmd.StdinPipe()
	if err != nil {
		_ = os.RemoveAll(persistRoot)
		return nil, fmt.Errorf("打开桥 stdin: %w", err)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		_ = os.RemoveAll(persistRoot)
		return nil, fmt.Errorf("打开桥 stdout: %w", err)
	}
	if err := cmd.Start(); err != nil {
		_ = os.RemoveAll(persistRoot)
		return nil, fmt.Errorf("启动 dsh-acp-demo: %w", err)
	}
	t := &dshBinTransport{
		cmd:         cmd,
		stdin:       stdin,
		stderr:      ring,
		persistRoot: persistRoot,
	}
	// stdout 每行一帧；scanner 缓冲上限 1 MiB，容忍较大的助手文本块。
	scanner := bufio.NewScanner(stdout)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	t.scanner = scanner
	return t, nil
}

// minimalEnv 构造子进程最小环境：PATH/HOME/TMPDIR + 持久化重定向（DPO 冒烟口径）。
func minimalEnv(persistRoot string) []string {
	env := []string{
		"PATH=" + os.Getenv("PATH"),
		"HOME=" + os.Getenv("HOME"),
		"TMPDIR=" + os.Getenv("TMPDIR"),
	}
	if persistRoot != "" {
		env = append(env, "DSH_SNAPSHOT_SESSIONS_ROOT="+filepath.Join(persistRoot, "sessions"))
	}
	return env
}

// dshBinTransport 是 BridgeTransport 的子进程实现。
type dshBinTransport struct {
	cmd         *exec.Cmd
	stdin       io.WriteCloser
	scanner     *bufio.Scanner
	stderr      *diagRing
	persistRoot string

	writeMu   sync.Mutex // stdin 写串行化（Send/通知/权限应答并发安全）
	closeOnce sync.Once
	closeErr  error

	// grace 是受控关闭宽限期的可注入覆盖：Close 等待桥退出的时间上限，超时后 SIGKILL
	// 整个进程组。<=0 时使用包级缺省 closeGrace（10s）。用途：进程所有权回归测试需要把
	// "EOF→SIGKILL 升级时序"压缩到毫秒级可观测（如 200ms），而生产调用点 newBinTransport
	// 不设置该字段，保持缺省 10s 与既有调用点行为完全一致。
	grace time.Duration

	exitMu   sync.Mutex
	exitCode int // -1 表示被信号终止或未知
	exited   bool
}

// WriteFrame 序列化 JSON-RPC 帧为 ndjson 单行并写入桥 stdin。
func (t *dshBinTransport) WriteFrame(msg map[string]any) error {
	raw, err := json.Marshal(msg)
	if err != nil {
		return fmt.Errorf("编码 JSON-RPC 帧: %w", err)
	}
	raw = append(raw, '\n')
	t.writeMu.Lock()
	defer t.writeMu.Unlock()
	if _, err := t.stdin.Write(raw); err != nil {
		return fmt.Errorf("写入桥 stdin: %w", err)
	}
	return nil
}

// ReadFrame 读取桥 stdout 的下一帧原始字节；桥退出后返回 io.EOF。
func (t *dshBinTransport) ReadFrame() ([]byte, error) {
	if t.scanner == nil {
		return nil, errors.New("dsh bridge stdout 未初始化")
	}
	if !t.scanner.Scan() {
		if err := t.scanner.Err(); err != nil {
			return nil, fmt.Errorf("读取桥 stdout: %w", err)
		}
		return nil, io.EOF
	}
	// 复制行内容：scanner 下次 Scan 会复用底层缓冲，不能把指针交出去。
	line := t.scanner.Bytes()
	out := make([]byte, len(line))
	copy(out, line)
	return out, nil
}

// Close 受控关闭：关 stdin → 桥受控 dispose → 宽限 10s → SIGKILL 进程组。幂等。
func (t *dshBinTransport) Close() error {
	t.closeOnce.Do(func() { t.closeErr = t.close(false) })
	return t.closeErr
}

// ForceKill 立即 SIGKILL 进程组并等待退出（session.kill 语义）。幂等。
func (t *dshBinTransport) ForceKill() error {
	t.closeOnce.Do(func() { t.closeErr = t.close(true) })
	return t.closeErr
}

// close 实现两种终止路径；force=true 时跳过 EOF dispose 与宽限，直接信号终止。
func (t *dshBinTransport) close(force bool) error {
	if !force {
		// 关 stdin 触发桥的受控 dispose（P0 实测 EOF 后 exit 0）。
		_ = t.stdin.Close()
	}
	waitDone := make(chan struct{})
	go func() {
		waitErr := t.cmd.Wait()
		t.exitMu.Lock()
		t.exitCode = exitCodeOf(waitErr)
		t.exited = true
		t.exitMu.Unlock()
		close(waitDone)
	}()
	if !force {
		select {
		case <-waitDone:
		case <-time.After(t.effectiveGrace()):
			t.killGroup()
			<-waitDone
			_ = os.RemoveAll(t.persistRoot)
			return errors.New("dsh bridge 未在宽限内退出，已强制终止进程组")
		}
		_ = os.RemoveAll(t.persistRoot)
		// 桥异常退出（非 0）时返回含退出码与脱敏 stderr 摘要的错误，便于诊断。
		return t.exitErr()
	}
	t.killGroup()
	<-waitDone
	_ = os.RemoveAll(t.persistRoot)
	return nil
}

// effectiveGrace 返回本实例生效的宽限期：显式注入（grace>0）优先，否则回落到
// 包级缺省 closeGrace（10s）。生产调用点不注入，故与既有语义完全一致。
func (t *dshBinTransport) effectiveGrace() time.Duration {
	if t.grace > 0 {
		return t.grace
	}
	return closeGrace
}

// exitErr 返回进程退出诊断：正常退出（0 或信号终止）返回 nil；非 0 错误码返回
// 带退出码与脱敏 stderr 摘要的错误。
func (t *dshBinTransport) exitErr() error {
	t.exitMu.Lock()
	code, exited := t.exitCode, t.exited
	t.exitMu.Unlock()
	if !exited || code == 0 {
		return nil
	}
	digest := t.stderr.digest()
	if digest == "" {
		return fmt.Errorf("dsh bridge 异常退出（exit code %d）", code)
	}
	if len(digest) > 600 {
		digest = digest[:600] + "..."
	}
	return fmt.Errorf("dsh bridge 异常退出（exit code %d）: %s", code, digest)
}

// exitCodeOf 提取 Wait 的错误退出码；未被信号终止时返回 -1。
func exitCodeOf(waitErr error) int {
	if waitErr == nil {
		return 0
	}
	var exitErr *exec.ExitError
	if errors.As(waitErr, &exitErr) {
		return exitErr.ExitCode()
	}
	return -1
}

// killGroup 向整个进程组发 SIGKILL（Setpgid 使 pgid==子进程 pid）。
func (t *dshBinTransport) killGroup() {
	if t.cmd.Process == nil {
		return
	}
	_ = syscall.Kill(-t.cmd.Process.Pid, syscall.SIGKILL)
}

// stderr 诊断环形缓冲上限。
const (
	maxDiagLines = 64
	maxDiagBytes = 8 << 10
	maxDiagLine  = 512
)

// diagRing 是桥 stderr 的脱敏环形缓冲：只保留最近 maxDiagLines 行、总长不超过
// maxDiagBytes，每行截断到 maxDiagLine 并清洗非法 UTF-8，防止敏感正文或超大日志
// 进入诊断信息。写入侧并发安全。
type diagRing struct {
	mu       sync.Mutex
	buf      [maxDiagLines]string
	next     int
	count    int
	total    int
	leftover []byte
}

// Write 实现 io.Writer：按行收集 stderr 诊断。
func (r *diagRing) Write(p []byte) (int, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.leftover = append(r.leftover, p...)
	for {
		idx := bytes.IndexByte(r.leftover, '\n')
		if idx < 0 {
			break
		}
		line := r.leftover[:idx]
		r.leftover = r.leftover[idx+1:]
		r.push(string(line))
	}
	return len(p), nil
}

// push 追加一行（环形覆盖最旧行）。
func (r *diagRing) push(line string) {
	line = sanitizeDiag(line)
	if r.count == maxDiagLines {
		r.total -= len(r.buf[r.next])
	} else {
		r.count++
	}
	r.buf[r.next] = line
	r.total += len(line)
	r.next = (r.next + 1) % maxDiagLines
}

// digest 返回最近诊断（按时间序），供错误信息引用；无诊断时返回空串。
func (r *diagRing) digest() string {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.count == 0 {
		return ""
	}
	lines := make([]string, 0, r.count)
	for i := 0; i < r.count; i++ {
		idx := (r.next - r.count + i + maxDiagLines) % maxDiagLines
		lines = append(lines, r.buf[idx])
	}
	return strings.Join(lines, "\n")
}

// sanitizeDiag 清洗单行诊断：非法 UTF-8 替换 + 超长截断。
func sanitizeDiag(line string) string {
	line = strings.ToValidUTF8(line, "\uFFFD")
	if len(line) > maxDiagLine {
		line = line[:maxDiagLine] + "...(truncated)"
	}
	return line
}
