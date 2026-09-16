package dsh

import (
	"context"
	"strings"
	"testing"

	"github.com/yubi233/agent-sessions/internal/adapter"
)

// isClosed 并发安全地返回假桥是否已关闭（Dispose 回收断言用）。
func (f *fakeBridge) isClosed() bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.closed
}

// respondInitializeAgentInfo 是版本门专用脚本：initialize 按 protocolVersion=1
// 返回指定 agentInfo（其余 method 不应答，门通过前不应出现任何后续请求）。
func respondInitializeAgentInfo(t *testing.T, name, version string) func(fb *fakeBridge, msg map[string]any) {
	t.Helper()
	return func(fb *fakeBridge, msg map[string]any) {
		if methodOf(msg) != "initialize" {
			return
		}
		fb.push(t, map[string]any{
			"jsonrpc": "2.0", "id": frameID(msg),
			"result": map[string]any{
				"protocolVersion": 1,
				"agentInfo":       map[string]any{"name": name, "version": version},
				"_meta":           map[string]any{"com.deepseek.dsh/model-catalog": fakeACPModelCatalog()},
			},
		})
	}
}

// assertFailClosedMatrix 断言 fail-closed 矩阵：Version 留空、全 unsupported、原因含指定子串。
func assertFailClosedMatrix(t *testing.T, caps adapter.Capabilities, reasonContains string) {
	t.Helper()
	if caps.Provider != "dsh" || caps.Version != "" {
		t.Fatalf("版本门未通过时 Version 必须留空: %#v", caps)
	}
	for _, c := range caps.Capabilities {
		if c.Status != adapter.CapabilityUnsupported {
			t.Fatalf("%s status=%q：版本门未通过必须全 unsupported", c.Name, c.Status)
		}
		if !strings.Contains(c.Reason, reasonContains) {
			t.Fatalf("%s 原因 %q 必须包含 %q", c.Name, c.Reason, reasonContains)
		}
	}
}

// (a) protocolVersion=1 但版本越界（9.9.9）→ Detect 全 unsupported、中文原因含版本、Version 留空。
func TestDetectBridgeVersionOutOfAllowlistFailClosed(t *testing.T) {
	fb := newFakeBridge()
	fb.script = respondInitializeAgentInfo(t, verifiedBridgeName, "9.9.9")
	a := NewWithTransport(func() (BridgeTransport, error) { return fb, nil })
	caps, err := a.Detect(context.Background())
	if err != nil {
		t.Fatalf("Detect: %v", err)
	}
	assertFailClosedMatrix(t, caps, "9.9.9")
}

// (b) 桥名不匹配 → 同样 fail-closed，原因点名桥名。
func TestDetectBridgeNameMismatchFailClosed(t *testing.T) {
	fb := newFakeBridge()
	fb.script = respondInitializeAgentInfo(t, "other-bridge", "0.0.1")
	a := NewWithTransport(func() (BridgeTransport, error) { return fb, nil })
	caps, err := a.Detect(context.Background())
	if err != nil {
		t.Fatalf("Detect: %v", err)
	}
	assertFailClosedMatrix(t, caps, "other-bridge")
}

// (c) 版本门未通过的握手不写回：last-good 快照保持不变。
func TestStoreHandshakeGateKeepsLastGoodSnapshot(t *testing.T) {
	good := initializeResult{ProtocolVersion: 1}
	good.AgentInfo.Name = verifiedBridgeName
	good.AgentInfo.Version = "0.0.1"
	bad := initializeResult{ProtocolVersion: 1}
	bad.AgentInfo.Name = verifiedBridgeName
	bad.AgentInfo.Version = "9.9.9"

	a := NewWithTransport(func() (BridgeTransport, error) { return newFakeBridge(), nil })
	a.storeHandshake(good)
	a.storeHandshake(bad)

	if a.version != "0.0.1" {
		t.Fatalf("坏握手不得覆盖 last-good 版本: got %q", a.version)
	}
	caps := a.Capabilities()
	if caps.Version != "0.0.1" {
		t.Fatalf("能力矩阵应保持 last-good Version: got %q", caps.Version)
	}
	for _, c := range caps.Capabilities {
		if c.Name == "start" && c.Status != adapter.CapabilityNative {
			t.Fatalf("start 应保持 native，got %q（%s）", c.Status, c.Reason)
		}
	}
}

