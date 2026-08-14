package logging

import (
	"io"
	"log/slog"
	"strings"
)

// New 创建 JSON 日志器，并按字段名在输出边界脱敏机密和密文数据。
func New(writer io.Writer, level slog.Level) *slog.Logger {
	handler := slog.NewJSONHandler(writer, &slog.HandlerOptions{
		Level: level,
		ReplaceAttr: func(_ []string, attribute slog.Attr) slog.Attr {
			if isSensitive(attribute.Key) {
				return slog.String(attribute.Key, "[REDACTED]")
			}
			return attribute
		},
	})
	return slog.New(handler)
}

func isSensitive(key string) bool {
	key = strings.ToLower(key)
	for _, needle := range []string{"token", "secret", "password", "private_key", "ciphertext", "plaintext"} {
		if strings.Contains(key, needle) {
			return true
		}
	}
	return false
}
