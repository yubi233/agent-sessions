package main

import (
	"flag"
	"log/slog"
	"os"

	"github.com/gin-gonic/gin"
	"github.com/yubi233/agent-sessions/internal/config"
	"github.com/yubi233/agent-sessions/internal/logging"
	"github.com/yubi233/agent-sessions/internal/relay"
	"github.com/yubi233/agent-sessions/internal/store"
)

func main() {
	settings := config.LoadRelay()
	address := flag.String("addr", settings.Address, "Relay listen address")
	databasePath := flag.String("db", settings.DatabasePath, "SQLite database path")
	flag.Parse()
	level, err := config.ParseLogLevel(settings.LogLevel)
	if err != nil {
		slog.Error("invalid relay configuration", "error", err)
		os.Exit(2)
	}
	// Terminal 签名窗口进度必须显式合法：未知值在启动时失败，不允许静默回退 bearer。
	signatureMode, err := config.ParseTerminalSignatureMode(settings.TerminalSignatureMode)
	if err != nil {
		slog.Error("invalid relay configuration", "error", err)
		os.Exit(2)
	}
	logger := logging.New(os.Stderr, level)

	// 启动前打开并迁移 SQLite；失败时进程直接退出，避免提供未就绪的 Relay。
	db, err := store.Open(*databasePath)
	if err != nil {
		logger.Error("open relay store failed", "error", err)
		os.Exit(1)
	}
	defer db.Close()

	logger.Info("relay listening", "address", *address, "database", *databasePath,
		"terminal_signature_mode", signatureMode)
	var engine *gin.Engine
	if signatureMode == config.TerminalSignatureModeRequired {
		engine = relay.NewServerWithTerminalSignatureRequired(db, logger)
	} else {
		engine = relay.NewServer(db, logger)
	}
	if err := engine.Run(*address); err != nil {
		logger.Error("relay stopped", "error", err)
		os.Exit(1)
	}
}
