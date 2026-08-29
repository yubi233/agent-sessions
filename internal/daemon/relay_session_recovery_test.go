package daemon

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"
)

// 进程启动清扫声明（POST /v1/daemon/sessions/recover）每进程最多成功一次：
// 瞬时失败不置位、下一次 runOnce 重试；成功后不再重复往返。
func TestRelayLoopStartupSessionRecoveryFiresOnce(t *testing.T) {
	var recoverCalls int
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
		if request.Method != http.MethodPost || request.URL.Path != "/v1/daemon/sessions/recover" {
			t.Errorf("unexpected request %s %s", request.Method, request.URL.Path)
			w.WriteHeader(http.StatusNotFound)
			return
		}
		var body struct {
			ProtocolVersion int `json:"protocol_version"`
		}
		if err := json.NewDecoder(request.Body).Decode(&body); err != nil {
			t.Errorf("decode body: %v", err)
		}
		if body.ProtocolVersion != daemonProtocolVersion {
			t.Errorf("protocol_version=%d, want %d", body.ProtocolVersion, daemonProtocolVersion)
		}
		recoverCalls++
		if recoverCalls == 1 {
			w.WriteHeader(http.StatusInternalServerError)
			_, _ = io.WriteString(w, `{}`)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, `{"recovered_idle":2,"recovered_stopped":1}`)
	}))
	defer server.Close()

	loop := NewRelayLoop(nil, &RelayClient{BaseURL: server.URL, AccessToken: "fixture"}, nil, nil, slog.New(slog.NewTextHandler(io.Discard, nil)))
	ctx := context.Background()

	if err := loop.ensureStartupSessionRecovery(ctx); err == nil {
		t.Fatal("first recovery expected transient failure")
	}
	if loop.sessionRecoveryDone {
		t.Fatal("failed recovery must not mark done")
	}
	if err := loop.ensureStartupSessionRecovery(ctx); err != nil {
		t.Fatalf("second recovery: %v", err)
	}
	if err := loop.ensureStartupSessionRecovery(ctx); err != nil {
		t.Fatalf("third recovery: %v", err)
	}
	if recoverCalls != 2 {
		t.Fatalf("recover calls=%d, want 2 (1 failed retry + 1 success, then no more)", recoverCalls)
	}
}
