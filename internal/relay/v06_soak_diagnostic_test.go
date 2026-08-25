package relay

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/yubi233/agent-sessions/internal/domain"
)

// TestV06SoakSQLiteConcurrencyAndOutboxBacklog 是 P3 的受限并发诊断（非生产性能目标）：
// 在单个共享 SQLite 上以真实 HTTP 栈并发提交命令并上传密文事件，
// 记录延迟分位、错误分类与 outbox 积压，用于说明当前单写者架构是否满足单租户范围。
// 口径：local_test=true、fixture_data=true、real_browser=false、real_model=false、headless=false。
func TestV06SoakSQLiteConcurrencyAndOutboxBacklog(t *testing.T) {
	if testing.Short() {
		t.Skip("soak diagnostic skipped in -short mode")
	}
	env := newTestEnv(t)
	server := httptest.NewServer(env.router)
	t.Cleanup(server.Close)
	client := server.Client()

	doJSON := func(method, path string, body any, token string) (int, []byte) {
		raw, _ := json.Marshal(body)
		req, err := http.NewRequest(method, server.URL+path, strings.NewReader(string(raw)))
		if err != nil {
			return 0, nil
		}
		req.Header.Set("Content-Type", "application/json")
		if token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
		}
		resp, err := client.Do(req)
		if err != nil {
			return 0, nil
		}
		defer resp.Body.Close()
		var buf strings.Builder
		tmp := make([]byte, 4096)
		for {
			n, err := resp.Body.Read(tmp)
			buf.Write(tmp[:n])
			if err != nil {
				break
			}
		}
		return resp.StatusCode, []byte(buf.String())
	}

	owner := env.registerAs(t, "v06-soak@test.dev")
	token := owner.AccessToken

	// Terminal 配对 + bearer 签发（与 pairTerminal 相同流程，但保留 device id 供后续使用）。
	statusCode, bodyBytes := doJSON(http.MethodPost, "/v1/pairing/requests", map[string]any{
		"role": "terminal", "display_name": "v06-soak-terminal", "platform": "test",
		"identity_public_key": "idk-soak", "encryption_public_key": "ekk-soak",
	}, token)
	if statusCode != http.StatusCreated {
		t.Fatalf("pairing status=%d", statusCode)
	}
	var pairingView struct {
		ID string `json:"id"`
	}
	_ = json.Unmarshal(bodyBytes, &pairingView)
	approveStatus, approveBody := doJSON(http.MethodPost, "/v1/pairing/requests/"+pairingView.ID+"/approve", nil, token)
	if approveStatus != http.StatusOK {
		t.Fatalf("approve status=%d", approveStatus)
	}
	var approvedDevice struct {
		ID string `json:"id"`
	}
	_ = json.Unmarshal(approveBody, &approvedDevice)
	tokens, err := domain.NewAuthService(env.repo).IssueForDevice(t.Context(), owner.AccountID, approvedDevice.ID)
	if err != nil {
		t.Fatalf("issue terminal token: %v", err)
	}
	terminalToken := tokens.AccessToken

	helloStatus, helloBody := doJSON(http.MethodPost, "/v1/daemon/hello", map[string]any{
		"protocol_version": 1, "daemon_version": "v06-soak", "hostname": "soak", "platform": "test",
		"capabilities": []string{"start"},
	}, terminalToken)
	if helloStatus != http.StatusOK {
		t.Fatalf("daemon hello status=%d body=%s", helloStatus, helloBody)
	}
	var helloView struct {
		TerminalID string `json:"terminal_id"`
	}
	_ = json.Unmarshal(helloBody, &helloView)

	wsStatus, wsBody := doJSON(http.MethodPost, "/v1/workspaces", map[string]any{
		"project_id": "proj-v06-soak", "terminal_id": helloView.TerminalID,
		"canonical_root": "/fixture/v06-soak", "status": "active",
	}, token)
	if wsStatus != http.StatusCreated {
		t.Fatalf("workspace status=%d body=%s", wsStatus, wsBody)
	}
	var workspaceView struct {
		ID string `json:"id"`
	}
	_ = json.Unmarshal(wsBody, &workspaceView)
	sessionStatus, sessionBody := doJSON(http.MethodPost, "/v1/sessions", map[string]any{
		"workspace_id": workspaceView.ID, "provider": "fixture",
	}, token)
	if sessionStatus != http.StatusCreated {
		t.Fatalf("session status=%d", sessionStatus)
	}
	var sessionView struct {
		ID string `json:"id"`
	}
	_ = json.Unmarshal(sessionBody, &sessionView)
	leaseStatus, leaseBody := doJSON(http.MethodPost, "/v1/sessions/"+sessionView.ID+"/lease", nil, token)
	if leaseStatus != http.StatusOK {
		t.Fatalf("lease status=%d", leaseStatus)
	}
	var leaseView struct {
		LeaseEpoch int64 `json:"lease_epoch"`
	}
	_ = json.Unmarshal(leaseBody, &leaseView)

	const (
		workers          = 6
		commandsEach     = 12
		eventsPerCommand = 2
	)
	submitLatencies := make([]int64, 0, workers*commandsEach)
	eventLatencies := make([]int64, 0, workers*commandsEach*eventsPerCommand)
	var mu sync.Mutex
	var serverErrors, otherNonOK int64

	var wg sync.WaitGroup
	startBarrier := time.Now().Add(50 * time.Millisecond)
	for w := 0; w < workers; w++ {
		wg.Add(1)
		go func(worker int) {
			defer wg.Done()
			time.Sleep(time.Until(startBarrier))
			for i := 0; i < commandsEach; i++ {
				key := fmt.Sprintf("v06-soak-%d-%d", worker, i)
				begin := time.Now()
				code, body := doJSON(http.MethodPost, "/v1/sessions/"+sessionView.ID+"/commands", map[string]any{
					"kind": "session.send", "idempotency_key": key, "lease_epoch": leaseView.LeaseEpoch,
					"target_terminal_id": helloView.TerminalID,
					"ciphertext": map[string]any{
						"kind": "session.send", "session_id": sessionView.ID,
						"ciphertext": map[string]any{"fixture_payload": map[string]any{"worker": worker}},
					},
				}, token)
				elapsed := time.Since(begin).Milliseconds()
				mu.Lock()
				submitLatencies = append(submitLatencies, elapsed)
				mu.Unlock()
				if code == http.StatusInternalServerError {
					mu.Lock()
					serverErrors++
					mu.Unlock()
					continue
				}
				if code != http.StatusAccepted {
					mu.Lock()
					otherNonOK++
					mu.Unlock()
					continue
				}
				var submitted struct {
					ID string `json:"id"`
				}
				_ = json.Unmarshal(body, &submitted)
				for e := 0; e < eventsPerCommand; e++ {
					eventBegin := time.Now()
					eventCode, _ := doJSON(http.MethodPost, "/v1/daemon/events", map[string]any{
						"protocol_version": 1,
						"event_id":         fmt.Sprintf("%s-evt-%d", key, e),
						"command_id":       submitted.ID,
						"session_id":       sessionView.ID,
						"event_type":       "message.completed",
						"envelope": map[string]any{
							"alg": "fixture-aead", "key_id": "k", "nonce": "n",
							"ciphertext": "opaque", "aad_hash": "a", "payload_version": 1,
						},
					}, terminalToken)
					elapsedEvent := time.Since(eventBegin).Milliseconds()
					mu.Lock()
					eventLatencies = append(eventLatencies, elapsedEvent)
					switch {
					case eventCode >= 500:
						serverErrors++
					case eventCode != http.StatusOK:
						otherNonOK++
					}
					mu.Unlock()
				}
			}
		}(w)
	}
	wg.Wait()

	percentile := func(values []int64, p float64) int64 {
		if len(values) == 0 {
			return 0
		}
		sorted := append([]int64(nil), values...)
		sort.Slice(sorted, func(i, j int) bool { return sorted[i] < sorted[j] })
		return sorted[int(float64(len(sorted)-1)*p)]
	}

	diagStatus, diagBody := doJSON(http.MethodGet, "/v1/diagnostics", nil, token)
	if diagStatus != http.StatusOK {
		t.Fatalf("diagnostics status=%d", diagStatus)
	}
	var diag struct {
		Outbox struct {
			Pending   int64 `json:"pending"`
			Failed    int64 `json:"failed"`
			Delivered int64 `json:"delivered"`
		} `json:"outbox"`
	}
	_ = json.Unmarshal(diagBody, &diag)

	metrics := map[string]any{
		"commands_submitted":        len(submitLatencies),
		"events_uploaded":           len(eventLatencies),
		"submit_p50_ms":             percentile(submitLatencies, 0.5),
		"submit_p95_ms":             percentile(submitLatencies, 0.95),
		"event_p50_ms":              percentile(eventLatencies, 0.5),
		"event_p95_ms":              percentile(eventLatencies, 0.95),
		"server_errors_5xx":         serverErrors,
		"non_acceptance_responses":  otherNonOK,
		"outbox_pending_after_load": diag.Outbox.Pending,
		"outbox_failed_after_load":  diag.Outbox.Failed,
		"outbox_delivered_total":    diag.Outbox.Delivered,
		"workers":                   workers,
		"events_per_command":        eventsPerCommand,
	}
	encoded, _ := json.Marshal(metrics)
	t.Logf("V06_SOAK_METRICS=%s", encoded)

	if serverErrors != 0 {
		t.Fatalf("soak exposed %d server-side 5xx under bounded concurrency", serverErrors)
	}
	if diag.Outbox.Failed != 0 {
		t.Fatalf("soak produced failed outbox rows: %d", diag.Outbox.Failed)
	}
	// 每条 command.updated 都随命令事务入队；积压等于已提交命令数是预期状态，
	// 由 OutboxWorker 消化。这里钉住"不丢行、不失败"，不设定性能阈值。
	if diag.Outbox.Pending+diag.Outbox.Delivered < int64(len(submitLatencies)) {
		t.Fatalf("outbox lost rows: pending=%d delivered=%d submitted=%d",
			diag.Outbox.Pending, diag.Outbox.Delivered, len(submitLatencies))
	}
}