// (d) Start 遇未登记版本：拒绝建会话、错误含版本、子进程已回收、无 session/new。
func TestStartRejectsUnregisteredBridgeVersion(t *testing.T) {
	fb := newFakeBridge()
	fb.script = respondInitializeAgentInfo(t, verifiedBridgeName, "9.9.9")
	a := NewWithTransport(func() (BridgeTransport, error) { return fb, nil })
	h, err := a.Start(context.Background(), adapter.StartRequest{WorkspaceRoot: "/tmp/dsh-ws"})
	if err == nil {
		t.Fatal("未登记版本必须拒绝 Start")
	}
	if h != nil {
		t.Fatal("拒绝时不得返回 handle")
	}
	if !strings.Contains(err.Error(), "9.9.9") {
		t.Fatalf("错误应含版本值: %v", err)
	}
	if !fb.isClosed() {
		t.Fatal("拒绝路径必须回收子进程")
	}
	if frames := framesByMethod(fb.written(), "session/new"); len(frames) != 0 {
		t.Fatalf("门未通过不得发出 session/new: %v", frames)
	}
}

// (e) Resume 遇未登记版本：同口径拒绝并回收。
func TestResumeRejectsUnregisteredBridgeVersion(t *testing.T) {
	fb := newFakeBridge()
	fb.script = respondInitializeAgentInfo(t, verifiedBridgeName, "9.9.9")
	a := NewWithTransport(func() (BridgeTransport, error) { return fb, nil })
	result, err := a.Resume(context.Background(), adapter.ResumeRequest{InstanceID: "sess-1", WorkspaceRoot: "/tmp/dsh-ws"})
	if err == nil {
		t.Fatal("未登记版本必须拒绝 Resume")
	}
	if result != (adapter.ResumeResult{}) {
		t.Fatalf("失败路径应返回零值 ResumeResult: %#v", result)
	}
	if !fb.isClosed() {
		t.Fatal("拒绝路径必须回收子进程")
	}
}

// (f) 环境变量白名单覆盖：登记 0.2.0 后放行，Version 如实写回。
func TestAllowedVersionsEnvOverride(t *testing.T) {
	t.Setenv(EnvAllowedVersions, "0.0.1, 0.2.0")
	fb := newFakeBridge()
	fb.script = respondInitializeAgentInfo(t, verifiedBridgeName, "0.2.0")
	a := NewWithTransport(func() (BridgeTransport, error) { return fb, nil })
	caps, err := a.Detect(context.Background())
	if err != nil {
		t.Fatalf("Detect: %v", err)
	}
	if caps.Version != "0.2.0" {
		t.Fatalf("白名单内版本应放行并写回 Version: got %q", caps.Version)
	}
	for _, c := range caps.Capabilities {
		if c.Name == "start" && c.Status != adapter.CapabilityNative {
			t.Fatalf("start 应为 native，got %q（%s）", c.Status, c.Reason)
		}
	}
}

// (g) 白名单解析语义：未设置→默认；显式置空→报错；空白项过滤；仅分隔符→报错。
func TestVerifiedBridgeVersionsEnv(t *testing.T) {
	if versions, err := verifiedBridgeVersions(); err != nil || len(versions) != 1 || versions[0] != "0.0.1" {
		t.Fatalf("未设置时应返回内置默认: %v, %v", versions, err)
	}
	t.Setenv(EnvAllowedVersions, "   ")
	if _, err := verifiedBridgeVersions(); err == nil {
		t.Fatal("显式置空必须报错")
	}
	t.Setenv(EnvAllowedVersions, "0.0.1,, 0.2.0,")
	versions, err := verifiedBridgeVersions()
	if err != nil || len(versions) != 2 || versions[0] != "0.0.1" || versions[1] != "0.2.0" {
		t.Fatalf("空白项应被过滤: %v, %v", versions, err)
	}
	t.Setenv(EnvAllowedVersions, ",, ,")
	if _, err := verifiedBridgeVersions(); err == nil {
		t.Fatal("仅分隔符必须报错")
	}
}
