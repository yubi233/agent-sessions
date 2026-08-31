package dsh

import (
	"bufio"
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/yubi233/agent-sessions/internal/adapter"
)

// 本文件承载 DSH 适配器的进程所有权回归（对齐 SESS-05 / DAEMON-PROC-02 断言风格：
// 按 pid 探活、幂等强杀、宽限期收敛轮询）与 Resume 六态定级固化。
// 全部使用 /bin/sh 脚本作为被监督子进程（Setpgid 独占进程组，口径与生产
// newBinTransport 一致），不依赖 node/DSH checkout、不联网；单个用例 <5s。

// startShTransport 用 /bin/sh 脚本启动一个 dshBinTransport：与生产 newBinTransport
// 同口径（Setpgid 独占进程组、stdout 走 scanner、stderr 进诊断环形缓冲、独立持久化
// 临时目录），但可注入更短宽限期 grace（<=0 使用包级缺省 10s）。测试专用脚手架。
func startShTransport(t *testing.T, script string, env []string, grace time.Duration) (*dshBinTransport, int) {
	t.Helper()
	cmd := exec.Command("/bin/sh", "-c", script)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Env = append(os.Environ(), env...)
	ring := &diagRing{}
	cmd.Stderr = ring
	stdin, err := cmd.StdinPipe()
	if err != nil {
		t.Fatalf("打开 sh stdin: %v", err)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatalf("打开 sh stdout: %v", err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatalf("启动 sh 脚本: %v", err)
	}
	tr := &dshBinTransport{
		cmd:         cmd,
		stdin:       stdin,
		stderr:      ring,
		persistRoot: t.TempDir(),
		grace:       grace,
	}
	scanner := bufio.NewScanner(stdout)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	tr.scanner = scanner
	// 任何失败路径都兜底强杀进程组（closeOnce 幂等），防止测试提前退出留下孤儿。
	t.Cleanup(func() { _ = tr.ForceKill() })
	return tr, cmd.Process.Pid
}

// withEnvUnset 临时清理环境变量，测试结束后恢复原值。
func withEnvUnset(t *testing.T, key string) {
	t.Helper()
	old, ok := os.LookupEnv(key)
	if err := os.Unsetenv(key); err != nil {
		t.Fatalf("unset %s: %v", key, err)
	}
	t.Cleanup(func() {
		if ok {
			_ = os.Setenv(key, old)
		} else {
			_ = os.Unsetenv(key)
		}
	})
}

func TestPersistRootDefaultsToTemporaryAndCleanup(t *testing.T) {
	withEnvUnset(t, EnvPersistRoot)
	root, retain, err := newPersistRoot()
	if err != nil {
		t.Fatalf("newPersistRoot: %v", err)
	}
	if retain {
		t.Fatal("默认 persist root 不应保留")
	}
	if _, err := os.Stat(root); err != nil {
		t.Fatalf("默认 persist root 应已创建: %v", err)
	}
	tr := &dshBinTransport{persistRoot: root}
	tr.cleanupPersistRoot()
	if _, err := os.Stat(root); !os.IsNotExist(err) {
		t.Fatalf("默认 persist root 应被清理，stat err=%v", err)
	}
}

func TestPersistRootRetentionOptIn(t *testing.T) {
	verificationRoot := t.TempDir()
	t.Setenv(EnvPersistRoot, verificationRoot)
	root, retain, err := newPersistRoot()
	if err != nil {
		t.Fatalf("newPersistRoot: %v", err)
	}
	if !retain {
		t.Fatal("设置验证根目录后必须保留 persist root")
	}
	if !strings.HasPrefix(root, verificationRoot+string(os.PathSeparator)) {
		t.Fatalf("persist root = %q, want under %q", root, verificationRoot)
	}
	marker := filepath.Join(root, "marker.txt")
	if err := os.WriteFile(marker, []byte("cache-retained"), 0o600); err != nil {
		t.Fatalf("write marker: %v", err)
	}
	tr := &dshBinTransport{persistRoot: root, retainPersistRoot: true}
	tr.cleanupPersistRoot()
	if _, err := os.Stat(marker); err != nil {
		t.Fatalf("验证 persist root 应保留 marker: %v", err)
	}
}

func TestPersistRootRejectsEmptyOrRelativeOptIn(t *testing.T) {
	for _, value := range []string{"", "relative/cache"} {
		t.Run(fmt.Sprintf("value=%q", value), func(t *testing.T) {
			t.Setenv(EnvPersistRoot, value)
			if _, _, err := newPersistRoot(); err == nil {
				t.Fatalf("%s=%q 应 fail-closed", EnvPersistRoot, value)
			}
		})
	}
}

func TestMinimalEnvBindsExactPersistenceRootAndWorkspaceFallback(t *testing.T) {
	withEnvUnset(t, EnvPersistCompression)
	env := strings.Join(minimalEnv("/tmp/workspace/.dsh-sessions", "/tmp/workspace"), "\n")
	if strings.Contains(env, "DSH_SNAPSHOT_SESSIONS_ROOT=/tmp/workspace/.dsh-sessions/sessions") {
		t.Fatal("持久化根不得被错误追加 sessions 子目录")
	}
	if !strings.Contains(env, "DSH_SNAPSHOT_SESSIONS_ROOT=/tmp/workspace/.dsh-sessions") {
		t.Fatal("环境变量必须使用精确 DSH 持久化根")
	}
	if !strings.Contains(env, "DSH_SESSION_CWD=/tmp/workspace") {
		t.Fatal("工作区会话回退根未注入")
	}
	if !strings.Contains(env, "DSH_SNAPSHOT_COMPRESSION=none") {
		t.Fatal("默认 artifact 编码必须显式注入为 none")
	}
}

func TestMinimalEnvHonorsZstdPersistenceCompression(t *testing.T) {
	t.Setenv(EnvPersistCompression, PersistenceCompressionZstd)
	env := strings.Join(minimalEnv("/tmp/workspace/.dsh-sessions", "/tmp/workspace"), "\n")
	if !strings.Contains(env, "DSH_SNAPSHOT_COMPRESSION=zstd") {
		t.Fatal("zstd artifact 编码未注入桥环境")
	}
}

// awaitPidFile 轮询等待 pid 文件出现（SESS-05 awaitChildPID 同款口径）。
func awaitPidFile(t *testing.T, path string) int {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		raw, err := os.ReadFile(path)
		if err == nil {
			pid, parseErr := strconv.Atoi(strings.TrimSpace(string(raw)))
			if parseErr == nil && pid > 0 {
				return pid
			}
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("pid 文件未出现: %s", path)
	return 0
}

// pidAlive 按 pid 探活：signal 0 探测成功即认为存活；ESRCH 表示进程已不存在
// （SESS-05 断言风格：不依赖 wait 状态，直接问内核）。
func pidAlive(pid int) bool {
	return syscall.Kill(pid, 0) == nil
}

// awaitPidGone 轮询等待 pid 进程消失；超时失败（SESS-05 waitChildGone 同款口径）。
func awaitPidGone(t *testing.T, pid int, timeout time.Duration) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if !pidAlive(pid) {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("pid %d 在 %s 内仍未消失", pid, timeout)
}

// 1. 进程所有权回归：ForceKill 必须覆盖整棵进程树——sh 主进程后台再 spawn 一个
// sleep 孙进程（PID 写入文件）后自身长睡；ForceKill 后主进程与孙进程均须消失
// （按 pid 探活），且重复 ForceKill 幂等不报错（closeOnce 收敛）。
func TestForceKillTerminatesWholeProcessGroup(t *testing.T) {
	pidFile := filepath.Join(t.TempDir(), "grandchild.pid")
	script := `sleep 600 &
echo $! > "$PIDFILE"
sleep 600`
	tr, mainPID := startShTransport(t, script, []string{"PIDFILE=" + pidFile}, 0)
	grandPID := awaitPidFile(t, pidFile)

	// 第一刀：立即 SIGKILL 整个进程组（force 路径，跳过 EOF dispose 与宽限）。
	if err := tr.ForceKill(); err != nil {
		t.Fatalf("ForceKill: %v", err)
	}
	// 第二刀：必须幂等不报错。
	if err := tr.ForceKill(); err != nil {
		t.Fatalf("重复 ForceKill 必须幂等: %v", err)
	}
	// 主进程与孙进程都必须消失（失孤孙进程由内核/launchd 回收，轮询等最多 5s）。
	awaitPidGone(t, mainPID, 5*time.Second)
	awaitPidGone(t, grandPID, 5*time.Second)
	// 信号终止的退出码记录为 -1（SIGKILL 证据，未被 reaper 改写成普通退出）。
	if tr.exitCode != -1 {
		t.Fatalf("ForceKill 后 exitCode = %d, want -1（信号终止）", tr.exitCode)
	}
}

// 2. 优雅退出：子进程读 stdin 直到 EOF 后自行退出（模拟桥的受控 dispose）；
// Dispose 返回后进程必须已退出且未触发 SIGKILL 路径——正常退出码 0、无
// “已强制终止进程组”错误、耗时远小于缺省 10s 宽限（走的是 EOF 快路径）。
func TestDisposeGracefulExitOnEOF(t *testing.T) {
	tr, pid := startShTransport(t, `cat > /dev/null
exit 0`, nil, 0)
	h := newHandle(tr)
	go h.readLoop()

	start := time.Now()
	if err := h.Dispose(context.Background()); err != nil {
		t.Fatalf("Dispose: %v", err)
	}
	elapsed := time.Since(start)
	if tr.exitCode != 0 {
		t.Fatalf("EOF 自行退出后 exitCode = %d, want 0（-1 说明走了信号强杀路径）", tr.exitCode)
	}
	if !tr.exited {
		t.Fatal("Dispose 返回后进程必须已退出")
	}
	awaitPidGone(t, pid, 3*time.Second)
	if elapsed >= closeGrace {
		t.Fatalf("优雅退出耗时 %v，不应触及 %v 宽限", elapsed, closeGrace)
	}
}

// 3. SIGKILL 升级：子脚本忽略 stdin 关闭（不读 stdin）持续长睡；把宽限期调短到
// 200ms 后 Dispose，进程必须被强杀（错误含“已强制终止进程组”、exitCode==-1），
// 且总耗时 >= 宽限期；同时守住单用例 <5s 的预算。
func TestDisposeEscalatesToKillWhenChildIgnoresEOF(t *testing.T) {
	const grace = 200 * time.Millisecond
	tr, pid := startShTransport(t, `sleep 600`, nil, grace)
	h := newHandle(tr)
	go h.readLoop()

	start := time.Now()
	err := h.Dispose(context.Background())
	elapsed := time.Since(start)
	if err == nil || !strings.Contains(err.Error(), "已强制终止进程组") {
		t.Fatalf("忽略 EOF 的子进程必须被宽限超时强杀, err = %v", err)
	}
	if elapsed < grace {
		t.Fatalf("强杀总耗时 %v < 宽限期 %v", elapsed, grace)
	}
	if tr.exitCode != -1 {
		t.Fatalf("强杀后 exitCode = %d, want -1（信号终止）", tr.exitCode)
	}
	awaitPidGone(t, pid, 3*time.Second)
	if elapsed >= 5*time.Second {
		t.Fatalf("单用例耗时 %v 超过 5s 预算", elapsed)
	}
}

// 4. Dispose 后 Events() 通道最终关闭（读循环在桥退出后关闭事件通道的回归，
// 且 Dispose 等待 readDone 后才返回，保证不会向已关闭通道写事件）。
func TestEventsChannelClosedAfterDispose(t *testing.T) {
	tr, _ := startShTransport(t, `cat > /dev/null
exit 0`, nil, 0)
	h := newHandle(tr)
	go h.readLoop()

	if err := h.Dispose(context.Background()); err != nil {
		t.Fatalf("Dispose: %v", err)
	}
	select {
	case ev, ok := <-h.Events():
		if ok {
			t.Fatalf("Dispose 后事件通道必须已关闭，仍收到事件 %#v", ev)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("事件通道未在 Dispose 后关闭")
	}
}

// 5. stderr 诊断环形缓冲的容量与脱敏：超长行（>8KiB）被截断并带截断标记、导出中
// 单行不超过行上限；伪造的 sk-xxxx 形态密钥置于 512 截断点之后，随超长行被截断而
// 完整原文/密钥均不出现在缓冲导出（digest，即现有诊断导出方法）中；环形容量只保留
// 最近 maxDiagLines 行，最旧内容被覆盖。
func TestStderrRingBufferCapsAndRedacts(t *testing.T) {
	// 场景一：超长行 + 伪造密钥（密钥放在截断点之后才能验证“截断即脱敏”）。
	ring := &diagRing{}
	fakeKey := "sk-" + strings.Repeat("k", 48)
	original := strings.Repeat("L", 9<<10) + fakeKey
	if _, err := ring.Write([]byte(original + "\n")); err != nil {
		t.Fatalf("Write: %v", err)
	}
	digest := ring.digest()
	if !strings.Contains(digest, "...(truncated)") {
		t.Fatalf("超长行摘要缺少截断标记: %q", digest)
	}
	// 完整原文与 sk- 密钥都不得泄漏进缓冲导出。
	if strings.Contains(digest, original) {
		t.Fatal("完整原文泄漏进缓冲导出")
	}
	if strings.Contains(digest, fakeKey) {
		t.Fatal("伪造 sk- 密钥泄漏进缓冲导出")
	}
	// 导出中每一行都不超过行上限（截断行 = maxDiagLine + 标记长度；未截断 <= maxDiagLine）。
	marker := "...(truncated)"
	for _, line := range strings.Split(digest, "\n") {
		if len(line) > maxDiagLine+len(marker) {
			t.Fatalf("导出行长度 %d 超过上限 %d", len(line), maxDiagLine+len(marker))
		}
		if !strings.HasSuffix(line, marker) && len(line) > maxDiagLine {
			t.Fatalf("未截断行长度 %d 超过 maxDiagLine %d", len(line), maxDiagLine)
		}
	}

	// 场景二：环形容量——写入超过 maxDiagLines 行后只保留最近 maxDiagLines 行，
	// 最旧内容被覆盖、最新内容保留（每行 400B，不触发单行截断，纯测容量）。
	ring = &diagRing{}
	const extra = 10
	const lineLen = 400
	for i := 0; i < maxDiagLines+extra; i++ {
		payload := fmt.Sprintf("%04d-", i) + strings.Repeat("x", lineLen)
		if _, err := ring.Write([]byte(payload + "\n")); err != nil {
			t.Fatalf("Write #%d: %v", i, err)
		}
	}
	digest = ring.digest()
	if got := strings.Count(digest, "\n") + 1; got > maxDiagLines {
		t.Fatalf("digest 行数 %d 超过环形容量 %d", got, maxDiagLines)
	}
	if strings.Contains(digest, "0000-") {
		t.Fatal("环形缓冲应覆盖最旧内容（0000 行不应保留）")
	}
	if last := fmt.Sprintf("%04d-", maxDiagLines+extra-1); !strings.Contains(digest, last) {
		t.Fatalf("最新内容 %s 应保留在 digest 中", last)
	}
}

// 6. Resume 输入缺失时保持 unsupported，且不触发桥进程。
func TestResumeMissingRequestDoesNotSpawn(t *testing.T) {
	spawned := 0
	factory := func() (BridgeTransport, error) {
		spawned++
		return newFakeBridge(), nil
	}
	a := NewWithTransport(factory)

	cases := []adapter.ResumeRequest{
		{},
		{InstanceID: "   "},
		{InstanceID: "sk-" + strings.Repeat("x", 32)},
	}
	sixStates := []string{
		adapter.WakeResumed,
		adapter.WakeRestartedWithContext,
		adapter.WakeUnsupported,
		adapter.WakeLocalStateMissing,
		adapter.WakeWorkspaceMoved,
		adapter.WakeTerminalOffline,
	}
	for i, req := range cases {
		res, err := a.Resume(context.Background(), req)
		if err != nil {
			t.Fatalf("case %d Resume 必须不报错: %v", i, err)
		}
		if res.Result != adapter.WakeUnsupported {
			t.Fatalf("case %d Result = %q, want %q", i, res.Result, adapter.WakeUnsupported)
		}
		inSix := false
		for _, s := range sixStates {
			if res.Result == s {
				inSix = true
				break
			}
		}
		if !inSix {
			t.Fatalf("case %d Result %q 不在六态集合内", i, res.Result)
		}
		if res.InstanceID != "" {
			t.Fatalf("case %d InstanceID = %q, want 空（未恢复任何会话）", i, res.InstanceID)
		}
	}
	if spawned != 0 {
		t.Fatalf("Resume 产生了 %d 个子进程，必须为 0", spawned)
	}

}

// 7. 有效 Resume 通过 ACP session/resume 恢复已有会话；直接 Adapter.Resume
// 没有 Daemon 句柄接收通道，因此调用完成后会主动释放桥进程。
func TestResumeExistingSessionUsesACPResume(t *testing.T) {
	fb := newFakeBridge()
	fb.script = respondByMethod(t, "sess-existing")
	a := NewWithTransport(func() (BridgeTransport, error) { return fb, nil })
	result, err := a.Resume(context.Background(), adapter.ResumeRequest{
		InstanceID: "sess-existing", WorkspaceRoot: "/tmp/dsh-ws", ReplayHistory: false,
	})
	if err != nil {
		t.Fatalf("Resume: %v", err)
	}
	if result.Result != adapter.WakeResumed || result.InstanceID != "sess-existing" {
		t.Fatalf("Resume 结果 = %+v", result)
	}
	var found bool
	for _, frame := range fb.written() {
		if methodOf(frame) == "session/resume" {
			found = true
			params, _ := frame["params"].(map[string]any)
			if params["cwd"] != "/tmp/dsh-ws" {
				t.Fatalf("session/resume cwd = %v", params["cwd"])
			}
			if values, _ := params["mcpServers"].([]any); len(values) != 0 {
				t.Fatalf("session/resume mcpServers = %v", values)
			}
		}
	}
	if !found {
		t.Fatal("有效 Resume 必须发送 session/resume")
	}
}

// 工作区不匹配时，无论调用方是否接管句柄，都必须回收已经启动的桥进程。
func TestResumeWorkspaceMovedDisposesBridge(t *testing.T) {
	fb := newFakeBridge()
	fb.script = func(fb *fakeBridge, msg map[string]any) {
		id := frameID(msg)
		switch methodOf(msg) {
		case "initialize":
			fb.push(t, map[string]any{
				"jsonrpc": "2.0", "id": id,
				"result": map[string]any{
					"protocolVersion": 1,
					"agentInfo":       map[string]any{"name": "deepseek-harness-acp", "version": "0.0.1"},
				},
			})
		case "session/resume":
			fb.push(t, map[string]any{
				"jsonrpc": "2.0", "id": id,
				"error": map[string]any{"code": -32602, "message": "cwd does not match stored cwd"},
			})
		}
	}
	a := NewWithTransport(func() (BridgeTransport, error) { return fb, nil })
	result, err := a.Resume(context.Background(), adapter.ResumeRequest{
		InstanceID: "sess-moved", WorkspaceRoot: "/tmp/dsh-ws", ReplayHistory: false,
	})
	if err != nil || result.Result != adapter.WakeWorkspaceMoved {
		t.Fatalf("工作区移动 Resume = %+v, %v", result, err)
	}
	fb.mu.Lock()
	closed := fb.closed
	fb.mu.Unlock()
	if !closed {
		t.Fatal("工作区移动后桥进程必须回收")
	}
}
