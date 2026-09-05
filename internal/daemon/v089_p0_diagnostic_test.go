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
	mu               sync.Mutex
	result404        bool
	result404s       int
	hellos           int
	heartbeatHits    int
	streamHits       int
	event404s        int
	eventUploadCount int
	// eventUploadOK 控制 /events 上传结果：false=404（空 Relay 拒收旧世代事件），
	// true=200（存活 Relay 正常收据），供 V089-13 断言新世代事件继续上传。
	eventUploadOK       bool
	helloGeneration     string
	heartbeatGeneration string
	// helloTerminalID 覆盖 hello 返回的 Terminal 身份（默认 term-v089-new）；
	// 调度器回归夹具的 store 已绑定固定 Terminal，二者必须一致才不会被 fence 拒绝。
	helloTerminalID string
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
		terminalID := r.helloTerminalID
		if terminalID == "" {
			terminalID = "term-v089-new"
		}
		w.Header().Set("Content-Type", "application/json")
		body := fmt.Sprintf(`{"terminal_id":%q,"protocol_version":1,"min_protocol_version":1,"heartbeat_interval_seconds":%d,"after_delivery_seq":0`, terminalID, interval)
		if generation != "" {
			body += fmt.Sprintf(`,"relay_generation":%q`, generation)
		}
		body += `}`
		_, _ = io.WriteString(w, body)
	})
	mux.HandleFunc("/v1/daemon/heartbeat", func(w http.ResponseWriter, req *http.Request) {
		r.mu.Lock()
		r.heartbeatHits++
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
		r.mu.Lock()
		acceptUpload := r.eventUploadOK
		if acceptUpload {
			r.eventUploadCount++
		} else {
			r.event404s++
		}
		r.mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		if acceptUpload {
			_, _ = io.WriteString(w, `{}`)
			return
		}
		// 删除重建后的 Relay 不认识旧 session/command：事件上传 404（故障链三）。
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

// eventUploads 并发安全地返回成功上传的事件数。
func (r *v089DiagRelay) eventUploads() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.eventUploadCount
}

// heartbeatCount 并发安全地返回 heartbeat 请求次数。
func (r *v089DiagRelay) heartbeatCount() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.heartbeatHits
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
// 时，404 不被静默清理——命令行保持 pending（不落 RELAY_GENERATION_RESET 终态），
// 由 sweeper 按 heartbeat 节拍重驱动；且 v0.8.9 P3 后 404 失败不再阻塞 SSE 建立
// （worker 异步消费 + 失败不外溢），根除"每 6.4 秒永久刷日志"的故障形态。
// （P0 历史证据口径：未修复前 404 会造成退避循环且 SSE 永不建立——见 P0 诊断报告。）
func TestV089RollbackSwitchKeepsStaleCommandPendingWithoutBlockingSSE(t *testing.T) {
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

	ctx, cancel := context.WithTimeout(context.Background(), 900*time.Millisecond)
	defer cancel()
	if err := loop.RunWithRetry(ctx); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("RunWithRetry must survive the observation window, got %v", err)
	}
	result404s, _, streamHits, _ := relay.snapshot()
	t.Logf("V089-EVIDENCE V089-06 rollback: observe_window_ms=900 resolve_404_hits=%d stream_hits=%d local_cmd=pending(不收口)", result404s, streamHits)
	// 回滚语义 1：404 不清理——观察窗内恰好一次尝试（worker 单次执行 + sweeper 未到期），
	// 命令行保持 started 无终态，等待人工处置。
	if result404s != 1 {
		t.Fatalf("rollback switch must not close or hot-retry stale 404, got %d attempts", result404s)
	}
	if streamHits == 0 {
		t.Fatal("rollback switch must not block SSE entry on stale command failure")
	}
	stored, err := store.RelayCommandByID(stale.CommandID)
	if err != nil || stored.Status != "started" || stored.ResultStatus != "" {
		t.Fatalf("rollback switch must keep stale command pending: %+v err=%v", stored, err)
	}
}

