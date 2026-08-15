// Package main 是 PC Daemon 的 CLI 入口：status/project/session/doctor/run/runner。
// 真实 Provider、service 安装与 keyring 属于平台/发布 gate，此处提供本地可验证子集。
package main

import (
	"context"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
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
		// mock terminal 前台运行，连接 Relay。
		return cmdRun(st)
	case "runner":
		// 本地 outbox -> Adapter 兑现演示（Relay 连接未实现，不假装已连）。
		return cmdRunner(st)
	case "doctor-path":
		// 校验指定工作区路径安全。
		return cmdDoctorPath(fs.Arg(0))
	default:
		return fmt.Errorf("unknown command %q (支持 status/doctor/run/runner)", sub)
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

func cmdRun(st *daemon.Store) error {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo}))
	logger.Info("daemon run starting (mock)")
	// mock terminal 心跳：每 5s 汇报在线（真实 WS 在 P2 完整接入）。
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()
	<-ctx.Done()
	_ = ticker
	return nil
}

// cmdRunner 把 outbox 中 pending 的 Relay 命令兑现到 OpenCode Adapter（ADPT-OPENCODE-06）。
// 对应项目文档 docs/zh/项目文档.md 的「PC Daemon」：启动/恢复/停止本地 Session Instance，
// 统一为 canonical event stream。
// Relay 连接尚未实现（cmdRun 只是 mock 心跳），因此本命令只做「读取 outbox 并消费」
// 的本地演示：消费成功的标记 delivered，失败的保持 pending 等待重试，不假装已连 Relay。
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
