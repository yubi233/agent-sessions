// 回合流式摘要契约测试（v0.8.7 V087-10）：
//  1. 含 delta 的回合在 turn_completed 终态输出恰好一条摘要（条数/字符数正确）；
//  2. session_aborted 同样收敛摘要；
//  3. 无 delta 的回合（如看门狗超时）不输出摘要；
//  4. 开关 AGENT_SESSIONS_TURN_STREAM_SUMMARY=0 关闭（回滚开关语义）。
package daemon

import (
	"bytes"
	"context"
	"fmt"
	"log/slog"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/yubi233/agent-sessions/internal/adapter"
)

// syncBuffer 是并发安全的日志缓冲：daemon 事件泵 goroutine 经 slog 写入、
// 测试 goroutine 经 waitForSummary 轮询读取；bytes.Buffer 本身非并发安全，
// 两侧必须持同一把锁（-race 在 V087 摘要用例抓到的真实竞争）。
type syncBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *syncBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *syncBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

// newV087SummaryRunner 建一台带捕获日志的 runner（断言摘要 Info 的内容与次数）。
func newV087SummaryRunner(t *testing.T) (*SessionRunner, *fakeAdapter, *syncBuffer) {
	t.Helper()
	s, err := OpenStore(filepath.Join(t.TempDir(), "daemon.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	t.Cleanup(func() { _ = s.Close() })
	buf := &syncBuffer{}
	fake := newFakeAdapter("opencode")
	runner := NewSessionRunner(s, map[string]adapter.Adapter{"opencode": fake},
		slog.New(slog.NewTextHandler(buf, &slog.HandlerOptions{Level: slog.LevelInfo})))
	t.Cleanup(func() { _ = runner.Close(context.Background()) })
	return runner, fake, buf
}

// waitForSummary 轮询日志缓冲直到谓词命中或超时，返回当前全文。
func waitForSummary(t *testing.T, buf *syncBuffer, predicate func(string) bool) string {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for {
		out := buf.String()
		if predicate(out) {
			return out
		}
		if time.Now().After(deadline) {
			return out
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// summaryLines 抽出全部"回合流式摘要"日志行。
func summaryLines(out string) []string {
	var lines []string
	for _, line := range strings.Split(out, "\n") {
		if strings.Contains(line, "回合流式摘要") {
			lines = append(lines, line)
		}
	}
	return lines
}

// 1) delta 回合 + turn_completed：恰好一条摘要，条数与字符数（rune 计）正确。
func TestV087TurnStreamSummaryFlushedOnTurnCompleted(t *testing.T) {
	runner, fake, buf := newV087SummaryRunner(t)
	startV086Session(t, runner)
	handle := fake.lastHandle()

	// 三个 assistant delta（1+2+3 rune）+ 一个 thought delta（2 rune）+ 终态。
	seq := int64(100)
	for _, text := range []string{"a", "bb", "ccc"} {
		handle.emit(adapter.Event{Type: adapter.EventMessageDelta, Seq: seq,
			Payload: map[string]any{"text": text}})
		seq++
	}
	handle.emit(adapter.Event{Type: adapter.EventThoughtDelta, Seq: seq,
		Payload: map[string]any{"text": "想法"}})
	seq++
	handle.emit(adapter.Event{Type: adapter.EventTurnCompleted, Seq: seq,
		Payload: map[string]any{"instance_id": "s1", "stop_reason": "end_turn"}})

	out := waitForSummary(t, buf, func(s string) bool {
		return len(summaryLines(s)) > 0
	})
	lines := summaryLines(out)
	if len(lines) != 1 {
		t.Fatalf("回合终态必须恰好一条摘要, got %d:\n%s", len(lines), out)
	}
	// fakeHandle 启动种子自带一条 "fixture delta"（turn_started 之后、我的合成
	// 事件之前），它属于同一回合窗口，正确地计入摘要。
	for _, want := range []string{"delta_events=5", "delta_chars=21", "terminal=turn_completed"} {
		if !strings.Contains(lines[0], want) {
			t.Fatalf("摘要缺少字段 %s:\n%s", want, lines[0])
		}
	}
	// 再等一拍确认不会重复输出（终态清零后无二次摘要）。
	time.Sleep(120 * time.Millisecond)
	if lines = summaryLines(buf.String()); len(lines) != 1 {
		t.Fatalf("摘要必须只输出一次, got %d:\n%s", len(lines), buf.String())
	}
}

// 2) session_aborted 终态同样收敛摘要（用户中止也是完整回合证据）。
func TestV087TurnStreamSummaryFlushedOnAbort(t *testing.T) {
	runner, fake, buf := newV087SummaryRunner(t)
	startV086Session(t, runner)
	handle := fake.lastHandle()

	for i := 0; i < 2; i++ {
		handle.emit(adapter.Event{Type: adapter.EventMessageDelta, Seq: int64(200 + i),
			Payload: map[string]any{"text": fmt.Sprintf("增量%d", i)}})
	}
	handle.emit(adapter.Event{Type: adapter.EventSessionAborted, Seq: 300,
		Payload: map[string]any{"instance_id": "s1"}})

	out := waitForSummary(t, buf, func(s string) bool {
		return strings.Contains(s, "terminal=session_aborted")
	})
	if lines := summaryLines(out); len(lines) != 1 {
		t.Fatalf("abort 收敛必须恰好一条摘要:\n%s", out)
	}
}

// 3) 无 delta 回合（如看门狗超时收敛）不输出摘要。turn_started 先重置启动
// 种子 delta（边界语义），随后零产出即终态。
func TestV087TurnStreamSummarySilentWithoutDeltas(t *testing.T) {
	runner, fake, buf := newV087SummaryRunner(t)
	startV086Session(t, runner)
	handle := fake.lastHandle()

	handle.emit(adapter.Event{Type: adapter.EventTurnStarted, Seq: 399,
		Payload: map[string]any{"instance_id": "s1"}})
	handle.emit(adapter.Event{Type: adapter.EventTurnCompleted, Seq: 400,
		Payload: map[string]any{"instance_id": "s1", "stop_reason": "watchdog_timeout"}})
	time.Sleep(200 * time.Millisecond)
	if lines := summaryLines(buf.String()); len(lines) != 0 {
		t.Fatalf("无 delta 回合不得输出摘要:\n%s", buf.String())
	}
}

// 4) 开关关闭（env "0"）：delta 回合终态不再输出摘要（回滚开关语义）。
func TestV087TurnStreamSummaryDisabledByEnv(t *testing.T) {
	t.Setenv(TurnStreamSummaryEnv, "0")
	runner, fake, buf := newV087SummaryRunner(t)
	startV086Session(t, runner)
	handle := fake.lastHandle()

	handle.emit(adapter.Event{Type: adapter.EventMessageDelta, Seq: 500,
		Payload: map[string]any{"text": "增量"}})
	handle.emit(adapter.Event{Type: adapter.EventTurnCompleted, Seq: 501,
		Payload: map[string]any{"instance_id": "s1"}})
	time.Sleep(200 * time.Millisecond)
	if lines := summaryLines(buf.String()); len(lines) != 0 {
		t.Fatalf("开关关闭时不得输出摘要:\n%s", buf.String())
	}
}
