// Package main 是 PC Daemon 的 CLI 入口：status/project/session/doctor/run/runner。
// 真实 Provider、service 安装与 keyring 属于平台/发布 gate，此处提供本地可验证子集。
package main

import (
	"context"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"path/filepath"
	"runtime"
	"syscall"
	"time"

	"github.com/yubi233/agent-sessions/internal/adapter"
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
	default:
		return fmt.Errorf("unknown command %q (支持 status/doctor/run/runner/workspace-confirm)", sub)
	}
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
	encoder, clearEventDEK, err := eventEncoderForRun(useFixtureAdapter, os.Getenv)
	if err != nil {
		return fmt.Errorf("加载生产 event E2EE 配置: %w", err)
	}
	defer clearEventDEK()
	if useFixtureAdapter {
		adapters = map[string]adapter.Adapter{"mock": adapter.NewMockAdapter()}
	}
	runner := daemon.NewSessionRunner(st, adapters, logger)
	defer func() { _ = runner.Close(context.Background()) }()
	loop := daemon.NewRelayLoop(st, &daemon.RelayClient{BaseURL: relayBase, AccessToken: accessToken}, runner, encoder, logger)
	loop.DaemonVersion = "agent-sessions-daemon-p2"
	loop.Hostname = hostname
	loop.Platform = runtime.GOOS
	if useFixtureAdapter {
		loop.Capabilities = []string{"start", "send", "resume", "abort", "file_read", "git_read"}
	} else {
		loop.Capabilities = []string{"start", "send", "resume", "abort"}
	}
	logger.Info("daemon relay loop starting", "fixture_adapter", useFixtureAdapter, "relay_configured", relayBase != "")
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
	encoder, err := daemon.LoadE2EEEventEncoderFromEnv(getenv)
	if err != nil {
		return nil, nil, err
	}
	if encoder == nil {
		return nil, func() {}, nil
	}
	return encoder, encoder.Destroy, nil
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
