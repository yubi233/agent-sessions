package main

import (
	"encoding/base64"
	"testing"

	"github.com/yubi233/agent-sessions/internal/daemon"
)

// P2-C：生产 run 与 fixture run 的 encoder 选择必须隔离，fixture 不得触碰生产环境中的 DEK。
func TestEventEncoderForRunSeparatesFixtureAndProduction(t *testing.T) {
	dek := make([]byte, 32)
	for i := range dek {
		dek[i] = byte(i + 1)
	}
	validEnv := map[string]string{
		daemon.EventDEKEnvironment:   base64.RawStdEncoding.EncodeToString(dek),
		daemon.EventKeyIDEnvironment: "event-key-main-test",
	}

	fixture, clearFixture, err := eventEncoderForRun(true, func(string) string { return "not-valid-base64" })
	if err != nil {
		t.Fatalf("fixture encoder: %v", err)
	}
	defer clearFixture()
	if _, ok := fixture.(daemon.FixtureEventEncoder); !ok {
		t.Fatalf("fixture encoder = %T, want daemon.FixtureEventEncoder", fixture)
	}

	production, clearProduction, err := eventEncoderForRun(false, func(key string) string { return validEnv[key] })
	if err != nil {
		t.Fatalf("production encoder: %v", err)
	}
	defer clearProduction()
	if _, ok := production.(*daemon.E2EEEventEncoder); !ok {
		t.Fatalf("production encoder = %T, want *daemon.E2EEEventEncoder", production)
	}

	if _, _, err := eventEncoderForRun(false, func(key string) string {
		if key == daemon.EventDEKEnvironment {
			return validEnv[key]
		}
		return ""
	}); err == nil {
		t.Fatal("生产半配置必须拒绝启动")
	}
}
