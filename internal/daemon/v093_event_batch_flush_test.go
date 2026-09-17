package daemon

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/yubi233/agent-sessions/internal/id"
)

// V093-02 回归（v0.9.3 P1）：flushEvents 批量上传的行为契约。
// 修复目标（T1/T3 裁决）：万级 delta 出箱追平从「N×RTT」降到「⌈N/批⌉×RTT」，
// 同时不放松既有可靠性语义——毒丸逐条隔离、瞬态退避、delivered 只在确认后标记。

const v093FixtureEnvelope = `{"alg":"fixture-aead","key_id":"k","nonce":"n","ciphertext":"c","aad_hash":"h","payload_version":1}`

// v093BatchFixture 是批量 flush 测试的公共基建：假 Relay 同时挂单条与批量端点，
// 记录每个端点的命中数与批量接收顺序；毒丸/瞬态行为由注入的谓词控制。
type v093BatchFixture struct {
	store  *Store
	loop   *RelayLoop
	server *httptest.Server

	mu           sync.Mutex
	batchHits    int
	singleHits   int
	batchOrder   [][]string // 每次批量请求收到的 event_id 顺序
	singlePoison map[string]bool
	batchReject  bool          // true：批量端点恒 400（模拟 Relay 整批拒绝）
	batchFail    bool          // true：批量端点恒 503（模拟瞬态失败）
	batchRTT     time.Duration // 每请求模拟 RTT
}

func newV093BatchFixture(t *testing.T) *v093BatchFixture {
	t.Helper()
	store, err := OpenStore(filepath.Join(t.TempDir(), "daemon.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	t.Cleanup(func() { _ = store.Close() })
	fx := &v093BatchFixture{store: store, singlePoison: map[string]bool{}}
	fx.server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if fx.batchRTT > 0 {
			time.Sleep(fx.batchRTT)
		}
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/v1/daemon/events/batch":
			fx.mu.Lock()
			fx.batchHits++
			reject, fail := fx.batchReject, fx.batchFail
			var payload struct {
				Events []struct {
					EventID string `json:"event_id"`
				} `json:"events"`
			}
			_ = json.NewDecoder(r.Body).Decode(&payload)
			ids := make([]string, len(payload.Events))
			for i, event := range payload.Events {
				ids[i] = event.EventID
			}
			fx.batchOrder = append(fx.batchOrder, ids)
			fx.mu.Unlock()
			if reject {
				w.WriteHeader(http.StatusBadRequest)
				_, _ = io.WriteString(w, `{"code":"invalid_request","message":"batch rejected"}`)
				return
			}
			if fail {
				w.WriteHeader(http.StatusServiceUnavailable)
				_, _ = io.WriteString(w, `{"code":"unavailable","message":"transient"}`)
				return
			}
			// 回执与请求等长、按请求顺序返回（与真实 Relay 的响应形状一致）。
			results := make([]string, len(ids))
			for i, eventID := range ids {
				results[i] = fmt.Sprintf(`{"event_id":%q,"event_seq":%d,"idempotent":false}`, eventID, i+1)
			}
			_, _ = io.WriteString(w, fmt.Sprintf(`{"results":[%s]}`, strings.Join(results, ",")))
		case "/v1/daemon/events":
			fx.mu.Lock()
			fx.singleHits++
			var payload struct {
				EventID string `json:"event_id"`
			}
			_ = json.NewDecoder(r.Body).Decode(&payload)
			poison := fx.singlePoison[payload.EventID]
			fx.mu.Unlock()
			if poison {
				w.WriteHeader(http.StatusBadRequest)
				_, _ = io.WriteString(w, `{"code":"invalid_request","message":"poison"}`)
				return
			}
			_, _ = io.WriteString(w, `{}`)
		default:
			t.Errorf("unexpected relay path %s", r.URL.Path)
		}
	}))
	t.Cleanup(fx.server.Close)
	fx.loop = NewRelayLoop(store, &RelayClient{BaseURL: fx.server.URL, AccessToken: "fixture"}, nil,
		FixtureEventEncoder{}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	return fx
}

// enqueue 入箱 n 条事件；useFixedIDs 时使用 evt-1..evt-n（毒丸注入需要确定性 ID）。
func (fx *v093BatchFixture) enqueue(t *testing.T, n int, useFixedIDs bool) []string {
	t.Helper()
	ids := make([]string, n)
	for i := 0; i < n; i++ {
		if useFixedIDs {
			ids[i] = fmt.Sprintf("evt-%d", i+1)
		} else {
			ids[i] = id.New("evt")
		}
		if err := fx.store.EnqueueRelayEvent(RelayEvent{
			EventID: ids[i], CommandID: "cmd-v093", SessionID: "sess-v093",
			EventType: "message.delta", EnvelopeJSON: v093FixtureEnvelope,
			CreatedAtUnixMS: time.Now().UnixMilli(),
		}); err != nil {
			t.Fatalf("enqueue %d: %v", i, err)
		}
	}
	return ids
}

