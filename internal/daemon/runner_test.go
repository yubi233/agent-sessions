package daemon

// ADPT-OPENCODE-06 回归：runner 把 Relay 命令兑现到 Adapter handle。
// 本测试使用记录调用的 fake adapter（fixture，不代表真实 Provider 成功），
// 证明 runner 调用 Adapter Start/Send/Abort/Resume 而非只写 outbox；
// 真实 opencode transport 的 fixture contract 由 internal/adapter/opencode 包内测试覆盖，
// 授权 live gate 由 ADPT-OPENCODE-05（task test:real）覆盖，本测试不做跨包 fixture。
// 对应项目文档 docs/zh/项目文档.md 的「PC Daemon」与「统一能力模型」章节。

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/yubi233/agent-sessions/internal/adapter"
)

// fakeAdapter 记录 Start/Resume 调用与参数（fixture）。
type fakeAdapter struct {
	mu            sync.Mutex
	provider      string
	starts        []adapter.StartRequest
	resumes       []adapter.ResumeRequest
	resumeResult  adapter.ResumeResult
	startOverride adapter.Handle // 注入异常 handle（如事件流已关闭）
	handles       []*fakeHandle
}

func newFakeAdapter(provider string) *fakeAdapter {
	return &fakeAdapter{
		provider:     provider,
		resumeResult: adapter.ResumeResult{Result: adapter.WakeResumed},
	}
}

func (f *fakeAdapter) Detect(ctx context.Context) (adapter.Capabilities, error) {
	return adapter.Capabilities{Provider: f.provider}, nil
}

func (f *fakeAdapter) Capabilities() adapter.Capabilities {
	caps, _ := f.Detect(context.Background())
	return caps
}

func (f *fakeAdapter) Start(ctx context.Context, req adapter.StartRequest) (adapter.Handle, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.starts = append(f.starts, req)
	if f.startOverride != nil {
		return f.startOverride, nil
	}
	h := newFakeHandle(fmt.Sprintf("instance-%d", len(f.starts)))
	f.handles = append(f.handles, h)
	return h, nil
}

func (f *fakeAdapter) Resume(ctx context.Context, req adapter.ResumeRequest) (adapter.ResumeResult, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.resumes = append(f.resumes, req)
	res := f.resumeResult
	if res.InstanceID == "" {
		res.InstanceID = req.InstanceID
	}
	return res, nil
}

func (f *fakeAdapter) lastHandle() *fakeHandle {
	f.mu.Lock()
	defer f.mu.Unlock()
	if len(f.handles) == 0 {
		return nil
	}
	return f.handles[len(f.handles)-1]
}

// fakeHandle 记录 Send/Abort 调用并流式产生 fixture 事件。
type fakeHandle struct {
	mu     sync.Mutex
	id     string
	sends  []string
	aborts int
	events chan adapter.Event
	done   chan struct{}
}

func newFakeHandle(id string) *fakeHandle {
	h := &fakeHandle{id: id, events: make(chan adapter.Event, 16), done: make(chan struct{})}
	// fixture：首个事件是 turn_started 并携带 instance_id，随后是 message_delta。
	go func() {
		defer close(h.events)
		h.emit(adapter.Event{Type: adapter.EventTurnStarted, Seq: 1,
			Payload: map[string]any{"instance_id": id}})
		h.emit(adapter.Event{Type: adapter.EventMessageDelta, Seq: 2,
			Payload: map[string]any{"text": "fixture delta"}})
		<-h.done
	}()
	return h
}

func (h *fakeHandle) emit(ev adapter.Event) {
	select {
	case h.events <- ev:
	case <-h.done:
	}
}

func (h *fakeHandle) Send(ctx context.Context, text string) error {
	h.mu.Lock()
	h.sends = append(h.sends, text)
	h.mu.Unlock()
	h.emit(adapter.Event{Type: adapter.EventMessageDelta, Seq: 3,
		Payload: map[string]any{"text": text}})
	return nil
}

func (h *fakeHandle) Abort(ctx context.Context) error {
	h.mu.Lock()
	h.aborts++
	h.mu.Unlock()
	return nil
}

