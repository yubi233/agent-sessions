package config

import (
	"fmt"
	"log/slog"
	"os"
)

// RelayConfig 只承载 Relay 启动所需的非敏感配置；令牌和私钥不允许通过此结构写入日志。
type RelayConfig struct {
	Address      string
	DatabasePath string
	LogLevel     string
}

// LoadRelay 读取带统一前缀的环境变量，为本地开发提供安全默认值。
func LoadRelay() RelayConfig {
	return RelayConfig{
		Address:      envOrDefault("AGENT_SESSIONS_RELAY_ADDR", "127.0.0.1:8787"),
		DatabasePath: envOrDefault("AGENT_SESSIONS_SQLITE_PATH", "./data/relay.db"),
		LogLevel:     envOrDefault("AGENT_SESSIONS_LOG_LEVEL", "info"),
	}
}

// ParseLogLevel 把配置文本转换为 slog 级别；未知值必须在启动时失败而非静默降级。
func ParseLogLevel(value string) (slog.Level, error) {
	var level slog.Level
	if err := level.UnmarshalText([]byte(value)); err != nil {
		return 0, fmt.Errorf("invalid log level %q: %w", value, err)
	}
	return level, nil
}

func envOrDefault(name, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return fallback
}
