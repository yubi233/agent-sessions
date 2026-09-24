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
	// EnvPersistRoot 是验证专用的 DSH session cache 保留根目录；未设置时仍使用临时目录并在关闭后删除。
	// 它只影响 Detect/无 workspace 的隔离探测，不能覆盖生产 Start/Resume 的工作区根。
	EnvPersistRoot = "AGENT_SESSIONS_DSH_PERSIST_ROOT"
	// EnvPersistCompression 选择 DSH JSONL artifact 的物理编码；必须与 cordis.yml
	// 中的 persistenceCompression 保持一致，迁移入口也使用同一值。
	EnvPersistCompression = "AGENT_SESSIONS_DSH_PERSIST_COMPRESSION"
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

// newBinTransport 启动一个无工作区上下文的探测桥（每会话一个，Setpgid 独占进程组）。
// 启动/恢复使用 newBinTransportForWorkspace，使 DSH persistenceRoot 与用户工作区绑定。
func newBinTransport() (*dshBinTransport, error) {
	return newBinTransportForWorkspace("")
}

// newBinTransportForWorkspace 启动一个 dsh-acp-demo 子进程。
// workspaceRoot 非空时，持久化根固定为 <workspaceRoot>/.dsh-sessions，且不拥有/不清理该目录。
// workspaceRoot 为空时才允许使用临时根或 EnvPersistRoot 隔离根。
func newBinTransportForWorkspace(workspaceRoot string) (*dshBinTransport, error) {
	compression, err := configuredPersistenceCompression()
	if err != nil {
		return nil, err
	}
	persistRoot, retainPersistRoot, ownsPersistRoot, canonicalWorkspace, err := persistRootForWorkspace(workspaceRoot)
	if err != nil {
		return nil, err
	}
	return spawnBridgeTransport(persistRoot, canonicalWorkspace, compression, retainPersistRoot, ownsPersistRoot)
}

// newBinTransportForSource 启动一个绑定「既有 DSH 存储根」的桥子进程（v0.9.5 P0）。
// persistenceRoot 是会话 artifact 实际所在的存储根（工作区 .dsh-sessions 或全局
// ~/.dsh/sessions），compression 是该 artifact 的物理编码——两者都必须与存储现状
// 一致，否则上游按「根编码归属」拒绝加载。该根由用户/DSH 所有：不创建、不迁移、
// 不清理，只校验可读后原样绑定。
func newBinTransportForSource(persistenceRoot, workspaceRoot, compression string) (*dshBinTransport, error) {
	persistenceRoot = strings.TrimSpace(persistenceRoot)
	if persistenceRoot == "" {
		return nil, errors.New("DSH 持久化根为空")
	}
	if !filepath.IsAbs(persistenceRoot) {
		return nil, errors.New("DSH 持久化根必须是绝对路径")
	}
	if compression != PersistenceCompressionNone && compression != PersistenceCompressionZstd {
		return nil, fmt.Errorf("DSH artifact 物理编码 %q 非法（仅支持 none|zstd）", compression)
	}
	// 在 spawn 之前校验根与工作区：fail-closed 且错误信息指向根问题，
	// 绝不留下半开进程或误创建用户存储目录。
	info, err := os.Stat(persistenceRoot)
	if err != nil {
		return nil, fmt.Errorf("DSH 持久化根不可用: %w", err)
	}
	if !info.IsDir() {
		return nil, errors.New("DSH 持久化根不是目录")
	}
	canonicalWorkspace, err := canonicalWorkspaceRoot(workspaceRoot)
	if err != nil {
		return nil, err
	}
	return spawnBridgeTransport(filepath.Clean(persistenceRoot), canonicalWorkspace, compression, true, false)
}

// spawnBridgeTransport 是工作区根与显式存储根两条路径共用的桥 spawn：
// 持久化根、工作区、编码与目录所有权由调用方决定，其余口径（进程组、最小环境、
// 诊断环形缓冲、scanner 缓冲）完全一致。
func spawnBridgeTransport(persistRoot, canonicalWorkspace, compression string, retainPersistRoot, ownsPersistRoot bool) (*dshBinTransport, error) {
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
	ring := &diagRing{}
	cmd := exec.Command(node, bin, "-c", config)
	cmd.Dir = runRoot
	// 最小环境注入（ADR-013 §5）：只透传进程生存必需项并显式重定向持久化，
	// scrub 掉其他 Provider 凭据变量；桥自身按设计加载 DSH 根 .env，本仓库不读取不转储。
	cmd.Env = minimalEnvWithCompression(persistRoot, compression, canonicalWorkspace)
	// 独立进程组：Close/ForceKill 可对整个进程树（含子进程）发信号。
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Stderr = ring
	stdin, err := cmd.StdinPipe()
	if err != nil {
		cleanupPersistPath(persistRoot, ownsPersistRoot, retainPersistRoot, canonicalWorkspace)
		return nil, fmt.Errorf("打开桥 stdin: %w", err)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		cleanupPersistPath(persistRoot, ownsPersistRoot, retainPersistRoot, canonicalWorkspace)
		return nil, fmt.Errorf("打开桥 stdout: %w", err)
	}
	if err := cmd.Start(); err != nil {
		cleanupPersistPath(persistRoot, ownsPersistRoot, retainPersistRoot, canonicalWorkspace)
		return nil, fmt.Errorf("启动 dsh-acp-demo: %w", err)
	}
	t := &dshBinTransport{
		cmd:               cmd,
		stdin:             stdin,
		stderr:            ring,
		persistRoot:       persistRoot,
		retainPersistRoot: retainPersistRoot,
		ownsPersistRoot:   ownsPersistRoot,
		workspaceRoot:     canonicalWorkspace,
	}
	// stdout 每行一帧；scanner 缓冲上限 1 MiB，容忍较大的助手文本块。
	scanner := bufio.NewScanner(stdout)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	t.scanner = scanner
	return t, nil
}

