// Package main 是 PC Daemon 的 CLI 入口：status/project/session/doctor/run/runner。
// 真实 Provider、service 安装与 keyring 属于平台/发布 gate，此处提供本地可验证子集。
package main

import (
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"time"

	"github.com/yubi233/agent-sessions/internal/adapter"
	"github.com/yubi233/agent-sessions/internal/adapter/codex"
	"github.com/yubi233/agent-sessions/internal/adapter/dsh"
	"github.com/yubi233/agent-sessions/internal/adapter/opencode"
	"github.com/yubi233/agent-sessions/internal/daemon"
	"github.com/yubi233/agent-sessions/internal/workspacesafe"
)

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "daemon:", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	fs := flag.NewFlagSet("daemon", flag.ExitOnError)
	stateDir := fs.String("state-dir", "", "本地状态目录")
	relayBase := fs.String("relay-base", "", "Relay base URL（也可由本机 state/环境提供）")
	accessToken := fs.String("access-token", "", "Daemon device bearer（建议使用环境变量，不会打印）")
	fixtureAdapter := fs.Bool("fixture-adapter", false, "使用 deterministic fixture Adapter；仅本地测试")
	workspaceID := fs.String("workspace-id", "", "Relay Workspace ID（仅 workspace-confirm 使用）")
	workspaceRoot := fs.String("workspace-root", "", "已确认 Git 根目录（仅 workspace-confirm 使用）")
	sub := ""
	if len(args) > 0 && args[0][0] != '-' {
		sub = args[0]
		args = args[1:]
	}
	// keygen 使用独立 flag 集（--out <file>），必须绕过主 flag 集解析，
	// 否则 -out 会被当作未知全局参数拒绝。
	if sub == "keygen" {
		return cmdKeygen(args)
	}
	fs.Parse(args)

	dir := *stateDir
	if dir == "" {
		dir = filepath.Join(os.TempDir(), "agent-sessions-daemon")
	}
	_ = os.MkdirAll(dir, 0o700)
	st, err := daemon.OpenStore(daemon.DefaultStatePath(dir))
	if err != nil {
		return fmt.Errorf("open local store: %w", err)
	}
	defer st.Close()

	switch sub {
	case "", "status":
		return cmdStatus(st)
	case "doctor":
		return cmdDoctor()
	case "run":
		return cmdRun(st, *relayBase, *accessToken, *fixtureAdapter)
	case "runner":
		// 本地 outbox -> Adapter 兑现演示（Relay 连接未实现，不假装已连）。
		return cmdRunner(st)
	case "workspace-confirm":
		return cmdWorkspaceConfirm(st, *workspaceID, *workspaceRoot)
	case "doctor-path":
		// 校验指定工作区路径安全。
		return cmdDoctorPath(fs.Arg(0))
	case "keygen":
		// v0.6 残余项收口：生成本机 Terminal 身份密钥（ed25519 seed 文件 + stdout 公钥），
		// restart.sh 在 --terminal-signing 配对流程中调用；详见 internal/daemon/terminal_signing.go。
		return cmdKeygen(fs.Args())
	default:
		return fmt.Errorf("unknown command %q (支持 status/doctor/run/runner/workspace-confirm/keygen)", sub)
	}
}