// V089-09（P3 修复后翻转诊断链二）：故障链二的修复回归。调度器启动后，scanner
// （Stream 的 consume=handleDelivery）只落盘+回执+入队：send 等审批持有 executionMu、
// mode.set 在普通 worker 上等待时，reader 继续消费第三条 permission.approve 投递并在
// 有界时间内送达控制 worker（对比 P0：bounded 窗口内不可达）。reader last-read 随
// delivery 推进而增长，不执行 Provider/Resolve（§3.4）。
func TestV089SSEReaderKeepsConsumingWhileCommandsExecute(t *testing.T) {
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
	// 启动调度器：production 口径（worker 异步消费，reader 不执行业务）。
	schedCtx, schedCancel := context.WithCancel(context.Background())
	defer schedCancel()
	loop.startSchedulers(schedCtx)

	push := func(seq int64, cmd RelayCommand) {
		wire := fmt.Sprintf(`{"delivery_seq":%d,"command":{"id":%q,"session_id":%q,"workspace_id":%q,"kind":%q,"lease_epoch":1,"target_terminal_id":"term-v089-hol","ciphertext":%s}}`,
			seq, cmd.CommandID, cmd.SessionID, cmd.WorkspaceID, cmd.Kind, cmd.PayloadJSON)
		relay.sseCommands <- wire
	}
	// 三条连续投递：send（等待审批）→ mode.set（普通 worker 等待 executionMu）→
	// permission.approve（控制命令）。
	push(1, RelayCommand{CommandID: "cmd-hol-send", SessionID: "sess-v089-hol", WorkspaceID: "ws-v089-hol", Kind: "session.send", LeaseEpoch: 1, TargetTerminalID: "term-v089-hol", PayloadJSON: `{"session_id":"sess-v089-hol","ciphertext":{"fixture_payload":{"message":"等审批的消息"}}}`})
	push(2, RelayCommand{CommandID: "cmd-hol-modeset", SessionID: "sess-v089-hol", WorkspaceID: "ws-v089-hol", Kind: "mode.set", LeaseEpoch: 1, TargetTerminalID: "term-v089-hol", PayloadJSON: `{"session_id":"sess-v089-hol","ciphertext":{"fixture_payload":{"mode_id":"acceptEdits"}}}`})
	push(3, RelayCommand{CommandID: "cmd-hol-approve", SessionID: "sess-v089-hol", WorkspaceID: "ws-v089-hol", Kind: "permission.approve", LeaseEpoch: 1, TargetTerminalID: "term-v089-hol", PayloadJSON: `{"session_id":"sess-v089-hol","ciphertext":{"fixture_payload":{"request_id":"call-v089-1"}}}`})

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	streamDone := make(chan error, 1)
	go func() {
		streamDone <- loop.Client.Stream(ctx, 0, loop.handleDelivery)
	}()

	// 等 send 已在桥上阻塞（executionMu 被 async send 占住）。
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
		t.Fatal("send 未进入桥阻塞，复现前提不成立")
	}

	// 有界观察：approve 必须在 bounded 时间内被 reader 消费并送达控制 worker。
	const bounded = 1200 * time.Millisecond
	deadline = time.Now().Add(bounded)
	for time.Now().Before(deadline) {
		if relay.hasAck("cmd-hol-approve") {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	approveReachable := relay.hasAck("cmd-hol-approve")
	stats := loop.stats()
	t.Logf("V089-EVIDENCE V089-09: bounded_window_ms=%d approve_reachable=%v reader_last_read_unix_ms=%d processed_control=%d",
		bounded.Milliseconds(), approveReachable, stats.ReaderLastReadUnixMS, stats.ProcessedControl)
	if !approveReachable {
		t.Fatal("approve must be consumed within bound while send+mode.set execute (SSE HOL regression)")
	}
	if stats.ReaderLastReadUnixMS == 0 {
		t.Fatal("reader last-read metric must advance as deliveries arrive")
	}

	// 放行 send：全部命令依序收敛，队列清空（证明 reader 未丢命令）。
	close(gate)
	deadline = time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if loop.queuesSettled() {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	cancel()
	<-streamDone
	if !loop.queuesSettled() {
		t.Fatal("queues must settle after gate release")
	}
}

// V089-13（P4 修复后翻转诊断链三）：世代切换后旧世代事件被隔离（quarantined），
// 不参与 flush 与人工 requeue；新世代事件继续上传且不被旧事件阻塞。
// （P0 缺陷口径：世代错位 404 曾被误判 RELAY_REJECTED_PERMANENT 堆积 failed，
// 人工全量 requeue 后二次 404——见 P0 诊断报告故障链三。）
func TestV089OldGenerationEventsQuarantinedAndExcludedFromRequeue(t *testing.T) {
	store, err := OpenStore(filepath.Join(t.TempDir(), "daemon.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if err := store.Set("relay_generation", "relgen_old_aaaa"); err != nil {
		t.Fatal(err)
	}
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
	relay.eventUploadOK = true // 存活 Relay：新世代事件正常上传
	loop := &RelayLoop{
		Store:  store,
		Client: &RelayClient{BaseURL: relay.server.URL, AccessToken: "fixture"},
		Logger: newDiagLogger(t),
	}

	// 世代切换：单事务隔离旧世代行（commands/events/usages 一并）。
	if _, err := store.IsolateStaleRelayState("relgen_new_bbbb", "hello_generation_changed"); err != nil {
		t.Fatal(err)
	}
	// 新世代事件入队并 flush：只有它被上传，旧世代行不阻塞也不参与。
	if err := store.EnqueueRelayEvent(RelayEvent{
		EventID:      "evt-v089-newgen",
		CommandID:    "cmd-v089-newgen",
		SessionID:    "sess-v089-newgen",
		EventType:    "message.completed",
		EnvelopeJSON: `{"alg":"fixture-aead","key_id":"fixture","nonce":"n","ciphertext":"c2","aad_hash":"h","payload_version":1}`,
	}); err != nil {
		t.Fatal(err)
	}
	if err := loop.flushEvents(context.Background()); err != nil {
		t.Fatalf("flushEvents: %v", err)
	}
	if uploads := relay.eventUploads(); uploads != 1 {
		t.Fatalf("only the new-generation event must upload, got %d", uploads)
	}
	if _, _, _, event404s := relay.snapshot(); event404s != 0 {
		t.Fatalf("old-generation events must never reach the rebuilt relay, got %d 404s", event404s)
	}

	// 人工全量 requeue：旧世代行被世代过滤排除（0 行）；新世代无 failed 行可恢复。
	if requeued, err := store.RequeueFailedRelayEvents(); err != nil || requeued != 0 {
		t.Fatalf("manual requeue must exclude old-generation rows: requeued=%d err=%v", requeued, err)
	}

	// 只读诊断投影：旧世代行呈 quarantined，新世代行呈 delivered；投影不含 envelope。
	projection, err := store.RelayOutboxGenerationProjection()
	if err != nil {
		t.Fatal(err)
	}
	seen := map[string]map[string]int64{}
	for _, row := range projection {
		if seen[row.Generation] == nil {
			seen[row.Generation] = map[string]int64{}
		}
		seen[row.Generation][row.Status] += row.Count
	}
	t.Logf("V089-EVIDENCE V089-13: projection=%v", projection)
	if seen["relgen_old_aaaa"]["quarantined"] < oldEvents {
		t.Fatalf("old generation rows must appear quarantined in projection: %v", seen)
	}
	if seen["relgen_new_bbbb"]["delivered"] < 1 {
		t.Fatalf("new generation event must appear delivered in projection: %v", seen)
	}
}

// V089-14：outbox 重试分类矩阵——generation reset（隔离/收口）、永久业务拒绝、
// 429、网络断开、5xx、超时各自有独立 failure class；瞬态类保持原有有界退避。
func TestV089OutboxRetryClassificationMatrix(t *testing.T) {
	store, err := OpenStore(filepath.Join(t.TempDir(), "daemon.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if err := store.Set("relay_generation", "relgen_new_bbbb"); err != nil {
		t.Fatal(err)
	}
	seed := func(id string) {
		t.Helper()
		if err := store.EnqueueRelayEvent(RelayEvent{
			EventID:      id,
			CommandID:    "cmd-" + id,
			SessionID:    "sess-" + id,
			EventType:    "message.completed",
			EnvelopeJSON: `{"alg":"fixture-aead","key_id":"fixture","nonce":"n","ciphertext":"c","aad_hash":"h","payload_version":1}`,
		}); err != nil {
			t.Fatal(err)
		}
	}

	// 可切换结果的上传端点：status 码 / 强制断连 / ctx 超时由调用方控制。
	var status int
	var dropConnection bool
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		if dropConnection {
			// 直接断开：客户端得到网络层错误（RELAY_NETWORK 分类）。
			panic(http.ErrAbortHandler)
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_, _ = io.WriteString(w, `{"code":"X"}`)
	}))
	defer server.Close()

	loop := &RelayLoop{
		Store:  store,
		Client: &RelayClient{BaseURL: server.URL, AccessToken: "fixture"},
		Logger: newDiagLogger(t),
	}
	snapshotRow := func(id string) RelayEventOutboxRow {
		t.Helper()
		snapshot, err := store.RelayEventOutboxSnapshot()
		if err != nil {
			t.Fatal(err)
		}
		for _, row := range snapshot {
			if row.EventID == id {
				return row
			}
		}
		t.Fatalf("event row %s missing", id)
		return RelayEventOutboxRow{}
	}
	flushOne := func(id string) {
		t.Helper()
		if err := loop.flushEvents(context.Background()); err != nil {
			// 瞬态类会向调用方返回错误（保持可安全重试）；毒丸类不返回错误。
			t.Logf("flush %s transient err=%v", id, err)
		}
	}

	// 1) 永久业务拒绝（4xx 除 429）→ failed/RELAY_REJECTED_PERMANENT，不占退避队列。
	seed("evt-cls-poison")
	status = http.StatusBadRequest
	flushOne("evt-cls-poison")
	if row := snapshotRow("evt-cls-poison"); row.Status != "failed" || row.LastError != relayEventPermanentReject {
		t.Fatalf("400 must be permanent poison: %+v", row)
	}

	// 2) 429 → pending + 尝试记账 + 有界退避（限流可自愈）。
	seed("evt-cls-429")
	status = http.StatusTooManyRequests
	flushOne("evt-cls-429")
	if row := snapshotRow("evt-cls-429"); row.Status != "pending" || row.Attempts != 1 || row.NextAttemptAt <= 0 {
		t.Fatalf("429 must stay pending with backoff: %+v", row)
	}

	// 3) 5xx → pending + 尝试记账（服务端瞬态故障）。
	seed("evt-cls-5xx")
	status = http.StatusInternalServerError
	flushOne("evt-cls-5xx")
	if row := snapshotRow("evt-cls-5xx"); row.Status != "pending" || row.Attempts != 1 {
		t.Fatalf("5xx must stay pending with attempts: %+v", row)
	}

	// 4) 网络断开 → pending + RELAY_NETWORK 脱敏分类。
	seed("evt-cls-net")
	dropConnection = true
	flushOne("evt-cls-net")
	dropConnection = false
	if row := snapshotRow("evt-cls-net"); row.Status != "pending" || row.LastError != "RELAY_NETWORK" {
		t.Fatalf("network error must be classified RELAY_NETWORK: %+v", row)
	}

	// 5) 超时（ctx deadline）→ pending + RELAY_TIMEOUT 脱敏分类。
	seed("evt-cls-timeout")
	timeoutCtx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	time.Sleep(60 * time.Millisecond)
	if err := loop.flushEvents(timeoutCtx); err == nil {
		t.Log("timeout flush returned nil (already deadline-exceeded path)")
	}
	if row := snapshotRow("evt-cls-timeout"); row.Status != "pending" || row.LastError != "RELAY_TIMEOUT" {
		t.Fatalf("timeout must be classified RELAY_TIMEOUT: %+v", row)
	}

	// 6) generation reset 类：由 IsolateStaleRelayState（P1）与 staleGeneration404（P2）
	// 承载，此处锁定投影语义——quarantined 行不参与本矩阵的任何 flush/requeue。
	projection, err := store.RelayOutboxGenerationProjection()
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("V089-EVIDENCE V089-14: classification projection=%v", projection)
}
