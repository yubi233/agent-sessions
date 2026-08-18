package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/yubi233/agent-sessions/internal/adapter"
	"github.com/yubi233/agent-sessions/packages/protocol"
)

type relayRoundTripperFunc func(*http.Request) (*http.Response, error)

func (f relayRoundTripperFunc) RoundTrip(request *http.Request) (*http.Response, error) {
	return f(request)
}

// SYNC-05：已 started 但 Daemon 重启前未写 result 的命令绝不能再次交给 Adapter。
func TestRelayLoopFailsClosedForInterruptedStartedCommand(t *testing.T) {
	store, err := OpenStore(filepath.Join(t.TempDir(), "daemon.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	command := RelayCommand{
		CommandID: "cmd-restart", DeliverySeq: 1, SessionID: "sess-restart", Kind: "session.start", LeaseEpoch: 1,
		TargetTerminalID: "term-restart", PayloadJSON: `{"session_id":"sess-restart","provider":"test"}`,
	}
	if inserted, err := store.RecordRelayCommand(command); err != nil || !inserted {
		t.Fatalf("record command inserted=%v err=%v", inserted, err)
	}
	if err := store.MarkRelayCommandStarted(command.CommandID); err != nil {
		t.Fatal(err)
	}

	var mu sync.Mutex
	var resultStatus, resultCode string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
		if request.Method != http.MethodPost || request.URL.Path != "/v1/daemon/commands/cmd-restart/result" {
			t.Fatalf("unexpected request %s %s", request.Method, request.URL.Path)
		}
		var body struct {
			Status    string `json:"status"`
			ErrorCode string `json:"error_code"`
		}
		if err := json.NewDecoder(request.Body).Decode(&body); err != nil {
			t.Fatal(err)
		}
		mu.Lock()
		resultStatus, resultCode = body.Status, body.ErrorCode
		mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		// Relay 的 result endpoint 返回权威终态；Daemon 重启重放时必须以它回填本机状态，
		// 因此夹具不能用空对象掩盖公开收据契约。
		_, _ = io.WriteString(w, `{"status":"failed","error_code":"DAEMON_RESTART_RECOVERY"}`)
	}))
	defer server.Close()

	guard := &startGuardAdapter{}
	runner := NewSessionRunner(store, map[string]adapter.Adapter{"test": guard}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	defer runner.Close(context.Background())
	loop := NewRelayLoop(store, &RelayClient{BaseURL: server.URL, AccessToken: "fixture"}, runner, nil, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err := loop.processPending(context.Background()); err != nil {
		t.Fatalf("process pending: %v", err)
	}
	mu.Lock()
	gotStatus, gotCode := resultStatus, resultCode
	mu.Unlock()
	if gotStatus != "failed" || gotCode != "DAEMON_RESTART_RECOVERY" {
		t.Fatalf("restart result status=%q code=%q", gotStatus, gotCode)
	}
	if guard.started {
		t.Fatal("interrupted started command must not execute adapter again")
	}
}

// P0-SCHEMA-02：Daemon 的本机执行错误必须投影为协议登记的稳定码，调用方不能从自由错误
// 文本推断是否应重试、升级能力或创建新会话动作。
func TestCommandErrorCodeUsesPublicProtocolCodes(t *testing.T) {
	if got := CommandErrorCode(ErrUnsupportedCommand); got != protocol.ErrCapabilityUnsupported {
		t.Fatalf("unsupported command code=%q want %q", got, protocol.ErrCapabilityUnsupported)
	}
	if got := CommandErrorCode(ErrSessionInstanceMissing); got != protocol.ErrLocalStateMissing {
		t.Fatalf("local instance code=%q want %q", got, protocol.ErrLocalStateMissing)
	}
	if got := CommandErrorCode(context.DeadlineExceeded); got != protocol.ErrDaemonExecutionFailed {
		t.Fatalf("generic command code=%q want %q", got, protocol.ErrDaemonExecutionFailed)
	}
}

// DAEMON-RPC-01：即使专用 SSE 已按 Terminal 认证，Daemon 也不信任 payload 内的目标或能力。
// 不匹配命令必须在本地持久化后以 rejected 收敛，绝不能进入 Provider runner。
func TestRelayLoopRejectsMismatchedTerminalAndUndeclaredCapability(t *testing.T) {
	cases := []struct {
		name         string
		kind         string
		target       string
		capabilities []string
		wantCode     string
	}{
		{name: "target mismatch", kind: "session.start", target: "term-other", capabilities: []string{"start"}, wantCode: protocol.ErrScopeDenied},
		{name: "capability absent", kind: "session.start", target: "term-local", capabilities: []string{"git_read"}, wantCode: protocol.ErrCapabilityUnsupported},
		{name: "kill capability absent", kind: "session.kill", target: "term-local", capabilities: []string{"abort"}, wantCode: protocol.ErrCapabilityUnsupported},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			store, err := OpenStore(filepath.Join(t.TempDir(), "daemon.db"))
			if err != nil {
				t.Fatal(err)
			}
			defer store.Close()
			if err := store.Set("terminal_id", "term-local"); err != nil {
				t.Fatal(err)
			}

			var mu sync.Mutex
			var gotAckKind, gotErrorCode string
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
				if request.Method != http.MethodPost || request.URL.Path != "/v1/daemon/commands/cmd-local-check/ack" {
					t.Fatalf("unexpected request %s %s", request.Method, request.URL.Path)
				}
				var body struct {
					AckKind   string `json:"ack_kind"`
					ErrorCode string `json:"error_code"`
				}
				if err := json.NewDecoder(request.Body).Decode(&body); err != nil {
					t.Fatal(err)
				}
				mu.Lock()
				gotAckKind, gotErrorCode = body.AckKind, body.ErrorCode
				mu.Unlock()
				w.Header().Set("Content-Type", "application/json")
				_, _ = io.WriteString(w, `{}`)
			}))
			defer server.Close()

			guard := &startGuardAdapter{}
			runner := NewSessionRunner(store, map[string]adapter.Adapter{"test": guard}, slog.New(slog.NewTextHandler(io.Discard, nil)))
			defer runner.Close(context.Background())
			loop := NewRelayLoop(store, &RelayClient{BaseURL: server.URL, AccessToken: "fixture"}, runner, nil, slog.New(slog.NewTextHandler(io.Discard, nil)))
			loop.Capabilities = tc.capabilities
			err = loop.handleDelivery(context.Background(), RelayDelivery{DeliverySeq: 1, Command: RelayCommand{
				CommandID: "cmd-local-check", SessionID: "sess-local-check", WorkspaceID: "ws-local-check",
				Kind: tc.kind, LeaseEpoch: 1, TargetTerminalID: tc.target, PayloadJSON: `{}`,
			}})
			if err != nil {
				t.Fatalf("handle delivery: %v", err)
			}
			if guard.started {
				t.Fatal("rejected delivery reached provider runner")
			}
			mu.Lock()
			ackKind, errorCode := gotAckKind, gotErrorCode
			mu.Unlock()
			if ackKind != "rejected" || errorCode != tc.wantCode {
				t.Fatalf("ack=%q/%q want rejected/%q", ackKind, errorCode, tc.wantCode)
			}
			var status, resultStatus, storedCode string
			if err := store.db.QueryRow(`SELECT status,result_status,error_code FROM relay_commands WHERE command_id='cmd-local-check'`).Scan(&status, &resultStatus, &storedCode); err != nil {
				t.Fatal(err)
			}
			if status != "completed" || resultStatus != "rejected" || storedCode != tc.wantCode {
				t.Fatalf("stored rejection=%q/%q/%q", status, resultStatus, storedCode)
			}
		})
	}
}