func (fx *v093BatchFixture) drain(t *testing.T) {
	t.Helper()
	ctx := context.Background()
	for drain := 0; drain < 100; drain++ {
		pending, err := fx.store.PendingRelayEventCount()
		if err != nil {
			t.Fatalf("pending count: %v", err)
		}
		if pending == 0 {
			return
		}
		if err := fx.loop.flushEvents(ctx); err != nil {
			t.Fatalf("flush: %v", err)
		}
	}
	t.Fatal("排空循环超限：pending 未归零")
}

func (fx *v093BatchFixture) mustRow(t *testing.T, eventID string) RelayEventOutboxRow {
	t.Helper()
	rows, err := fx.store.RelayEventOutboxSnapshot()
	if err != nil {
		t.Fatal(err)
	}
	for _, row := range rows {
		if row.EventID == eventID {
			return row
		}
	}
	t.Fatalf("event %s missing from outbox snapshot", eventID)
	return RelayEventOutboxRow{}
}

// 批量成功路径：7 条事件、分块大小 3 → 3 次批量请求（3+3+1）、0 次单条请求；
// 顺序跨块保持出箱排序；全部 delivered。
func TestV093FlushEventsBatchesUploadsInOrder(t *testing.T) {
	fx := newV093BatchFixture(t)
	fx.loop.eventBatchSize = 3
	ids := fx.enqueue(t, 7, true)

	fx.drain(t)

	fx.mu.Lock()
	hits, order := fx.batchHits, fx.batchOrder
	single := fx.singleHits
	fx.mu.Unlock()
	if hits != 3 || single != 0 {
		t.Fatalf("batch hits=%d single hits=%d, want 3/0（批量路径未按分块大小聚合）", hits, single)
	}
	flat := append(append(append([]string{}, order[0]...), order[1]...), order[2]...)
	if len(flat) != 7 {
		t.Fatalf("batched ids len=%d, want 7", len(flat))
	}
	for i := range ids {
		if flat[i] != ids[i] {
			t.Fatalf("order broken at %d: %q != %q（批量化不得改变投递顺序）", i, flat[i], ids[i])
		}
	}
	rows, err := fx.store.RelayEventOutboxSnapshot()
	if err != nil {
		t.Fatal(err)
	}
	for _, row := range rows {
		if row.Status != "delivered" {
			t.Fatalf("event %s status=%q, want delivered", row.EventID, row.Status)
		}
	}
}

// 字节上限分块：超大 envelope 独占一块（不与其它事件同批，防止单批请求体失控），
// 且仍能全部投递。
func TestV093FlushEventsChunksByBytes(t *testing.T) {
	fx := newV093BatchFixture(t)
	fx.loop.eventBatchSize = 200
	// 超过单批字节上限的 envelope：必须是合法 JSON（envelope 在 wire 上是 JSON 原文），
	// 这里用一个巨大的 JSON 字符串字面量占位。
	big := `"` + strings.Repeat("x", eventBatchMaxBytes+1) + `"`
	if err := fx.store.EnqueueRelayEvent(RelayEvent{
		EventID: "evt-big", CommandID: "cmd-v093", SessionID: "sess-v093",
		EventType: "message.completed", EnvelopeJSON: big, CreatedAtUnixMS: 1,
	}); err != nil {
		t.Fatal(err)
	}
	fx.enqueue(t, 2, true)

	fx.drain(t)

	fx.mu.Lock()
	order := fx.batchOrder
	fx.mu.Unlock()
	bigAlone := false
	for _, chunk := range order {
		if len(chunk) == 1 && chunk[0] == "evt-big" {
			bigAlone = true
		}
	}
	if !bigAlone {
		t.Fatalf("大 envelope 未独占一块：%v", order)
	}
}

