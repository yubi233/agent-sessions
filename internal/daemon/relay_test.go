package daemon

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"sync"
	"testing"

	"github.com/yubi233/agent-sessions/internal/adapter"
	"github.com/yubi233/agent-sessions/packages/protocol"
)

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
		_, _ = io.WriteString(w, `{}`)
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