// SYNC-05：Relay 已持久化 rejected ack、但 HTTP 响应丢失时，本机必须先保持 rejecting。
// Daemon 重启后只能重放 rejected receipt，绝不能把这条不可信命令重新送进 Provider。
func TestRelayLoopReplaysDurableRejectionAfterResponseLoss(t *testing.T) {
	store, err := OpenStore(filepath.Join(t.TempDir(), "daemon.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if err := store.Set("terminal_id", "term-local"); err != nil {
		t.Fatal(err)
	}
	command := RelayCommand{
		CommandID: "cmd-rejection-recovery", DeliverySeq: 1, SessionID: "sess-rejection-recovery", WorkspaceID: "ws-local",
		Kind: "session.start", LeaseEpoch: 1, TargetTerminalID: "term-other", PayloadJSON: `{}`,
	}
	if inserted, err := store.RecordRelayCommand(command); err != nil || !inserted {
		t.Fatalf("record rejection command inserted=%v err=%v", inserted, err)
	}

	var mu sync.Mutex
	ackKinds := []string{}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
		if request.Method != http.MethodPost || request.URL.Path != "/v1/daemon/commands/"+command.CommandID+"/ack" {
			t.Fatalf("unexpected request %s %s", request.Method, request.URL.Path)
		}
		var body struct {
			AckKind string `json:"ack_kind"`
		}
		if err := json.NewDecoder(request.Body).Decode(&body); err != nil {
			t.Fatal(err)
		}
		mu.Lock()
		ackKinds = append(ackKinds, body.AckKind)
		mu.Unlock()
		_, _ = io.WriteString(w, `{}`)
	}))
	defer server.Close()

	dropFirstResponse := true
	client := &http.Client{Transport: relayRoundTripperFunc(func(request *http.Request) (*http.Response, error) {
		response, err := http.DefaultTransport.RoundTrip(request)
		if err != nil {
			return nil, err
		}
		if dropFirstResponse {
			dropFirstResponse = false
			_ = response.Body.Close()
			return nil, io.ErrUnexpectedEOF
		}
		return response, nil
	})}
	guard := &startGuardAdapter{}
	runner := NewSessionRunner(store, map[string]adapter.Adapter{"test": guard}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	defer runner.Close(context.Background())
	loop := NewRelayLoop(store, &RelayClient{BaseURL: server.URL, AccessToken: "fixture", HTTPClient: client}, runner, nil, slog.New(slog.NewTextHandler(io.Discard, nil)))
	loop.Capabilities = []string{"start"}
	if err := loop.rejectDelivery(context.Background(), command, protocol.ErrScopeDenied); err == nil {
		t.Fatal("lost rejected response must leave durable pending state")
	}
	pending, err := store.RelayCommandByID(command.CommandID)
	if err != nil || pending.Status != "rejecting" || pending.ErrorCode != protocol.ErrScopeDenied {
		t.Fatalf("durable rejected state=%+v err=%v", pending, err)
	}

	if err := loop.processPending(context.Background()); err != nil {
		t.Fatalf("replay durable rejection: %v", err)
	}
	settled, err := store.RelayCommandByID(command.CommandID)
	if err != nil || settled.Status != "completed" || settled.ResultStatus != "rejected" || settled.ErrorCode != protocol.ErrScopeDenied {
		t.Fatalf("settled rejected state=%+v err=%v", settled, err)
	}
	if guard.started {
		t.Fatal("recovered rejection reached provider runner")
	}
	mu.Lock()
	defer mu.Unlock()
	if len(ackKinds) != 2 || ackKinds[0] != "rejected" || ackKinds[1] != "rejected" {
		t.Fatalf("replayed ack kinds=%v", ackKinds)
	}
}

