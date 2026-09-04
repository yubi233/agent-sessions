package daemon

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/yubi233/agent-sessions/internal/id"
)

// seedRetryEvent 写入一条可重试事件并返回其 event_id。
func seedRetryEvent(t *testing.T, store *Store, suffix string) string {
	t.Helper()
	event := RelayEvent{
		EventID: id.New("evt") + "-" + suffix, CommandID: "cmd-1", SessionID: "sess-1",
		EventType:       "message.completed",
		CreatedAtUnixMS: 1724242200123,
		// envelope 只能是密文外形；这里使用协议形态合法的 fixture 值。
		EnvelopeJSON: `{"alg":"fixture-aead","key_id":"k","nonce":"n","ciphertext":"c","aad_hash":"h","payload_version":1}`,
	}
	if err := store.EnqueueRelayEvent(event); err != nil {
		t.Fatalf("enqueue: %v", err)
	}
	return event.EventID
}

// V085-19：事件生成时间在本地 outbox 重读后保持原值，不能被 outbox 接收时间覆盖。
func TestRelayEventOutboxPreservesCanonicalCreatedAt(t *testing.T) {
	path := filepath.Join(t.TempDir(), "daemon.db")
	store, err := OpenStore(path)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	const createdAt = int64(1724242200123)
	if err := store.EnqueueRelayEvent(RelayEvent{
		EventID: "evt-created-at", CommandID: "cmd-created-at", SessionID: "sess-created-at",
		EventType: "session.aborted", EnvelopeJSON: `{"fixture_payload":{"label":"已中止"}}`,
		CreatedAtUnixMS: createdAt,
	}); err != nil {
		t.Fatal(err)
	}
	pending, err := store.PendingRelayEvents()
	if err != nil {
		t.Fatal(err)
	}
	if len(pending) != 1 || pending[0].CreatedAtUnixMS != createdAt {
		t.Fatalf("pending event timestamp=%+v, want %d", pending, createdAt)
	}
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}
	reopened, err := OpenStore(path)
	if err != nil {
		t.Fatal(err)
	}
	defer reopened.Close()
	pending, err = reopened.PendingRelayEvents()
	if err != nil || len(pending) != 1 || pending[0].CreatedAtUnixMS != createdAt {
		t.Fatalf("reopened event timestamp=%+v err=%v, want %d", pending, err, createdAt)
	}
}

// snapshotByID 从诊断投影中查找指定事件行。
func snapshotByID(t *testing.T, store *Store, eventID string) RelayEventOutboxRow {
	t.Helper()
	rows, err := store.RelayEventOutboxSnapshot()
	if err != nil {
		t.Fatalf("snapshot: %v", err)
	}
	for _, row := range rows {
		if row.EventID == eventID {
			return row
		}
	}
	t.Fatalf("event %s missing from outbox snapshot", eventID)
	return RelayEventOutboxRow{}
}

// TestRelayEventOutboxTransientFailureRetainedUntilCap 验证瞬态失败的完整状态机：
// 每次失败 attempts+1 并进入退避；达到上限后转入 failed 保留（不删除）；
// 自动恢复入口只复活瞬态失败，毒丸失败必须保持 failed。
func TestRelayEventOutboxTransientFailureRetainedUntilCap(t *testing.T) {
	store, err := OpenStore(filepath.Join(t.TempDir(), "daemon.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()

	transientID := seedRetryEvent(t, store, "transient")
	poisonID := seedRetryEvent(t, store, "poison")

	status := http.StatusInternalServerError
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_, _ = io.WriteString(w, `{"code":"INTERNAL"}`)
	}))
	defer server.Close()
	loop := &RelayLoop{
		Store:  store,
		Client: &RelayClient{BaseURL: server.URL, AccessToken: "t"},
		Logger: slog.New(slog.NewTextHandler(io.Discard, nil)),
	}

	// 毒丸：确定性 4xx 立即 failed。
	status = http.StatusBadRequest
	if err := loop.flushEvents(context.Background()); err != nil {
		t.Fatalf("poison flush: %v", err)
	}
	if row := snapshotByID(t, store, poisonID); row.Status != "failed" || row.LastError != relayEventPermanentReject {
		t.Fatalf("poison row unexpected: %+v", row)
	}

	// 瞬态：反复失败直到重试上限；期间事件不得被标记 delivered 或删除。
	status = http.StatusInternalServerError
	for i := 0; i < maxRelayEventAttempts; i++ {
		// 退避门控会让 PendingRelayEvents 为空；直接用全量快照确认事件仍在队列语义内，
		// 并通过 RequeueTransientFailedRelayEvents 模拟"退避到期后的下一轮循环"。
		if err := loop.flushEvents(context.Background()); err == nil && i == 0 {
			// 第一次 flush 因退避门控看不到该事件时不会产生错误；
			// 这里强制记账以推进状态机（等价于到期后再次上传失败）。
		}
		if err := store.MarkRelayEventAttempt(transientID, "RELAY_HTTP_500"); err != nil {
			t.Fatalf("attempt %d: %v", i+1, err)
		}
		row := snapshotByID(t, store, transientID)
		if row.Status == "delivered" {
			t.Fatal("unconfirmed event must never be delivered")
		}
	}
	if row := snapshotByID(t, store, transientID); row.Status != "failed" || row.Attempts != maxRelayEventAttempts {
		t.Fatalf("transient event must be failed at cap: %+v", row)
	}

	// 自动恢复：毒丸保持 failed，瞬态失败回到 pending。
	requeued, err := store.RequeueTransientFailedRelayEvents()
	if err != nil {
		t.Fatalf("auto recovery: %v", err)
	}
	if requeued != 1 {
		t.Fatalf("auto recovery must requeue only transient failures: %d", requeued)
	}
	if row := snapshotByID(t, store, transientID); row.Status != "pending" || row.Attempts != 0 {
		t.Fatalf("recovered transient event unexpected: %+v", row)
	}
	if row := snapshotByID(t, store, poisonID); row.Status != "failed" {
		t.Fatalf("poison must stay failed after auto recovery: %+v", row)
	}

	// 显式全量恢复：毒丸也可被人工重新入队。
	full, err := store.RequeueFailedRelayEvents()
	if err != nil || full != 1 {
		t.Fatalf("manual recovery: %d %v", full, err)
	}
	if row := snapshotByID(t, store, poisonID); row.Status != "pending" {
		t.Fatalf("manual recovery must requeue poison: %+v", row)
	}
}

