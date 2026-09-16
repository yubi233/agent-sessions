package daemon

// V092-02 P0 复现矩阵（v0.9.2 §4「P0 实测归因」）：把云端实测到的
// "手机发送 DSH 消息 → Provider 当前不可用 / local_state_missing" 故障链
// 拆成四个可重复的 fixture 场景，逐层钉死归属，供 T2 裁决取证。
//
// 本文件只做归因复现（diagnostic），不修改产品行为；四个场景与 §1.2 的
// L1..L4 一一对应：
//   a) 新会话：start → Provider 实例建立 → send 成功（基线可用）；
//   b) Daemon 重启：store 映射在、内存句柄无 → send fail-closed；
//      resume 可原样恢复同一 instance（G3/C3 契约的事实基础）；
//   c) 桥异常退出：事件流关闭 → send 的可见终态；恢复必须先 resume；
//   d) 版本门拒绝：桥版本越界时 runner 得到显式错误，不伪造成会话建立。
//
// 对应项目文档 docs/zh/项目文档.md「PC Daemon」与「统一能力模型」章节。
// 结论回填：docs/zh/实施记录/32-*.md、docs/test/31-v092-*.json。

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"strings"
	"sync"
	"testing"

	"github.com/yubi233/agent-sessions/internal/adapter"
)

// v092RestartRunner 模拟 "Daemon 进程重启"：复用同一 store（映射持久化在 SQLite），
// 但构造全新的 SessionRunner（内存 handles 为空）。返回新 runner 与同一 fake adapter。
// 旧 runner 必须显式 Close，避免旧事件泵继续写入 store 污染观测。
func v092RestartRunner(t *testing.T, s *Store, provider string, ad adapter.Adapter) *SessionRunner {
	t.Helper()
	restarted := NewSessionRunner(s, map[string]adapter.Adapter{provider: ad},
		slog.New(slog.NewTextHandler(io.Discard, nil)))
	t.Cleanup(func() { _ = restarted.Close(context.Background()) })
	return restarted
}

// v092ReadMapping 读取并解析本地 instance 映射（诊断断言共用）。
func v092ReadMapping(t *testing.T, s *Store, sessionID string) providerThread {
	t.Helper()
	raw, err := s.Get(instanceKey(sessionID))
	if err != nil {
		t.Fatalf("instance 映射缺失（session=%s）: %v", sessionID, err)
	}
	var th providerThread
	if err := json.Unmarshal([]byte(raw), &th); err != nil {
		t.Fatalf("instance 映射损坏: %v", err)
	}
	return th
}

// v092RecordEvents 记录同一 runner 上的 canonical 事件类型序列（失败可见性断言用）。
func v092RecordEvents(runner *SessionRunner) func() []adapter.EventType {
	var mu sync.Mutex
	var seq []adapter.EventType
	runner.SetEventSink(func(_ string, event adapter.Event) {
		mu.Lock()
		defer mu.Unlock()
		seq = append(seq, event.Type)
	})
	return func() []adapter.EventType {
		mu.Lock()
		defer mu.Unlock()
		return append([]adapter.EventType(nil), seq...)
	}
}

// (a) 新会话基线：start 建立 Provider 实例并持久化映射，随后 send 直接可用。
// 该场景证明"Daemon 不会自动创建会话"以外的正常链路在 fixture 层成立，
// 与 §1.3「已排除的误判」一致——不需要新增自动创建逻辑。
func TestV092AttribNewSessionBaseline(t *testing.T) {
	s, runner, fake := newRunnerFixture(t, "dsh")
	record := v092RecordEvents(runner)

	if err := runner.ConsumeCommand(context.Background(), Command{
		Kind: "session.start",
		PayloadJSON: `{"session_id":"v092-new","workspace_root":"/tmp/v092-ws",` +
			`"provider":"dsh","ciphertext":{"fixture_payload":{"prompt":"你好"}}}`,
	}); err != nil {
		t.Fatalf("session.start: %v", err)
	}

	mapping := v092ReadMapping(t, s, "v092-new")
	if mapping.Provider != "dsh" || mapping.InstanceID != "instance-1" || mapping.WorkspaceRoot != "/tmp/v092-ws" {
		t.Fatalf("新会话映射不正确: %+v", mapping)
	}
	if err := runner.ConsumeCommand(context.Background(), Command{
		Kind:        "session.send",
		PayloadJSON: `{"session_id":"v092-new","ciphertext":{"fixture_payload":{"message":"继续"}}}`,
	}); err != nil {
		t.Fatalf("新会话 send 必须成功: %v", err)
	}
	handle := v092LastHandle(t, fake)
	if sends := handle.sendSnapshot(); len(sends) != 1 || sends[0] != "继续" {
		t.Fatalf("Provider Send 调用 = %v, want [继续]", sends)
	}
	// 正常路径不得出现失败终态（避免把基线误判为故障）。
	for _, typ := range record() {
		if typ == adapter.EventSessionError {
			t.Fatalf("新会话正常路径不得出现 session_error: %v", record())
		}
	}
}

