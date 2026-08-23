package main

import (
	"encoding/base64"
	"testing"

	"github.com/yubi233/agent-sessions/internal/adapter"
	"github.com/yubi233/agent-sessions/internal/adapter/codex"
	"github.com/yubi233/agent-sessions/internal/adapter/opencode"
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

// 本地开发明文事件编码器：默认扣留、开关生效、与生产 E2EE 互斥，fixture 优先级最高。
func TestEventEncoderForRunLocalDevPlaintext(t *testing.T) {
	if encoder, _, err := eventEncoderForRun(false, func(string) string { return "" }); err != nil || encoder != nil {
		t.Fatalf("default encoder = %v err=%v, want nil/nil", encoder, err)
	}
	getenv := func(key string) string {
		if key == daemon.LocalDevPlaintextEnv {
			return "1"
		}
		return ""
	}
	encoder, destroy, err := eventEncoderForRun(false, getenv)
	if err != nil {
		t.Fatalf("local dev encoder: %v", err)
	}
	defer destroy()
	if _, ok := encoder.(daemon.LocalDevEventEncoder); !ok {
		t.Fatalf("encoder type = %T, want daemon.LocalDevEventEncoder", encoder)
	}

	conflict := func(key string) string {
		switch key {
		case daemon.LocalDevPlaintextEnv:
			return "1"
		case daemon.EventDEKEnvironment:
			return base64.RawStdEncoding.EncodeToString(make([]byte, 32))
		case daemon.EventKeyIDEnvironment:
			return "dev-key"
		}
		return ""
	}
	if _, _, err := eventEncoderForRun(false, conflict); err == nil {
		t.Fatal("e2ee + local dev plaintext must be rejected")
	}
	fixture, clearFixture, err := eventEncoderForRun(true, conflict)
	if err != nil {
		t.Fatalf("fixture adapter: %v", err)
	}
	defer clearFixture()
	if _, ok := fixture.(daemon.FixtureEventEncoder); !ok {
		t.Fatalf("fixture encoder type = %T", fixture)
	}
}

// Codex 执行侧灰度：feature flag 关闭时不注册 codex adapter；fixture 模式永不注册。
func TestCodexAdapterRegistrationFollowsFeatureFlag(t *testing.T) {
	env := map[string]string{codex.EnvEnabled: "1", codex.EnvBin: ""}
	getenv := func(k string) string { return env[k] }

	adapters := map[string]adapter.Adapter{"opencode": opencode.New()}
	if !useFixtureAdapterForTest() && codex.EnabledFromEnv(getenv) {
		adapters["codex"] = codex.New()
	}
	if _, ok := adapters["codex"]; !ok {
		t.Fatal("flag on: codex adapter should be registered")
	}

	env[codex.EnvEnabled] = ""
	adapters = map[string]adapter.Adapter{"opencode": opencode.New()}
	if codex.EnabledFromEnv(getenv) {
		t.Fatal("unset flag must not enable")
	}
	if _, ok := adapters["codex"]; ok {
		t.Fatal("flag off: codex adapter must stay unregistered")
	}
}

func useFixtureAdapterForTest() bool { return false }