// cmdKeygen 生成本机 Terminal 签名身份密钥：--out 指定的文件写入一行 base64url
// 编码的 ed25519 seed（0600），stdout 只输出对应公钥；私钥材料绝不进入 stdout/日志。
// 幂等语义：文件已存在且内容合法时不覆盖，直接输出该 seed 派生的公钥——同一状态目录
// 内反复调用永远得到同一设备身份；内容非法或无法解析时 fail-closed 报错。
func cmdKeygen(args []string) error {
	keyFs := flag.NewFlagSet("daemon keygen", flag.ExitOnError)
	out := keyFs.String("out", "", "私钥种子文件输出路径（必须显式指定）")
	if err := keyFs.Parse(args); err != nil {
		return err
	}
	if strings.TrimSpace(*out) == "" {
		return fmt.Errorf("keygen 需要 --out <file> 指定私钥种子文件路径")
	}
	if raw, err := os.ReadFile(*out); err == nil {
		// 已存在：不覆盖旧身份（可能已绑定配对设备与历史事件），只回放其公钥。
		pubB64, pubErr := derivePubFromSeedFile(raw)
		if pubErr != nil {
			return fmt.Errorf("密钥文件 %s 内容非法: %w", *out, pubErr)
		}
		fmt.Println(pubB64)
		return nil
	}
	seedB64, pubB64, err := daemon.GenerateTerminalSigningSeed()
	if err != nil {
		return err
	}
	// 0600：只有运行 Daemon 的本机用户可读；写入失败时不落任何临时副本。
	if err := os.WriteFile(*out, []byte(seedB64+"\n"), 0o600); err != nil {
		return fmt.Errorf("写入 Terminal 私钥种子文件失败: %w", err)
	}
	fmt.Println(pubB64)
	return nil
}

// derivePubFromSeedFile 从密钥文件内容（一行 base64url ed25519 seed）推导公钥。
func derivePubFromSeedFile(raw []byte) (string, error) {
	seed, err := daemon.DecodeTerminalSigningSeed(strings.TrimSpace(string(raw)))
	if err != nil {
		return "", err
	}
	pub, ok := seed.Public().(ed25519.PublicKey)
	if !ok {
		return "", fmt.Errorf("ed25519 public key type assertion failed")
	}
	return base64.RawURLEncoding.EncodeToString(pub), nil
}

func cmdStatus(st *daemon.Store) error {
	dev, err := st.Get("device_id")
	if err != nil {
		dev = "(未配对)"
	}
	relay, _ := st.Get("relay_base")
	fmt.Printf("daemon status\n  device_id: %s\n  relay: %s\n", dev, relay)
	return nil
}

func cmdDoctor() error {
	fmt.Println("daemon doctor: OK")
	return nil
}

