package config

import "testing"

func TestLoadRelayUsesPrefixedEnvironment(t *testing.T) {
	t.Setenv("AGENT_SESSIONS_RELAY_ADDR", "127.0.0.1:9999")
	t.Setenv("AGENT_SESSIONS_SQLITE_PATH", "./tmp/test.db")
	t.Setenv("AGENT_SESSIONS_LOG_LEVEL", "debug")

	got := LoadRelay()
	if got.Address != "127.0.0.1:9999" || got.DatabasePath != "./tmp/test.db" || got.LogLevel != "debug" {
		t.Fatalf("unexpected config: %#v", got)
	}
}

func TestParseLogLevelRejectsUnknownValue(t *testing.T) {
	if _, err := ParseLogLevel("verbose"); err == nil {
		t.Fatal("expected invalid log level error")
	}
}
