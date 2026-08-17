package relay

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/yubi233/agent-sessions/internal/adapter"
	"github.com/yubi233/agent-sessions/internal/daemon"
	"github.com/yubi233/agent-sessions/internal/domain"
	"github.com/yubi233/agent-sessions/internal/store"
	"github.com/yubi233/agent-sessions/packages/protocol"
)

// DAEMON-RPC-01 / CTRL-04 / SESS-05 / SYNC-05：已配对 Terminal 通过独立 REST+SSE
// 接收命令，确认、结果和 canonical event 都在同一个端到端 Relay fixture 中验证。
func TestP2DaemonCommandLifecycleAndSSERecovery(t *testing.T) {
	env := newTestEnv(t)
	owner := env.registerAs(t, "p2-daemon-lifecycle@test.dev")
	terminal := env.pairTerminal(t, owner, "p2-terminal")
	terminalID := daemonHello(t, env, terminal.AccessToken)

	sessionID, _ := env.createBoundSession(t, owner, terminalID, "p2-lifecycle")
	epoch := p2SessionLeaseEpoch(t, env, owner.AccessToken, sessionID)
	command := env.do(t, http.MethodPost, "/v1/sessions/"+sessionID+"/commands", map[string]any{
		"kind": "session.start", "idempotency_key": "p2-command-1", "lease_epoch": epoch,
		"target_terminal_id": terminalID,
		"ciphertext": map[string]any{
			"kind": "session.start", "session_id": sessionID,
			"ciphertext": map[string]any{"fixture_payload": map[string]any{"provider": "fixture"}},
		},
	}, owner.AccessToken)
	if command.Code != http.StatusAccepted {
		t.Fatalf("submit daemon command status=%d body=%s", command.Code, command.Body.String())
	}
	var submitted struct {
		ID               string `json:"id"`
		TargetTerminalID string `json:"target_terminal_id"`
	}
	decodeW1(t, command.Body.Bytes(), &submitted)
	if submitted.ID == "" || submitted.TargetTerminalID != terminalID {
		t.Fatalf("unexpected command projection: %+v", submitted)
	}

	// 专用 stream 以 delivery_seq 恢复，不借用账号 SSE 的 session event_seq。
	streamBody := streamDaemonOnce(t, env, terminal.AccessToken, 0)
	if !strings.Contains(streamBody, "event: command") || !strings.Contains(streamBody, submitted.ID) || !strings.Contains(streamBody, "id: 1") {
		t.Fatalf("daemon stream missing delivery: %s", streamBody)
	}
	if replay := streamDaemonOnce(t, env, terminal.AccessToken, 1); strings.Contains(replay, submitted.ID) {
		t.Fatalf("daemon stream replayed acknowledged cursor delivery: %s", replay)
	}

	ack := func(kind string) *httptest.ResponseRecorder {
		return env.do(t, http.MethodPost, "/v1/daemon/commands/"+submitted.ID+"/ack", map[string]any{
			"protocol_version": 1, "delivery_seq": 1, "ack_kind": kind,
		}, terminal.AccessToken)
	}
	if response := ack("received"); response.Code != http.StatusOK {
		t.Fatalf("received ack status=%d body=%s", response.Code, response.Body.String())
	}
	if response := ack("started"); response.Code != http.StatusOK {
		t.Fatalf("started ack status=%d body=%s", response.Code, response.Body.String())
	}
	// 同一个 command_id + ack_kind 只能推进一次，重试保持当前 receipt。
	if response := ack("started"); response.Code != http.StatusOK {
		t.Fatalf("idempotent started ack status=%d body=%s", response.Code, response.Body.String())
	}
	// Relay 接口只接受版本化密文 envelope，不能用看似 JSON 合法的正文/路径字段绕过边界。
	plaintextEvent := env.do(t, http.MethodPost, "/v1/daemon/events", map[string]any{
		"protocol_version": 1, "event_id": "evt-p2-plaintext", "command_id": submitted.ID,
		"session_id": sessionID, "event_type": "turn.started",
		"envelope": map[string]any{
			"alg": "fixture", "key_id": "fixture", "nonce": "n", "ciphertext": "opaque", "aad_hash": "a", "payload_version": 1,
			"content": "must-not-reach-relay",
		},
	}, terminal.AccessToken)
	if plaintextEvent.Code != http.StatusBadRequest {
		t.Fatalf("plaintext event status=%d want 400 body=%s", plaintextEvent.Code, plaintextEvent.Body.String())
	}

	eventBody := map[string]any{
		"protocol_version": 1,
		"event_id":         "evt-p2-lifecycle-1",
		"command_id":       submitted.ID,
		"session_id":       sessionID,
		"event_type":       "turn.started",
		"envelope":         opaqueFixtureEnvelope("daemon-event"),
	}
	firstEvent := env.do(t, http.MethodPost, "/v1/daemon/events", eventBody, terminal.AccessToken)
	if firstEvent.Code != http.StatusOK {
		t.Fatalf("event upload status=%d body=%s", firstEvent.Code, firstEvent.Body.String())
	}
	var eventReceipt struct {
		EventSeq   int64 `json:"event_seq"`
		Idempotent bool  `json:"idempotent"`
	}
	decodeW1(t, firstEvent.Body.Bytes(), &eventReceipt)
	if eventReceipt.EventSeq <= 0 || eventReceipt.Idempotent {
		t.Fatalf("first event receipt=%+v", eventReceipt)
	}
	replayEvent := env.do(t, http.MethodPost, "/v1/daemon/events", eventBody, terminal.AccessToken)
	if replayEvent.Code != http.StatusOK {
		t.Fatalf("event replay status=%d body=%s", replayEvent.Code, replayEvent.Body.String())
	}
	var replayReceipt struct {
		EventSeq   int64 `json:"event_seq"`
		Idempotent bool  `json:"idempotent"`
	}
	decodeW1(t, replayEvent.Body.Bytes(), &replayReceipt)
	if !replayReceipt.Idempotent || replayReceipt.EventSeq != eventReceipt.EventSeq {
		t.Fatalf("event replay receipt=%+v first=%+v", replayReceipt, eventReceipt)
	}

	result := env.do(t, http.MethodPost, "/v1/daemon/commands/"+submitted.ID+"/result", map[string]any{
		"protocol_version": 1, "delivery_seq": 1, "status": "succeeded",
	}, terminal.AccessToken)
	if result.Code != http.StatusOK {
		t.Fatalf("result status=%d body=%s", result.Code, result.Body.String())
	}
	got := env.do(t, http.MethodGet, "/v1/commands/"+submitted.ID, nil, owner.AccessToken)
	var commandView struct {
		Status string `json:"status"`
	}
	decodeW1(t, got.Body.Bytes(), &commandView)
	if got.Code != http.StatusOK || commandView.Status != domain.CommandSucceeded {
		t.Fatalf("command after result status=%d view=%+v", got.Code, commandView)
	}
}

// RELAY-LEASE-03：Daemon 在命令已经发出、Android 控制权已换代后不能以旧 epoch 启动执行。
func TestP2DaemonRejectsStaleLeaseBeforeStart(t *testing.T) {
	env := newTestEnv(t)
	owner := env.registerAs(t, "p2-daemon-stale@test.dev")
	terminal := env.pairTerminal(t, owner, "p2-stale-terminal")
	terminalID := daemonHello(t, env, terminal.AccessToken)
	sessionID, _ := env.createBoundSession(t, owner, terminalID, "p2-stale")
	epoch := p2SessionLeaseEpoch(t, env, owner.AccessToken, sessionID)

	command := env.do(t, http.MethodPost, "/v1/sessions/"+sessionID+"/commands", map[string]any{
		"kind": "session.abort", "idempotency_key": "p2-stale-command", "lease_epoch": epoch,
		"target_terminal_id": terminalID, "ciphertext": map[string]any{"kind": "session.abort", "session_id": sessionID},
	}, owner.AccessToken)
	var submitted struct {
		ID string `json:"id"`
	}
	decodeW1(t, command.Body.Bytes(), &submitted)
	if command.Code != http.StatusAccepted || submitted.ID == "" {
		t.Fatalf("submit stale command status=%d body=%s", command.Code, command.Body.String())
	}
	if next := p2SessionLeaseEpoch(t, env, owner.AccessToken, sessionID); next != epoch+1 {
		t.Fatalf("lease epoch=%d want %d", next, epoch+1)
	}

	started := env.do(t, http.MethodPost, "/v1/daemon/commands/"+submitted.ID+"/ack", map[string]any{
		"protocol_version": 1, "delivery_seq": 1, "ack_kind": "started",
	}, terminal.AccessToken)
	if started.Code != http.StatusConflict {
		t.Fatalf("stale start status=%d want 409 body=%s", started.Code, started.Body.String())
	}
}