// cmdRun 启动真实 Relay REST+SSE 循环。凭据只从显式 flag、当前环境变量或 Daemon 本机 state 读取，
// 不读取浏览器/其他 CLI 登录态；生产 event DEK 只从 Daemon 环境读取，未配置时会 fail-closed 地扣留事件。
func cmdRun(st *daemon.Store, relayBase, accessToken string, useFixtureAdapter bool) error {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo}))
	if relayBase == "" {
		relayBase = os.Getenv("AGENT_SESSIONS_RELAY_BASE")
	}
	if relayBase == "" {
		relayBase, _ = st.Get("relay_base")
	}
	if accessToken == "" {
		accessToken = os.Getenv("AGENT_SESSIONS_DAEMON_TOKEN")
	}
	if accessToken == "" {
		accessToken, _ = st.Get("daemon_access_token")
	}
	if relayBase == "" || accessToken == "" {
		return fmt.Errorf("需要 Relay 地址和已配对 Terminal 凭据（--relay-base / --access-token 或本机配置）")
	}
	hostname, err := os.Hostname()
	if err != nil || hostname == "" {
		hostname = "agent-sessions-daemon"
	}
	adapters := map[string]adapter.Adapter{"opencode": opencode.New()}
	if !useFixtureAdapter {
		// dsh 由每个 session 自己 spawn ACP 桥；注册表中的 dsh 能力快照
		// 与 Daemon 执行侧必须使用同一个生产适配器，否则 Flutter 创建
		// provider=dsh 的 session.start 会在 runner 处错误地 fail-closed。
		adapters["dsh"] = dsh.New()
	}
	encoder, clearEventDEK, err := eventEncoderForRun(useFixtureAdapter, os.Getenv)
	if err != nil {
		return fmt.Errorf("加载生产 event E2EE 配置: %w", err)
	}
	defer clearEventDEK()
	webRead, err := daemon.LoadWebReadTransportFromEnv(os.Getenv)
	if err != nil {
		return fmt.Errorf("加载 Web 只读 transport 配置: %w", err)
	}
	if webRead != nil {
		defer webRead.Destroy()
	}
	if useFixtureAdapter {
		adapters = map[string]adapter.Adapter{"mock": adapter.NewMockAdapter()}
	}
	// Codex 执行侧灰度接入：feature flag（AGENT_SESSIONS_CODEX_ENABLE）显式开启才注册，
	// 关闭/未配置时完全不影响既有链路；回滚即 unset。
	if !useFixtureAdapter && codex.EnabledFromEnv(os.Getenv) {
		a := codex.New()
		adapters["codex"] = a
		defer func() { _ = a.Close() }()
		logger.Info("codex adapter enabled", "bin_configured", os.Getenv(codex.EnvBin) != "")
	}
	runner := daemon.NewSessionRunner(st, adapters, logger)
	defer func() { _ = runner.Close(context.Background()) }()
	// workspace.create 的绝对路径只能由本机授权根推导；授权根在进程启动时
	// fail-closed 校验，避免 Daemon 在错误目录下先上线再处理命令。
	workspaceManager, err := daemon.NewWorkspaceManager(st, os.Getenv(daemon.WorkspaceRootEnv))
	if err != nil {
		return fmt.Errorf("加载工作区授权根: %w", err)
	}
	// v0.6 残余项收口：按环境契约加载 Terminal 出站签名器（文件/内联互斥）。
	// 未配置时 signer 为 nil，进程保持 bearer 桥接行为；配置后所有 Terminal POST
	// 自动附加 Ed25519 签名，且签名类失败会让 RelayLoop 立即退出（不静默回退 bearer，
	// 见 internal/daemon.RelayLoop.RunWithRetry）。
	deviceID, _ := st.Get("device_id")
	signer, err := daemon.LoadTerminalSignerFromEnv(os.Getenv, deviceID)
	if err != nil {
		return fmt.Errorf("加载 Terminal 签名私钥: %w", err)
	}
	loop := daemon.NewRelayLoop(st, &daemon.RelayClient{BaseURL: relayBase, AccessToken: accessToken, Signer: signer}, runner, encoder, logger)
	loop.DaemonVersion = "agent-sessions-daemon-p2"
	loop.Hostname = hostname
	loop.Platform = runtime.GOOS
	loop.WorkspaceManager = workspaceManager
	if useFixtureAdapter {
		loop.Capabilities = []string{"start", "send", "resume", "abort", "model_select", "effort_select", "file_read", "git_read", "workspace_create"}
	} else {
		loop.Capabilities = []string{"start", "send", "resume", "abort", "model_select", "effort_select", "workspace_create"}
	}
	if webRead != nil {
		// 只在私钥实际可用时声明 browser read capability；缺失配置时 Web endpoint 必须保持
		// fail-closed，不能因为普通 file_read capability 误认为可加密响应。
		loop.Capabilities = append(loop.Capabilities, "web_read_transport")
		loop.WebRead = webRead
	}
	// 观测口径：只记录签名是否启用（布尔），绝不记录密钥材料或 key id 之外的设备元数据。
	logger.Info("daemon relay loop starting", "fixture_adapter", useFixtureAdapter, "relay_configured", relayBase != "", "terminal_signing", signer != nil)
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	return loop.RunWithRetry(ctx)
}

// eventEncoderForRun 集中生产与 fixture 的加密边界：fixture 永远不接触生产 DEK；
// 生产环境只有在两项密钥配置都缺失时才沿用旧的事件扣留行为，半配置必须拒绝启动。
func eventEncoderForRun(useFixtureAdapter bool, getenv func(string) string) (daemon.EventEncoder, func(), error) {
	if useFixtureAdapter {
		return daemon.FixtureEventEncoder{}, func() {}, nil
	}
	localDevPlaintext := strings.TrimSpace(getenv(daemon.LocalDevPlaintextEnv)) != ""
	encoder, err := daemon.LoadE2EEEventEncoderFromEnv(getenv)
	if err != nil {
		return nil, nil, err
	}
	// 生产 E2EE 与本地开发明文互斥：同时配置说明操作者意图不明确，必须拒绝启动，
	// 不能悄悄选择其中一条路径。
	if encoder != nil && localDevPlaintext {
		return nil, nil, fmt.Errorf("%s 与生产事件密钥（%s/%s）互斥",
			daemon.LocalDevPlaintextEnv, daemon.EventDEKEnvironment, daemon.EventKeyIDEnvironment)
	}
	if encoder != nil {
		return encoder, encoder.Destroy, nil
	}
	if localDevPlaintext {
		return daemon.NewLocalDevEventEncoder(), func() {}, nil
	}
	return nil, func() {}, nil
}

