package daemon

// v0.8.9 P0 诊断基线（迭代计划 §1 三条故障链的可执行复现）。
//
// 本文件的测试在 P0 时点固化「当前缺陷行为」作为根因证据；P1-P4 修复落地后，
// 各测试断言将被翻转为正确行为并升级为 V089 回归（V089-05/06/10 等），
// 诊断输出经 go test -v 捕获后归档到 e2e-verify/reports/<ts>/V089/（脱敏口径）。
//
// 复现口径（迭代计划 §5 P0）：隔离 Relay SQLite（httptest 假 Relay 模拟删除重建后的空库）
// + 可复用 Daemon state（daemon.db 中保留上一生命周期的 relay_commands/outbox 行）。
// 四个 reset 触发点（owner refresh / owner key rotation / daemon pairing / restart-flutter）
// 都汇聚到 restart.sh reset_default_local_relay_db 的同一机制：Relay 库文件删除重建，
// Daemon 本地状态不处理——因此根因层用「空 Relay + 旧 Daemon state」等价复现。

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/yubi233/agent-sessions/internal/adapter"
)

// v089DiagRelay 是模拟 Relay 的 httptest 服务。
// result404=true 时模拟「删除重建后的空 Relay」：旧命令的 result 请求 404 NOT_FOUND
// （v0.8.8 真实日志中「未建立 SSE 的 404 retry」的服务端形态）；
// result404=false 时回显提交状态（正常存活 Relay 的权威收据契约）。
// helloGeneration / heartbeatGeneration 模拟 Relay 世代字段（v0.8.9 P1）；
// 两者为空时响应不含 relay_generation（旧 Relay legacy 形态）。
type v089DiagRelay struct {
	mu                  sync.Mutex
	result404           bool
	result404s          int
	hellos              int
	streamHits          int
	event404s           int
	helloGeneration     string
	heartbeatGeneration string
	// heartbeatIntervalSeconds 覆盖 hello 返回的心跳周期（默认 15s）；运行期世代
	// 发现回归需要短周期（≥1s）才能在有界测试时间内触发 ticker 分支。
	heartbeatIntervalSeconds int
	ackKinds                 map[string][]string // command_id -> ack kinds（顺序，并发安全快照用 mu）
	// resolvedCommands 记录 command_id -> 提交状态列表（/result 请求轨迹），
	// 用于断言"某命令从未向该 Relay 发起 resolve"。
	resolvedCommands map[string][]string
	server           *httptest.Server
	// sseCommands 是 SSE 待投递队列；Stream 命中后按序推出（诊断只关心 reader 到达时序）。
	sseCommands chan string
}

