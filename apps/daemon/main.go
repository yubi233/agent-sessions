// Package main 是 PC Daemon 的 CLI 入口：status/project/session/doctor/run。
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
	case "doctor-path":
		// 校验指定工作区路径安全。
		return cmdDoctorPath(fs.Arg(0))
	default:
		return fmt.Errorf("unknown command %q (支持 status/doctor/run)", sub)
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