// 批量级 4xx → 回退逐条路径：毒丸事件被逐条隔离为 failed（RELAY_REJECTED_PERMANENT），
// 其余事件照常 delivered。整批拒绝不得把任何合法事件打成毒丸。
func TestV093FlushEventsBatchRejectFallsBackAndIsolatesPoison(t *testing.T) {
	fx := newV093BatchFixture(t)
	fx.loop.eventBatchSize = 3
	fx.mu.Lock()
	fx.batchReject = true
	fx.singlePoison["evt-2"] = true // 逐条回退时，第 2 条被 Relay 确定性拒绝
	fx.mu.Unlock()
	fx.enqueue(t, 3, true)

	fx.drain(t)

	rows, err := fx.store.RelayEventOutboxSnapshot()
	if err != nil {
		t.Fatal(err)
	}
	byID := map[string]RelayEventOutboxRow{}
	for _, row := range rows {
		byID[row.EventID] = row
	}
	poison, ok := byID["evt-2"]
	if !ok {
		t.Fatal("evt-2 missing from outbox")
	}
	if poison.Status != "failed" || poison.LastError != relayEventPermanentReject {
		t.Fatalf("poison event status=%q last_error=%q, want failed/RELAY_REJECTED_PERMANENT", poison.Status, poison.LastError)
	}
	delivered := 0
	for _, row := range rows {
		if row.EventID != "evt-2" && row.Status != "delivered" {
			t.Fatalf("event %s status=%q, want delivered", row.EventID, row.Status)
		}
		if row.EventID != "evt-2" {
			delivered++
		}
	}
	if delivered != 2 {
		t.Fatalf("delivered=%d, want 2", delivered)
	}
}

// 批量瞬态失败 → 整批保持 pending 并记录退避；恢复后自动重试成功。
func TestV093FlushEventsBatchTransientFailureRetries(t *testing.T) {
	fx := newV093BatchFixture(t)
	fx.loop.eventBatchSize = 3
	fx.mu.Lock()
	fx.batchFail = true
	fx.mu.Unlock()
	ids := fx.enqueue(t, 3, true)

	ctx := context.Background()
	if err := fx.loop.flushEvents(ctx); err == nil {
		t.Fatal("批量瞬态失败必须返回错误（交给重连路径）")
	}
	rows, err := fx.store.RelayEventOutboxSnapshot()
	if err != nil {
		t.Fatal(err)
	}
	for _, row := range rows {
		if row.Status != "pending" || row.Attempts != 1 {
			t.Fatalf("event %s status=%q attempts=%d, want pending/1（整批未投递，统一退避）", row.EventID, row.Status, row.Attempts)
		}
	}
	// 退避后的 next_attempt_at 在未来；测试把退避时间归零等价于时间前进。
	if _, err := fx.store.db.Exec(`UPDATE relay_event_outbox SET next_attempt_at=0`); err != nil {
		t.Fatal(err)
	}
	fx.mu.Lock()
	fx.batchFail = false
	fx.mu.Unlock()
	fx.drain(t)
	for _, eventID := range ids {
		if row := fx.mustRow(t, eventID); row.Status != "delivered" {
			t.Fatalf("event %s status=%q after recovery, want delivered", eventID, row.Status)
		}
	}
}

// 回滚开关：eventBatchSize=1 时全部走单条端点（v0.9.2 行为），批量端点零命中。
func TestV093FlushEventsRollbackSwitchUsesPerEventPath(t *testing.T) {
	fx := newV093BatchFixture(t)
	fx.loop.eventBatchSize = 1
	fx.enqueue(t, 4, true)
	fx.drain(t)
	fx.mu.Lock()
	batch, single := fx.batchHits, fx.singleHits
	fx.mu.Unlock()
	if batch != 0 || single != 4 {
		t.Fatalf("batch hits=%d single hits=%d, want 0/4（回滚开关必须完整还原逐条路径）", batch, single)
	}
}

// V093-02 吞吐达标门（T3 阈值断言）：万级 delta 在批量化后必须在 30s 内追平
// （模拟 RTT=30ms）。门控 AGENT_SESSIONS_V093_ATTRIB=1，与 V093-01 基线同入口复跑。
func TestV093EventThroughputBatched(t *testing.T) {
	if os.Getenv("AGENT_SESSIONS_V093_ATTRIB") != "1" {
		t.Skip("AGENT_SESSIONS_V093_ATTRIB != 1：跳过 V093-02 全量吞吐达标门（定向复跑入口）")
	}
	eventsN := envIntOr("AGENT_SESSIONS_V093_ATTRIB_EVENTS", 10000)
	rttMS := envIntOr("AGENT_SESSIONS_V093_ATTRIB_RTT_MS", 30)

	fx := newV093BatchFixture(t)
	fx.batchRTT = time.Duration(rttMS) * time.Millisecond
	fx.enqueue(t, eventsN, false)

	started := time.Now()
	fx.drain(t)
	drainMS := time.Since(started).Milliseconds()

	fx.mu.Lock()
	hits, single := fx.batchHits, fx.singleHits
	fx.mu.Unlock()
	if single != 0 {
		t.Fatalf("批量达标门不允许回退到单条端点：single hits=%d", single)
	}
	if drainMS > 30_000 {
		t.Fatalf("万级 delta 追平耗时 %dms，超过 T3 阈值 30s", drainMS)
	}
	t.Logf("V093-02 达标：%d 条在 %dms 追平（批量请求 %d 次、RTT=%dms）", eventsN, drainMS, hits, rttMS)
}
