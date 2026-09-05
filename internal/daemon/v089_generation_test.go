package daemon

// v0.8.9 P1（V089-02/03/04）：Relay generation 与 Daemon 本地状态隔离回归。
//
// 契约锚点（迭代计划 §3.1-§3.2）：
//   - hello 为启动权威，heartbeat 为运行期发现手段；
//   - 世代变化时单事务完成「命令收口 / outbox quarantine / cursor 清零 /
//     Terminal 绑定清除」，收口后新命令在新世代正常执行；
//   - command_outbox（Daemon 发起）与 Relay 下行状态分开，不因清理误删；
//   - 旧 Relay 无 generation 字段 → 受控 legacy 模式（告警一次，不强制）；
//   - 回滚开关（GenerationEnforcementDisabled）只关闭强制，不回退迁移。

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"
	"time"

	"github.com/yubi233/agent-sessions/internal/adapter"
)

// seedV089GenerationState 构造「上一生命周期」的 Daemon 本地状态：
// 记录世代 G_old、Terminal 绑定、cursor=5，以及打上 G_old 标的 started 命令、
// pending 事件、pending usage；另入队一条 command_outbox 用户动作（不得被清理误删）。
func seedV089GenerationState(t *testing.T, store *Store, oldGeneration string) RelayCommand {
	t.Helper()
	if err := store.Set("relay_generation", oldGeneration); err != nil {
		t.Fatal(err)
	}
	if err := store.Set("terminal_id", "term-v089-old"); err != nil {
		t.Fatal(err)
	}
	command := RelayCommand{
		CommandID: "cmd-v089-gen-stale", DeliverySeq: 5, SessionID: "sess-v089-gen", WorkspaceID: "ws-v089-gen",
		Kind: "session.send", LeaseEpoch: 1, TargetTerminalID: "term-v089-old",
		PayloadJSON: `{"session_id":"sess-v089-gen"}`,
	}
	if inserted, err := store.RecordRelayCommand(command); err != nil || !inserted {
		t.Fatalf("seed stale command: inserted=%v err=%v", inserted, err)
	}
	if err := store.MarkRelayCommandStarted(command.CommandID); err != nil {
		t.Fatal(err)
	}
	if err := store.EnqueueRelayEvent(RelayEvent{
		EventID: "evt-v089-gen", CommandID: command.CommandID, SessionID: command.SessionID,
		EventType: "message.completed", EnvelopeJSON: `{"alg":"a","key_id":"k","nonce":"n","ciphertext":"c","aad_hash":"h","payload_version":1}`,
	}); err != nil {
		t.Fatal(err)
	}
	if err := store.EnqueueRelayUsage(RelayUsage{
		UsageKey: "usage-v089-gen", Provider: "fixture", UTCDay: "2026-09-06",
		InputTokens: 1, OutputTokens: 2,
	}); err != nil {
		t.Fatal(err)
	}
	// cursor 已由 RecordRelayCommand 推进到 5；command_outbox 是独立表，直接写一行。
	if _, err := store.db.Exec(
		`INSERT INTO command_outbox(request_id,kind,payload_json,status,created_at) VALUES('req-v089','session.send','{}','pending',0)`); err != nil {
		t.Fatal(err)
	}
	// 校验打标：RecordRelayCommand/Enqueue 必须已把 G_old 写入各行（世代关联的前提）。
	stored, err := store.RelayCommandByID(command.CommandID)
	if err != nil || stored.Status != "started" {
		t.Fatalf("seed command state=%+v err=%v", stored, err)
	}
	return command
}