// (b) Daemon 重启归因：store 里的 instance 映射仍在，但内存句柄丢失。
// 这正是云端 2026-09-16 07:40 日志 `local_state_missing: session instance 不存在` 的
// 本机可复现形态（L2）。同时证明 C3/T3 语义：
//   - send 在无句柄时 fail-closed（ErrSessionInstanceMissing）且失败可见；
//   - resume 使用**原 instance id** 恢复（不新建实例）。
//
// 该场景也是"移动端发送前自动恢复必须走 resume 而不是 start"的判据：
// start 会创建 instance-2，历史与原实例丢失。
func TestV092AttribRestartResumePreservesInstance(t *testing.T) {
	s, runner, fake := newRunnerFixture(t, "dsh")
	if err := runner.ConsumeCommand(context.Background(), Command{
		Kind: "session.start",
		PayloadJSON: `{"session_id":"v092-restart","workspace_root":"/tmp/v092-ws",` +
			`"provider":"dsh","ciphertext":{"fixture_payload":{"prompt":"第一问"}}}`,
	}); err != nil {
		t.Fatalf("session.start: %v", err)
	}
	before := v092ReadMapping(t, s, "v092-restart")
	if before.InstanceID != "instance-1" {
		t.Fatalf("起始 instance = %q, want instance-1", before.InstanceID)
	}
	// 模拟进程退出：释放旧 runner 的内存句柄（store 保留）。
	if err := runner.Close(context.Background()); err != nil {
		t.Fatalf("close 旧 runner: %v", err)
	}

	restarted := v092RestartRunner(t, s, "dsh", fake)
	record := v092RecordEvents(restarted)

	// b1) 重启后直接 send：无运行句柄，必须 fail-closed 且失败可见。
	err := restarted.ConsumeCommand(context.Background(), Command{
		Kind:        "session.send",
		PayloadJSON: `{"session_id":"v092-restart","ciphertext":{"fixture_payload":{"message":"重启后直接发"}}}`,
	})
	if !errors.Is(err, ErrSessionInstanceMissing) {
		t.Fatalf("重启后 send 错误 = %v, want ErrSessionInstanceMissing", err)
	}
	if _, err := s.Get(resumeResultKey("v092-restart")); err == nil {
		t.Fatal("失败的 send 不得写入 resume 成功结果")
	}
	wantVisible := []adapter.EventType{
		adapter.EventUserMessage, adapter.EventSessionError, adapter.EventTurnCompleted,
	}
	if got := record(); len(got) != len(wantVisible) {
		t.Fatalf("重启后 send 事件 = %v, want %v", got, wantVisible)
	} else {
		for i, typ := range wantVisible {
			if got[i] != typ {
				t.Fatalf("重启后 send 事件 = %v, want %v", got, wantVisible)
			}
		}
	}

	// b2) 非流式 adapter 的 resume 契约（V092-07/G4 证据）：即使 adapter 自报
	// resumed，只要没交出本机可运行句柄，runner 也必须 fail-closed，绝不伪造可用实例。
	// v0.9.2 P2：该形态与"映射不存在"统一归入 ErrSessionInstanceMissing，
	// 客户端才能稳定区分"需要重建本机实例"与真实执行失败。
	if err := restarted.ConsumeCommand(context.Background(), Command{
		Kind:        "session.resume",
		PayloadJSON: `{"session_id":"v092-restart","workspace_root":"/tmp/v092-ws"}`,
	}); err == nil {
		t.Fatal("非流式 adapter 无句柄时必须 fail-closed（不得伪造 resumed）")
	} else if !errors.Is(err, ErrSessionInstanceMissing) {
		t.Fatalf("无可用句柄必须归入 local_state_missing 语义: %v", err)
	} else if !strings.Contains(err.Error(), "没有可用句柄") {
		t.Fatalf("错误应保留可诊断原因: %v", err)
	}
	if _, getErr := s.Get(resumeResultKey("v092-restart")); getErr == nil {
		t.Fatal("失败恢复不得写入成功唤醒结果")
	}

	// b3) 流式 adapter（DSH 的真实形态：ResumeStreaming 交出句柄）恢复原 instance。
	streamFake := newStreamingFakeAdapter("dsh")
	if err := restarted.Close(context.Background()); err != nil {
		t.Fatalf("close 非流式 runner: %v", err)
	}
	// 注册的必须是流式适配器本身（*streamingFakeAdapter 实现 ResumeStreamingAdapter），
	// 只注册内嵌的 *fakeAdapter 会退回非流式分支。
	streamRunner := v092RestartRunner(t, s, "dsh", streamFake)
	if err := streamRunner.ConsumeCommand(context.Background(), Command{
		Kind:        "session.resume",
		PayloadJSON: `{"session_id":"v092-restart","workspace_root":"/tmp/v092-ws"}`,
	}); err != nil {
		t.Fatalf("流式 session.resume: %v", err)
	}
	streamFake.mu.Lock()
	resumes := append([]adapter.ResumeRequest(nil), streamFake.resumes...)
	startsAfter := len(streamFake.starts)
	streamFake.mu.Unlock()
	if len(resumes) != 1 {
		t.Fatalf("adapter.Resume 调用 = %d, want 1", len(resumes))
	}
	if resumes[0].InstanceID != "instance-1" {
		t.Fatalf("resume instance = %q, want 原 instance-1（不得新建）", resumes[0].InstanceID)
	}
	if startsAfter != 0 {
		t.Fatalf("resume 不得触发 adapter.Start（starts=%d）", startsAfter)
	}
	// 映射保持原 instance（恢复不重写为其它 id）。
	if after := v092ReadMapping(t, s, "v092-restart"); after.InstanceID != "instance-1" {
		t.Fatalf("resume 后 instance = %q, want instance-1", after.InstanceID)
	}

	// b4) 恢复后 send 立即可用（闭环）。
	if err := streamRunner.ConsumeCommand(context.Background(), Command{
		Kind:        "session.send",
		PayloadJSON: `{"session_id":"v092-restart","ciphertext":{"fixture_payload":{"message":"恢复后发送"}}}`,
	}); err != nil {
		t.Fatalf("恢复后 send 必须成功: %v", err)
	}

	// b5) 对照：若移动端误用 start 重建，则会产生新 Provider 实例并覆盖映射
	//（历史断链）。该分支正是本计划把移动端"发送前自动恢复"从 start 改为 resume
	// 的直接理由（G3/C3/T3）。对照使用独立 adapter，避免与前面实例计数器串味。
	startFake := newStreamingFakeAdapter("dsh")
	// 预占一个实例序号，让对照分支产出可区分的新实例 id（否则与首次 start 的
	// "instance-1" 同名，无法区分"映射被覆盖"与"未被触碰"）。
	startFake.starts = append(startFake.starts, adapter.StartRequest{Provider: "dsh"})
	startRunner := v092RestartRunner(t, s, "dsh", startFake)
	if err := startRunner.ConsumeCommand(context.Background(), Command{
		Kind: "session.start",
		PayloadJSON: `{"session_id":"v092-restart","workspace_root":"/tmp/v092-ws",` +
			`"provider":"dsh","ciphertext":{"fixture_payload":{"prompt":"误用 start"}}}`,
	}); err != nil {
		t.Fatalf("对照 start: %v", err)
	}
	startFake.mu.Lock()
	startCount := len(startFake.starts)
	startFake.mu.Unlock()
	if startCount != 2 {
		t.Fatalf("对照分支必须真实调用 adapter.Start（含预占共 2 次），starts=%d", startCount)
	}
	if got := v092ReadMapping(t, s, "v092-restart").InstanceID; got == "instance-1" {
		t.Fatalf("start 重建应覆盖为新的 Provider 实例（断链证据），got %q", got)
	}
}