// canonicalWorkspaceRoot 校验并规约工作区根：绝对路径、存在且是目录，
// 返回 EvalSymlinks 后的 canonical 路径（桥 cwd 与 DSH_SESSION_CWD 都用它）。
func canonicalWorkspaceRoot(workspaceRoot string) (string, error) {
	workspaceRoot = strings.TrimSpace(workspaceRoot)
	if workspaceRoot == "" {
		return "", nil
	}
	if !filepath.IsAbs(workspaceRoot) {
		return "", errors.New("workspace root 必须是绝对路径")
	}
	canonicalWorkspace, err := filepath.EvalSymlinks(workspaceRoot)
	if err != nil {
		return "", fmt.Errorf("解析 workspace root: %w", err)
	}
	canonicalWorkspace, err = filepath.Abs(canonicalWorkspace)
	if err != nil {
		return "", fmt.Errorf("规约 workspace root: %w", err)
	}
	info, statErr := os.Stat(canonicalWorkspace)
	if statErr != nil || !info.IsDir() {
		return "", errors.New("workspace root 不是目录")
	}
	return canonicalWorkspace, nil
}

// persistRootForWorkspace 解析生产与探测两种持久化策略。
func persistRootForWorkspace(workspaceRoot string) (path string, retain bool, owns bool, canonicalWorkspace string, err error) {
	workspaceRoot = strings.TrimSpace(workspaceRoot)
	if workspaceRoot != "" {
		canonicalWorkspace, err = canonicalWorkspaceRoot(workspaceRoot)
		if err != nil {
			return "", false, false, "", err
		}
		path = filepath.Join(canonicalWorkspace, ".dsh-sessions")
		if err := os.MkdirAll(path, 0o700); err != nil {
			return "", false, false, "", fmt.Errorf("创建 workspace DSH 持久化根: %w", err)
		}
		return path, true, false, canonicalWorkspace, nil
	}
	path, retain, err = newPersistRoot()
	return path, retain, true, "", err
}

// newPersistRoot 创建桥持久化目录。默认使用系统临时目录并由 Close/ForceKill 清理；
// 设置 AGENT_SESSIONS_DSH_PERSIST_ROOT 时只在该根目录下创建独立子目录并保留，用于真实
// 模型验证把 DSH 原始 session cache 作为可审计 artifact。该开关要求绝对路径，避免相对
// 路径随 dsh checkout cwd 漂移并误落入源码树。
func newPersistRoot() (path string, retain bool, err error) {
	if raw, ok := os.LookupEnv(EnvPersistRoot); ok {
		root := strings.TrimSpace(raw)
		if root == "" {
			return "", false, fmt.Errorf("%s 显式置空，视为未配置", EnvPersistRoot)
		}
		if !filepath.IsAbs(root) {
			return "", false, fmt.Errorf("%s 必须是绝对路径", EnvPersistRoot)
		}
		if err := os.MkdirAll(root, 0o700); err != nil {
			return "", false, fmt.Errorf("创建 DSH 验证持久化根目录: %w", err)
		}
		path, err := os.MkdirTemp(root, "dsh-bridge-")
		if err != nil {
			return "", false, fmt.Errorf("创建 DSH 验证持久化会话目录: %w", err)
		}
		return path, true, nil
	}
	path, err = os.MkdirTemp("", "dsh-bridge-")
	if err != nil {
		return "", false, fmt.Errorf("创建桥持久化临时目录: %w", err)
	}
	return path, false, nil
}

// minimalEnv 构造子进程最小环境：PATH/HOME/TMPDIR、持久化根和会话工作区。
// 编码取环境变量缺省；workspaceRoots 保留可选参数形状，兼容旧的探测 fixture 调用。
func minimalEnv(persistRoot string, workspaceRoots ...string) []string {
	compression, err := configuredPersistenceCompression()
	if err != nil {
		compression = ""
	}
	return minimalEnvWithCompression(persistRoot, compression, workspaceRoots...)
}

