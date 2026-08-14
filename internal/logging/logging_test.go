package logging

import (
	"bytes"
	"log/slog"
	"strings"
	"testing"
)

func TestNewRedactsSensitiveFields(t *testing.T) {
	var buffer bytes.Buffer
	New(&buffer, slog.LevelInfo).Info("command accepted", "access_token", "secret-token", "ciphertext", "private-content", "trace_id", "trace-1")
	output := buffer.String()
	if strings.Contains(output, "secret-token") || strings.Contains(output, "private-content") {
		t.Fatalf("sensitive content leaked: %s", output)
	}
	if !strings.Contains(output, "trace-1") || !strings.Contains(output, "[REDACTED]") {
		t.Fatalf("expected allowed metadata and redaction: %s", output)
	}
}