// DAEMON-RPC-01：协议窗口与撤销行为在 Daemon 入口直接 fail-closed。
func TestP2DaemonProtocolAndRevocationFailClosed(t *testing.T) {
	env := newTestEnv(t)
	owner := env.registerAs(t, "p2-daemon-revoked@test.dev")
	terminal := env.pairTerminal(t, owner, "p2-revoke-terminal")
	if legacy := env.do(t, http.MethodPost, "/v1/daemon/hello", map[string]any{
		"protocol_version": 0, "daemon_version": "fixture", "hostname": "p2", "platform": "test", "capabilities": []string{},
	}, terminal.AccessToken); legacy.Code != http.StatusUpgradeRequired {
		t.Fatalf("legacy hello status=%d want 426 body=%s", legacy.Code, legacy.Body.String())
	}
	if unsupported := env.do(t, http.MethodPost, "/v1/daemon/hello", map[string]any{
		"protocol_version": 2, "daemon_version": "fixture", "hostname": "p2", "platform": "test", "capabilities": []string{},
	}, terminal.AccessToken); unsupported.Code != http.StatusConflict {
		t.Fatalf("future hello status=%d want 409 body=%s", unsupported.Code, unsupported.Body.String())
	}
	// JSON 的新增可选字段不应破坏当前版本 Daemon；强制升级仅由 protocol_version 决定。
	if additive := env.do(t, http.MethodPost, "/v1/daemon/hello", map[string]any{
		"protocol_version": 1, "daemon_version": "fixture", "hostname": "p2", "platform": "test", "capabilities": []string{},
		"future_optional": "ignored-by-v1",
	}, terminal.AccessToken); additive.Code != http.StatusOK {
		t.Fatalf("additive hello status=%d want 200 body=%s", additive.Code, additive.Body.String())
	}
	_ = daemonHello(t, env, terminal.AccessToken)
	if revoke := env.do(t, http.MethodDelete, "/v1/devices/"+terminal.DeviceID, nil, owner.AccessToken); revoke.Code != http.StatusNoContent {
		t.Fatalf("revoke terminal status=%d body=%s", revoke.Code, revoke.Body.String())
	}
	if heartbeat := env.do(t, http.MethodPost, "/v1/daemon/heartbeat", map[string]any{"protocol_version": 1}, terminal.AccessToken); heartbeat.Code != http.StatusForbidden {
		t.Fatalf("revoked heartbeat status=%d want 403 body=%s", heartbeat.Code, heartbeat.Body.String())
	}
}

// P2-F / DAEMON-RPC-01：Android 只读观察只能读取账号内的命令状态、稳定错误码和安全 envelope
// 元数据；它不能订阅 Terminal command SSE，也不能拿到 command/terminal 标识、lease 或密文。
func TestP2FlutterDaemonObservationReadOnly(t *testing.T) {
	env := newTestEnv(t)
	owner := env.registerAs(t, "p2-flutter-observation@test.dev")
	terminal := env.pairTerminal(t, owner, "p2-flutter-observation-terminal")
	terminalID := daemonHello(t, env, terminal.AccessToken)
	sessionID, _ := env.createBoundSession(t, owner, terminalID, "p2-flutter-observation")
	epoch := p2SessionLeaseEpoch(t, env, owner.AccessToken, sessionID)

	command := env.do(t, http.MethodPost, "/v1/sessions/"+sessionID+"/commands", map[string]any{
		"kind": "session.start", "idempotency_key": "p2-flutter-observation-start", "lease_epoch": epoch,
		"target_terminal_id": terminalID,
		"ciphertext":         map[string]any{"opaque": "must-not-reach-observation"},
	}, owner.AccessToken)
	if command.Code != http.StatusAccepted {
		t.Fatalf("submit observation command status=%d body=%s", command.Code, command.Body.String())
	}
	var submitted struct {
		ID string `json:"id"`
	}
	decodeW1(t, command.Body.Bytes(), &submitted)
	if submitted.ID == "" {
		t.Fatal("missing observation command ID")
	}

	for _, ackKind := range []string{"received", "started"} {
		response := env.do(t, http.MethodPost, "/v1/daemon/commands/"+submitted.ID+"/ack", map[string]any{
			"protocol_version": 1, "delivery_seq": 1, "ack_kind": ackKind,
		}, terminal.AccessToken)
		if response.Code != http.StatusOK {
			t.Fatalf("%s acknowledgement status=%d body=%s", ackKind, response.Code, response.Body.String())
		}
	}
	// 该 envelope 仅用于验证投影是否正确裁剪；nonce、key_id、AAD 和 ciphertext 都不得进入 Android 响应。
	event := env.do(t, http.MethodPost, "/v1/daemon/events", map[string]any{
		"protocol_version": 1, "event_id": "evt-p2-flutter-observation", "command_id": submitted.ID,
		"session_id": sessionID, "event_type": "turn.started",
		"envelope": map[string]any{
			"alg": "v1-aes256gcm-hkdfsha256", "key_id": "p2-observation-key", "nonce": "p2-observation-nonce",
			"ciphertext": "p2-observation-ciphertext", "aad_hash": "p2-observation-aad", "payload_version": 1,
		},
	}, terminal.AccessToken)
	if event.Code != http.StatusOK {
		t.Fatalf("upload observation event status=%d body=%s", event.Code, event.Body.String())
	}
	var eventReceipt struct {
		EventSeq int64 `json:"event_seq"`
	}
	decodeW1(t, event.Body.Bytes(), &eventReceipt)
	if eventReceipt.EventSeq <= 0 {
		t.Fatalf("observation event receipt=%+v", eventReceipt)
	}
	result := env.do(t, http.MethodPost, "/v1/daemon/commands/"+submitted.ID+"/result", map[string]any{
		"protocol_version": 1, "delivery_seq": 1, "status": "failed", "error_code": protocol.ErrDaemonRestartRecovery,
	}, terminal.AccessToken)
	if result.Code != http.StatusOK {
		t.Fatalf("resolve observation command status=%d body=%s", result.Code, result.Body.String())
	}

	observation := env.do(t, http.MethodGet, "/v1/sessions/"+sessionID+"/commands?after_seq="+strconv.FormatInt(eventReceipt.EventSeq-1, 10), nil, owner.AccessToken)
	if observation.Code != http.StatusOK {
		t.Fatalf("get Flutter observation status=%d body=%s", observation.Code, observation.Body.String())
	}
	var body struct {
		Session struct {
			Status  string `json:"status"`
			LastSeq int64  `json:"last_seq"`
		} `json:"session"`
		Commands []struct {
			Kind          string `json:"kind"`
			Status        string `json:"status"`
			DeliveryState string `json:"delivery_state"`
			ErrorCode     string `json:"error_code"`
		} `json:"commands"`
		Events []struct {
			EventSeq  int64  `json:"event_seq"`
			EventType string `json:"event_type"`
			Envelope  struct {
				State          string `json:"state"`
				Algorithm      string `json:"algorithm"`
				PayloadVersion int    `json:"payload_version"`
			} `json:"envelope"`
		} `json:"events"`
	}
	decodeW1(t, observation.Body.Bytes(), &body)
	if body.Session.Status != domain.SessionRunning || body.Session.LastSeq < eventReceipt.EventSeq {
		t.Fatalf("observation session=%+v", body.Session)
	}
	if len(body.Commands) != 1 || body.Commands[0].Kind != "session.start" || body.Commands[0].Status != domain.CommandFailed || body.Commands[0].DeliveryState != "resolved" || body.Commands[0].ErrorCode != protocol.ErrDaemonRestartRecovery {
		t.Fatalf("observation commands=%+v", body.Commands)
	}
	if len(body.Events) != 1 || body.Events[0].EventType != "turn.started" || body.Events[0].Envelope.State != "verified" || body.Events[0].Envelope.Algorithm != "v1-aes256gcm-hkdfsha256" || body.Events[0].Envelope.PayloadVersion != 1 {
		t.Fatalf("observation events=%+v", body.Events)
	}
	for _, forbidden := range []string{submitted.ID, terminalID, "p2-observation-key", "p2-observation-nonce", "p2-observation-ciphertext", "p2-observation-aad", "must-not-reach-observation", "workspace_id", "lease_epoch"} {
		if strings.Contains(observation.Body.String(), forbidden) {
			t.Fatalf("Flutter observation leaked forbidden value %q: %s", forbidden, observation.Body.String())
		}
	}

	other := env.provisionAdditionalAccount(t, "p2-flutter-observation-other@test.dev")
	if denied := env.do(t, http.MethodGet, "/v1/sessions/"+sessionID+"/commands", nil, other.AccessToken); denied.Code != http.StatusForbidden {
		t.Fatalf("cross-account observation status=%d want 403 body=%s", denied.Code, denied.Body.String())
	}
}