// SYNC-05：进程若在 command 本机落盘后、handleDelivery 的即时校验前退出，runOnce 的
// processPending 仍必须重做 Terminal/capability fence，不能因为状态还是 received 而执行。
func TestRelayLoopRecoveryRevalidatesReceivedDeliveryBeforeExecution(t *testing.T) {
	store, err := OpenStore(filepath.Join(t.TempDir(), "daemon.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if err := store.Set("terminal_id", "term-local"); err != nil {
		t.Fatal(err)
	}
	command := RelayCommand{
		CommandID: "cmd-recovery-fence", DeliverySeq: 1, SessionID: "sess-recovery-fence", WorkspaceID: "ws-local",
		Kind: "session.start", LeaseEpoch: 1, TargetTerminalID: "term-other", PayloadJSON: `{}`,
	}
	if inserted, err := store.RecordRelayCommand(command); err != nil || !inserted {
		t.Fatalf("record received command inserted=%v err=%v", inserted, err)
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
		var body struct {
			AckKind   string `json:"ack_kind"`
			ErrorCode string `json:"error_code"`
		}
		if request.Method != http.MethodPost || request.URL.Path != "/v1/daemon/commands/"+command.CommandID+"/ack" || json.NewDecoder(request.Body).Decode(&body) != nil || body.AckKind != "rejected" || body.ErrorCode != protocol.ErrScopeDenied {
			t.Fatalf("unexpected rejection replay %s %s %+v", request.Method, request.URL.Path, body)
		}
		_, _ = io.WriteString(w, `{}`)
	}))
	defer server.Close()
	guard := &startGuardAdapter{}
	runner := NewSessionRunner(store, map[string]adapter.Adapter{"test": guard}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	defer runner.Close(context.Background())
	loop := NewRelayLoop(store, &RelayClient{BaseURL: server.URL, AccessToken: "fixture"}, runner, nil, slog.New(slog.NewTextHandler(io.Discard, nil)))
	loop.Capabilities = []string{"start"}
	if err := loop.processPending(context.Background()); err != nil {
		t.Fatalf("recover received invalid delivery: %v", err)
	}
	if guard.started {
		t.Fatal("unvalidated received delivery reached provider runner")
	}
	settled, err := store.RelayCommandByID(command.CommandID)
	if err != nil || settled.ResultStatus != "rejected" || settled.ErrorCode != protocol.ErrScopeDenied {
		t.Fatalf("recovered rejection=%+v err=%v", settled, err)
	}
}

