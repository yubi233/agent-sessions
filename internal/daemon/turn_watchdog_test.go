// 回合看门狗契约测试（v0.8.6 A① / V086-11）：
//  1. 静默回合（send 受理后执行端零事件）在窗口到期时必须产出脱敏
//     session_error + turn_completed(stop_reason=watchdog_timeout)；
//  2. 持续产出的事件会为看门狗续命，慢回合不误报；终态事件撤防；
//  3. 用户 abort 撤防——用户主动停止后不得再补发看门狗失败；
//  4. 窗口置 0 = 关闭（回滚开关），行为与无看门狗一致。
package daemon

import (
	"context"
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/yubi233/agent-sessions/internal/adapter"
)

// v086SilentHandle：Send 受理后不产出任何事件的静默句柄，复现执行端失联。
type v086SilentHandle struct {
	*fakeHandle
}

func (h *v086SilentHandle) Send(ctx context.Context, text string) error {
	h.mu.Lock()
	h.sends = append(h.sends, text)
	h.mu.Unlock()
	// 静默返回成功：回合已受理但执行端毫无产出（A① 事故形态）。
	return nil
}

// v086WatchdogSink 收集事件出口的 canonical 事件，支持带超时的等待与断言。
type v086WatchdogSink struct {
	mu     sync.Mutex
	events []adapter.Event
}

func (s *v086WatchdogSink) attach(runner *SessionRunner) {
	runner.SetEventSink(func(sessionID string, event adapter.Event) {
		if sessionID != "s1" {
			return
		}
		s.mu.Lock()
		defer s.mu.Unlock()
		s.events = append(s.events, event)
	})
}

func (s *v086WatchdogSink) snapshot() []adapter.Event {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]adapter.Event(nil), s.events...)
}