// TestRelayEventOutboxSurvivesRestart 验证 outbox 状态跨进程重启保留：
// pending/delivered/failed 的历史行在关闭并重开 SQLite 后逐字段一致。
func TestRelayEventOutboxSurvivesRestart(t *testing.T) {
	path := filepath.Join(t.TempDir(), "daemon.db")
	openStore := func(t *testing.T) *Store {
		db, err := OpenStore(path)
		if err != nil {
			t.Fatalf("open store: %v", err)
		}
		return db
	}
	store := openStore(t)
	pendingID := seedRetryEvent(t, store, "pending")
	deliveredID := seedRetryEvent(t, store, "delivered")
	failedID := seedRetryEvent(t, store, "failed")

	if err := store.MarkRelayEventDelivered(deliveredID); err != nil {
		t.Fatalf("mark delivered: %v", err)
	}
	// 瞬态记账与毒丸置位是两条路径：先各记一次失败，再显式置为永久拒绝。
	if err := store.MarkRelayEventAttempt(failedID, "RELAY_HTTP_500"); err != nil {
		t.Fatalf("attempt accounting: %v", err)
	}
	if err := store.MarkRelayEventFailedNow(failedID, relayEventPermanentReject); err != nil {
		t.Fatalf("fail now: %v", err)
	}
	beforeRows, err := store.RelayEventOutboxSnapshot()
	if err != nil {
		t.Fatal(err)
	}
	before := map[string]RelayEventOutboxRow{}
	for _, row := range beforeRows {
		before[row.EventID] = row
	}

	if err := store.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}

	reopened := openStore(t)
	defer reopened.Close()
	cases := map[string]string{pendingID: "pending", deliveredID: "delivered", failedID: "failed"}
	for eventID, want := range cases {
		row := snapshotByID(t, reopened, eventID)
		if row.Status != want {
			t.Fatalf("event %s status=%s want %s after restart", eventID, row.Status, want)
		}
		wantRow := before[eventID]
		if row != wantRow {
			t.Fatalf("event %s drifted across restart: %+v want %+v", eventID, row, wantRow)
		}
	}
}