func newV089DiagRelay(t *testing.T, result404 bool) *v089DiagRelay {
	t.Helper()
	r := &v089DiagRelay{result404: result404, ackKinds: map[string][]string{}, resolvedCommands: map[string][]string{}, sseCommands: make(chan string, 16)}
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/daemon/hello", func(w http.ResponseWriter, req *http.Request) {
		r.mu.Lock()
		r.hellos++
		generation := r.helloGeneration
		interval := r.heartbeatIntervalSeconds
		r.mu.Unlock()
		if interval <= 0 {
			interval = 15
		}
		w.Header().Set("Content-Type", "application/json")
		body := fmt.Sprintf(`{"terminal_id":"term-v089-new","protocol_version":1,"min_protocol_version":1,"heartbeat_interval_seconds":%d,"after_delivery_seq":0`, interval)
		if generation != "" {
			body += fmt.Sprintf(`,"relay_generation":%q`, generation)
		}
		body += `}`
		_, _ = io.WriteString(w, body)
	})
	mux.HandleFunc("/v1/daemon/heartbeat", func(w http.ResponseWriter, req *http.Request) {
		r.mu.Lock()
		generation := r.heartbeatGeneration
		r.mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		body := `{}`
		if generation != "" {
			body = fmt.Sprintf(`{"terminal_id":"term-v089-new","server_time_unix_ms":0,"relay_generation":%q}`, generation)
		}
		_, _ = io.WriteString(w, body)
	})
	mux.HandleFunc("/v1/daemon/sessions/recover", func(w http.ResponseWriter, req *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, `{"recovered_idle":0,"recovered_stopped":0}`)
	})
	mux.HandleFunc("/v1/daemon/events", func(w http.ResponseWriter, req *http.Request) {
		// 删除重建后的 Relay 不认识旧 session/command：事件上传 404（故障链三）。
		r.mu.Lock()
		r.event404s++
		r.mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusNotFound)
		_, _ = io.WriteString(w, `{"code":"NOT_FOUND","message":"unknown session or command"}`)
	})
	mux.HandleFunc("/v1/daemon/commands/", func(w http.ResponseWriter, req *http.Request) {
		path := req.URL.Path
		// 路径形态：/v1/daemon/commands/{command_id}/ack|result|stream。
		// command_id 只在 URL 路径中，请求体不回带（与 RelayClient 现有契约一致）。
		commandID := path
		commandID = strings.TrimPrefix(commandID, "/v1/daemon/commands/")
		if i := strings.Index(commandID, "/"); i >= 0 {
			commandID = commandID[:i]
		}
		switch {
		case strings.HasSuffix(path, "/stream"):
			r.mu.Lock()
			r.streamHits++
			r.mu.Unlock()
			w.Header().Set("Content-Type", "text/event-stream")
			w.WriteHeader(http.StatusOK)
			if flusher, ok := w.(http.Flusher); ok {
				flusher.Flush()
			}
			for {
				select {
				case cmd := <-r.sseCommands:
					_, _ = fmt.Fprintf(w, "event: command\ndata: %s\n\n", cmd)
					if flusher, ok := w.(http.Flusher); ok {
						flusher.Flush()
					}
				case <-req.Context().Done():
					return
				}
			}
		case strings.HasSuffix(path, "/ack"):
			var body struct {
				AckKind string `json:"ack_kind"`
			}
			_ = json.NewDecoder(req.Body).Decode(&body)
			r.mu.Lock()
			r.ackKinds[commandID] = append(r.ackKinds[commandID], body.AckKind)
			r.mu.Unlock()
			w.Header().Set("Content-Type", "application/json")
			_, _ = io.WriteString(w, `{}`)
		case strings.HasSuffix(path, "/result"):
			var body struct {
				DeliverySeq int64  `json:"delivery_seq"`
				Status      string `json:"status"`
			}
			_ = json.NewDecoder(req.Body).Decode(&body)
			r.mu.Lock()
			should404 := r.result404
			r.result404s++
			r.resolvedCommands[commandID] = append(r.resolvedCommands[commandID], body.Status)
			r.mu.Unlock()
			w.Header().Set("Content-Type", "application/json")
			if should404 {
				// 空 Relay：命令不存在（世代错位的确定性 404）。
				w.WriteHeader(http.StatusNotFound)
				_, _ = io.WriteString(w, `{"code":"NOT_FOUND","message":"command not found"}`)
				return
			}
			// 存活 Relay 的权威收据：回显提交状态（resolveAndPersist 以回显为准）。
			_, _ = fmt.Fprintf(w, `{"command_id":%q,"delivery_seq":%d,"status":%q,"error_code":""}`,
				commandID, body.DeliverySeq, body.Status)
		default:
			w.WriteHeader(http.StatusNotFound)
			_, _ = io.WriteString(w, `{"code":"NOT_FOUND"}`)
		}
	})
	r.server = httptest.NewServer(mux)
	t.Cleanup(r.server.Close)
	return r
}

func (r *v089DiagRelay) snapshot() (result404s, hellos, streamHits, event404s int) {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.result404s, r.hellos, r.streamHits, r.event404s
}

// hasAck 并发安全地返回某命令是否已收到过任一 ack。
func (r *v089DiagRelay) hasAck(commandID string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	return len(r.ackKinds[commandID]) > 0
}