// cmdRunner 把 outbox 中 pending 的 Relay 命令兑现到 OpenCode Adapter（ADPT-OPENCODE-06）。
// 对应项目文档 docs/zh/项目文档.md 的「PC Daemon」：启动/恢复/停止本地 Session Instance，
// 统一为 canonical event stream。
// runner 子命令保留为「读取本地 outbox 并消费」诊断入口；真实 Relay 命令闭环由 run 负责。
// 未配置 AGENT_SESSIONS_OPENCODE_URL 时 opencode adapter Detect 全 unsupported，
// session.start/resume 对 runner 返回 fail-closed 错误（「统一能力模型」章节）。
func cmdRunner(st *daemon.Store) error {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo}))
	logger.Info("daemon runner starting (local outbox loop)")
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	runner := daemon.NewSessionRunner(st, map[string]adapter.Adapter{
		"opencode": opencode.New(),
	}, logger)
	if codex.EnabledFromEnv(os.Getenv) {
		a := codex.New()
		// 诊断入口同样按 feature flag 注册；进程生命周期随 cmdRunner 返回结束。
		defer func() { _ = a.Close() }()
		runner.RegisterAdapter("codex", a)
	}
	defer func() { _ = runner.Close(context.Background()) }()

	pending, err := st.PendingCommands()
	if err != nil {
		return fmt.Errorf("pending commands: %w", err)
	}
	consumed := 0
	for _, cmd := range pending {
		if err := runner.ConsumeCommand(ctx, cmd); err != nil {
			// 消费失败：保持 pending，等待下轮重试；不把失败标记为 delivered。
			logger.Warn("daemon runner deferred", "command", cmd.ID, "kind", cmd.Kind, "error", err)
			continue
		}
		if err := st.MarkDelivered(cmd.ID); err != nil {
			logger.Error("daemon runner mark delivered", "command", cmd.ID, "error", err)
			continue
		}
		consumed++
	}
	logger.Info("daemon runner pass", "consumed", consumed, "pending", len(pending))
	return nil
}

func cmdDoctorPath(p string) error {
	if p == "" {
		return fmt.Errorf("需要工作区路径")
	}
	// 校验该目录是否安全 Git 根。
	if !workspacesafe.IsGitRoot(p) {
		return fmt.Errorf("%s 不是 Git 仓库根", p)
	}
	abs, err := workspacesafe.ResolveRepoRelative(p, ".")
	if err != nil {
		return fmt.Errorf("路径不安全: %w", err)
	}
	fmt.Printf("workspace OK: %s\n", abs)
	return nil
}

// cmdWorkspaceConfirm 只在本机登记已经由用户确认的 Git 根。Relay 命令中的 Workspace ID 只是
// opaque 元数据，不能单独授予目录权限；后续只读 dispatcher 会同时检查这个本机登记和 Terminal ID。
func cmdWorkspaceConfirm(st *daemon.Store, workspaceID, workspaceRoot string) error {
	confirmed, err := st.ConfirmWorkspace(workspaceID, workspaceRoot)
	if err != nil {
		return fmt.Errorf("确认工作区失败: %w", err)
	}
	// 为避免将绝对路径扩散到终端输出，只确认 opaque ID 已保存。
	fmt.Printf("workspace confirmed: %s\n", confirmed.ID)
	return nil
}