func (h *fakeHandle) Events() <-chan adapter.Event { return h.events }

func (h *fakeHandle) Dispose(ctx context.Context) error {
	select {
	case <-h.done:
	default:
		close(h.done)
	}
	return nil
}

// forceKillFakeHandle 只在 Runner 回归中表示 Daemon 明确拥有的受控进程树。真实 HTTP Adapter
// 不实现 ForceKill，因此此 fixture 用于验证 session.kill 不会退化为 Abort。
type forceKillFakeHandle struct {
	*fakeHandle
	forceKills   int
	forceKillErr error
}

func (h *forceKillFakeHandle) ForceKill(ctx context.Context) error {
	h.mu.Lock()
	h.forceKills++
	err := h.forceKillErr
	h.mu.Unlock()
	if err != nil {
		return err
	}
	return h.Dispose(ctx)
}

// newRunnerFixture 构造 store + fake adapter 的 runner 测试环境。
func newRunnerFixture(t *testing.T, provider string) (*Store, *SessionRunner, *fakeAdapter) {
	t.Helper()
	s, err := OpenStore(filepath.Join(t.TempDir(), "daemon.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	t.Cleanup(func() { _ = s.Close() })
	fake := newFakeAdapter(provider)
	runner := NewSessionRunner(s, map[string]adapter.Adapter{provider: fake},
		slog.New(slog.NewTextHandler(io.Discard, nil)))
	t.Cleanup(func() { _ = runner.Close(context.Background()) })
	return s, runner, fake
}

// waitEvent 轮询 local_state，直到事件转发 goroutine 写入 last_event。
func waitEvent(t *testing.T, s *Store, sessionID, want string) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for {
		v, err := s.Get(eventKey(sessionID))
		if err == nil && strings.Contains(v, want) {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("等待事件回写超时: last_event=%q err=%v", v, err)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// a) session.start：adapter.Start 被调用、instance 映射持久化到 store、事件回写。
func TestSessionRunnerStartPersistsInstanceMapping(t *testing.T) {
	s, runner, fake := newRunnerFixture(t, "opencode")
	cmd := Command{
		Kind: "session.start",
		PayloadJSON: `{"session_id":"s1","workspace_root":"/tmp/ws","provider":"opencode",` +
			`"model":"deepseek","effort":"high","plan_mode":true,` +
			`"ciphertext":{"fixture_payload":{"prompt":"开始"}}}`,
	}
	if err := runner.ConsumeCommand(context.Background(), cmd); err != nil {
		t.Fatalf("consume session.start: %v", err)
	}

	fake.mu.Lock()
	starts := append([]adapter.StartRequest(nil), fake.starts...)
	fake.mu.Unlock()
	if len(starts) != 1 {
		t.Fatalf("adapter.Start calls = %d, want 1", len(starts))
	}
	req := starts[0]
	if req.WorkspaceRoot != "/tmp/ws" || req.Provider != "opencode" ||
		req.Model != "deepseek" || req.Effort != "high" ||
		!req.PlanMode || req.Prompt != "开始" {
		t.Fatalf("adapter.Start request = %+v", req)
	}

	raw, err := s.Get(instanceKey("s1"))
	if err != nil {
		t.Fatalf("instance 映射未持久化: %v", err)
	}
	var th providerThread
	if err := json.Unmarshal([]byte(raw), &th); err != nil {
		t.Fatalf("instance 映射 JSON: %v", err)
	}
	if th.Provider != "opencode" || th.InstanceID != "instance-1" {
		t.Fatalf("instance 映射 = %+v", th)
	}
	// 事件转发 goroutine 已把 canonical 事件写回 store（证明调用了 Adapter Handle 而非只写 outbox）。
	waitEvent(t, s, "s1", "message_delta")
}

// b) session.send：fixture payload 的 message 被转发给 handle.Send。
func TestSessionRunnerSendForwardsFixtureMessage(t *testing.T) {
	_, runner, fake := newRunnerFixture(t, "opencode")
	if err := runner.ConsumeCommand(context.Background(), Command{
		Kind:        "session.start",
		PayloadJSON: `{"session_id":"s1","workspace_root":"/tmp/ws","provider":"opencode"}`,
	}); err != nil {
		t.Fatalf("start: %v", err)
	}
	cmd := Command{
		Kind:        "session.send",
		PayloadJSON: `{"session_id":"s1","ciphertext":{"fixture_payload":{"message":"继续"}}}`,
	}
	if err := runner.ConsumeCommand(context.Background(), cmd); err != nil {
		t.Fatalf("consume session.send: %v", err)
	}
	h := fake.lastHandle()
	if h == nil {
		t.Fatalf("handle 不存在")
	}
	h.mu.Lock()
	sends := append([]string(nil), h.sends...)
	h.mu.Unlock()
	if len(sends) != 1 || sends[0] != "继续" {
		t.Fatalf("handle.Send got %v, want [继续]", sends)
	}
}

// c) session.abort：handle.Abort 被调用。
func TestSessionRunnerAbortCallsHandle(t *testing.T) {
	_, runner, fake := newRunnerFixture(t, "opencode")
	if err := runner.ConsumeCommand(context.Background(), Command{
		Kind:        "session.start",
		PayloadJSON: `{"session_id":"s1","workspace_root":"/tmp/ws","provider":"opencode"}`,
	}); err != nil {
		t.Fatalf("start: %v", err)
	}
	if err := runner.ConsumeCommand(context.Background(), Command{
		Kind:        "session.abort",
		PayloadJSON: `{"session_id":"s1"}`,
	}); err != nil {
		t.Fatalf("consume session.abort: %v", err)
	}
	h := fake.lastHandle()
	h.mu.Lock()
	aborts := h.aborts
	h.mu.Unlock()
	if aborts != 1 {
		t.Fatalf("handle.Abort calls = %d, want 1", aborts)
	}
}

// session.kill 只能触发明确拥有本机进程树的 ForceKill，并会删除本地 instance 映射；它绝不
// 借用 Abort 伪造强制终止成功。
func TestSessionRunnerKillUsesOwnedProcessHandle(t *testing.T) {
	s, runner, fake := newRunnerFixture(t, "opencode")
	owned := &forceKillFakeHandle{fakeHandle: newFakeHandle("instance-owned")}
	fake.mu.Lock()
	fake.startOverride = owned
	fake.mu.Unlock()
	if err := runner.ConsumeCommand(context.Background(), Command{
		Kind: "session.start", PayloadJSON: `{"session_id":"s1","workspace_root":"/tmp/ws","provider":"opencode"}`,
	}); err != nil {
		t.Fatalf("start: %v", err)
	}
	if err := runner.ConsumeCommand(context.Background(), Command{
		Kind: "session.kill", PayloadJSON: `{"session_id":"s1"}`,
	}); err != nil {
		t.Fatalf("kill: %v", err)
	}
	owned.mu.Lock()
	forceKills, aborts := owned.forceKills, owned.aborts
	owned.mu.Unlock()
	if forceKills != 1 || aborts != 0 {
		t.Fatalf("forceKills/aborts=%d/%d, want 1/0", forceKills, aborts)
	}
	if _, err := s.Get(instanceKey("s1")); err == nil {
		t.Fatal("killed session must remove instance mapping")
	}
	if _, err := runner.lookupSession("s1"); !errors.Is(err, ErrSessionInstanceMissing) {
		t.Fatalf("killed session must remove handle, err=%v", err)
	}
}

// 远端/共享服务 Handle 没有可证明的本机进程所有权时，session.kill 必须 fail-closed，且不得
// 调用 Abort 或 Dispose 来伪造成功。
func TestSessionRunnerKillWithoutOwnedProcessFailsClosed(t *testing.T) {
	s, runner, fake := newRunnerFixture(t, "opencode")
	if err := runner.ConsumeCommand(context.Background(), Command{
		Kind: "session.start", PayloadJSON: `{"session_id":"s1","workspace_root":"/tmp/ws","provider":"opencode"}`,
	}); err != nil {
		t.Fatalf("start: %v", err)
	}
	err := runner.ConsumeCommand(context.Background(), Command{Kind: "session.kill", PayloadJSON: `{"session_id":"s1"}`})
	if !errors.Is(err, ErrUnsupportedCommand) {
		t.Fatalf("kill error=%v, want ErrUnsupportedCommand", err)
	}
	h := fake.lastHandle()
	h.mu.Lock()
	aborts := h.aborts
	h.mu.Unlock()
	if aborts != 0 {
		t.Fatalf("unsupported kill called Abort %d times", aborts)
	}
	if _, err := s.Get(instanceKey("s1")); err != nil {
		t.Fatalf("unsupported kill must retain instance mapping: %v", err)
	}
}

// d) session.resume：adapter.Resume 被调用，结果写入 store、在六态之内且不是伪造。
func TestSessionRunnerResumeWritesAdapterResult(t *testing.T) {
	s, runner, fake := newRunnerFixture(t, "opencode")
	if err := runner.ConsumeCommand(context.Background(), Command{
		Kind:        "session.start",
		PayloadJSON: `{"session_id":"s1","workspace_root":"/tmp/ws","provider":"opencode"}`,
	}); err != nil {
		t.Fatalf("start: %v", err)
	}
	// 注入非 resumed 结果，证明 runner 原样记录 adapter 结果，而不是硬编码成功。
	fake.mu.Lock()
	fake.resumeResult = adapter.ResumeResult{Result: adapter.WakeRestartedWithContext}
	fake.mu.Unlock()

	cmd := Command{
		Kind:        "session.resume",
		PayloadJSON: `{"session_id":"s1","workspace_root":"/tmp/ws"}`,
	}
	if err := runner.ConsumeCommand(context.Background(), cmd); err != nil {
		t.Fatalf("consume session.resume: %v", err)
	}

	fake.mu.Lock()
	resumes := append([]adapter.ResumeRequest(nil), fake.resumes...)
	fake.mu.Unlock()
	if len(resumes) != 1 {
		t.Fatalf("adapter.Resume calls = %d, want 1", len(resumes))
	}
	if resumes[0].InstanceID != "instance-1" || resumes[0].WorkspaceRoot != "/tmp/ws" {
		t.Fatalf("adapter.Resume request = %+v", resumes[0])
	}

	raw, err := s.Get(resumeResultKey("s1"))
	if err != nil {
		t.Fatalf("resume 结果未写入 store: %v", err)
	}
	var res adapter.ResumeResult
	if err := json.Unmarshal([]byte(raw), &res); err != nil {
		t.Fatalf("resume 结果 JSON: %v", err)
	}
	if res.Result != adapter.WakeRestartedWithContext {
		t.Fatalf("resume 结果 = %q, want adapter 原样返回 %q", res.Result, adapter.WakeRestartedWithContext)
	}
	if !validWakeResult(res.Result) {
		t.Fatalf("resume 结果 %q 不在六态之内", res.Result)
	}
}

// e) 未实现 kind（permission.approve）返回 ErrUnsupportedCommand，且不产生成功状态。
func TestSessionRunnerUnsupportedKindFailsClosed(t *testing.T) {
	s, runner, _ := newRunnerFixture(t, "opencode")
	err := runner.ConsumeCommand(context.Background(), Command{
		Kind:        "permission.approve",
		PayloadJSON: `{"session_id":"s1","ciphertext":{"fixture_payload":{"request_id":"permission-1"}}}`,
	})
	if !errors.Is(err, ErrUnsupportedCommand) {
		t.Fatalf("err = %v, want ErrUnsupportedCommand", err)
	}
	if _, err := s.Get(instanceKey("s1")); err == nil {
		t.Fatalf("unsupported kind 不得写 instance 映射")
	}
	if _, err := s.Get(resumeResultKey("s1")); err == nil {
		t.Fatalf("unsupported kind 不得写 resume 结果")
	}
}

// f) 无实例的 session.send 返回错误（local_state_missing 语义），fail-closed。
func TestSessionRunnerSendWithoutInstanceFailsClosed(t *testing.T) {
	_, runner, fake := newRunnerFixture(t, "opencode")
	err := runner.ConsumeCommand(context.Background(), Command{
		Kind:        "session.send",
		PayloadJSON: `{"session_id":"ghost","ciphertext":{"fixture_payload":{"message":"hi"}}}`,
	})
	if !errors.Is(err, ErrSessionInstanceMissing) {
		t.Fatalf("err = %v, want ErrSessionInstanceMissing", err)
	}
	fake.mu.Lock()
	defer fake.mu.Unlock()
	if len(fake.handles) != 0 {
		t.Fatalf("无实例时不得创建 handle")
	}
}

// 真实密文 envelope（无 fixture_payload）不可解时保持 fail-closed。
func TestSessionRunnerUndecryptableEnvelopeFailsClosed(t *testing.T) {
	s, runner, _ := newRunnerFixture(t, "opencode")
	if err := runner.ConsumeCommand(context.Background(), Command{
		Kind:        "session.start",
		PayloadJSON: `{"session_id":"s1","workspace_root":"/tmp/ws","provider":"opencode"}`,
	}); err != nil {
		t.Fatalf("start: %v", err)
	}
	// 只有真实密文字段，没有 fixture_payload：不可解。
	err := runner.ConsumeCommand(context.Background(), Command{
		Kind:        "session.send",
		PayloadJSON: `{"session_id":"s1","ciphertext":{"ciphertext":"opaque","nonce":"n"}}`,
	})
	if err == nil {
		t.Fatalf("密文不可解必须失败")
	}
	if _, err := s.Get(resumeResultKey("s1")); err == nil {
		t.Fatalf("失败命令不得写成功状态")
	}
}

// resume 无 instance 映射时 fail-closed（local_state_missing 语义）。
func TestSessionRunnerResumeWithoutInstanceFailsClosed(t *testing.T) {
	_, runner, _ := newRunnerFixture(t, "opencode")
	err := runner.ConsumeCommand(context.Background(), Command{
		Kind:        "session.resume",
		PayloadJSON: `{"session_id":"ghost"}`,
	})
	if !errors.Is(err, ErrSessionInstanceMissing) {
		t.Fatalf("err = %v, want ErrSessionInstanceMissing", err)
	}
}

// session.start 的 provider 未注册 adapter 时 fail-closed。
func TestSessionRunnerStartUnknownProviderFailsClosed(t *testing.T) {
	_, runner, _ := newRunnerFixture(t, "opencode")
	err := runner.ConsumeCommand(context.Background(), Command{
		Kind:        "session.start",
		PayloadJSON: `{"session_id":"s1","workspace_root":"/tmp/ws","provider":"claude"}`,
	})
	if err == nil {
		t.Fatalf("未注册 provider 必须失败")
	}
}

// 启动失败（handle 事件流无 turn_started）时回滚句柄登记并保持 fail-closed。
func TestSessionRunnerStartWithoutTurnStartedFailsClosed(t *testing.T) {
	_, runner, fake := newRunnerFixture(t, "opencode")
	// 注入事件流已立即关闭的 handle：awaitFirstEvent 走「事件流提前关闭」路径，避免超时等待。
	closed := make(chan adapter.Event)
	close(closed)
	fake.mu.Lock()
	fake.startOverride = &fakeHandle{id: "instance-x", events: closed, done: make(chan struct{})}
	fake.mu.Unlock()

	err := runner.ConsumeCommand(context.Background(), Command{
		Kind:        "session.start",
		PayloadJSON: `{"session_id":"s1","workspace_root":"/tmp/ws","provider":"opencode"}`,
	})
	if err == nil {
		t.Fatalf("无 turn_started 事件必须启动失败")
	}
	// 启动失败后 handle 不得留在登记表：send 必须 fail-closed。
	if _, err := runner.lookupSession("s1"); !errors.Is(err, ErrSessionInstanceMissing) {
		t.Fatalf("启动失败后登记表应回滚, err = %v", err)
	}
}