// resolveAttempts 并发安全地返回某命令向该 Relay 发起 /result 的次数。
func (r *v089DiagRelay) resolveAttempts(commandID string) int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return len(r.resolvedCommands[commandID])
}

// newDiagLogger 把 slog 诊断行打上 V089-EVIDENCE 前缀进测试日志，供报告归档提取。
func newDiagLogger(t *testing.T) *slog.Logger {
	return slog.New(slog.NewTextHandler(evidenceWriter{t: t}, nil))
}

type evidenceWriter struct{ t *testing.T }

func (w evidenceWriter) Write(p []byte) (int, error) {
	w.t.Logf("V089-EVIDENCE %s", strings.TrimRight(string(p), "\n"))
	return len(p), nil
}

// V089-05（P2 修复后翻转断言）：故障链一的修复回归。Relay DB 重建后，本地残留 started
// 命令对空 Relay resolve 404——按 §3.3 legacy 口径（Relay 不报告 generation）本地收口为
// completed/result_status=failed/RELAY_GENERATION_RESET，processPending 取得进展，
// RunWithRetry 正常进入 SSE（stream_hits≥1），不再无限退避重试。
func TestV089StaleCommand404ConvergesLocallyAndEntersSSE(t *testing.T) {
	store, err := OpenStore(filepath.Join(t.TempDir(), "daemon.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	// 可复用 Daemon state：上一生命周期的 Terminal 身份与 started 命令残留。
	if err := store.Set("terminal_id", "term-v089-old"); err != nil {
		t.Fatal(err)
	}
	stale := RelayCommand{
		CommandID: "cmd-v089-stale-send", DeliverySeq: 7, SessionID: "sess-v089-old", WorkspaceID: "ws-v089-old",
		Kind: "session.send", LeaseEpoch: 1, TargetTerminalID: "term-v089-old",
		PayloadJSON: `{"session_id":"sess-v089-old"}`,
	}
	if inserted, err := store.RecordRelayCommand(stale); err != nil || !inserted {
		t.Fatalf("seed stale command: inserted=%v err=%v", inserted, err)
	}
	if err := store.MarkRelayCommandStarted(stale.CommandID); err != nil {
		t.Fatal(err)
	}

	// legacy Relay：hello 不返回 generation（本机世代为空），404 走 legacy 收口口径。
	relay := newV089DiagRelay(t, true)
	guard := &startGuardAdapter{}
	runner := NewSessionRunner(store, map[string]adapter.Adapter{"test": guard}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	defer runner.Close(context.Background())
	loop := NewRelayLoop(store, &RelayClient{BaseURL: relay.server.URL, AccessToken: "fixture"}, runner, nil, newDiagLogger(t))

	ctx, cancel := context.WithTimeout(context.Background(), 900*time.Millisecond)
	defer cancel()
	if err := loop.RunWithRetry(ctx); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("RunWithRetry 应存活至观察窗结束（进入 SSE 后等待），got %v", err)
	}
	result404s, _, streamHits, _ := relay.snapshot()
	t.Logf("V089-EVIDENCE V089-05: resolve_404_hits=%d stream_hits=%d local_cmd=failed/RELAY_GENERATION_RESET", result404s, streamHits)

	// 本地命令已收口为固定错误码终态（不新增 wire 终态）。
	stored, err := store.RelayCommandByID(stale.CommandID)
	if err != nil {
		t.Fatal(err)
	}
	if stored.Status != "completed" || stored.ResultStatus != "failed" || stored.ErrorCode != RelayGenerationResetErrorCode {
		t.Fatalf("stale command must converge to failed/RELAY_GENERATION_RESET, got %q/%q/%q", stored.Status, stored.ResultStatus, stored.ErrorCode)
	}
	// 404 只发生一次（无重试循环），且 SSE 已进入。
	if result404s != 1 {
		t.Fatalf("stale 404 must converge in one attempt, got %d", result404s)
	}
	if streamHits == 0 {
		t.Fatal("RunWithRetry must proceed to SSE after stale convergence")
	}
}

// V089-06 回滚口径：enforcement 关闭（AGENT_SESSIONS_RELAY_GENERATION_ENFORCEMENT=0）
// 时，404 不被静默清理——保留 v0.8.9 前的退避重试行为（文档化的回滚语义，
// 同时固化"未修复前 404 无限重试"的 P0 历史证据口径）。
func TestV089RollbackSwitchPreservesLegacyRetryLoopOn404(t *testing.T) {
	store, err := OpenStore(filepath.Join(t.TempDir(), "daemon.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if err := store.Set("terminal_id", "term-v089-old"); err != nil {
		t.Fatal(err)
	}
	stale := RelayCommand{
		CommandID: "cmd-v089-rollback", DeliverySeq: 7, SessionID: "sess-v089-old", WorkspaceID: "ws-v089-old",
		Kind: "session.send", LeaseEpoch: 1, TargetTerminalID: "term-v089-old",
		PayloadJSON: `{"session_id":"sess-v089-old"}`,
	}
	if inserted, err := store.RecordRelayCommand(stale); err != nil || !inserted {
		t.Fatalf("seed stale command: inserted=%v err=%v", inserted, err)
	}
	if err := store.MarkRelayCommandStarted(stale.CommandID); err != nil {
		t.Fatal(err)
	}

	relay := newV089DiagRelay(t, true)
	guard := &startGuardAdapter{}
	runner := NewSessionRunner(store, map[string]adapter.Adapter{"test": guard}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	defer runner.Close(context.Background())
	loop := NewRelayLoop(store, &RelayClient{BaseURL: relay.server.URL, AccessToken: "fixture"}, runner, nil, newDiagLogger(t))
	loop.GenerationEnforcementDisabled = true

	ctx, cancel := context.WithTimeout(context.Background(), 650*time.Millisecond)
	defer cancel()
	if err := loop.RunWithRetry(ctx); err == nil {
		t.Fatal("enforcement-off rollback must keep retrying (original error propagates)")
	}
	result404s, _, streamHits, _ := relay.snapshot()
	t.Logf("V089-EVIDENCE V089-06 rollback: observe_window_ms=650 resolve_404_hits=%d stream_hits=%d", result404s, streamHits)
	if result404s < 3 {
		t.Fatalf("rollback switch must preserve retry loop, got %d attempts", result404s)
	}
	if streamHits != 0 {
		t.Fatal("rollback switch must not enter SSE while stale 404 loops")
	}
	stored, err := store.RelayCommandByID(stale.CommandID)
	if err != nil || stored.Status != "started" || stored.ResultStatus != "" {
		t.Fatalf("rollback switch must not close stale command locally: %+v err=%v", stored, err)
	}
}

// 故障链二复现（迭代计划 §1.2）：SSE scanner 同步调用 consume=handleDelivery。
// send 已异步执行（既有行为）但持有 executionMu 等待审批；紧随其后的 mode.set
// 在 executeAndResolve→ConsumeCommand 上等待 executionMu——handleDelivery 阻塞，
// scanner 无法继续读取第三条 permission.approve 投递，形成队头阻塞（控制命令不可达）。
// 修复方向（P3）：scanner 只落盘入队；普通命令进有界 worker；控制命令走优先队列。
func TestV089DiagSSEHeadOfLineBlockingStallsControlCommand(t *testing.T) {
	s, runner, fake := newRunnerFixture(t, "dsh")
	// 预置会话：start 完成后桥 handle 可注入 sendGate（模拟回合等待 DSH 审批）。
	if err := runner.ConsumeCommand(context.Background(), Command{
		Kind: "session.start",
		PayloadJSON: `{"session_id":"sess-v089-hol","workspace_root":"/tmp/ws-v089","provider":"dsh",` +
			`"ciphertext":{"fixture_payload":{"prompt":"开始"}}}`,
	}); err != nil {
		t.Fatalf("consume start: %v", err)
	}
	h := fake.handles[0]
	gate := make(chan struct{})
	h.mu.Lock()
	h.sendGate = gate
	h.mu.Unlock()

	relay := newV089DiagRelay(t, false)
	loop := NewRelayLoop(s, &RelayClient{BaseURL: relay.server.URL, AccessToken: "fixture"}, runner, FixtureEventEncoder{}, newDiagLogger(t))
	loop.Capabilities = []string{"start", "send", "permission_mode", "permission"}
	if err := s.Set("terminal_id", "term-v089-hol"); err != nil {
		t.Fatal(err)
	}

	push := func(seq int64, cmd RelayCommand) {
		wire := fmt.Sprintf(`{"delivery_seq":%d,"command":{"id":%q,"session_id":%q,"workspace_id":%q,"kind":%q,"lease_epoch":1,"target_terminal_id":"term-v089-hol","ciphertext":%s}}`,
			seq, cmd.CommandID, cmd.SessionID, cmd.WorkspaceID, cmd.Kind, cmd.PayloadJSON)
		relay.sseCommands <- wire
	}
	// 三条连续投递：send（等待审批）→ mode.set（会在执行器上排队）→ permission.approve（控制命令）。
	// payload 为 Relay 下行的明文形状 envelope：命令元数据在顶层，语义字段在 ciphertext.fixture_payload。
	push(1, RelayCommand{CommandID: "cmd-hol-send", SessionID: "sess-v089-hol", WorkspaceID: "ws-v089-hol", Kind: "session.send", LeaseEpoch: 1, TargetTerminalID: "term-v089-hol", PayloadJSON: `{"session_id":"sess-v089-hol","ciphertext":{"fixture_payload":{"message":"等审批的消息"}}}`})
	push(2, RelayCommand{CommandID: "cmd-hol-modeset", SessionID: "sess-v089-hol", WorkspaceID: "ws-v089-hol", Kind: "mode.set", LeaseEpoch: 1, TargetTerminalID: "term-v089-hol", PayloadJSON: `{"session_id":"sess-v089-hol","ciphertext":{"fixture_payload":{"mode_id":"acceptEdits"}}}`})
	push(3, RelayCommand{CommandID: "cmd-hol-approve", SessionID: "sess-v089-hol", WorkspaceID: "ws-v089-hol", Kind: "permission.approve", LeaseEpoch: 1, TargetTerminalID: "term-v089-hol", PayloadJSON: `{"session_id":"sess-v089-hol","ciphertext":{"fixture_payload":{"request_id":"call-v089-1"}}}`})

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	streamDone := make(chan error, 1)
	go func() {
		streamDone <- loop.Client.Stream(ctx, 0, loop.handleDelivery)
	}()

	// 等待 send 已在桥上阻塞（executionMu 被异步 send 占住）。
	// 注意：send 命令经 Stream 投递后才执行，必须先启动 reader 再等待。
	deadline := time.Now().Add(3 * time.Second)
	var waiting int
	for {
		h.mu.Lock()
		waiting = h.sendGateWaiters
		h.mu.Unlock()
		if waiting > 0 || time.Now().After(deadline) {
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
	if waiting == 0 {
		t.Fatalf("send 未进入桥阻塞，复现前提不成立")
	}

	// 有界观察：approve 投递应在 bounded 时间内被消费（当前缺陷下不会）。
	const bounded = 1200 * time.Millisecond
	deadline = time.Now().Add(bounded)
	for time.Now().Before(deadline) {
		if relay.hasAck("cmd-hol-approve") {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	approveReachable := relay.hasAck("cmd-hol-approve")
	t.Logf("V089-EVIDENCE 故障链二: bounded_window_ms=%d approve_reachable_within_bound=%v（当前缺陷预期 false）", bounded.Milliseconds(), approveReachable)

	// 放行 send：mode.set 与 approve 依序解阻（证明是队头阻塞而非命令丢失）。
	close(gate)
	deadline = time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if relay.hasAck("cmd-hol-approve") {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	cancel()
	<-streamDone
	if !relay.hasAck("cmd-hol-approve") {
		t.Fatalf("gate 释放后 approve 仍未被消费：队列丢命令")
	}
	if approveReachable {
		t.Fatalf("当前代码预期 approve 在 send+mode.set 阻塞期间不可达（若已可达说明 P3 修复已落地，请翻转断言为 V089-10 回归）")
	}
}

// 故障链三复现（迭代计划 §1.3）：Relay DB 重建后旧 session/command 事件上传全部 404，
// flushEvents 把非 429 的 4xx 一律标记 RELAY_REJECTED_PERMANENT——世代错位的 404 被误判为
// 内容毒丸长期堆积 failed；自动恢复不碰、人工全量 requeue 后又重复 404。
// 修复方向（P4）：outbox 按 generation 过滤，旧世代行 quarantine，不参与 requeue。
func TestV089DiagOldGenerationEventsMisclassifiedAsPermanentPoison(t *testing.T) {
	store, err := OpenStore(filepath.Join(t.TempDir(), "daemon.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	const oldEvents = 3
	for i := 0; i < oldEvents; i++ {
		if err := store.EnqueueRelayEvent(RelayEvent{
			EventID:      fmt.Sprintf("evt-v089-oldgen-%d", i),
			CommandID:    "cmd-v089-oldgen",
			SessionID:    "sess-v089-oldgen",
			EventType:    "message.completed",
			EnvelopeJSON: `{"alg":"fixture-aead","key_id":"fixture","nonce":"n","ciphertext":"c","aad_hash":"h","payload_version":1}`,
		}); err != nil {
			t.Fatal(err)
		}
	}
	relay := newV089DiagRelay(t, false)
	loop := &RelayLoop{
		Store:  store,
		Client: &RelayClient{BaseURL: relay.server.URL, AccessToken: "fixture"},
		Logger: newDiagLogger(t),
	}
	// 第一轮 flush：全部 404 → RELAY_REJECTED_PERMANENT（世代错位被误判为内容毒丸）。
	if err := loop.flushEvents(context.Background()); err != nil {
		t.Fatalf("flushEvents: %v", err)
	}
	snapshot, err := store.RelayEventOutboxSnapshot()
	if err != nil {
		t.Fatal(err)
	}
	failed := 0
	for _, row := range snapshot {
		if row.Status == "failed" && row.LastError == relayEventPermanentReject {
			failed++
		}
	}
	// 自动恢复（hello 成功后调用）不恢复毒丸——行为保持，但本轮 404 的根因是世代错位而非内容。
	if requeued, err := store.RequeueTransientFailedRelayEvents(); err != nil || requeued != 0 {
		t.Fatalf("transient requeue 应跳过 permanent 行: requeued=%d err=%v", requeued, err)
	}
	// 人工全量 requeue（既有唯一恢复入口）：旧行重新投递 → 再次全部 404（重复拒绝循环）。
	if requeued, err := store.RequeueFailedRelayEvents(); err != nil || requeued != int64(oldEvents) {
		t.Fatalf("manual requeue: requeued=%d err=%v", requeued, err)
	}
	if err := loop.flushEvents(context.Background()); err != nil {
		t.Fatalf("second flushEvents: %v", err)
	}
	_, _, _, event404s := relay.snapshot()
	t.Logf("V089-EVIDENCE 故障链三: old_events=%d first_pass_failed=%d manual_requeue_then_404_total=%d", oldEvents, failed, event404s)
	if failed != oldEvents {
		t.Fatalf("世代错位 404 被误判毒丸的数量=%d want %d", failed, oldEvents)
	}
	if event404s != 2*oldEvents {
		t.Fatalf("人工 requeue 应造成第二轮 404（当前缺陷），总 404=%d want %d", event404s, 2*oldEvents)
	}
}