// (c) 桥异常退出归因：Provider 事件流关闭（桥进程消失）后，句柄仍在内存，
// send 会走到 handle.Send；fixture 用 sendErr 模拟"桥已不可写"。
// 断言失败被补发为可见终态（user_message → session_error → turn_completed），
// 客户端不会永久停留在"生成中"；恢复仍需显式 resume。
func TestV092AttribBridgeExitVisibleFailure(t *testing.T) {
	s, runner, fake := newRunnerFixture(t, "dsh")
	if err := runner.ConsumeCommand(context.Background(), Command{
		Kind: "session.start",
		PayloadJSON: `{"session_id":"v092-bridge","workspace_root":"/tmp/v092-ws",` +
			`"provider":"dsh","ciphertext":{"fixture_payload":{"prompt":"启动"}}}`,
	}); err != nil {
		t.Fatalf("session.start: %v", err)
	}
	handle := v092LastHandle(t, fake)
	// 模拟桥进程异常退出：让后续 Send 直接失败（broken pipe 语义）。
	handle.injectSendError(errors.New("bridge exited: broken pipe"))
	record := v092RecordEvents(runner)

	err := runner.ConsumeCommand(context.Background(), Command{
		Kind:        "session.send",
		PayloadJSON: `{"session_id":"v092-bridge","ciphertext":{"fixture_payload":{"message":"桥已退出"}}}`,
	})
	if err == nil {
		t.Fatal("桥退出后 send 必须失败")
	}
	got := record()
	// 句柄自身会先产出 turn_started/message_delta（fixture 事件流）；这里断言的是
	// "失败必须可见"：user_message 之后必须出现 session_error 且以 turn_completed 收口。
	if !v092HasSequence(got, adapter.EventUserMessage, adapter.EventSessionError, adapter.EventTurnCompleted) {
		t.Fatalf("桥退出事件 = %v, want 含 user_message→session_error→turn_completed 可见失败链", got)
	}
	// 终态摘要必须落库（客户端重连后仍能看到失败事实，而不是"生成中"）。
	waitEvent(t, s, "v092-bridge", "turn_completed")
	// 句柄仍登记：send 不会静默改走 resume；用户必须先恢复。
	if _, err := s.Get(instanceKey("v092-bridge")); err != nil {
		t.Fatalf("桥退出不改变本地映射: %v", err)
	}
}