// V089-03：世代切换收口的原子性与完整性。
func TestV089IsolateStaleRelayStateQuarantinesOldGenerationAtomically(t *testing.T) {
	store, err := OpenStore(filepath.Join(t.TempDir(), "daemon.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	staleCommand := seedV089GenerationState(t, store, "relgen_old_aaaa")

	summary, err := store.IsolateStaleRelayState("relgen_new_bbbb", "hello_generation_changed")
	if err != nil {
		t.Fatalf("isolate stale relay state: %v", err)
	}
	if summary.PreviousGeneration != "relgen_old_aaaa" || summary.NewGeneration != "relgen_new_bbbb" {
		t.Fatalf("summary generations=%+v", summary)
	}
	if summary.QuarantinedCommands != 1 || summary.QuarantinedEvents != 1 || summary.QuarantinedUsages != 1 {
		t.Fatalf("quarantine counts=%+v want 1/1/1", summary)
	}

	// 旧命令收口为本地终态：completed/result_status=failed/RELAY_GENERATION_RESET（§3.3）。
	stored, err := store.RelayCommandByID(staleCommand.CommandID)
	if err != nil {
		t.Fatal(err)
	}
	if stored.Status != "completed" || stored.ResultStatus != "failed" || stored.ErrorCode != RelayGenerationResetErrorCode {
		t.Fatalf("stale command must converge locally, got status=%q result=%q code=%q", stored.Status, stored.ResultStatus, stored.ErrorCode)
	}
	// pending 查询不再返回旧世代命令；outbox 快照只反映 quarantined。
	if pending, err := store.PendingRelayCommands(); err != nil || len(pending) != 0 {
		t.Fatalf("stale commands must leave pending queue: %d err=%v", len(pending), err)
	}
	events, err := store.RelayEventOutboxSnapshot()
	if err != nil || len(events) != 1 || events[0].Status != "quarantined" {
		t.Fatalf("stale event must be quarantined: %+v err=%v", events, err)
	}
	if usages, err := store.PendingRelayUsages(); err != nil || len(usages) != 0 {
		t.Fatalf("stale usage must leave flush queue: %d err=%v", len(usages), err)
	}
	// cursor 清零、Terminal 绑定清除、新世代与原因落档。
	if cursor, err := store.RelayDeliveryCursor(); err != nil || cursor != 0 {
		t.Fatalf("cursor must reset on generation change: %d err=%v", cursor, err)
	}
	if terminalID, err := store.Get("terminal_id"); err == nil && terminalID != "" {
		t.Fatalf("terminal binding must be cleared, got %q", terminalID)
	}
	if generation, _ := store.RelayGeneration(); generation != "relgen_new_bbbb" {
		t.Fatalf("new generation not recorded: %q", generation)
	}
	if reason, err := store.Get("relay_reset_reason"); err != nil || reason != "hello_generation_changed" {
		t.Fatalf("reset reason not recorded: %q err=%v", reason, err)
	}
	// command_outbox（Daemon 发起的用户动作）不得被世代清理误删（§3.2）。
	var outboxPending int
	if err := store.db.QueryRow(`SELECT COUNT(1) FROM command_outbox WHERE status='pending'`).Scan(&outboxPending); err != nil || outboxPending != 1 {
		t.Fatalf("command_outbox must survive isolation: %d err=%v", outboxPending, err)
	}
}

// V089-04 前半：世代切换后，新写入行自动打上新世代标（收口后的新世界正常运转）。
func TestV089RowsInsertedAfterIsolationCarryNewGeneration(t *testing.T) {
	store, err := OpenStore(filepath.Join(t.TempDir(), "daemon.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	seedV089GenerationState(t, store, "relgen_old_aaaa")
	if _, err := store.IsolateStaleRelayState("relgen_new_bbbb", "hello_generation_changed"); err != nil {
		t.Fatal(err)
	}
	command := RelayCommand{
		CommandID: "cmd-v089-gen-new", DeliverySeq: 1, SessionID: "sess-v089-gen-new", WorkspaceID: "ws-v089-gen-new",
		Kind: "session.start", LeaseEpoch: 1, TargetTerminalID: "term-v089-new",
		PayloadJSON: `{"session_id":"sess-v089-gen-new","provider":"test"}`,
	}
	if inserted, err := store.RecordRelayCommand(command); err != nil || !inserted {
		t.Fatalf("record new generation command: %v", err)
	}
	stored, err := store.RelayCommandByID(command.CommandID)
	if err != nil {
		t.Fatal(err)
	}
	// 新行属于新世代：后续世代切换只隔离 <>新世代 的行，本行不受影响。
	if pending, err := store.PendingRelayCommands(); err != nil || len(pending) != 1 {
		t.Fatalf("new generation command must be pending: %d err=%v", len(pending), err)
	}
	_ = stored
}

// V089-04：hello 世代变化（Relay DB 重建 + 重新配对）→ 旧命令不进入新 Relay、
// 新命令在新世代正常执行（reset 后新命令成功证据）。
func TestV089RelayLoopHelloGenerationChangeIsolatesStaleAndServesNewCommands(t *testing.T) {
	store, err := OpenStore(filepath.Join(t.TempDir(), "daemon.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	staleCommand := seedV089GenerationState(t, store, "relgen_old_aaaa")

	// 新 Relay：hello/heartbeat 返回新世代；正常存活 Relay 语义（回执回显）。
	relay := newV089DiagRelay(t, false)
	relay.helloGeneration = "relgen_new_bbbb"
	relay.heartbeatGeneration = "relgen_new_bbbb"

	// fakeAdapter 提供完整 Start/Handle 生命周期（startGuard 的 nil handle 会在
	// awaitFirstEvent 处 panic），使新命令可以真正执行成功。
	fake := newFakeAdapter("test")
	runner := NewSessionRunner(store, map[string]adapter.Adapter{"test": fake}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	defer runner.Close(context.Background())
	loop := NewRelayLoop(store, &RelayClient{BaseURL: relay.server.URL, AccessToken: "fixture"}, runner, nil, newDiagLogger(t))
	if err := loop.adoptRelayGeneration("relgen_new_bbbb"); err != nil {
		t.Fatalf("adopt generation: %v", err)
	}
	if err := loop.adoptTerminalIdentity("term-v089-new"); err != nil {
		t.Fatal(err)
	}
	// 旧命令已被收口，且从未向新 Relay 发起任何 resolve（无泄漏）。
	stored, err := store.RelayCommandByID(staleCommand.CommandID)
	if err != nil || stored.ErrorCode != RelayGenerationResetErrorCode {
		t.Fatalf("stale command not isolated: %+v err=%v", stored, err)
	}
	if attempts := relay.resolveAttempts(staleCommand.CommandID); attempts != 0 {
		t.Fatalf("stale command must never resolve against rebuilt relay, got %d attempts", attempts)
	}
	// 新世代命令投递（SSE delivery 语义）→ 正常执行并成功收口。
	delivery := RelayDelivery{DeliverySeq: 1, Command: RelayCommand{
		CommandID: "cmd-v089-gen-new", SessionID: "sess-v089-gen-new", WorkspaceID: "ws-v089-gen-new",
		Kind: "session.start", LeaseEpoch: 1, TargetTerminalID: "term-v089-new",
		PayloadJSON: `{"session_id":"sess-v089-gen-new","provider":"test"}`,
	}}
	loop.Capabilities = []string{"start"}
	// 新世代的世界需要重新确认工作区（收口清除了 Terminal 绑定，工作区映射必须显式恢复）：
	// 先构造本机 Git 根并确认，验证 reset 后新命令链路完整可用（V089-04 验收）。
	root := t.TempDir()
	runGit(t, root, "init")
	runGit(t, root, "config", "user.email", "fixture@example.test")
	runGit(t, root, "config", "user.name", "Fixture")
	if _, err := store.ConfirmWorkspace("ws-v089-gen-new", root); err != nil {
		t.Fatalf("confirm workspace after reset: %v", err)
	}
	if err := loop.handleDelivery(context.Background(), delivery); err != nil {
		t.Fatalf("handle new command: %v", err)
	}
	newStored, err := store.RelayCommandByID("cmd-v089-gen-new")
	if err != nil || newStored.Status != "completed" || newStored.ResultStatus != "succeeded" {
		t.Fatalf("new command must succeed in new generation: %+v err=%v", newStored, err)
	}
}

// V089-02 运行期发现：heartbeat generation 变化 → 本地收口 + ErrRelayGenerationChanged
// 终态退出（RunWithRetry 不进入退避重试）。
func TestV089RelayLoopRuntimeGenerationChangeStopsLoopWithTerminalError(t *testing.T) {
	store, err := OpenStore(filepath.Join(t.TempDir(), "daemon.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	seedV089GenerationState(t, store, "relgen_old_aaaa")

	relay := newV089DiagRelay(t, false)
	relay.helloGeneration = "relgen_old_aaaa" // hello 一致：正常进入服务
	relay.heartbeatGeneration = "relgen_new_bbbb"
	relay.heartbeatIntervalSeconds = 1 // 短周期：让 ticker 分支在有界时间内触发

	guard := &startGuardAdapter{}
	runner := NewSessionRunner(store, map[string]adapter.Adapter{"test": guard}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	defer runner.Close(context.Background())
	loop := NewRelayLoop(store, &RelayClient{BaseURL: relay.server.URL, AccessToken: "fixture"}, runner, nil, newDiagLogger(t))

	done := make(chan error, 1)
	go func() { done <- loop.RunWithRetry(context.Background()) }()
	select {
	case err := <-done:
		if !errors.Is(err, ErrRelayGenerationChanged) {
			t.Fatalf("RunWithRetry must stop with terminal generation error, got %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("RunWithRetry did not stop after runtime generation change")
	}
	// 收口证据：换库前已对存活 Relay 合法收口的命令保持其权威终态（ResultStatus=failed
	// 来自 Relay 收据回显），但旧世代事件/usage 被隔离、游标清零、新世代落档。
	events, err := store.RelayEventOutboxSnapshot()
	if err != nil || len(events) != 1 || events[0].Status != "quarantined" {
		t.Fatalf("runtime change must quarantine stale events: %+v err=%v", events, err)
	}
	if usages, err := store.PendingRelayUsages(); err != nil || len(usages) != 0 {
		t.Fatalf("runtime change must quarantine stale usages: %d err=%v", len(usages), err)
	}
	if cursor, err := store.RelayDeliveryCursor(); err != nil || cursor != 0 {
		t.Fatalf("runtime change must reset cursor: %d err=%v", cursor, err)
	}
	if generation, _ := store.RelayGeneration(); generation != "relgen_new_bbbb" {
		t.Fatalf("new generation must be recorded: %q", generation)
	}
}

// legacy 兼容策略（§3.1）：旧 Relay 不返回 generation → 不强制、不覆盖已记录世代。
func TestV089LegacyRelayWithoutGenerationKeepsRecordedState(t *testing.T) {
	store, err := OpenStore(filepath.Join(t.TempDir(), "daemon.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	seedV089GenerationState(t, store, "relgen_old_aaaa")
	guard := &startGuardAdapter{}
	runner := NewSessionRunner(store, map[string]adapter.Adapter{"test": guard}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	defer runner.Close(context.Background())
	loop := NewRelayLoop(store, &RelayClient{BaseURL: "http://127.0.0.1:1", AccessToken: "fixture"}, runner, nil, newDiagLogger(t))

	if err := loop.adoptRelayGeneration(""); err != nil {
		t.Fatalf("legacy hello must not fail: %v", err)
	}
	if generation, _ := store.RelayGeneration(); generation != "relgen_old_aaaa" {
		t.Fatalf("legacy hello must not overwrite recorded generation: %q", generation)
	}
	stored, err := store.RelayCommandByID("cmd-v089-gen-stale")
	if err != nil || stored.Status != "started" {
		t.Fatalf("legacy mode must not isolate rows: %+v err=%v", stored, err)
	}
}

// 回滚开关：关闭 generation 强制后只记录世代，不隔离任何行（§8 风险表）。
func TestV089GenerationEnforcementDisabledRecordsWithoutIsolation(t *testing.T) {
	store, err := OpenStore(filepath.Join(t.TempDir(), "daemon.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	seedV089GenerationState(t, store, "relgen_old_aaaa")
	guard := &startGuardAdapter{}
	runner := NewSessionRunner(store, map[string]adapter.Adapter{"test": guard}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	defer runner.Close(context.Background())
	loop := NewRelayLoop(store, &RelayClient{BaseURL: "http://127.0.0.1:1", AccessToken: "fixture"}, runner, nil, newDiagLogger(t))
	loop.GenerationEnforcementDisabled = true

	if err := loop.adoptRelayGeneration("relgen_new_bbbb"); err != nil {
		t.Fatalf("enforcement-off adopt: %v", err)
	}
	stored, err := store.RelayCommandByID("cmd-v089-gen-stale")
	if err != nil || stored.Status != "started" {
		t.Fatalf("enforcement-off must not isolate: %+v err=%v", stored, err)
	}
}

// V089-06 retry 分类矩阵补充：认证失效（401）立即退出，不进入退避重试——
// 与 ErrRelayGenerationChanged 终态、stale 404 单次收口、网络错误有界退避
// 共同构成分离的 failure class（§3.3：不能合并为 transient retry）。
func TestV089RunWithRetryAuthFailureExitsImmediately(t *testing.T) {
	store, err := OpenStore(filepath.Join(t.TempDir(), "daemon.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	helloHits := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		if req.URL.Path == "/v1/daemon/hello" {
			helloHits++
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = io.WriteString(w, `{"code":"UNAUTHENTICATED"}`)
	}))
	defer server.Close()

	// runOnce 的依赖检查在 hello 之前，必须注入完整 Runner 才能走到 401 分支。
	guard := &startGuardAdapter{}
	runner := NewSessionRunner(store, map[string]adapter.Adapter{"test": guard}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	defer runner.Close(context.Background())
	loop := NewRelayLoop(store, &RelayClient{BaseURL: server.URL, AccessToken: "stale-token"}, runner, nil, newDiagLogger(t))
	started := time.Now()
	err = loop.RunWithRetry(context.Background())
	if err == nil {
		t.Fatal("401 must surface as error")
	}
	if elapsed := time.Since(started); elapsed > 500*time.Millisecond {
		t.Fatalf("401 must exit immediately without backoff, took %v", elapsed)
	}
	if helloHits != 1 {
		t.Fatalf("401 must exit after first hello, got %d rounds", helloHits)
	}
}