// waitFor 轮询直到 predicate 命中或超时；返回超时前最后一次快照。
func (s *v086WatchdogSink) waitFor(t *testing.T, timeout time.Duration, predicate func([]adapter.Event) bool) []adapter.Event {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for {
		snapshot := s.snapshot()
		if predicate(snapshot) {
			return snapshot
		}
		if time.Now().After(deadline) {
			return snapshot
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// waitDisarmed 轮询等待指定会话从看门狗表中移除（撤防事件已被事件泵消费）。
// v0.9.7：CI 2 核 runner 下固定 sleep 200ms 存在"撤防事件排队未消费、看门狗
// tick 先行"的竞态窗口；改为同步确认撤防完成后再断言，语义不放宽。
func waitDisarmed(t *testing.T, r *SessionRunner, sessionID string) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for {
		r.watchdogMu.Lock()
		_, stillArmed := r.watchdogs[sessionID]
		r.watchdogMu.Unlock()
		if !stillArmed {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("撤防未在窗口内完成: %s", sessionID)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// hasWatchdogTerminalFunc 是 waitFor 用的函数式断言（判断是否已出现看门狗终态）。
func hasWatchdogTerminalFunc(events []adapter.Event) bool {
	for _, event := range events {
		if event.Type == adapter.EventTurnCompleted &&
			event.Payload["stop_reason"] == "watchdog_timeout" {
			return true
		}
	}
	return false
}

func (s *v086WatchdogSink) hasWatchdogTerminal() bool {
	for _, event := range s.snapshot() {
		if event.Type == adapter.EventTurnCompleted &&
			event.Payload["stop_reason"] == "watchdog_timeout" {
			return true
		}
	}
	return false
}

// startV086Session 建立一台已 start 的 opencode fixture 会话。
func startV086Session(t *testing.T, runner *SessionRunner) {
	t.Helper()
	if err := runner.ConsumeCommand(context.Background(), Command{
		Kind:        "session.start",
		PayloadJSON: `{"session_id":"s1","workspace_root":"/tmp/ws","provider":"opencode"}`,
	}); err != nil {
		t.Fatalf("start: %v", err)
	}
}

// 1) 静默回合：窗口到期必须补发失败事实，且 session_error 先于终态、文案脱敏。
func TestV086TurnWatchdogFiresOnSilentTurn(t *testing.T) {
	_, runner, fake := newRunnerFixture(t, "opencode")
	runner.turnWatchdogWindow = 60 * time.Millisecond
	var sink v086WatchdogSink
	sink.attach(runner)
	startV086Session(t, runner)
	fake.startOverride = &v086SilentHandle{fakeHandle: newFakeHandle("s1-hang")}

	// 重新 start 使静默句柄生效（startOverride 只影响下一次 Start）。
	if err := runner.ConsumeCommand(context.Background(), Command{
		Kind:        "session.start",
		PayloadJSON: `{"session_id":"s1","workspace_root":"/tmp/ws","provider":"opencode"}`,
	}); err != nil {
		t.Fatalf("restart with silent handle: %v", err)
	}
	if err := runner.ConsumeCommand(context.Background(), Command{
		Kind:        "session.send",
		PayloadJSON: `{"session_id":"s1","ciphertext":{"fixture_payload":{"message":"看看天德华府的最新情况"}}}`,
	}); err != nil {
		t.Fatalf("send: %v", err)
	}

	snapshot := sink.waitFor(t, 3*time.Second, hasWatchdogTerminalFunc)
	var failure, terminal adapter.Event
	for _, event := range snapshot {
		switch event.Type {
		case adapter.EventSessionError:
			failure = event
		case adapter.EventTurnCompleted:
			if event.Payload["stop_reason"] == "watchdog_timeout" {
				terminal = event
			}
		}
	}
	if failure.Type == "" || terminal.Type == "" {
		t.Fatalf("看门狗未收敛静默回合: failure=%+v terminal=%+v", failure, terminal)
	}
	if message, _ := failure.Payload["message"].(string); !strings.Contains(message, "回合超时") {
		t.Fatalf("session_error 必须是脱敏超时文案: %q", message)
	}
	if failure.Seq >= terminal.Seq {
		t.Fatalf("事件序必须单调: error=%d terminal=%d", failure.Seq, terminal.Seq)
	}
}

// 2) 持续产出的事件为看门狗续命：慢回合不误报；终态事件撤防后也不再触发。
func TestV086TurnWatchdogResetByStreamingEvents(t *testing.T) {
	_, runner, fake := newRunnerFixture(t, "opencode")
	runner.turnWatchdogWindow = 80 * time.Millisecond
	var sink v086WatchdogSink
	sink.attach(runner)
	startV086Session(t, runner)
	handle := fake.lastHandle()

	if err := runner.ConsumeCommand(context.Background(), Command{
		Kind:        "session.send",
		PayloadJSON: `{"session_id":"s1","ciphertext":{"fixture_payload":{"message":"慢回合"}}}`,
	}); err != nil {
		t.Fatalf("send: %v", err)
	}

	// 模拟慢回合：每 30ms 产出一条 delta，持续 300ms（> 3 个看门狗窗口）。
	stopStreaming := make(chan struct{})
	go func() {
		seq := int64(100)
		for {
			select {
			case <-stopStreaming:
				return
			case <-time.After(30 * time.Millisecond):
			}
			// emit 只做 channel send，无需持 handle 锁；seq 由测试 goroutine 独享。
			handle.emit(adapter.Event{Type: adapter.EventMessageDelta, Seq: seq,
				Payload: map[string]any{"text": fmt.Sprintf("增量 %d", seq)}})
			seq++
		}
	}()
	time.Sleep(300 * time.Millisecond)
	close(stopStreaming)
	if sink.hasWatchdogTerminal() {
		t.Fatal("持续产出的慢回合不得被看门狗误判")
	}

	// 终态事件撤防：之后的长沉默不再触发看门狗。
	// emit 现已内部持 handle.mu（与 close(events) 互斥），外部不得再包一层锁
	// （非重入互斥锁会自死锁）。
	handle.emit(adapter.Event{Type: adapter.EventTurnCompleted, Seq: 500,
		Payload: map[string]any{"instance_id": "s1", "stop_reason": "end_turn"}})
	waitDisarmed(t, runner, "s1")
	if sink.hasWatchdogTerminal() {
		t.Fatal("终态撤防后看门狗不得再触发")
	}
}

// 3) 用户 abort 撤防：用户主动停止后，看门狗不得再补发失败事实。
func TestV086TurnWatchdogDisarmOnAbort(t *testing.T) {
	_, runner, fake := newRunnerFixture(t, "opencode")
	runner.turnWatchdogWindow = 60 * time.Millisecond
	var sink v086WatchdogSink
	sink.attach(runner)
	startV086Session(t, runner)
	fake.startOverride = &v086SilentHandle{fakeHandle: newFakeHandle("s1-abort")}
	if err := runner.ConsumeCommand(context.Background(), Command{
		Kind:        "session.start",
		PayloadJSON: `{"session_id":"s1","workspace_root":"/tmp/ws","provider":"opencode"}`,
	}); err != nil {
		t.Fatalf("restart with silent handle: %v", err)
	}
	if err := runner.ConsumeCommand(context.Background(), Command{
		Kind:        "session.send",
		PayloadJSON: `{"session_id":"s1","ciphertext":{"fixture_payload":{"message":"会被中止"}}}`,
	}); err != nil {
		t.Fatalf("send: %v", err)
	}

	// abort 成功（session_aborted 由 abortSession 发出）后必须撤防。
	if err := runner.ConsumeCommand(context.Background(), Command{
		Kind:        "session.abort",
		PayloadJSON: `{"session_id":"s1"}`,
	}); err != nil {
		t.Fatalf("abort: %v", err)
	}
	time.Sleep(250 * time.Millisecond)
	if sink.hasWatchdogTerminal() {
		t.Fatal("用户 abort 后看门狗不得再补发失败事实")
	}
}

// 4) 窗口置 0 = 关闭：静默回合不再由看门狗收敛（回滚开关语义）。
func TestV086TurnWatchdogDisabledWhenWindowZero(t *testing.T) {
	_, runner, fake := newRunnerFixture(t, "opencode")
	runner.turnWatchdogWindow = 0
	var sink v086WatchdogSink
	sink.attach(runner)
	startV086Session(t, runner)
	fake.startOverride = &v086SilentHandle{fakeHandle: newFakeHandle("s1-off")}
	if err := runner.ConsumeCommand(context.Background(), Command{
		Kind:        "session.start",
		PayloadJSON: `{"session_id":"s1","workspace_root":"/tmp/ws","provider":"opencode"}`,
	}); err != nil {
		t.Fatalf("restart with silent handle: %v", err)
	}
	if err := runner.ConsumeCommand(context.Background(), Command{
		Kind:        "session.send",
		PayloadJSON: `{"session_id":"s1","ciphertext":{"fixture_payload":{"message":"静默"}}}`,
	}); err != nil {
		t.Fatalf("send: %v", err)
	}
	time.Sleep(200 * time.Millisecond)
	if sink.hasWatchdogTerminal() {
		t.Fatal("看门狗关闭（窗口=0）时不得产出失败事实")
	}
}

// 环境变量解析契约：缺省=默认窗口；0=关闭；非法值回退默认。
func TestV086TurnWatchdogWindowFromEnv(t *testing.T) {
	t.Setenv(TurnWatchdogWindowEnv, "")
	if got := turnWatchdogWindowFromEnv(); got != DefaultTurnWatchdogWindow {
		t.Fatalf("缺省窗口 = %v, want %v", got, DefaultTurnWatchdogWindow)
	}
	t.Setenv(TurnWatchdogWindowEnv, "0")
	if got := turnWatchdogWindowFromEnv(); got != 0 {
		t.Fatalf("显式 0 = %v, want 0（关闭）", got)
	}
	t.Setenv(TurnWatchdogWindowEnv, "not-a-number")
	if got := turnWatchdogWindowFromEnv(); got != DefaultTurnWatchdogWindow {
		t.Fatalf("非法值应回退默认 = %v", got)
	}
	t.Setenv(TurnWatchdogWindowEnv, "5000")
	if got := turnWatchdogWindowFromEnv(); got != 5*time.Second {
		t.Fatalf("自定义窗口 = %v, want 5s", got)
	}
}