// DAEMON-RPC-01：长连接 SSE 不得继承普通 REST 的总请求超时。这里让普通 client 仅有 20ms
// timeout，而 Relay 60ms 后才推送命令；正确实现依赖 Stream 的 context 管理而不会自行断流。
func TestRelayClientStreamDoesNotInheritRESTTimeout(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		if flusher, ok := w.(http.Flusher); ok {
			flusher.Flush()
		}
		select {
		case <-request.Context().Done():
			return
		case <-time.After(60 * time.Millisecond):
		}
		_, _ = io.WriteString(w, "event: command\ndata: {\"delivery_seq\":1,\"command\":{\"id\":\"cmd-stream\",\"session_id\":\"sess-stream\",\"workspace_id\":\"ws-stream\",\"kind\":\"session.abort\",\"lease_epoch\":1,\"target_terminal_id\":\"term-stream\",\"ciphertext\":{}}}\n\n")
		if flusher, ok := w.(http.Flusher); ok {
			flusher.Flush()
		}
	}))
	defer server.Close()
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	client := &RelayClient{
		BaseURL: server.URL, AccessToken: "fixture", HTTPClient: &http.Client{Timeout: 20 * time.Millisecond},
	}
	var received RelayDelivery
	err := client.Stream(ctx, 0, func(_ context.Context, delivery RelayDelivery) error {
		received = delivery
		cancel()
		return nil
	})
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("stream err=%v, want context.Canceled after delivery", err)
	}
	if received.DeliverySeq != 1 || received.Command.CommandID != "cmd-stream" {
		t.Fatalf("stream delivery=%+v", received)
	}
}

type startGuardAdapter struct {
	started bool
}

func (a *startGuardAdapter) Detect(context.Context) (adapter.Capabilities, error) {
	return adapter.Capabilities{Provider: "test"}, nil
}

func (a *startGuardAdapter) Capabilities() adapter.Capabilities {
	return adapter.Capabilities{Provider: "test"}
}

func (a *startGuardAdapter) Start(context.Context, adapter.StartRequest) (adapter.Handle, error) {
	a.started = true
	return nil, nil
}

func (a *startGuardAdapter) Resume(context.Context, adapter.ResumeRequest) (adapter.ResumeResult, error) {
	return adapter.ResumeResult{Result: adapter.WakeUnsupported}, nil
}