// minimalEnvWithCompression 在 minimalEnv 基础上允许显式指定 artifact 物理编码
// （v0.9.5：恢复既有会话时按 artifact 实际编码启动桥，上游按「根编码归属」校验，
// 编码错会被整根拒绝）。压缩编码为空时回落环境变量缺省。
func minimalEnvWithCompression(persistRoot, compression string, workspaceRoots ...string) []string {
	workspaceRoot := ""
	if len(workspaceRoots) > 0 {
		workspaceRoot = workspaceRoots[0]
	}
	env := []string{
		"PATH=" + os.Getenv("PATH"),
		"HOME=" + os.Getenv("HOME"),
		"TMPDIR=" + os.Getenv("TMPDIR"),
		// acp-demo 仅在 snapshot mode 已定义时为 stdin EOF 安装退出处理；
		// per-session 桥显式使用 record 模式以兑现 Dispose 的 graceful EOF 契约。
		"DSH_SNAPSHOT=record",
	}
	if persistRoot != "" {
		// persistenceRoot 本身就是 DSH backend root；再追加 /sessions 会把
		// workspace/.dsh-sessions 错位到 workspace/.dsh-sessions/sessions。
		env = append(env, "DSH_SNAPSHOT_SESSIONS_ROOT="+filepath.Clean(persistRoot))
	}
	if compression == "" {
		if resolved, err := configuredPersistenceCompression(); err == nil {
			compression = resolved
		}
	}
	if compression != "" {
		// 通过独立变量显式锁定桥配置，避免 DSH_SNAPSHOT/运行模式变化时
		// cordis.yml 与迁移目标采用不同后缀。
		env = append(env, "DSH_SNAPSHOT_COMPRESSION="+compression)
	}
	if strings.TrimSpace(workspaceRoot) != "" {
		// 无会话的沙箱调用使用此回退根；普通会话仍由 session.header.cwd 决定边界。
		env = append(env, "DSH_SESSION_CWD="+filepath.Clean(workspaceRoot))
	}
	return env
}

// dshBinTransport 是 BridgeTransport 的子进程实现。
type dshBinTransport struct {
	cmd               *exec.Cmd
	stdin             io.WriteCloser
	scanner           *bufio.Scanner
	stderr            *diagRing
	persistRoot       string
	retainPersistRoot bool
	// ownsPersistRoot 只有临时探测根为 true；工作区根和显式取证根均不可由桥删除。
	ownsPersistRoot bool
	workspaceRoot   string

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
			t.cleanupPersistRoot()
			return errors.New("dsh bridge 未在宽限内退出，已强制终止进程组")
		}
		t.cleanupPersistRoot()
		// 桥异常退出（非 0）时返回含退出码与脱敏 stderr 摘要的错误，便于诊断。
		return t.exitErr()
	}
	t.killGroup()
	<-waitDone
	t.cleanupPersistRoot()
	return nil
}

// cleanupPersistRoot 保留验证显式指定的 DSH cache，默认仍清理临时目录。
func (t *dshBinTransport) cleanupPersistRoot() {
	// 兼容新增 ownsPersistRoot 前构造的旧 fixture transport：workspaceRoot 为空时
	// 延续其历史临时根清理语义。
	owns := t.ownsPersistRoot || (t.workspaceRoot == "" && !t.retainPersistRoot)
	cleanupPersistPath(t.persistRoot, owns, t.retainPersistRoot, t.workspaceRoot)
}

// cleanupPersistPath 是 RemoveAll 的双重守卫：只有本实例拥有的临时根才可删除，
// 且 canonical 路径必须位于系统临时目录内；workspace/.dsh-sessions 永远拒绝删除。
func cleanupPersistPath(path string, owns, retain bool, workspaceRoot string) {
	if !owns || retain || strings.TrimSpace(path) == "" {
		return
	}
	cleanPath, err := filepath.Abs(filepath.Clean(path))
	if err != nil {
		return
	}
	if workspaceRoot != "" {
		cleanWorkspace, wsErr := filepath.Abs(filepath.Clean(workspaceRoot))
		if wsErr == nil {
			// 生产 workspace 根和其所有子路径都由用户所有；即使旧 fixture
			// 错误地把 owns 标成 true，也不能清理工作区内容。
			protected := filepath.Join(cleanWorkspace, ".dsh-sessions")
			if pathWithin(cleanWorkspace, cleanPath) || pathWithin(protected, cleanPath) {
				return
			}
			// 额外比较 realpath，拦截 workspace 符号链接别名形成的路径绕过。
			if realWorkspace, realWorkspaceErr := filepath.EvalSymlinks(cleanWorkspace); realWorkspaceErr == nil {
				if realPath, realPathErr := filepath.EvalSymlinks(cleanPath); realPathErr == nil &&
					pathWithin(realWorkspace, realPath) {
					return
				}
			}
		}
	}
	tempRoot, err := filepath.Abs(filepath.Clean(os.TempDir()))
	if err != nil || cleanPath == tempRoot || !pathWithin(tempRoot, cleanPath) {
		return
	}
	_ = os.RemoveAll(cleanPath)
}

func pathWithin(root, candidate string) bool {
	root = filepath.Clean(root)
	candidate = filepath.Clean(candidate)
	if root == candidate {
		return true
	}
	return strings.HasPrefix(candidate, root+string(os.PathSeparator))
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