// E2E-RELAY-02：真实本地 Relay HTTP Server + Daemon REST/SSE 客户端 + deterministic Adapter。
// 这不是 Provider live gate：fixture encoder 只证明消息不以明文穿过 Relay，不能证明 E2EE 密钥流程。
func TestP2RelayDaemonDeterministicFullLoop(t *testing.T) {
	env := newTestEnv(t)
	owner := env.registerAs(t, "p2-e2e-loop@test.dev")
	terminal := env.pairTerminal(t, owner, "p2-e2e-terminal")
	terminalID := daemonHello(t, env, terminal.AccessToken)

	server := httptest.NewServer(env.router)
	defer server.Close()
	local, err := daemon.OpenStore(filepath.Join(t.TempDir(), "daemon.db"))
	if err != nil {
		t.Fatalf("open daemon store: %v", err)
	}
	defer local.Close()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	runner := daemon.NewSessionRunner(local, map[string]adapter.Adapter{"mock": adapter.NewMockAdapter()}, logger)
	defer runner.Close(context.Background())
	loop := daemon.NewRelayLoop(local, &daemon.RelayClient{BaseURL: server.URL, AccessToken: terminal.AccessToken}, runner, daemon.FixtureEventEncoder{}, logger)
	loop.DaemonVersion = "p2-fixture"
	loop.Hostname = "p2-e2e-host"
	loop.Platform = "test"
	loop.Capabilities = []string{"start", "git_read"}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- loop.RunWithRetry(ctx) }()

	sessionID, _ := env.createBoundSession(t, owner, terminalID, "p2-e2e-loop")
	epoch := p2SessionLeaseEpoch(t, env, owner.AccessToken, sessionID)
	command := env.do(t, http.MethodPost, "/v1/sessions/"+sessionID+"/commands", map[string]any{
		"kind": "session.start", "idempotency_key": "p2-e2e-start", "lease_epoch": epoch,
		"target_terminal_id": terminalID,
		"ciphertext": map[string]any{
			"kind": "session.start", "session_id": sessionID, "workspace_root": "/fixture/p2-e2e-loop", "provider": "mock",
			"ciphertext": map[string]any{"fixture_payload": map[string]any{"provider": "mock", "prompt": "fixture only"}},
		},
	}, owner.AccessToken)
	if command.Code != http.StatusAccepted {
		cancel()
		<-done
		t.Fatalf("submit e2e command status=%d body=%s", command.Code, command.Body.String())
	}
	var submitted struct {
		ID string `json:"id"`
	}
	decodeW1(t, command.Body.Bytes(), &submitted)

	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		view := env.do(t, http.MethodGet, "/v1/commands/"+submitted.ID, nil, owner.AccessToken)
		var item struct {
			Status string `json:"status"`
		}
		decodeW1(t, view.Body.Bytes(), &item)
		events, _ := env.repo.ListEventsAfter(t.Context(), sessionID, 0)
		if view.Code == http.StatusOK && item.Status == domain.CommandSucceeded && len(events) > 1 {
			for _, event := range events[1:] {
				if strings.Contains(event.EnvelopeJSON, "fixture only") || strings.Contains(event.EnvelopeJSON, "hello from mock") {
					cancel()
					<-done
					t.Fatalf("relay event leaked fixture plaintext: %s", event.EnvelopeJSON)
				}
			}
			cancel()
			if runErr := <-done; runErr != context.Canceled {
				t.Fatalf("relay loop result=%v want context.Canceled", runErr)
			}
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	cancel()
	<-done
	t.Fatalf("deterministic relay-daemon loop did not converge")
}

// E2E-RELAY-02 / SESS-05：完整 deterministic 生命周期必须真的经过本地 Relay HTTP、
// Daemon 的专用 SSE、SessionRunner 和 Adapter Handle。这里不使用真实 Provider，也不把
// fixture encoder 当成真实 E2EE；它只验证本地命令状态与明文边界能随每个动作收敛。
func TestP2RelayDaemonDeterministicSessionLifecycleFullLoop(t *testing.T) {
	env := newTestEnv(t)
	owner := env.registerAs(t, "p2-e2e-session-lifecycle@test.dev")
	terminal := env.pairTerminal(t, owner, "p2-e2e-session-lifecycle-terminal")
	terminalID := daemonHello(t, env, terminal.AccessToken)

	server := httptest.NewServer(env.router)
	defer server.Close()
	local, err := daemon.OpenStore(filepath.Join(t.TempDir(), "daemon.db"))
	if err != nil {
		t.Fatalf("open daemon store: %v", err)
	}
	defer local.Close()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	adapterFixture := newP2LifecycleAdapter()
	runner := daemon.NewSessionRunner(local, map[string]adapter.Adapter{"lifecycle": adapterFixture}, logger)
	defer runner.Close(context.Background())
	loop := daemon.NewRelayLoop(local, &daemon.RelayClient{BaseURL: server.URL, AccessToken: terminal.AccessToken}, runner, daemon.FixtureEventEncoder{}, logger)
	loop.DaemonVersion = "p2-lifecycle-fixture"
	loop.Hostname = "p2-lifecycle-host"
	loop.Platform = "test"
	loop.Capabilities = []string{"start", "send", "resume", "abort", "kill"}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- loop.RunWithRetry(ctx) }()
	// 清理必须先收束 SSE/RelayLoop，再交给外层 runner.Close 回收 handle，避免测试失败时
	// 出现还在写 event 的 Adapter 与已经关闭的 runner 竞争。
	defer func() {
		cancel()
		if runErr := <-done; runErr != context.Canceled {
			t.Errorf("relay loop result=%v want context.Canceled", runErr)
		}
	}()
	waitP2DaemonLocalTerminal(t, local)

	sessionID, _ := env.createBoundSession(t, owner, terminalID, "p2-e2e-session-lifecycle")
	epoch := p2SessionLeaseEpoch(t, env, owner.AccessToken, sessionID)
	submit := func(kind, idempotencyKey string, envelope map[string]any) string {
		t.Helper()
		response := env.do(t, http.MethodPost, "/v1/sessions/"+sessionID+"/commands", map[string]any{
			"kind": kind, "idempotency_key": idempotencyKey, "lease_epoch": epoch,
			"target_terminal_id": terminalID, "ciphertext": envelope,
		}, owner.AccessToken)
		if response.Code != http.StatusAccepted {
			t.Fatalf("submit %s status=%d body=%s", kind, response.Code, response.Body.String())
		}
		var command struct {
			ID string `json:"id"`
		}
		decodeW1(t, response.Body.Bytes(), &command)
		if command.ID == "" {
			t.Fatalf("%s command id missing", kind)
		}
		return command.ID
	}

	startID := submit("session.start", "p2-e2e-lifecycle-start", map[string]any{
		"kind": "session.start", "session_id": sessionID, "workspace_root": "/fixture/p2-e2e-session-lifecycle", "provider": "lifecycle",
		"ciphertext": map[string]any{"fixture_payload": map[string]any{"provider": "lifecycle", "prompt": "start body must stay local"}},
	})
	waitP2CommandSucceeded(t, env, owner.AccessToken, startID)

	sendID := submit("session.send", "p2-e2e-lifecycle-send", map[string]any{
		"kind": "session.send", "session_id": sessionID,
		"ciphertext": map[string]any{"fixture_payload": map[string]any{"message": "send body must stay local"}},
	})
	waitP2CommandSucceeded(t, env, owner.AccessToken, sendID)

	resumeID := submit("session.resume", "p2-e2e-lifecycle-resume", map[string]any{
		"kind": "session.resume", "session_id": sessionID,
	})
	waitP2CommandSucceeded(t, env, owner.AccessToken, resumeID)

	abortID := submit("session.abort", "p2-e2e-lifecycle-abort", map[string]any{
		"kind": "session.abort", "session_id": sessionID,
	})
	waitP2CommandSucceeded(t, env, owner.AccessToken, abortID)
	killID := submit("session.kill", "p2-e2e-lifecycle-kill", map[string]any{
		"kind": "session.kill", "session_id": sessionID,
	})
	waitP2CommandSucceeded(t, env, owner.AccessToken, killID)

	if starts, sends, resumes, aborts, kills := adapterFixture.snapshot(); starts != 1 || sends != 1 || resumes != 1 || aborts != 1 || kills != 1 {
		t.Fatalf("adapter lifecycle calls start/send/resume/abort/kill=%d/%d/%d/%d/%d, want 1/1/1/1/1", starts, sends, resumes, aborts, kills)
	}
	if _, err := local.Get("instance:" + sessionID); err == nil {
		t.Fatal("session.kill must remove local provider instance mapping")
	}
	events := waitP2CanonicalEvents(t, env, sessionID, 2)
	var previousSeq int64
	for _, event := range events {
		if event.EventSeq <= previousSeq {
			t.Fatalf("Relay canonical event sequence not monotonic: previous=%d current=%d", previousSeq, event.EventSeq)
		}
		previousSeq = event.EventSeq
		if strings.Contains(event.EnvelopeJSON, "start body must stay local") || strings.Contains(event.EnvelopeJSON, "send body must stay local") {
			t.Fatalf("Relay event envelope leaked lifecycle plaintext: %s", event.EnvelopeJSON)
		}
	}
	// 账号级 SSE 只能看到事件类型和 opaque envelope；同样不能把 send 正文带到观察者侧。
	accountStream := streamAccountUntil(t, env, owner.AccessToken, "event: message.delta")
	if !strings.Contains(accountStream, "event: message.delta") || strings.Contains(accountStream, "send body must stay local") {
		t.Fatalf("account SSE lifecycle projection invalid: %s", accountStream)
	}
}

