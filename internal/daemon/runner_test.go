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
	// models 记录 SetModel 的调用序列；空值覆盖不产生记录。
	models []string
	// efforts 记录 SetEffort 的调用序列；空值覆盖不产生记录。
	efforts []string
	// sendErr/abortErr 注入传输层同步失败；失败时不得产生任何 Provider 事件。
	sendErr  error
	abortErr error
	// disposed 标记 Dispose 是否被调用（重复 start 回收语义的观测点）。
	disposed bool
	events   chan adapter.Event
	done     chan struct{}
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

// SetModel 实现 adapter.ModelOverrideHandle，记录运行期模型覆盖序列。
func (h *fakeHandle) SetModel(model string) {
	if strings.TrimSpace(model) == "" {
		return
	}
	h.mu.Lock()
	h.models = append(h.models, model)
	h.mu.Unlock()
}

// SetEffort 实现 adapter.EffortOverrideHandle，记录运行期推理档位覆盖序列。
func (h *fakeHandle) SetEffort(effort string) {
	if strings.TrimSpace(effort) == "" {
		return
	}
	h.mu.Lock()
	h.efforts = append(h.efforts, effort)
	h.mu.Unlock()
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
	err := h.sendErr
	h.mu.Unlock()
	if err != nil {
		return err
	}
	h.emit(adapter.Event{Type: adapter.EventMessageDelta, Seq: 3,
		Payload: map[string]any{"text": text}})
	return nil
}

func (h *fakeHandle) Abort(ctx context.Context) error {
	h.mu.Lock()
	h.aborts++
	err := h.abortErr
	h.mu.Unlock()
	return err
}

func (h *fakeHandle) Events() <-chan adapter.Event { return h.events }

func (h *fakeHandle) Dispose(ctx context.Context) error {
	h.mu.Lock()
	h.disposed = true
	h.mu.Unlock()
	select {
	case <-h.done:
	default:
		close(h.done)
	}
	return nil
}

// wasDisposed 返回 Dispose 是否已被调用（并发安全）。
func (h *fakeHandle) wasDisposed() bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.disposed
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