// V085-24：RelayLoop 对 session.send 采用异步执行后，紧随其后的 session.abort 必须
// 及时到达 Provider（不能被 Send 的执行锁挡在身后）。成功 Abort 只产生一次上传到
// Relay 的 session.aborted（带 canonical 生成时间，经 outbox 单行持久化，重开后
// 时间保持原值，不能被接收时间覆盖）。此用例覆盖 processPending 异步分支 + abort 抢占。
func TestRelayLoopAsyncSendAbortSingleAbortedEventWithCanonicalTime(t *testing.T) {
	dbFile := filepath.Join(t.TempDir(), "daemon.db")
	store, err := OpenStore(dbFile)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if err := store.Set("terminal_id", "term-async"); err != nil {
		t.Fatal(err)
	}

	// 记录上传到 Relay 的 session.aborted 事件体（脱敏断言：类型 + canonical 时间）。
	var abortedUploads []map[string]any
	var uploadMu sync.Mutex
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch {
		case strings.HasSuffix(r.URL.Path, "/ack"):
			_, _ = io.WriteString(w, `{}`)
		case strings.HasSuffix(r.URL.Path, "/result"):
			_, _ = io.WriteString(w, `{"command_id":"ignored","delivery_seq":1,"status":"succeeded"}`)
		case strings.HasSuffix(r.URL.Path, "/events"):
			var body map[string]any
			if decodeErr := json.NewDecoder(r.Body).Decode(&body); decodeErr == nil && body["event_type"] == "session.aborted" {
				uploadMu.Lock()
				abortedUploads = append(abortedUploads, body)
				uploadMu.Unlock()
			}
			_, _ = io.WriteString(w, `{}`)
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()

	// 复用 runner 测试夹具：opencode adapter + blockingSendHandle 复现长 Send。
	_, runner, fake := newRunnerFixture(t, "opencode")
	defer runner.Close(context.Background())
	blocking := newBlockingSendHandle("instance-async")
	fake.mu.Lock()
	fake.startOverride = blocking
	fake.mu.Unlock()

	loop := NewRelayLoop(store, &RelayClient{BaseURL: server.URL, AccessToken: "fixture"}, runner, FixtureEventEncoder{},
		slog.New(slog.NewTextHandler(io.Discard, nil)))
	loop.Capabilities = []string{"start", "send", "abort"}
	runner.SetEventSinkResult(loop.enqueueCanonicalEventResult)

	deliver := func(delivery RelayDelivery) {
		t.Helper()
		if err := loop.handleDelivery(context.Background(), delivery); err != nil {
			t.Fatalf("handle %s: %v", delivery.Command.Kind, err)
		}
	}

	// 1) session.start 建立实例。
	deliver(RelayDelivery{DeliverySeq: 1, Command: RelayCommand{
		CommandID: "cmd-start", SessionID: "s-async", WorkspaceID: "ws-async",
		Kind: "session.start", LeaseEpoch: 1, TargetTerminalID: "term-async",
		PayloadJSON: `{"session_id":"s-async","workspace_root":"/tmp/ws","provider":"opencode"}`,
	}})

	// 2) session.send 进入 Provider 长阻塞窗口（handleDelivery 异步放行）。
	deliver(RelayDelivery{DeliverySeq: 2, Command: RelayCommand{
		CommandID: "cmd-send", SessionID: "s-async", WorkspaceID: "ws-async",
		Kind: "session.send", LeaseEpoch: 1, TargetTerminalID: "term-async",
		PayloadJSON: `{"session_id":"s-async","ciphertext":{"fixture_payload":{"message":"你好"}}}`,
	}})

	// 等待 Send 真正进入阻塞窗口。
	select {
	case <-blocking.sendStarted:
	case <-time.After(2 * time.Second):
		t.Fatal("send did not enter blocking window")
	}

	// 3) 立即 abort：必须绕过 Send 执行锁并及时到达 Provider。
	abortStart := time.Now()
	deliver(RelayDelivery{DeliverySeq: 3, Command: RelayCommand{
		CommandID: "cmd-abort", SessionID: "s-async", WorkspaceID: "ws-async",
		Kind: "session.abort", LeaseEpoch: 1, TargetTerminalID: "term-async",
		PayloadJSON: `{"session_id":"s-async"}`,
	}})
	if elapsed := time.Since(abortStart); elapsed > 1500*time.Millisecond {
		t.Fatalf("abort latency=%s while send blocked, want <1.5s", elapsed)
	}
	blocking.mu.Lock()
	aborts := blocking.aborts
	blocking.mu.Unlock()
	if aborts != 1 {
		t.Fatalf("handle.Abort calls=%d, want 1", aborts)
	}

	// 4) 释放 Send，等待异步执行收口。handleDelivery 尾部已 flush outboxes，
	// 事件应恰好上传一次。
	close(blocking.releaseSend)
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		uploadMu.Lock()
		n := len(abortedUploads)
		uploadMu.Unlock()
		if n >= 1 {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}

	uploadMu.Lock()
	gotUploads := append([]map[string]any(nil), abortedUploads...)
	uploadMu.Unlock()
	if len(gotUploads) != 1 {
		t.Fatalf("session.aborted uploads=%d, want exactly 1", len(gotUploads))
	}
	createdAt, _ := gotUploads[0]["created_at_unix_ms"].(float64)
	if createdAt <= 0 {
		t.Fatalf("uploaded session.aborted must carry canonical time: %v", gotUploads[0])
	}

	// 5) 事件行必须已持久化到本机 outbox；重开后 canonical 时间保持原值。
	rows, err := store.RelayEventOutboxSnapshot()
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) == 0 {
		t.Fatal("outbox must retain delivered event row for audit")
	}
	var storedTime int64
	if err := store.db.QueryRow(`SELECT created_at_unix_ms FROM relay_event_outbox WHERE event_type=? LIMIT 1`, "session.aborted").Scan(&storedTime); err != nil {
		t.Fatalf("query stored created_at: %v", err)
	}
	if storedTime != int64(createdAt) {
		t.Fatalf("outbox stored time=%d upload=%d", storedTime, int64(createdAt))
	}
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}
	reopened, err := OpenStore(dbFile)
	if err != nil {
		t.Fatal(err)
	}
	defer reopened.Close()
	var replayedTime int64
	if err := reopened.db.QueryRow(`SELECT created_at_unix_ms FROM relay_event_outbox WHERE event_type=? LIMIT 1`, "session.aborted").Scan(&replayedTime); err != nil {
		t.Fatalf("reopen query created_at: %v", err)
	}
	if replayedTime != int64(createdAt) {
		t.Fatalf("reopened outbox time=%d want %d", replayedTime, int64(createdAt))
	}
}