// SYNC-05 / E2E-RELAY-02：started 回执的 HTTP 响应在网络中丢失时，Relay 可能已经持久化
// 回执，而 Daemon 只能看到错误。重启后必须重放回执并只启动一次 Provider，不能把已落盘的
// command 直接当作新命令执行。
func TestP2RelayDaemonRestartReplaysStartingAcknowledgement(t *testing.T) {
	env := newTestEnv(t)
	owner := env.registerAs(t, "p2-restart-starting@test.dev")
	terminal := env.pairTerminal(t, owner, "p2-restart-starting-terminal")
	terminalID := daemonHello(t, env, terminal.AccessToken)
	server := httptest.NewServer(env.router)
	defer server.Close()

	statePath := filepath.Join(t.TempDir(), "daemon.db")
	local, err := daemon.OpenStore(statePath)
	if err != nil {
		t.Fatalf("open first daemon store: %v", err)
	}
	firstAdapter := newP2LifecycleAdapter()
	firstRunner := daemon.NewSessionRunner(local, map[string]adapter.Adapter{"lifecycle": firstAdapter}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	drop := newP2DropCommittedResponseTransport(true, func(request *http.Request, body []byte) bool {
		return request.Method == http.MethodPost && strings.HasSuffix(request.URL.Path, "/ack") && bytes.Contains(body, []byte(`"ack_kind":"started"`))
	})
	firstLoop := newP2RecoveryLoop(local, server.URL, terminal.AccessToken, firstRunner, &http.Client{Transport: drop})
	firstCtx, cancelFirst := context.WithCancel(context.Background())
	firstDone := make(chan error, 1)
	go func() { firstDone <- firstLoop.RunWithRetry(firstCtx) }()
	waitP2DaemonLocalTerminal(t, local)

	sessionID, _ := env.createBoundSession(t, owner, terminalID, "p2-restart-starting")
	commandID := submitP2LifecycleStart(t, env, owner.AccessToken, sessionID, terminalID, "p2-restart-starting")
	waitP2TransportDrop(t, drop)
	cancelFirst()
	if runErr := <-firstDone; runErr != context.Canceled {
		t.Fatalf("first relay loop=%v want context.Canceled", runErr)
	}
	stored, err := local.RelayCommandByID(commandID)
	if err != nil || stored.Status != "starting" {
		t.Fatalf("first local command=%+v err=%v want starting", stored, err)
	}
	if starts, _, _, _, _ := firstAdapter.snapshot(); starts != 0 {
		t.Fatalf("provider started before started receipt was confirmed: %d", starts)
	}
	_ = firstRunner.Close(context.Background())
	if err := local.Close(); err != nil {
		t.Fatalf("close first daemon store: %v", err)
	}

	reopened, err := daemon.OpenStore(statePath)
	if err != nil {
		t.Fatalf("reopen daemon store: %v", err)
	}
	defer reopened.Close()
	secondAdapter := newP2LifecycleAdapter()
	secondRunner := daemon.NewSessionRunner(reopened, map[string]adapter.Adapter{"lifecycle": secondAdapter}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	defer secondRunner.Close(context.Background())
	secondLoop := newP2RecoveryLoop(reopened, server.URL, terminal.AccessToken, secondRunner, nil)
	secondCtx, cancelSecond := context.WithCancel(context.Background())
	secondDone := make(chan error, 1)
	go func() { secondDone <- secondLoop.RunWithRetry(secondCtx) }()
	waitP2CommandSucceeded(t, env, owner.AccessToken, commandID)
	if starts, _, _, _, _ := secondAdapter.snapshot(); starts != 1 {
		cancelSecond()
		<-secondDone
		t.Fatalf("replayed started acknowledgement executed provider %d times, want 1", starts)
	}
	cancelSecond()
	if runErr := <-secondDone; runErr != context.Canceled {
		t.Fatalf("second relay loop=%v want context.Canceled", runErr)
	}
}

// SYNC-05 / E2E-RELAY-02：当 Provider 已进入未知执行区间时，Daemon 重启不能尝试恢复或
// 重复 start。新的 RelayLoop 必须主动扫描本地 started 命令并以稳定错误收敛，而不是等待 SSE
// 再次推送已经被 cursor 跳过的 delivery。
func TestP2RelayDaemonRestartFailsClosedForInterruptedProviderStart(t *testing.T) {
	env := newTestEnv(t)
	owner := env.registerAs(t, "p2-restart-interrupted@test.dev")
	terminal := env.pairTerminal(t, owner, "p2-restart-interrupted-terminal")
	terminalID := daemonHello(t, env, terminal.AccessToken)
	server := httptest.NewServer(env.router)
	defer server.Close()

	statePath := filepath.Join(t.TempDir(), "daemon.db")
	local, err := daemon.OpenStore(statePath)
	if err != nil {
		t.Fatalf("open first daemon store: %v", err)
	}
	blocking := newP2BlockingStartAdapter()
	firstRunner := daemon.NewSessionRunner(local, map[string]adapter.Adapter{"blocking": blocking}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	firstLoop := newP2RecoveryLoop(local, server.URL, terminal.AccessToken, firstRunner, nil)
	firstCtx, cancelFirst := context.WithCancel(context.Background())
	firstDone := make(chan error, 1)
	go func() { firstDone <- firstLoop.RunWithRetry(firstCtx) }()
	waitP2DaemonLocalTerminal(t, local)

	sessionID, _ := env.createBoundSession(t, owner, terminalID, "p2-restart-interrupted")
	commandID := submitP2Start(t, env, owner.AccessToken, sessionID, terminalID, "blocking", "p2-restart-interrupted")
	select {
	case <-blocking.entered:
	case <-time.After(3 * time.Second):
		cancelFirst()
		<-firstDone
		t.Fatal("provider start did not enter the interrupted execution window")
	}
	cancelFirst()
	if runErr := <-firstDone; runErr != context.Canceled {
		t.Fatalf("first relay loop=%v want context.Canceled", runErr)
	}
	stored, err := local.RelayCommandByID(commandID)
	if err != nil || stored.Status != "started" {
		t.Fatalf("interrupted local command=%+v err=%v want started", stored, err)
	}
	_ = firstRunner.Close(context.Background())
	if err := local.Close(); err != nil {
		t.Fatalf("close first daemon store: %v", err)
	}

	reopened, err := daemon.OpenStore(statePath)
	if err != nil {
		t.Fatalf("reopen daemon store: %v", err)
	}
	defer reopened.Close()
	recoveryAdapter := newP2LifecycleAdapter()
	recoveryRunner := daemon.NewSessionRunner(reopened, map[string]adapter.Adapter{"blocking": recoveryAdapter}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	defer recoveryRunner.Close(context.Background())
	recoveryLoop := newP2RecoveryLoop(reopened, server.URL, terminal.AccessToken, recoveryRunner, nil)
	recoveryCtx, cancelRecovery := context.WithCancel(context.Background())
	recoveryDone := make(chan error, 1)
	go func() { recoveryDone <- recoveryLoop.RunWithRetry(recoveryCtx) }()
	waitP2CommandStatus(t, env, owner.AccessToken, commandID, domain.CommandFailed)
	recovered, err := reopened.RelayCommandByID(commandID)
	if err != nil || recovered.ResultStatus != domain.CommandFailed || recovered.ErrorCode != "DAEMON_RESTART_RECOVERY" {
		cancelRecovery()
		<-recoveryDone
		t.Fatalf("recovered local command=%+v err=%v", recovered, err)
	}
	if starts, _, _, _, _ := recoveryAdapter.snapshot(); starts != 0 {
		cancelRecovery()
		<-recoveryDone
		t.Fatalf("interrupted command executed after restart: %d starts", starts)
	}
	cancelRecovery()
	if runErr := <-recoveryDone; runErr != context.Canceled {
		t.Fatalf("recovery relay loop=%v want context.Canceled", runErr)
	}
}

// SYNC-05 / E2E-RELAY-02：Relay 已提交 result 但响应在网络中丢失时，重启重放必须接受
// Relay 的幂等 receipt。否则本地会把已成功的命令误写成 DAEMON_RESTART_RECOVERY。
func TestP2RelayDaemonRestartReconcilesCommittedResultReceipt(t *testing.T) {
	env := newTestEnv(t)
	owner := env.registerAs(t, "p2-restart-result@test.dev")
	terminal := env.pairTerminal(t, owner, "p2-restart-result-terminal")
	terminalID := daemonHello(t, env, terminal.AccessToken)
	server := httptest.NewServer(env.router)
	defer server.Close()

	statePath := filepath.Join(t.TempDir(), "daemon.db")
	local, err := daemon.OpenStore(statePath)
	if err != nil {
		t.Fatalf("open first daemon store: %v", err)
	}
	firstAdapter := newP2LifecycleAdapter()
	firstRunner := daemon.NewSessionRunner(local, map[string]adapter.Adapter{"lifecycle": firstAdapter}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	drop := newP2DropCommittedResponseTransport(true, func(request *http.Request, _ []byte) bool {
		return request.Method == http.MethodPost && strings.HasSuffix(request.URL.Path, "/result")
	})
	firstLoop := newP2RecoveryLoop(local, server.URL, terminal.AccessToken, firstRunner, &http.Client{Transport: drop})
	firstCtx, cancelFirst := context.WithCancel(context.Background())
	firstDone := make(chan error, 1)
	go func() { firstDone <- firstLoop.RunWithRetry(firstCtx) }()
	waitP2DaemonLocalTerminal(t, local)

	sessionID, _ := env.createBoundSession(t, owner, terminalID, "p2-restart-result")
	commandID := submitP2LifecycleStart(t, env, owner.AccessToken, sessionID, terminalID, "p2-restart-result")
	waitP2TransportDrop(t, drop)
	cancelFirst()
	if runErr := <-firstDone; runErr != context.Canceled {
		t.Fatalf("first relay loop=%v want context.Canceled", runErr)
	}
	if relayCommand, err := env.repo.CommandByID(t.Context(), commandID); err != nil || relayCommand.Status != domain.CommandSucceeded {
		t.Fatalf("Relay result before restart=%+v err=%v want succeeded", relayCommand, err)
	}
	stored, err := local.RelayCommandByID(commandID)
	if err != nil || stored.Status != "started" {
		t.Fatalf("local result before restart=%+v err=%v want started", stored, err)
	}
	_ = firstRunner.Close(context.Background())
	if err := local.Close(); err != nil {
		t.Fatalf("close first daemon store: %v", err)
	}

	reopened, err := daemon.OpenStore(statePath)
	if err != nil {
		t.Fatalf("reopen daemon store: %v", err)
	}
	defer reopened.Close()
	recoveryAdapter := newP2LifecycleAdapter()
	recoveryRunner := daemon.NewSessionRunner(reopened, map[string]adapter.Adapter{"lifecycle": recoveryAdapter}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	defer recoveryRunner.Close(context.Background())
	recoveryLoop := newP2RecoveryLoop(reopened, server.URL, terminal.AccessToken, recoveryRunner, nil)
	recoveryCtx, cancelRecovery := context.WithCancel(context.Background())
	recoveryDone := make(chan error, 1)
	go func() { recoveryDone <- recoveryLoop.RunWithRetry(recoveryCtx) }()
	waitP2CommandSucceeded(t, env, owner.AccessToken, commandID)
	recovered := waitP2LocalCommandResult(t, reopened, commandID, domain.CommandSucceeded, "")
	if recovered.ResultStatus != domain.CommandSucceeded || recovered.ErrorCode != "" {
		cancelRecovery()
		<-recoveryDone
		t.Fatalf("local result receipt reconciliation=%+v", recovered)
	}
	if starts, _, _, _, _ := recoveryAdapter.snapshot(); starts != 0 {
		cancelRecovery()
		<-recoveryDone
		t.Fatalf("committed result was executed again after restart: %d starts", starts)
	}
	cancelRecovery()
	if runErr := <-recoveryDone; runErr != context.Canceled {
		t.Fatalf("recovery relay loop=%v want context.Canceled", runErr)
	}
}

// SYNC-05 / E2E-RELAY-02：event 上传的响应丢失不等于 Relay 没有收到事件。Daemon 重启后必须
// 以相同 event_id 重放本地 outbox，Relay 只保留一条 canonical event，随后才标记本地 delivered。
func TestP2RelayDaemonRestartReplaysCommittedEventOutbox(t *testing.T) {
	env := newTestEnv(t)
	owner := env.registerAs(t, "p2-restart-event@test.dev")
	terminal := env.pairTerminal(t, owner, "p2-restart-event-terminal")
	terminalID := daemonHello(t, env, terminal.AccessToken)
	server := httptest.NewServer(env.router)
	defer server.Close()

	statePath := filepath.Join(t.TempDir(), "daemon.db")
	local, err := daemon.OpenStore(statePath)
	if err != nil {
		t.Fatalf("open first daemon store: %v", err)
	}
	firstAdapter := newP2LifecycleAdapter()
	firstRunner := daemon.NewSessionRunner(local, map[string]adapter.Adapter{"lifecycle": firstAdapter}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	drop := newP2DropCommittedResponseTransport(false, func(request *http.Request, _ []byte) bool {
		return request.Method == http.MethodPost && request.URL.Path == "/v1/daemon/events"
	})
	firstLoop := newP2RecoveryLoop(local, server.URL, terminal.AccessToken, firstRunner, &http.Client{Transport: drop})
	firstCtx, cancelFirst := context.WithCancel(context.Background())
	firstDone := make(chan error, 1)
	go func() { firstDone <- firstLoop.RunWithRetry(firstCtx) }()
	waitP2DaemonLocalTerminal(t, local)

	sessionID, _ := env.createBoundSession(t, owner, terminalID, "p2-restart-event")
	commandID := submitP2LifecycleStart(t, env, owner.AccessToken, sessionID, terminalID, "p2-restart-event")
	waitP2CommandSucceeded(t, env, owner.AccessToken, commandID)
	waitP2EventOutboxEmpty(t, local)
	drop.Enable()
	if err := firstAdapter.emitMessageDelta(); err != nil {
		cancelFirst()
		<-firstDone
		t.Fatalf("emit delayed event: %v", err)
	}
	waitP2TransportDrop(t, drop)
	waitP2EventOutboxPending(t, local)
	cancelFirst()
	if runErr := <-firstDone; runErr != context.Canceled {
		t.Fatalf("first relay loop=%v want context.Canceled", runErr)
	}
	_ = firstRunner.Close(context.Background())
	if err := local.Close(); err != nil {
		t.Fatalf("close first daemon store: %v", err)
	}

	reopened, err := daemon.OpenStore(statePath)
	if err != nil {
		t.Fatalf("reopen daemon store: %v", err)
	}
	defer reopened.Close()
	recoveryAdapter := newP2LifecycleAdapter()
	recoveryRunner := daemon.NewSessionRunner(reopened, map[string]adapter.Adapter{"lifecycle": recoveryAdapter}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	defer recoveryRunner.Close(context.Background())
	recoveryLoop := newP2RecoveryLoop(reopened, server.URL, terminal.AccessToken, recoveryRunner, nil)
	recoveryCtx, cancelRecovery := context.WithCancel(context.Background())
	recoveryDone := make(chan error, 1)
	go func() { recoveryDone <- recoveryLoop.RunWithRetry(recoveryCtx) }()
	waitP2EventOutboxEmpty(t, reopened)

	events, err := env.repo.ListEventsAfter(t.Context(), sessionID, 0)
	if err != nil {
		cancelRecovery()
		<-recoveryDone
		t.Fatalf("list replayed events: %v", err)
	}
	messageDeltas := 0
	for _, event := range events {
		if event.EventType == "message.delta" {
			messageDeltas++
		}
	}
	if messageDeltas != 1 {
		cancelRecovery()
		<-recoveryDone
		t.Fatalf("committed event was not idempotent: message.delta count=%d want 1", messageDeltas)
	}
	if starts, _, _, _, _ := recoveryAdapter.snapshot(); starts != 0 {
		cancelRecovery()
		<-recoveryDone
		t.Fatalf("event replay started a Provider unexpectedly: %d starts", starts)
	}
	cancelRecovery()
	if runErr := <-recoveryDone; runErr != context.Canceled {
		t.Fatalf("recovery relay loop=%v want context.Canceled", runErr)
	}
}

// p2LifecycleAdapter 是 full gate 专用的可观测 Adapter。它只在测试进程内创建，确保测试既能
// 验证 Runner 真正调用 Handle，又不会对任何真实 Provider、token 或本机 Workspace 产生副作用。
type p2LifecycleAdapter struct {
	mu      sync.Mutex
	nextID  int
	handles []*p2LifecycleHandle
	starts  int
	sends   int
	resumes int
	aborts  int
	kills   int
}

func newP2LifecycleAdapter() *p2LifecycleAdapter { return &p2LifecycleAdapter{} }

func (a *p2LifecycleAdapter) Detect(context.Context) (adapter.Capabilities, error) {
	return adapter.Capabilities{Provider: "lifecycle"}, nil
}

func (a *p2LifecycleAdapter) Capabilities() adapter.Capabilities {
	caps, _ := a.Detect(context.Background())
	return caps
}

func (a *p2LifecycleAdapter) Start(context.Context, adapter.StartRequest) (adapter.Handle, error) {
	a.mu.Lock()
	a.nextID++
	a.starts++
	id := fmt.Sprintf("lifecycle-%d", a.nextID)
	a.mu.Unlock()
	handle := &p2LifecycleHandle{adapter: a, id: id, events: make(chan adapter.Event, 8), done: make(chan struct{})}
	a.mu.Lock()
	a.handles = append(a.handles, handle)
	a.mu.Unlock()
	// 首条事件必须是 turn_started，供 SessionRunner 安全取得本地 instance 映射。
	handle.events <- adapter.Event{Type: adapter.EventTurnStarted, Seq: 1, Payload: map[string]any{"instance_id": id}}
	return handle, nil
}

func (a *p2LifecycleAdapter) Resume(context.Context, adapter.ResumeRequest) (adapter.ResumeResult, error) {
	a.mu.Lock()
	a.resumes++
	a.mu.Unlock()
	return adapter.ResumeResult{Result: adapter.WakeResumed}, nil
}

func (a *p2LifecycleAdapter) snapshot() (starts, sends, resumes, aborts, kills int) {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.starts, a.sends, a.resumes, a.aborts, a.kills
}

// emitMessageDelta 仅在重连矩阵中于已完成命令之后触发一条异步 canonical event，避免把
// event outbox 响应丢失与 command result 的响应丢失混为同一个失败窗口。
func (a *p2LifecycleAdapter) emitMessageDelta() error {
	a.mu.Lock()
	if len(a.handles) == 0 {
		a.mu.Unlock()
		return errors.New("lifecycle handle missing")
	}
	handle := a.handles[len(a.handles)-1]
	a.mu.Unlock()
	return handle.emitMessageDelta()
}

type p2LifecycleHandle struct {
	adapter *p2LifecycleAdapter
	id      string
	events  chan adapter.Event
	done    chan struct{}
	mu      sync.Mutex
	seq     int64
	closed  bool
}

func (h *p2LifecycleHandle) Send(context.Context, string) error {
	h.adapter.mu.Lock()
	h.adapter.sends++
	h.adapter.mu.Unlock()
	return h.emitMessageDelta()
}

func (h *p2LifecycleHandle) emitMessageDelta() error {
	h.mu.Lock()
	if h.closed {
		h.mu.Unlock()
		return context.Canceled
	}
	h.seq++
	seq := h.seq + 1 // seq=1 已由 turn_started 使用。
	h.mu.Unlock()
	select {
	case h.events <- adapter.Event{Type: adapter.EventMessageDelta, Seq: seq, Payload: map[string]any{"text": "deterministic lifecycle delta"}}:
		return nil
	case <-h.done:
		return context.Canceled
	}
}

func (h *p2LifecycleHandle) Abort(context.Context) error {
	h.adapter.mu.Lock()
	h.adapter.aborts++
	h.adapter.mu.Unlock()
	return nil
}

// ForceKill 只模拟 owned-process Handle 的调用边界，不创建任何真实 Provider 或子进程。实际
// 进程树语义由 daemon.ProcessSupervisor 的专属根因回归覆盖；这里验证 Relay 命令确实到达
// SessionRunner，且不会被降级为 Abort。
func (h *p2LifecycleHandle) ForceKill(context.Context) error {
	h.adapter.mu.Lock()
	h.adapter.kills++
	h.adapter.mu.Unlock()
	return nil
}

func (h *p2LifecycleHandle) Events() <-chan adapter.Event { return h.events }

func (h *p2LifecycleHandle) Dispose(context.Context) error {
	h.mu.Lock()
	defer h.mu.Unlock()
	if !h.closed {
		h.closed = true
		close(h.done)
		close(h.events)
	}
	return nil
}

// p2DropCommittedResponseTransport 让请求先到达真实 httptest Relay 并提交事务，再对 Daemon
// 伪造网络响应丢失。它不伪造 Relay 业务响应，专门覆盖“服务端已写入、客户端未收到”的恢复窗口。
type p2DropCommittedResponseTransport struct {
	base    http.RoundTripper
	match   func(*http.Request, []byte) bool
	firedCh chan struct{}

	mu      sync.Mutex
	enabled bool
	fired   bool
}

func newP2DropCommittedResponseTransport(enabled bool, match func(*http.Request, []byte) bool) *p2DropCommittedResponseTransport {
	return &p2DropCommittedResponseTransport{
		base: http.DefaultTransport, match: match, firedCh: make(chan struct{}), enabled: enabled,
	}
}

func (t *p2DropCommittedResponseTransport) Enable() {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.enabled = true
}

func (t *p2DropCommittedResponseTransport) RoundTrip(request *http.Request) (*http.Response, error) {
	var body []byte
	if request.Body != nil {
		var err error
		body, err = io.ReadAll(request.Body)
		if err != nil {
			return nil, err
		}
		_ = request.Body.Close()
		request.Body = io.NopCloser(bytes.NewReader(body))
	}
	response, err := t.base.RoundTrip(request)
	if err != nil {
		return nil, err
	}
	t.mu.Lock()
	drop := t.enabled && !t.fired && t.match(request, body)
	if drop {
		t.fired = true
		close(t.firedCh)
	}
	t.mu.Unlock()
	if !drop {
		return response, nil
	}
	_ = response.Body.Close()
	return nil, errors.New("fixture network response lost after relay commit")
}

func waitP2TransportDrop(t *testing.T, transport *p2DropCommittedResponseTransport) {
	t.Helper()
	select {
	case <-transport.firedCh:
	case <-time.After(3 * time.Second):
		t.Fatal("expected committed Relay response to be dropped")
	}
}

func newP2RecoveryLoop(local *daemon.Store, baseURL, token string, runner *daemon.SessionRunner, client *http.Client) *daemon.RelayLoop {
	loop := daemon.NewRelayLoop(local, &daemon.RelayClient{BaseURL: baseURL, AccessToken: token, HTTPClient: client}, runner, daemon.FixtureEventEncoder{}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	loop.DaemonVersion = "p2-recovery-fixture"
	loop.Hostname = "p2-recovery-host"
	loop.Platform = "test"
	loop.Capabilities = []string{"start"}
	return loop
}

func submitP2LifecycleStart(t *testing.T, env *testEnv, token, sessionID, terminalID, idempotencyKey string) string {
	return submitP2Start(t, env, token, sessionID, terminalID, "lifecycle", idempotencyKey)
}

func submitP2Start(t *testing.T, env *testEnv, token, sessionID, terminalID, provider, idempotencyKey string) string {
	t.Helper()
	epoch := p2SessionLeaseEpoch(t, env, token, sessionID)
	response := env.do(t, http.MethodPost, "/v1/sessions/"+sessionID+"/commands", map[string]any{
		"kind": "session.start", "idempotency_key": idempotencyKey, "lease_epoch": epoch, "target_terminal_id": terminalID,
		"ciphertext": map[string]any{
			"kind": "session.start", "session_id": sessionID, "workspace_root": "/fixture/" + idempotencyKey, "provider": provider,
			"ciphertext": map[string]any{"fixture_payload": map[string]any{"provider": provider, "prompt": "recovery fixture only"}},
		},
	}, token)
	if response.Code != http.StatusAccepted {
		t.Fatalf("submit recovery start status=%d body=%s", response.Code, response.Body.String())
	}
	var command struct {
		ID string `json:"id"`
	}
	decodeW1(t, response.Body.Bytes(), &command)
	if command.ID == "" {
		t.Fatal("recovery start command id missing")
	}
	return command.ID
}

// p2BlockingStartAdapter 在 Start 已经可能产生 Provider 副作用时阻塞直到 Daemon context
// 取消，模拟进程突然中止。它不启动真实子进程，只为验证重启后的 fail-closed 分支。
type p2BlockingStartAdapter struct {
	entered chan struct{}
}

func newP2BlockingStartAdapter() *p2BlockingStartAdapter {
	return &p2BlockingStartAdapter{entered: make(chan struct{}, 1)}
}

func (a *p2BlockingStartAdapter) Detect(context.Context) (adapter.Capabilities, error) {
	return adapter.Capabilities{Provider: "blocking"}, nil
}

func (a *p2BlockingStartAdapter) Capabilities() adapter.Capabilities {
	capabilities, _ := a.Detect(context.Background())
	return capabilities
}

func (a *p2BlockingStartAdapter) Start(ctx context.Context, _ adapter.StartRequest) (adapter.Handle, error) {
	select {
	case a.entered <- struct{}{}:
	default:
	}
	<-ctx.Done()
	return nil, ctx.Err()
}

func (a *p2BlockingStartAdapter) Resume(context.Context, adapter.ResumeRequest) (adapter.ResumeResult, error) {
	return adapter.ResumeResult{Result: adapter.WakeUnsupported}, nil
}

func waitP2DaemonLocalTerminal(t *testing.T, local *daemon.Store) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if terminalID, err := local.Get("terminal_id"); err == nil && terminalID != "" {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("daemon relay loop did not complete hello")
}

func waitP2CommandSucceeded(t *testing.T, env *testEnv, ownerToken, commandID string) {
	waitP2CommandStatus(t, env, ownerToken, commandID, domain.CommandSucceeded)
}

func waitP2CommandStatus(t *testing.T, env *testEnv, ownerToken, commandID, expectedStatus string) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		response := env.do(t, http.MethodGet, "/v1/commands/"+commandID, nil, ownerToken)
		var command struct {
			Status string `json:"status"`
		}
		decodeW1(t, response.Body.Bytes(), &command)
		if response.Code == http.StatusOK && command.Status == expectedStatus {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("command %s did not converge to %s", commandID, expectedStatus)
}

func waitP2LocalCommandResult(t *testing.T, local *daemon.Store, commandID, expectedStatus, expectedCode string) daemon.RelayCommand {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		command, err := local.RelayCommandByID(commandID)
		if err == nil && command.Status == "completed" && command.ResultStatus == expectedStatus && command.ErrorCode == expectedCode {
			return command
		}
		time.Sleep(10 * time.Millisecond)
	}
	command, err := local.RelayCommandByID(commandID)
	t.Fatalf("local command %s did not converge to %s/%s: %+v err=%v", commandID, expectedStatus, expectedCode, command, err)
	return daemon.RelayCommand{}
}

func waitP2EventOutboxEmpty(t *testing.T, local *daemon.Store) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		events, err := local.PendingRelayEvents()
		if err == nil && len(events) == 0 {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	events, err := local.PendingRelayEvents()
	t.Fatalf("local event outbox did not drain: events=%d err=%v", len(events), err)
}

func waitP2EventOutboxPending(t *testing.T, local *daemon.Store) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		events, err := local.PendingRelayEvents()
		if err == nil && len(events) > 0 {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	events, err := local.PendingRelayEvents()
	t.Fatalf("local event outbox did not retain lost response: events=%d err=%v", len(events), err)
}

func waitP2CanonicalEvents(t *testing.T, env *testEnv, sessionID string, minimum int) []store.SessionEventRow {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		events, err := env.repo.ListEventsAfter(t.Context(), sessionID, 0)
		if err == nil && len(events) >= minimum {
			return events
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("session %s did not receive %d canonical events", sessionID, minimum)
	return nil
}

// GIT-07 / E2E-RELAY-02：真实临时 Git 根只在 Daemon 本机确认。Relay 的专用 SSE 只能携带
// opaque workspace_id；file.read 的文本、相对路径和本机绝对根在 fixture event encoder 后均不得
// 出现在 Relay 事件或账号级 SSE 回放中。
func TestP2ReadOnlyWorkspaceCommandStaysOpaqueAcrossRelay(t *testing.T) {
	root := t.TempDir()
	initP2GitWorkspace(t, root)
	if err := os.MkdirAll(filepath.Join(root, "src"), 0o755); err != nil {
		t.Fatalf("create fixture source directory: %v", err)
	}
	const localOnlyContent = "package privatefixture\nconst localOnly = true\n"
	if err := os.WriteFile(filepath.Join(root, "src", "private.go"), []byte(localOnlyContent), 0o600); err != nil {
		t.Fatalf("write fixture source file: %v", err)
	}

	env := newTestEnv(t)
	owner := env.registerAs(t, "p2-readonly-e2e@test.dev")
	terminal := env.pairTerminal(t, owner, "p2-readonly-terminal")
	terminalID := daemonHello(t, env, terminal.AccessToken)
	sessionID, workspaceID := env.createBoundSessionAtRoot(t, owner, terminalID, "p2-readonly", root)
	epoch := p2SessionLeaseEpoch(t, env, owner.AccessToken, sessionID)

	command := env.do(t, http.MethodPost, "/v1/sessions/"+sessionID+"/commands", map[string]any{
		"kind": "file.read", "idempotency_key": "p2-readonly-file", "lease_epoch": epoch,
		"target_terminal_id": terminalID,
		"ciphertext": map[string]any{
			"ciphertext": map[string]any{"fixture_payload": map[string]any{"path": "src/private.go", "limit": 100}},
		},
	}, owner.AccessToken)
	if command.Code != http.StatusAccepted {
		t.Fatalf("submit read-only command status=%d", command.Code)
	}
	var submitted struct {
		ID string `json:"id"`
	}
	decodeW1(t, command.Body.Bytes(), &submitted)
	if submitted.ID == "" {
		t.Fatal("read-only command id missing")
	}

	// 先检查 Terminal 专用 delivery 的公开边界，再启动真实 Daemon 客户端消费同一条可重放命令。
	deliveryStream := streamDaemonOnce(t, env, terminal.AccessToken, 0)
	if !strings.Contains(deliveryStream, `"workspace_id":"`+workspaceID+`"`) {
		t.Fatal("daemon delivery omitted workspace_id")
	}
	if strings.Contains(deliveryStream, root) || strings.Contains(deliveryStream, "canonical_root") {
		t.Fatal("daemon delivery leaked local workspace root")
	}

	server := httptest.NewServer(env.router)
	defer server.Close()
	local, err := daemon.OpenStore(filepath.Join(t.TempDir(), "daemon.db"))
	if err != nil {
		t.Fatalf("open local daemon store: %v", err)
	}
	defer local.Close()
	if _, err := local.ConfirmWorkspace(workspaceID, root); err != nil {
		t.Fatalf("confirm local workspace: %v", err)
	}
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	runner := daemon.NewSessionRunner(local, map[string]adapter.Adapter{}, logger)
	defer runner.Close(context.Background())
	loop := daemon.NewRelayLoop(local, &daemon.RelayClient{BaseURL: server.URL, AccessToken: terminal.AccessToken}, runner, daemon.FixtureEventEncoder{}, logger)
	loop.DaemonVersion = "p2-readonly-fixture"
	loop.Hostname = "p2-readonly-host"
	loop.Platform = "test"
	loop.Capabilities = []string{"file_read", "git_read"}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- loop.RunWithRetry(ctx) }()

	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		view := env.do(t, http.MethodGet, "/v1/commands/"+submitted.ID, nil, owner.AccessToken)
		var item struct {
			Status string `json:"status"`
		}
		decodeW1(t, view.Body.Bytes(), &item)
		events, eventErr := env.repo.ListEventsAfter(t.Context(), sessionID, 0)
		if view.Code == http.StatusOK && item.Status == domain.CommandSucceeded && eventErr == nil {
			for _, event := range events {
				if event.EventType != "tool.result" {
					continue
				}
				if strings.Contains(event.EnvelopeJSON, localOnlyContent) || strings.Contains(event.EnvelopeJSON, "src/private.go") || strings.Contains(event.EnvelopeJSON, root) {
					cancel()
					<-done
					t.Fatal("relay event envelope leaked local read-only data")
				}
				accountStream := streamAccountUntil(t, env, owner.AccessToken, "event: tool.result")
				if strings.Contains(accountStream, localOnlyContent) || strings.Contains(accountStream, "src/private.go") || strings.Contains(accountStream, root) {
					cancel()
					<-done
					t.Fatal("account SSE replay leaked local read-only data")
				}
				cancel()
				if runErr := <-done; runErr != context.Canceled {
					t.Fatalf("relay loop result=%v want context.Canceled", runErr)
				}
				return
			}
		}
		time.Sleep(10 * time.Millisecond)
	}
	cancel()
	<-done
	t.Fatal("read-only relay-daemon loop did not converge")
}

// pairTerminal 只为隔离 Relay fixture 发行 terminal bearer；生产配对 UI 的凭据交付仍由
// P3/P5 的加密配对流程承担，测试不能把直接签发当成用户流程证据。
func (e *testEnv) pairTerminal(t *testing.T, owner authPair, name string) authPair {
	t.Helper()
	pending := e.do(t, http.MethodPost, "/v1/pairing/requests", map[string]any{
		"role": "terminal", "display_name": name, "platform": "test",
		"identity_public_key": "idk-" + name, "encryption_public_key": "ekk-" + name,
	}, owner.AccessToken)
	if pending.Code != http.StatusCreated {
		t.Fatalf("create terminal pairing status=%d body=%s", pending.Code, pending.Body.String())
	}
	var pairing struct {
		ID string `json:"id"`
	}
	decodeW1(t, pending.Body.Bytes(), &pairing)
	approved := e.do(t, http.MethodPost, "/v1/pairing/requests/"+pairing.ID+"/approve", nil, owner.AccessToken)
	if approved.Code != http.StatusOK {
		t.Fatalf("approve terminal pairing status=%d body=%s", approved.Code, approved.Body.String())
	}
	var device struct {
		ID string `json:"id"`
	}
	decodeW1(t, approved.Body.Bytes(), &device)
	tokens, err := domain.NewAuthService(e.repo).IssueForDevice(t.Context(), owner.AccountID, device.ID)
	if err != nil {
		t.Fatalf("issue isolated terminal token: %v", err)
	}
	return authPair{AccountID: owner.AccountID, AccessToken: tokens.AccessToken, RefreshToken: tokens.RefreshToken, DeviceID: device.ID}
}

func daemonHello(t *testing.T, env *testEnv, token string) string {
	t.Helper()
	response := env.do(t, http.MethodPost, "/v1/daemon/hello", map[string]any{
		"protocol_version": 1, "daemon_version": "fixture", "hostname": "p2-fixture", "platform": "test",
		"capabilities": []string{"start", "git_read"},
	}, token)
	if response.Code != http.StatusOK {
		t.Fatalf("daemon hello status=%d body=%s", response.Code, response.Body.String())
	}
	var hello struct {
		TerminalID string `json:"terminal_id"`
	}
	decodeW1(t, response.Body.Bytes(), &hello)
	if hello.TerminalID == "" {
		t.Fatalf("hello missing terminal id: %s", response.Body.String())
	}
	return hello.TerminalID
}

func (e *testEnv) createBoundSession(t *testing.T, owner authPair, terminalID, projectID string) (string, string) {
	return e.createBoundSessionAtRoot(t, owner, terminalID, projectID, "/fixture/"+projectID)
}

// createBoundSessionAtRoot 为 P2 relay fixture 构造有 Terminal 绑定的 Workspace。Relay 仅保存
// canonical_root 作为已有元数据；命令投递只输出 opaque workspace_id，本机根由 Daemon 单独确认。
func (e *testEnv) createBoundSessionAtRoot(t *testing.T, owner authPair, terminalID, projectID, canonicalRoot string) (string, string) {
	t.Helper()
	ws := e.do(t, http.MethodPost, "/v1/workspaces", map[string]any{
		"project_id": projectID, "terminal_id": terminalID, "canonical_root": canonicalRoot, "status": "active",
	}, owner.AccessToken)
	if ws.Code != http.StatusCreated {
		t.Fatalf("create bound workspace status=%d body=%s", ws.Code, ws.Body.String())
	}
	var workspace struct {
		ID string `json:"id"`
	}
	decodeW1(t, ws.Body.Bytes(), &workspace)
	session := e.do(t, http.MethodPost, "/v1/sessions", map[string]any{"workspace_id": workspace.ID, "provider": "fixture"}, owner.AccessToken)
	if session.Code != http.StatusCreated {
		t.Fatalf("create bound session status=%d body=%s", session.Code, session.Body.String())
	}
	var item struct {
		ID string `json:"id"`
	}
	decodeW1(t, session.Body.Bytes(), &item)
	return item.ID, workspace.ID
}

func p2SessionLeaseEpoch(t *testing.T, env *testEnv, token, sessionID string) int64 {
	t.Helper()
	lease := env.do(t, http.MethodPost, "/v1/sessions/"+sessionID+"/lease", nil, token)
	if lease.Code != http.StatusOK {
		t.Fatalf("acquire lease status=%d body=%s", lease.Code, lease.Body.String())
	}
	var response struct {
		LeaseEpoch int64 `json:"lease_epoch"`
	}
	decodeW1(t, lease.Body.Bytes(), &response)
	return response.LeaseEpoch
}

func opaqueFixtureEnvelope(ciphertext string) map[string]any {
	return map[string]any{
		"alg": "fixture-aead", "key_id": "fixture-key", "nonce": "fixture-nonce",
		"ciphertext": ciphertext, "aad_hash": "fixture-aad", "payload_version": 1,
	}
}

func streamDaemonOnce(t *testing.T, env *testEnv, token string, after int64) string {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	req := httptest.NewRequest(http.MethodGet, "/v1/daemon/commands/stream?after_delivery_seq="+strconv.FormatInt(after, 10), nil).WithContext(ctx)
	req.Header.Set("Authorization", "Bearer "+token)
	recorder := httptest.NewRecorder()
	done := make(chan struct{})
	go func() {
		env.router.ServeHTTP(recorder, req)
		close(done)
	}()
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		body := recorder.Body.String()
		if after > 0 || strings.Contains(body, "event: command") {
			cancel()
			<-done
			return body
		}
		time.Sleep(5 * time.Millisecond)
	}
	cancel()
	<-done
	return recorder.Body.String()
}

// streamAccountUntil 只用于 account SSE 的 replay 断言。它使用可取消请求，不以任意 sleep 作为
// 成功条件；若事件不存在则返回当前内容，由调用方以稳定 oracle 判定失败。
func streamAccountUntil(t *testing.T, env *testEnv, token, expected string) string {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	req := httptest.NewRequest(http.MethodGet, "/v1/events?after_seq=0", nil).WithContext(ctx)
	req.Header.Set("Authorization", "Bearer "+token)
	recorder := httptest.NewRecorder()
	done := make(chan struct{})
	go func() {
		env.router.ServeHTTP(recorder, req)
		close(done)
	}()
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		body := recorder.Body.String()
		if strings.Contains(body, expected) {
			cancel()
			<-done
			return body
		}
		time.Sleep(5 * time.Millisecond)
	}
	cancel()
	<-done
	return recorder.Body.String()
}

func initP2GitWorkspace(t *testing.T, root string) {
	t.Helper()
	command := exec.Command("git", "init", root)
	if output, err := command.CombinedOutput(); err != nil {
		t.Fatalf("initialize temporary Git workspace: %v (%s)", err, strings.TrimSpace(string(output)))
	}
}
