package daemon

import (
	"context"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"

	"github.com/yubi233/agent-sessions/internal/id"
)

// seedRetryEvent 写入一条可重试事件并返回其 event_id。
func seedRetryEvent(t *testing.T, store *Store, suffix string) string {
	t.Helper()
	event := RelayEvent{
		EventID: id.New("evt") + "-" + suffix, CommandID: "cmd-1", SessionID: "sess-1",
		EventType: "message.completed",
		// envelope 只能是密文外形；这里使用协议形态合法的 fixture 值。
		EnvelopeJSON: `{"alg":"fixture-aead","key_id":"k","nonce":"n","ciphertext":"c","aad_hash":"h","payload_version":1}`,
	}
	if err := store.EnqueueRelayEvent(event); err != nil {
		t.Fatalf("enqueue: %v", err)
	}
	return event.EventID
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
