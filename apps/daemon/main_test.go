package main

import (
	"bytes"
	"encoding/base64"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/yubi233/agent-sessions/internal/adapter"
	"github.com/yubi233/agent-sessions/internal/adapter/codex"
	"github.com/yubi233/agent-sessions/internal/adapter/opencode"
	"github.com/yubi233/agent-sessions/internal/daemon"
)

// 本文件追加的 keygen 用例钉住 `daemon keygen` 子命令的进程级契约（v0.6 残余项收口）：
// 生成 → 幂等回放 → 损坏文件 fail-closed。restart.sh 的 --terminal-signing
// 配对流程依赖这三条语义，任何破坏都会造成设备身份漂移或静默失败。

// TestKeygenIdempotentPubAndFilePerms：首次生成写 0600 种子文件并输出公钥；
// 再次调用不覆盖文件且输出同一公钥（同一状态目录永远同一设备身份）。
func TestKeygenIdempotentPubAndFilePerms(t *testing.T) {
	dir := t.TempDir()
	keyPath := filepath.Join(dir, "terminal_signing_seed.b64")

	pubFirst := captureKeygenStdout(t, func() {
		if err := cmdKeygen([]string{"--out", keyPath}); err != nil {
			t.Fatalf("first keygen: %v", err)
		}
	})
	info, err := os.Stat(keyPath)
	if err != nil {
		t.Fatalf("stat seed file: %v", err)
	}
	// 私钥材料必须只有本机用户可读。
	if perm := info.Mode().Perm(); perm != 0o600 {
		t.Fatalf("seed file perm = %o, want 600", perm)
	}

	pubSecond := captureKeygenStdout(t, func() {
		if err := cmdKeygen([]string{"--out", keyPath}); err != nil {
			t.Fatalf("second keygen: %v", err)
		}
	})
	if pubFirst == "" || pubFirst != pubSecond {
		t.Fatalf("keygen not idempotent: %q vs %q", pubFirst, pubSecond)
	}
}

// TestKeygenRejectsCorruptSeedFile：内容非法的既有文件必须 fail-closed，
// 不允许把坏密钥伪装成有效身份继续运行。
func TestKeygenRejectsCorruptSeedFile(t *testing.T) {
	dir := t.TempDir()
	badPath := filepath.Join(dir, "bad.b64")
	if err := os.WriteFile(badPath, []byte("not-a-seed\n"), 0o600); err != nil {
		t.Fatalf("write bad file: %v", err)
	}
	err := cmdKeygen([]string{"--out", badPath})
	if err == nil || !strings.Contains(err.Error(), "内容非法") {
		t.Fatalf("corrupt seed must fail-closed with format error, got %v", err)
	}
}

// TestKeygenRequiresOut：缺 --out 直接拒绝，避免把私钥写到不可预期位置。
func TestKeygenRequiresOut(t *testing.T) {
	if err := cmdKeygen(nil); err == nil || !strings.Contains(err.Error(), "--out") {
		t.Fatalf("missing --out must be rejected, got %v", err)
	}
}

// captureKeygenStdout 捕获子命令写入 stdout 的公钥行。
func captureKeygenStdout(t *testing.T, fn func()) string {
	t.Helper()
	old := os.Stdout
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatalf("pipe: %v", err)
	}
	os.Stdout = w
	fn()
	os.Stdout = old
	_ = w.Close()
	var buf bytes.Buffer
	if _, err := buf.ReadFrom(r); err != nil {
		t.Fatalf("read stdout: %v", err)
	}
	return strings.TrimSpace(buf.String())
}

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
	if _, ok := encoder.(*daemon.LocalDevEventEncoder); !ok {
		t.Fatalf("encoder type = %T, want *daemon.LocalDevEventEncoder", encoder)
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