// P2-C：本机重启诊断只保留 canonical event 的类型、序号与计数。Provider 正文即使尚未来得及
// 加密上传，也不能通过 local_state:last_event 旁路写入 SQLite。
func TestSessionRunnerLastEventMetadataNeverPersistsPayload(t *testing.T) {
	s, runner, fake := newRunnerFixture(t, "opencode")
	if err := runner.ConsumeCommand(context.Background(), Command{
		Kind: "session.start", PayloadJSON: `{"session_id":"s1","workspace_root":"/tmp/ws","provider":"opencode"}`,
	}); err != nil {
		t.Fatalf("start: %v", err)
	}
	const secret = "provider-body-must-not-persist-in-local-state"
	h := fake.lastHandle()
	if h == nil {
		t.Fatal("missing fixture handle")
	}
	h.emit(adapter.Event{Type: adapter.EventMessageDelta, Seq: 99, Payload: map[string]any{"text": secret}})
	waitEvent(t, s, "s1", `"seq":99`)

	raw, err := s.Get(eventKey("s1"))
	if err != nil {
		t.Fatalf("read event summary: %v", err)
	}
	if strings.Contains(raw, secret) {
		t.Fatalf("last_event leaked provider body: %s", raw)
	}
	var summary lastEvent
	if err := json.Unmarshal([]byte(raw), &summary); err != nil {
		t.Fatalf("decode event summary: %v", err)
	}
	if summary.Type != adapter.EventMessageDelta || summary.Seq != 99 || summary.Count < 1 {
		t.Fatalf("event summary=%+v", summary)
	}
	var persisted int
	if err := s.db.QueryRow(`SELECT COUNT(*) FROM local_state WHERE value LIKE ?`, "%"+secret+"%").Scan(&persisted); err != nil {
		t.Fatal(err)
	}
	if persisted != 0 {
		t.Fatal("provider body is present in daemon local_state")
	}
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

// 存量库可能通过 model_select 持久化了会话模型；send 密文不带模型时必须应用它，
// 绝不能把空模型交给 opencode 服务端回退到它的配置默认（可能命中付费条目）。
func TestSessionRunnerSendAppliesStoredSessionModel(t *testing.T) {
	store, runner, fake := newRunnerFixture(t, "opencode")
	if err := store.Set("model:s1", "opencode/big-pickle"); err != nil {
		t.Fatalf("seed session model: %v", err)
	}
	if err := runner.ConsumeCommand(context.Background(), Command{
		Kind:        "session.start",
		PayloadJSON: `{"session_id":"s1","workspace_root":"/tmp/ws","provider":"opencode"}`,
	}); err != nil {
		t.Fatalf("start: %v", err)
	}
	h := fake.lastHandle()
	if err := runner.ConsumeCommand(context.Background(), Command{
		Kind:        "session.send",
		PayloadJSON: `{"session_id":"s1","ciphertext":{"fixture_payload":{"message":"继续"}}}`,
	}); err != nil {
		t.Fatalf("consume session.send: %v", err)
	}
	h.mu.Lock()
	models := append([]string(nil), h.models...)
	h.mu.Unlock()
	if len(models) != 1 || models[0] != "opencode/big-pickle" {
		t.Fatalf("SetModel got %v, want [opencode/big-pickle]", models)
	}

	// send 密文随行模型优先于持久化选择。
	if err := runner.ConsumeCommand(context.Background(), Command{
		Kind:        "session.send",
		PayloadJSON: `{"session_id":"s1","ciphertext":{"fixture_payload":{"message":"再试","model":"opencode/hy3-free"}}}`,
	}); err != nil {
		t.Fatalf("consume session.send: %v", err)
	}
	h.mu.Lock()
	models = append([]string(nil), h.models...)
	h.mu.Unlock()
	if len(models) != 2 || models[1] != "opencode/hy3-free" {
		t.Fatalf("SetModel got %v, want 末次为 opencode/hy3-free", models)
	}
}

// runner-generated user_message events share the Provider event sequence. They
// must be positive for production E2EE and must not collide with the next
// Provider event emitted by the handle.
func TestSessionRunnerUserMessageSequenceIsCanonical(t *testing.T) {
	s, runner, _ := newRunnerFixture(t, "opencode")
	observed := make(chan adapter.Event, 32)
	userSummary := make(chan lastEvent, 1)
	runner.SetEventSink(func(sessionID string, event adapter.Event) {
		if sessionID == "s-user-seq" {
			observed <- event
			if event.Type == adapter.EventUserMessage {
				if raw, err := s.Get(eventKey(sessionID)); err == nil {
					var summary lastEvent
					if json.Unmarshal([]byte(raw), &summary) == nil {
						userSummary <- summary
					}
				}
			}
		}
	})
	if err := runner.ConsumeCommand(context.Background(), Command{
		Kind:        "session.start",
		PayloadJSON: "{\"session_id\":\"s-user-seq\",\"workspace_root\":\"/tmp/ws\",\"provider\":\"opencode\"}",
	}); err != nil {
		t.Fatalf("start: %v", err)
	}
	// Wait until the first Provider delta has been forwarded so the allocator's
	// current sequence is deterministic before sending the user message.
	var providerSeq int64
	deadline := time.After(2 * time.Second)
	for providerSeq == 0 {
		select {
		case event := <-observed:
			if event.Type == adapter.EventMessageDelta {
				providerSeq = event.Seq
			}
		case <-deadline:
			t.Fatal("timeout waiting for provider event")
		}
	}
	if providerSeq <= 0 {
		t.Fatalf("provider sequence=%d, want positive", providerSeq)
	}
	if err := runner.ConsumeCommand(context.Background(), Command{
		Kind:        "session.send",
		PayloadJSON: "{\"session_id\":\"s-user-seq\",\"ciphertext\":{\"fixture_payload\":{\"message\":\"用户输入\"}}}",
	}); err != nil {
		t.Fatalf("send: %v", err)
	}
	var userEvent adapter.Event
	deadline = time.After(2 * time.Second)
	for userEvent.Type == "" {
		select {
		case event := <-observed:
			if event.Type == adapter.EventUserMessage {
				userEvent = event
			}
		case <-deadline:
			t.Fatal("timeout waiting for user_message event")
		}
	}
	if userEvent.Seq != providerSeq+1 {
		t.Fatalf("user_message seq=%d, provider seq=%d; want next canonical sequence", userEvent.Seq, providerSeq)
	}
	encoder, err := NewE2EEEventEncoder(testEventDEK(), "runner-user-message-sequence")
	if err != nil {
		t.Fatalf("event encoder: %v", err)
	}
	defer encoder.Destroy()
	if _, err := encoder.Encode("s-user-seq", userEvent); err != nil {
		t.Fatalf("user_message seq=%d rejected by production encoder: %v", userEvent.Seq, err)
	}
	select {
	case summary := <-userSummary:
		if summary.Type != adapter.EventUserMessage || summary.Seq != userEvent.Seq || summary.Count < 1 {
			t.Fatalf("last_event=%+v, want user_message seq=%d with cumulative count", summary, userEvent.Seq)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timeout waiting for durable user_message summary")
	}
}

// The canonical sequence and count must survive a daemon restart. A provider
// that restarts its own sequence at one must still be folded after the durable
// local summary rather than reusing an earlier AAD sequence.
func TestSessionRunnerEventSequenceResumesFromDurableSummary(t *testing.T) {
	s, runner, _ := newRunnerFixture(t, "opencode")
	runner.recordEvent("s-restart", adapter.Event{Type: adapter.EventMessageCompleted, Seq: 17})
	if err := runner.Close(context.Background()); err != nil {
		t.Fatalf("close first runner: %v", err)
	}

	runner2 := NewSessionRunner(s, map[string]adapter.Adapter{}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	t.Cleanup(func() { _ = runner2.Close(context.Background()) })
	var got adapter.Event
	runner2.SetEventSink(func(sessionID string, event adapter.Event) {
		if sessionID == "s-restart" {
			got = event
		}
	})
	runner2.recordEvent("s-restart", adapter.Event{Type: adapter.EventTurnCompleted, Seq: 1})
	if got.Seq != 18 {
		t.Fatalf("restarted event seq=%d, want 18", got.Seq)
	}
	var summary lastEvent
	raw, err := s.Get(eventKey("s-restart"))
	if err != nil {
		t.Fatalf("read durable summary: %v", err)
	}
	if err := json.Unmarshal([]byte(raw), &summary); err != nil {
		t.Fatalf("decode durable summary: %v", err)
	}
	if summary.Seq != 18 || summary.Count != 2 || summary.Type != adapter.EventTurnCompleted {
		t.Fatalf("durable summary=%+v, want seq=18 count=2 turn_completed", summary)
	}
}

// Provider forwarding and runner-generated events can arrive concurrently. The
// sink must observe one strict per-session order and the durable count must
// match that order, with no duplicate sequence values.
func TestSessionRunnerConcurrentEventRecordingIsOrdered(t *testing.T) {
	s, runner, _ := newRunnerFixture(t, "opencode")
	const total = 64
	observed := make(chan adapter.Event, total)
	runner.SetEventSink(func(sessionID string, event adapter.Event) {
		if sessionID == "s-concurrent" {
			observed <- event
		}
	})
	var wg sync.WaitGroup
	for i := 0; i < total; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			runner.recordEvent("s-concurrent", adapter.Event{
				Type: adapter.EventMessageDelta,
				Seq:  1 + int64(i%3), // deliberately duplicate/late provider values
			})
		}(i)
	}
	wg.Wait()
	close(observed)
	var previous int64
	count := 0
	for event := range observed {
		if event.Seq <= previous {
			t.Fatalf("non-monotonic sink sequence: previous=%d current=%d", previous, event.Seq)
		}
		previous = event.Seq
		count++
	}
	if count != total {
		t.Fatalf("observed %d events, want %d", count, total)
	}
	var summary lastEvent
	raw, err := s.Get(eventKey("s-concurrent"))
	if err != nil {
		t.Fatalf("read concurrent summary: %v", err)
	}
	if err := json.Unmarshal([]byte(raw), &summary); err != nil {
		t.Fatalf("decode concurrent summary: %v", err)
	}
	if summary.Count != total || summary.Seq != previous {
		t.Fatalf("concurrent summary=%+v, want count=%d seq=%d", summary, total, previous)
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

// Provider 事件流异常关闭时，runner 必须发出脱敏错误和 stopped 终态，
// 否则 Relay/Flutter 会把历史会话永久保留为“生成中”。
func TestSessionRunnerForwardEventsClosesWithStoppedTerminal(t *testing.T) {
	s, runner, _ := newRunnerFixture(t, "opencode")
	closed := make(chan adapter.Event)
	close(closed)
	h := &fakeHandle{id: "instance-crashed", events: closed, done: make(chan struct{})}
	fwdCtx, cancel := context.WithCancel(context.Background())
	defer cancel()

	events := make(chan adapter.Event, 2)
	runner.SetEventSink(func(sessionID string, event adapter.Event) {
		if sessionID == "s-crashed" {
			events <- event
		}
	})
	done := make(chan struct{})
	go func() {
		runner.forwardEvents("s-crashed", h, fwdCtx)
		close(done)
	}()

	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("forwardEvents did not exit after provider stream close")
	}
	if raw, err := s.Get(eventKey("s-crashed")); err != nil || !strings.Contains(raw, string(adapter.EventTurnCompleted)) {
		t.Fatalf("last_event=%q err=%v, want stopped terminal", raw, err)
	}
	first := <-events
	second := <-events
	if first.Type != adapter.EventSessionError || first.Payload["instance_id"] != "s-crashed" {
		t.Fatalf("first synthetic event=%+v, want redacted session_error", first)
	}
	if first.Seq != 1 {
		t.Fatalf("first synthetic seq=%d, want 1 for an empty provider stream", first.Seq)
	}
	if second.Type != adapter.EventTurnCompleted || second.Payload["instance_id"] != "s-crashed" || second.Payload["stop_reason"] != "stopped" {
		t.Fatalf("second synthetic event=%+v, want stopped turn_completed", second)
	}
	if second.Seq != 2 || second.Seq <= first.Seq {
		t.Fatalf("second synthetic seq=%d, first=%d; want monotonic 2", second.Seq, first.Seq)
	}
}

// Synthetic recovery events must continue after the highest provider sequence,
// including when the first turn_started event is supplied through forwardEvents' initial argument.
func TestSessionRunnerForwardEventsSyntheticSequenceFollowsProvider(t *testing.T) {
	_, runner, _ := newRunnerFixture(t, "opencode")
	closed := make(chan adapter.Event)
	close(closed)
	h := &fakeHandle{id: "instance-sequence", events: closed, done: make(chan struct{})}
	fwdCtx, cancel := context.WithCancel(context.Background())
	defer cancel()
	var got []adapter.Event
	runner.SetEventSink(func(sessionID string, event adapter.Event) {
		if sessionID == "s-sequence" {
			got = append(got, event)
		}
	})
	// The initial event is the path used by session.start when the adapter emits
	// turn_started before the forwarding goroutine is launched.
	runner.forwardEvents("s-sequence", h, fwdCtx, adapter.Event{
		Type: adapter.EventTurnStarted, Seq: 41,
		Payload: map[string]any{"instance_id": "s-sequence"},
	})
	if len(got) != 3 {
		t.Fatalf("events=%+v, want initial + two synthetic terminals", got)
	}
	if got[0].Seq != 41 || got[1].Seq != 42 || got[2].Seq != 43 {
		t.Fatalf("sequence=%d,%d,%d, want 41,42,43", got[0].Seq, got[1].Seq, got[2].Seq)
	}
	if got[1].Type != adapter.EventSessionError || got[2].Type != adapter.EventTurnCompleted {
		t.Fatalf("synthetic events=%+v, want session_error then turn_completed", got[1:])
	}
	encoder, err := NewE2EEEventEncoder(testEventDEK(), "runner-sequence-test")
	if err != nil {
		t.Fatalf("event encoder: %v", err)
	}
	defer encoder.Destroy()
	for _, event := range got[1:] {
		if _, err := encoder.Encode("s-sequence", event); err != nil {
			t.Fatalf("synthetic event seq=%d rejected by production encoder: %v", event.Seq, err)
		}
	}
}

// Intentional runner cancellation (Close/kill) must not manufacture an
// abnormal stopped event after the caller has explicitly ended forwarding.
func TestSessionRunnerForwardEventsCancellationSuppressesSyntheticTerminal(t *testing.T) {
	s, runner, _ := newRunnerFixture(t, "opencode")
	closed := make(chan adapter.Event)
	close(closed)
	h := &fakeHandle{id: "instance-cancelled", events: closed, done: make(chan struct{})}
	fwdCtx, cancel := context.WithCancel(context.Background())
	cancel()
	events := make(chan adapter.Event, 1)
	runner.SetEventSink(func(sessionID string, event adapter.Event) { events <- event })
	runner.forwardEvents("s-cancelled", h, fwdCtx)
	if _, err := s.Get(eventKey("s-cancelled")); err == nil {
		t.Fatal("cancelled forwarding must not write a synthetic terminal event")
	}
	select {
	case event := <-events:
		t.Fatalf("cancelled forwarding emitted event=%+v", event)
	default:
	}
}

// A provider terminal event already closes the turn; an ensuing stream EOF
// must not append a duplicate stopped marker.
func TestSessionRunnerForwardEventsDoesNotDuplicateTerminalOnClose(t *testing.T) {
	s, runner, _ := newRunnerFixture(t, "opencode")
	closed := make(chan adapter.Event, 1)
	closed <- adapter.Event{Type: adapter.EventTurnCompleted, Seq: 7, Payload: map[string]any{
		"instance_id": "s-completed", "stop_reason": "session_idle",
	}}
	close(closed)
	h := &fakeHandle{id: "instance-completed", events: closed, done: make(chan struct{})}
	fwdCtx, cancel := context.WithCancel(context.Background())
	defer cancel()
	var got []adapter.Event
	runner.SetEventSink(func(sessionID string, event adapter.Event) { got = append(got, event) })
	runner.forwardEvents("s-completed", h, fwdCtx)
	if len(got) != 1 || got[0].Type != adapter.EventTurnCompleted || got[0].Payload["stop_reason"] != "session_idle" {
		t.Fatalf("events=%+v, want only provider terminal", got)
	}
	raw, err := s.Get(eventKey("s-completed"))
	if err != nil || strings.Contains(raw, "stopped") {
		t.Fatalf("last_event=%q err=%v, must not append stopped terminal", raw, err)
	}
}

// readSinkEvent 等待事件出口的下一条事件。
func readSinkEvent(t *testing.T, events <-chan adapter.Event) adapter.Event {
	t.Helper()
	select {
	case event := <-events:
		return event
	case <-time.After(2 * time.Second):
		t.Fatal("timeout waiting for sink event")
		return adapter.Event{}
	}
}

// ---- DCM-01：session.model_select 持久化与 fail-closed ----

// 合法的 model_select 持久化到 model:<session_id>；密文缺省时顶层 model 字段兜底，
// 覆盖写生效，且后续 send 不带随行模型时应用最近一次持久化选择。
func TestSessionRunnerModelSelectPersistsChoice(t *testing.T) {
	store, runner, fake := newRunnerFixture(t, "opencode")
	if err := runner.ConsumeCommand(context.Background(), Command{
		Kind:        "session.start",
		PayloadJSON: `{"session_id":"s1","workspace_root":"/tmp/ws","provider":"opencode"}`,
	}); err != nil {
		t.Fatalf("start: %v", err)
	}
	if err := runner.ConsumeCommand(context.Background(), Command{
		Kind:        "session.model_select",
		PayloadJSON: `{"session_id":"s1","ciphertext":{"fixture_payload":{"model":"opencode/hy3-free"}}}`,
	}); err != nil {
		t.Fatalf("consume session.model_select: %v", err)
	}
	if got, err := store.Get("model:s1"); err != nil || got != "opencode/hy3-free" {
		t.Fatalf("model:s1 = %q err=%v, want opencode/hy3-free", got, err)
	}
	if err := runner.ConsumeCommand(context.Background(), Command{
		Kind:        "session.model_select",
		PayloadJSON: `{"session_id":"s1","model":"opencode/big-pickle"}`,
	}); err != nil {
		t.Fatalf("consume session.model_select (top-level): %v", err)
	}
	if got, err := store.Get("model:s1"); err != nil || got != "opencode/big-pickle" {
		t.Fatalf("model:s1 = %q err=%v, want opencode/big-pickle", got, err)
	}
	if err := runner.ConsumeCommand(context.Background(), Command{
		Kind:        "session.send",
		PayloadJSON: `{"session_id":"s1","ciphertext":{"fixture_payload":{"message":"继续"}}}`,
	}); err != nil {
		t.Fatalf("consume session.send: %v", err)
	}
	h := fake.lastHandle()
	h.mu.Lock()
	models := append([]string(nil), h.models...)
	h.mu.Unlock()
	if len(models) != 1 || models[0] != "opencode/big-pickle" {
		t.Fatalf("SetModel got %v, want [opencode/big-pickle]", models)
	}
}

// 非法 model_select 输入必须稳定失败且不改写已持久化的选择。
func TestSessionRunnerModelSelectRejectsInvalidInput(t *testing.T) {
	store, runner, _ := newRunnerFixture(t, "opencode")
	if err := store.Set("model:s1", "keep-original"); err != nil {
		t.Fatalf("seed session model: %v", err)
	}
	cases := []struct {
		name    string
		payload string
	}{
		{"缺少 session_id", `{"model":"opencode/hy3-free"}`},
		{"缺少 model", `{"session_id":"s1"}`},
		{"空 model", `{"session_id":"s1","model":""}`},
		{"空白 model", `{"session_id":"s1","model":"   "}`},
		{"空 fixture model", `{"session_id":"s1","ciphertext":{"fixture_payload":{"model":""}}}`},
		{"envelope 不可解", `{"session_id":"s1",not-json`},
	}
	for _, tc := range cases {
		err := runner.ConsumeCommand(context.Background(), Command{
			Kind: "session.model_select", PayloadJSON: tc.payload,
		})
		if err == nil {
			t.Fatalf("%s: 必须失败", tc.name)
		}
		got, err := store.Get("model:s1")
		if err != nil || got != "keep-original" {
			t.Fatalf("%s: store 被改写为 %q (err=%v)", tc.name, got, err)
		}
	}
}

// ---- DCM-03：重复 session.start 回收旧句柄且不泄漏 ----

// 同一 session_id 重复 start：旧句柄 Dispose 被调用、回收后仍滞留在旧通道的事件
// 不串入时间线、登记表指向新句柄且后续 send 落到新句柄。
func TestSessionRunnerStartReclaimsPreviousHandle(t *testing.T) {
	s, runner, fake := newRunnerFixture(t, "opencode")
	var mu sync.Mutex
	var seen []adapter.Event
	runner.SetEventSink(func(sessionID string, event adapter.Event) {
		if sessionID != "s1" {
			return
		}
		mu.Lock()
		seen = append(seen, event)
		mu.Unlock()
	})

	// 旧句柄用测试完全控制的通道：fixture 句柄的 emit goroutine 会在 Dispose 后
	// 关闭事件通道，无法构造「回收后仍有滞留事件」的窗口。
	evsA := make(chan adapter.Event, 16)
	hA := &fakeHandle{id: "instance-a", events: evsA, done: make(chan struct{})}
	evsA <- adapter.Event{Type: adapter.EventTurnStarted, Seq: 1,
		Payload: map[string]any{"instance_id": "instance-a"}}
	fake.mu.Lock()
	fake.startOverride = hA
	fake.mu.Unlock()
	startCmd := Command{
		Kind:        "session.start",
		PayloadJSON: `{"session_id":"s1","workspace_root":"/tmp/ws","provider":"opencode"}`,
	}
	if err := runner.ConsumeCommand(context.Background(), startCmd); err != nil {
		t.Fatalf("first start: %v", err)
	}

	fake.mu.Lock()
	fake.startOverride = nil
	fake.mu.Unlock()
	if err := runner.ConsumeCommand(context.Background(), startCmd); err != nil {
		t.Fatalf("second start: %v", err)
	}
	if !hA.wasDisposed() {
		t.Fatal("重复 start 必须回收旧句柄（Dispose 未调用）")
	}
	hB := fake.lastHandle()
	if hB == nil || hB == hA {
		t.Fatal("第二次 start 必须产生新句柄")
	}

	// 向已回收的旧通道注入事件：不得进入时间线（canonical 序列不得跳到 99）。
	evsA <- adapter.Event{Type: adapter.EventMessageDelta, Seq: 99,
		Payload: map[string]any{"text": "stale-after-reclaim"}}
	// 新句柄的 fixture 事件接在旧句柄初始 turn_started 之后，canonical 序列为 2、3。
	waitEvent(t, s, "s1", `"seq":3`)
	deadline := time.Now().Add(300 * time.Millisecond)
	for time.Now().Before(deadline) {
		raw, err := s.Get(eventKey("s1"))
		if err != nil {
			t.Fatalf("read last_event: %v", err)
		}
		if strings.Contains(raw, `"seq":99`) {
			t.Fatalf("已回收句柄的事件串入时间线: %s", raw)
		}
		time.Sleep(20 * time.Millisecond)
	}
	mu.Lock()
	for _, event := range seen {
		if text, _ := event.Payload["text"].(string); text == "stale-after-reclaim" {
			mu.Unlock()
			t.Fatal("已回收句柄的事件进入了事件出口")
		}
	}
	mu.Unlock()

	// 新句柄正常收发：send 落到新句柄，旧句柄不得再收到任何调用。
	if err := runner.ConsumeCommand(context.Background(), Command{
		Kind:        "session.send",
		PayloadJSON: `{"session_id":"s1","ciphertext":{"fixture_payload":{"message":"继续"}}}`,
	}); err != nil {
		t.Fatalf("send after reclaim: %v", err)
	}
	if rs, err := runner.lookupSession("s1"); err != nil || rs.handle != adapter.Handle(hB) {
		t.Fatalf("登记句柄应为新句柄, err=%v", err)
	}
	hB.mu.Lock()
	sends := append([]string(nil), hB.sends...)
	hB.mu.Unlock()
	if len(sends) != 1 || sends[0] != "继续" {
		t.Fatalf("new handle sends = %v, want [继续]", sends)
	}
	hA.mu.Lock()
	aSends := len(hA.sends)
	hA.mu.Unlock()
	if aSends != 0 {
		t.Fatalf("旧句柄被再次调用 send %d 次", aSends)
	}
}

// ---- DCM-05：命令全种类收口与失败分类 ----

// abort/kill 对不存在的 session 保持 local_state_missing 语义，错误消息不含 payload 正文。
func TestSessionRunnerAbortAndKillWithoutInstanceFailsClosed(t *testing.T) {
	_, runner, _ := newRunnerFixture(t, "opencode")
	abortErr := runner.ConsumeCommand(context.Background(), Command{
		Kind:        "session.abort",
		PayloadJSON: `{"session_id":"ghost","ciphertext":{"fixture_payload":{"message":"secret-body"}}}`,
	})
	if !errors.Is(abortErr, ErrSessionInstanceMissing) {
		t.Fatalf("abort err = %v, want ErrSessionInstanceMissing", abortErr)
	}
	if strings.Contains(abortErr.Error(), "secret-body") {
		t.Fatalf("abort 错误消息泄漏 payload 正文: %v", abortErr)
	}
	killErr := runner.ConsumeCommand(context.Background(), Command{
		Kind:        "session.kill",
		PayloadJSON: `{"session_id":"ghost"}`,
	})
	if !errors.Is(killErr, ErrSessionInstanceMissing) {
		t.Fatalf("kill err = %v, want ErrSessionInstanceMissing", killErr)
	}
}

// 合法的 effort_select 持久化到 effort:<session_id>；密文缺省时顶层 effort 字段兜底，
// 覆盖写生效，且后续 send 不带随行 effort 时应用最近一次持久化选择。
func TestSessionRunnerEffortSelectPersistsChoice(t *testing.T) {
	store, runner, fake := newRunnerFixture(t, "opencode")
	if err := runner.ConsumeCommand(context.Background(), Command{
		Kind:        "session.start",
		PayloadJSON: `{"session_id":"s1","workspace_root":"/tmp/ws","provider":"opencode"}`,
	}); err != nil {
		t.Fatalf("start: %v", err)
	}
	if err := runner.ConsumeCommand(context.Background(), Command{
		Kind:        "session.effort_select",
		PayloadJSON: `{"session_id":"s1","ciphertext":{"fixture_payload":{"effort":"high"}}}`,
	}); err != nil {
		t.Fatalf("consume session.effort_select: %v", err)
	}
	if got, err := store.Get("effort:s1"); err != nil || got != "high" {
		t.Fatalf("effort:s1 = %q err=%v, want high", got, err)
	}
	if err := runner.ConsumeCommand(context.Background(), Command{
		Kind:        "session.effort_select",
		PayloadJSON: `{"session_id":"s1","effort":"medium"}`,
	}); err != nil {
		t.Fatalf("consume session.effort_select (top-level): %v", err)
	}
	if got, err := store.Get("effort:s1"); err != nil || got != "medium" {
		t.Fatalf("effort:s1 = %q err=%v, want medium", got, err)
	}
	if err := runner.ConsumeCommand(context.Background(), Command{
		Kind:        "session.send",
		PayloadJSON: `{"session_id":"s1","ciphertext":{"fixture_payload":{"message":"继续"}}}`,
	}); err != nil {
		t.Fatalf("consume session.send: %v", err)
	}
	h := fake.lastHandle()
	h.mu.Lock()
	efforts := append([]string(nil), h.efforts...)
	h.mu.Unlock()
	if len(efforts) != 1 || efforts[0] != "medium" {
		t.Fatalf("SetEffort got %v, want [medium]", efforts)
	}
}

// 非法 effort_select 输入必须稳定失败且不改写已持久化的选择。
func TestSessionRunnerEffortSelectRejectsInvalidInput(t *testing.T) {
	store, runner, _ := newRunnerFixture(t, "opencode")
	if err := store.Set("effort:s1", "keep-original"); err != nil {
		t.Fatalf("seed session effort: %v", err)
	}
	cases := []struct {
		name    string
		payload string
	}{
		{"缺少 session_id", `{"effort":"high"}`},
		{"缺少 effort", `{"session_id":"s1"}`},
		{"空 effort", `{"session_id":"s1","effort":""}`},
		{"空白 effort", `{"session_id":"s1","effort":"   "}`},
		{"空 fixture effort", `{"session_id":"s1","ciphertext":{"fixture_payload":{"effort":""}}}`},
		{"envelope 不可解", `{"session_id":"s1",not-json`},
	}
	for _, tc := range cases {
		err := runner.ConsumeCommand(context.Background(), Command{
			Kind: "session.effort_select", PayloadJSON: tc.payload,
		})
		if err == nil {
			t.Fatalf("%s: 必须失败", tc.name)
		}
		got, err := store.Get("effort:s1")
		if err != nil || got != "keep-original" {
			t.Fatalf("%s: store 被改写为 %q (err=%v)", tc.name, got, err)
		}
	}
}

// resume 命中存活实例后，登记句柄不变，后续 send 仍走原句柄可用。
func TestSessionRunnerResumeThenSendRemainsUsable(t *testing.T) {
	s, runner, fake := newRunnerFixture(t, "opencode")
	if err := runner.ConsumeCommand(context.Background(), Command{
		Kind:        "session.start",
		PayloadJSON: `{"session_id":"s1","workspace_root":"/tmp/ws","provider":"opencode"}`,
	}); err != nil {
		t.Fatalf("start: %v", err)
	}
	live := fake.lastHandle()
	if err := runner.ConsumeCommand(context.Background(), Command{
		Kind:        "session.resume",
		PayloadJSON: `{"session_id":"s1","workspace_root":"/tmp/ws"}`,
	}); err != nil {
		t.Fatalf("resume: %v", err)
	}
	raw, err := s.Get(resumeResultKey("s1"))
	if err != nil {
		t.Fatalf("resume 结果未写入 store: %v", err)
	}
	var res adapter.ResumeResult
	if err := json.Unmarshal([]byte(raw), &res); err != nil {
		t.Fatalf("resume 结果 JSON: %v", err)
	}
	if res.Result != adapter.WakeResumed {
		t.Fatalf("resume 结果 = %q, want resumed", res.Result)
	}
	if err := runner.ConsumeCommand(context.Background(), Command{
		Kind:        "session.send",
		PayloadJSON: `{"session_id":"s1","ciphertext":{"fixture_payload":{"message":"继续"}}}`,
	}); err != nil {
		t.Fatalf("send after resume: %v", err)
	}
	if rs, err := runner.lookupSession("s1"); err != nil || rs.handle != adapter.Handle(live) {
		t.Fatalf("resume 后登记句柄不得变化, err=%v", err)
	}
	live.mu.Lock()
	sends := append([]string(nil), live.sends...)
	live.mu.Unlock()
	if len(sends) != 1 || sends[0] != "继续" {
		t.Fatalf("send after resume got %v, want [继续]", sends)
	}
}

// ---- 失败可见性回归：传输层同步失败没有 Provider SSE 事件，runner 必须补发可见错误 ----

// session.send 的传输层同步失败必须补发脱敏 session_error 与失败终态，
// 让 user_message 之后的失败在时间线可见，客户端不会停留在生成中。
func TestSessionRunnerSendFailureEmitsVisibleError(t *testing.T) {
	_, runner, fake := newRunnerFixture(t, "opencode")
	events := make(chan adapter.Event, 16)
	runner.SetEventSink(func(sessionID string, event adapter.Event) {
		if sessionID == "s1" {
			events <- event
		}
	})
	if err := runner.ConsumeCommand(context.Background(), Command{
		Kind:        "session.start",
		PayloadJSON: `{"session_id":"s1","workspace_root":"/tmp/ws","provider":"opencode"}`,
	}); err != nil {
		t.Fatalf("start: %v", err)
	}
	h := fake.lastHandle()
	h.mu.Lock()
	h.sendErr = errors.New(`opencode POST /session/ses_1/prompt_async: status 500 body "upstream down"`)
	h.mu.Unlock()

	err := runner.ConsumeCommand(context.Background(), Command{
		Kind:        "session.send",
		PayloadJSON: `{"session_id":"s1","ciphertext":{"fixture_payload":{"message":"继续"}}}`,
	})
	if err == nil {
		t.Fatal("传输失败必须返回错误")
	}
	// provider 转发事件与命令生成事件的相对到达顺序取决于转发 goroutine 调度；
	// 断言对象是 user_message、session_error、失败终态自身的存在与单调序。
	var user, failure, terminal adapter.Event
	for terminal.Type == "" {
		event := readSinkEvent(t, events)
		switch event.Type {
		case adapter.EventUserMessage:
			user = event
		case adapter.EventSessionError:
			failure = event
		case adapter.EventTurnCompleted:
			if event.Payload["stop_reason"] == "send_failed" {
				terminal = event
			}
		}
	}
	if user.Type == "" || failure.Type == "" {
		t.Fatalf("时间线缺少 user_message/session_error: user=%+v failure=%+v", user, failure)
	}
	if user.Payload["text"] != "继续" {
		t.Fatalf("user_message = %+v", user)
	}
	if message, _ := failure.Payload["message"].(string); message != "Provider 发送失败，详情仅限本机诊断。" {
		t.Fatalf("session_error 必须脱敏: %q", message)
	}
	if terminal.Type != adapter.EventTurnCompleted {
		t.Fatalf("terminal = %+v, want turn_completed(send_failed)", terminal)
	}
	if !(user.Seq < failure.Seq && failure.Seq < terminal.Seq) {
		t.Fatalf("seq not monotonic: %d/%d/%d", user.Seq, failure.Seq, terminal.Seq)
	}
}

// session.abort 同步失败必须进入时间线；回合可能仍在进行，不得伪造终态。
func TestSessionRunnerAbortFailureEmitsVisibleError(t *testing.T) {
	_, runner, fake := newRunnerFixture(t, "opencode")
	events := make(chan adapter.Event, 16)
	runner.SetEventSink(func(sessionID string, event adapter.Event) {
		if sessionID == "s1" {
			events <- event
		}
	})
	if err := runner.ConsumeCommand(context.Background(), Command{
		Kind:        "session.start",
		PayloadJSON: `{"session_id":"s1","workspace_root":"/tmp/ws","provider":"opencode"}`,
	}); err != nil {
		t.Fatalf("start: %v", err)
	}
	h := fake.lastHandle()
	h.mu.Lock()
	h.abortErr = errors.New("opencode POST abort: status 409")
	h.mu.Unlock()

	if err := runner.ConsumeCommand(context.Background(), Command{
		Kind:        "session.abort",
		PayloadJSON: `{"session_id":"s1"}`,
	}); err == nil {
		t.Fatal("abort 失败必须返回错误")
	}
	var failure adapter.Event
	for failure.Type == "" {
		event := readSinkEvent(t, events)
		if event.Type == adapter.EventSessionError {
			failure = event
		}
	}
	if message, _ := failure.Payload["message"].(string); message != "Provider 中止失败，详情仅限本机诊断。" {
		t.Fatalf("session_error 必须脱敏: %q", message)
	}
	// 回合可能仍在进行：abort 失败绝不合成 turn_completed 终态；窗口内允许转发
	// goroutine 滞留的 provider 事件到达，只对终态类型断言。
	deadline := time.Now().Add(300 * time.Millisecond)
	for time.Now().Before(deadline) {
		select {
		case event := <-events:
			if event.Type == adapter.EventTurnCompleted {
				t.Fatalf("abort 失败不得合成终态事件: %+v", event)
			}
		case <-time.After(50 * time.Millisecond):
		}
	}
}

// session.kill 的 ForceKill 失败必须进入时间线，且本地映射保持原状以便重试。
func TestSessionRunnerKillFailureEmitsVisibleError(t *testing.T) {
	s, runner, fake := newRunnerFixture(t, "opencode")
	events := make(chan adapter.Event, 16)
	runner.SetEventSink(func(sessionID string, event adapter.Event) {
		if sessionID == "s1" {
			events <- event
		}
	})
	owned := &forceKillFakeHandle{
		fakeHandle:   newFakeHandle("instance-owned"),
		forceKillErr: errors.New("signal denied"),
	}
	fake.mu.Lock()
	fake.startOverride = owned
	fake.mu.Unlock()
	if err := runner.ConsumeCommand(context.Background(), Command{
		Kind:        "session.start",
		PayloadJSON: `{"session_id":"s1","workspace_root":"/tmp/ws","provider":"opencode"}`,
	}); err != nil {
		t.Fatalf("start: %v", err)
	}
	if err := runner.ConsumeCommand(context.Background(), Command{
		Kind:        "session.kill",
		PayloadJSON: `{"session_id":"s1"}`,
	}); err == nil {
		t.Fatal("kill 失败必须返回错误")
	}
	var failure adapter.Event
	for failure.Type == "" {
		event := readSinkEvent(t, events)
		if event.Type == adapter.EventSessionError {
			failure = event
		}
	}
	if message, _ := failure.Payload["message"].(string); message != "Provider 进程终止失败，详情仅限本机诊断。" {
		t.Fatalf("session_error 必须脱敏: %q", message)
	}
	if _, err := s.Get(instanceKey("s1")); err != nil {
		t.Fatalf("kill 失败必须保留 instance 映射: %v", err)
	}
	if owned.wasDisposed() {
		t.Fatal("kill 失败不得释放句柄")
	}
}

// ---- DCM-06：新回合必须重新武装合成终态 ----

// 上一回合已终态后，新回合的 turn_started 重置抑制；新回合被流中断时仍要补发
// 合成 session_error 与 stopped 终态，否则该回合在客户端永久停留在生成中。
func TestSessionRunnerForwardEventsRearmsTerminalAfterNewTurn(t *testing.T) {
	s, runner, _ := newRunnerFixture(t, "opencode")
	events := make(chan adapter.Event, 8)
	runner.SetEventSink(func(sessionID string, event adapter.Event) {
		if sessionID == "s-rearm" {
			events <- event
		}
	})
	evs := make(chan adapter.Event, 8)
	h := &fakeHandle{id: "instance-rearm", events: evs, done: make(chan struct{})}
	evs <- adapter.Event{Type: adapter.EventTurnCompleted, Seq: 7,
		Payload: map[string]any{"instance_id": "instance-rearm", "stop_reason": "session_idle"}}
	evs <- adapter.Event{Type: adapter.EventTurnStarted, Seq: 8,
		Payload: map[string]any{"instance_id": "instance-rearm"}}
	close(evs)

	fwdCtx, cancel := context.WithCancel(context.Background())
	defer cancel()
	runner.forwardEvents("s-rearm", h, fwdCtx)

	first := readSinkEvent(t, events)
	second := readSinkEvent(t, events)
	third := readSinkEvent(t, events)
	fourth := readSinkEvent(t, events)
	if first.Type != adapter.EventTurnCompleted || first.Payload["stop_reason"] != "session_idle" {
		t.Fatalf("first = %+v, want provider terminal", first)
	}
	if second.Type != adapter.EventTurnStarted {
		t.Fatalf("second = %+v, want new turn", second)
	}
	if third.Type != adapter.EventSessionError {
		t.Fatalf("third = %+v, want synthetic session_error after interrupted new turn", third)
	}
	if fourth.Type != adapter.EventTurnCompleted || fourth.Payload["stop_reason"] != "stopped" {
		t.Fatalf("fourth = %+v, want synthetic stopped terminal", fourth)
	}
	// provider 序号（7、8）被保留，合成终态在其后接续；脱敏摘要只含类型、序号与计数。
	var summary lastEvent
	raw, err := s.Get(eventKey("s-rearm"))
	if err != nil {
		t.Fatalf("read last_event: %v", err)
	}
	if err := json.Unmarshal([]byte(raw), &summary); err != nil {
		t.Fatalf("decode last_event: %v", err)
	}
	if summary.Count != 4 || summary.Type != adapter.EventTurnCompleted || summary.Seq != fourth.Seq {
		t.Fatalf("durable summary=%+v, want count=4 turn_completed seq=%d", summary, fourth.Seq)
	}
}