// (d) 版本门拒绝归因：桥版本越界时 Start 返回显式错误（含版本值），
// 不产生 instance 映射、不伪造会话建立。该场景区分"版本门拒绝"与
// "环境/拓扑失败"（计划 §0 版本门不回退）。
func TestV092AttribVersionGateRejectionIsExplicit(t *testing.T) {
	s, runner, fake := newRunnerFixture(t, "dsh")
	fake.mu.Lock()
	fake.startOverride = nil
	fake.startErr = errors.New("桥版本 9.9.9 不在已登记白名单内")
	fake.mu.Unlock()

	err := runner.ConsumeCommand(context.Background(), Command{
		Kind: "session.start",
		PayloadJSON: `{"session_id":"v092-gate","workspace_root":"/tmp/v092-ws",` +
			`"provider":"dsh","ciphertext":{"fixture_payload":{"prompt":"启动"}}}`,
	})
	if err == nil {
		t.Fatal("版本门拒绝必须返回错误")
	}
	if !strings.Contains(err.Error(), "9.9.9") {
		t.Fatalf("错误必须点明版本值: %v", err)
	}
	if _, getErr := s.Get(instanceKey("v092-gate")); getErr == nil {
		t.Fatal("版本门拒绝不得写入 instance 映射")
	}
	if _, getErr := s.Get(eventKey("v092-gate")); getErr == nil {
		t.Fatal("版本门拒绝不得留下事件摘要")
	}
}

// v092LastHandle 返回最近创建的 fake handle。调用方不得持 fake.mu——
// lastHandle() 自身会加锁（P0 矩阵首轮曾因持锁调用导致测试自死锁 600s 超时）。
func v092LastHandle(t *testing.T, fake *fakeAdapter) *fakeHandle {
	t.Helper()
	h := fake.lastHandle()
	if h == nil {
		t.Fatal("fake adapter 尚未创建 handle")
	}
	return h
}

// sendSnapshot 并发安全地读取 Provider Send 调用序列。
func (h *fakeHandle) sendSnapshot() []string {
	h.mu.Lock()
	defer h.mu.Unlock()
	return append([]string(nil), h.sends...)
}

// injectSendError 并发安全地注入 Send 失败（模拟桥进程已退出）。
func (h *fakeHandle) injectSendError(err error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.sendErr = err
}

// newStreamingFakeAdapter 构造 DSH 真实形态的流式 fake adapter（ResumeStreaming 交出句柄）。
// 非流式 fakeAdapter 无法把 runtime handle 交给 runner，只能验证 fail-closed 分支。
func newStreamingFakeAdapter(provider string) *streamingFakeAdapter {
	return &streamingFakeAdapter{fakeAdapter: newFakeAdapter(provider)}
}

// v092HasSequence 判断 want 是否为 got 的子序列（允许句柄自身事件前缀/穿插）。
func v092HasSequence(got []adapter.EventType, want ...adapter.EventType) bool {
	idx := 0
	for _, typ := range got {
		if idx < len(want) && typ == want[idx] {
			idx++
		}
	}
	return idx == len(want)
}

// wasDisposedNow 并发安全地读取 Dispose 是否被调用（重复 start 回收语义的观测点）。
func (h *fakeHandle) wasDisposedNow() bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.disposed
}
