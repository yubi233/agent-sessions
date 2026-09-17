package daemon

// v0.8.8 P2 只读命令链路 daemon 半段回归（V088-07 / 迭代计划 §5）：
// 移动端形状的只读命令（git.status fixture_payload envelope）经 RelayLoop
// executeAndResolve → ReadOnlyDispatcher（真实 git 仓库沙箱）→ LocalDevEventEncoder
// 投影 "tool_result"（result 结构化对象整体透传）→ 事件上行 + receipt 收口。
// 失败分支：越权路径 → 稳定脱敏错误码（receipt failed），无结果事件。

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// startV088RelayStub 起一个最小 Relay 形状 httptest 端点：接受事件上行与命令收口，
// 并把载荷记录下来供断言（events: POST /v1/daemon/events；results: POST .../result）。
func startV088RelayStub(t *testing.T) (events chan map[string]any, results chan map[string]any, server *httptest.Server) {
	t.Helper()
	events = make(chan map[string]any, 16)
	results = make(chan map[string]any, 16)
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/daemon/events", func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		var payload map[string]any
		_ = json.Unmarshal(body, &payload)
		events <- payload
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"status":"accepted"}`))
	})
	// v0.9.3 V093-02：事件上行默认走批量端点。stub 把批内事件逐条转入同一
	// events 通道（断言视角不变），并按请求条数回传等长回执。
	mux.HandleFunc("/v1/daemon/events/batch", func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		var payload struct {
			Events []map[string]any `json:"events"`
		}
		_ = json.Unmarshal(body, &payload)
		for _, event := range payload.Events {
			events <- event
		}
		receipts := make([]string, len(payload.Events))
		for i := range payload.Events {
			receipts[i] = fmt.Sprintf(`{"event_id":"evt-%d","event_seq":%d,"idempotent":false}`, i+1, i+1)
		}
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"results":[` + strings.Join(receipts, ",") + `]}`))
	})
	mux.HandleFunc("/v1/daemon/commands/", func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		var payload map[string]any
		_ = json.Unmarshal(body, &payload)
		results <- payload
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"status":"succeeded"}`))
	})
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{}`))
	})
	server = httptest.NewServer(mux)
	t.Cleanup(server.Close)
	return events, results, server
}

// setupV088GitWorkspace 造一个带未提交修改的真实 git 仓库 + 已确认工作区。
func setupV088GitWorkspace(t *testing.T) *Store {
	t.Helper()
	root := t.TempDir()
	runGit(t, root, "init")
	runGit(t, root, "config", "user.email", "fixture@example.test")
	runGit(t, root, "config", "user.name", "Fixture")
	if err := os.WriteFile(filepath.Join(root, "app.go"), []byte("package app\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	runGit(t, root, "add", "app.go")
	runGit(t, root, "commit", "-m", "initial")
	if err := os.WriteFile(filepath.Join(root, "app.go"), []byte("package app\n// dirty\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	store, err := OpenStore(filepath.Join(t.TempDir(), "daemon.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = store.Close() })
	if _, err := store.ConfirmWorkspace("ws-readonly", root); err != nil {
		t.Fatalf("confirm workspace: %v", err)
	}
	if err := store.Set("terminal_id", "term-readonly"); err != nil {
		t.Fatal(err)
	}
	return store
}

// TestV088ReadonlyCommandChainProjectsToolResult（V088-07 daemon 半段）：
// git.status 命令全链执行成功，tool_result 投影含结构化 result（snapshot_token 等），
// receipt 以 succeeded 收口。
func TestV088ReadonlyCommandChainProjectsToolResult(t *testing.T) {
	store := setupV088GitWorkspace(t)
	events, results, server := startV088RelayStub(t)
	loop := NewRelayLoop(store, &RelayClient{BaseURL: server.URL, AccessToken: "t"}, nil, NewLocalDevEventEncoder(), slog.New(slog.NewTextHandler(io.Discard, nil)))

	command := fixtureReadOnlyRelayCommand("git.status", "", "", "term-readonly")
	command.CommandID = "cmd-v088-status"
	if err := loop.executeAndResolve(context.Background(), command); err != nil {
		t.Fatalf("executeAndResolve git.status: %v", err)
	}

	// receipt 收口：daemon 上行 succeeded（真实 Relay 以此标记命令终态）。
	var receipt map[string]any
	select {
	case receipt = <-results:
	default:
		t.Fatalf("命令收口未上行")
	}
	if receipt["status"] != "succeeded" {
		t.Fatalf("git.status 应 succeeded，得到 %v error_code=%v", receipt["status"], receipt["error_code"])
	}

	// tool_result 投影：kind=tool_result + command_kind + result（结构化对象）。
	// 上行 envelope 是 JSON 对象（alg/nonce/ciphertext 形状门 + localdev
	// fixture_payload 明文投影），移动端从 snapshot 原始事件读同一形状。
	var toolResult map[string]any
	for i, n := 0, len(events); i < n; i += 1 {
		event := <-events
		if event["event_type"] != "tool.result" {
			continue
		}
		envelope, ok := event["envelope"].(map[string]any)
		if !ok {
			t.Fatalf("事件 envelope 应为对象: %T", event["envelope"])
		}
		fixture, ok := envelope["fixture_payload"].(map[string]any)
		if !ok {
			t.Fatalf("localdev envelope 应含 fixture_payload: %v", envelope)
		}
		if fixture["kind"] != "tool_result" {
			t.Fatalf("只读结果应投影为 tool_result，得到 %v", fixture["kind"])
		}
		if fixture["command_kind"] != "git.status" {
			t.Fatalf("command_kind 关联不符: %v", fixture["command_kind"])
		}
		result, ok := fixture["result"].(map[string]any)
		if !ok || result["snapshot_token"] == "" {
			t.Fatalf("result 应含结构化 git.status 输出: %v", fixture["result"])
		}
		toolResult = fixture
	}
	if toolResult == nil {
		t.Fatalf("未找到 tool.result 事件")
	}
}

// TestV088ReadonlyCommandChainFailsClosedOnDeniedPath（V088-10 负向 daemon 半段）：
// 越权路径（绝对路径）→ receipt failed + 稳定脱敏错误码，无 tool.result 事件。
func TestV088ReadonlyCommandChainFailsClosedOnDeniedPath(t *testing.T) {
	store := setupV088GitWorkspace(t)
	events, results, server := startV088RelayStub(t)
	loop := NewRelayLoop(store, &RelayClient{BaseURL: server.URL, AccessToken: "t"}, nil, NewLocalDevEventEncoder(), slog.New(slog.NewTextHandler(io.Discard, nil)))

	// 绝对路径逃逸（/etc）在 workspacesafe 边界被拒。
	command := fixtureReadOnlyRelayCommand("file.read", "/etc/passwd", "", "term-readonly")
	command.CommandID = "cmd-v088-escape"
	if err := loop.executeAndResolve(context.Background(), command); err != nil {
		t.Fatalf("executeAndResolve 应在 dispatcher 内收口为 failed receipt: %v", err)
	}

	var receipt map[string]any
	select {
	case receipt = <-results:
	default:
		t.Fatalf("命令收口未上行")
	}
	if receipt["status"] != "failed" {
		t.Fatalf("越权路径应 failed，得到 %v", receipt["status"])
	}
	errorCode, _ := receipt["error_code"].(string)
	if errorCode != "WORKSPACE_PATH_DENIED" && errorCode != "INVALID_REQUEST" {
		t.Fatalf("错误码应为稳定脱敏值，得到 %q", errorCode)
	}
	if strings.Contains(errorCode, "/etc") || strings.Contains(receipt["error_code"].(string), "/etc") {
		t.Fatalf("错误码泄漏路径")
	}
	for i, n := 0, len(events); i < n; i += 1 {
		event := <-events
		if event["event_type"] == "tool.result" {
			t.Fatalf("失败路径不得产生 tool.result 事件")
		}
	}
}

// TestCapabilityForCommandSessionControlKinds（V088-14/15 真实栈首曝回归）：
// 会话控制 kind 必须映射到 hello 声明的 capability——缺映射时 relay 门以
// CAPABILITY_UNSUPPORTED 拒绝（v0.8.3 起 mode.set 等在真实栈不可达）。
func TestCapabilityForCommandSessionControlKinds(t *testing.T) {
	cases := map[string]string{
		"mode.set":           "permission_mode",
		"question.answer":    "question",
		"plan.action":        "plan",
		"goal.action":        "goal",
		"skill.invoke":       "invoke_skill",
		"permission.approve": "permission",
		"permission.reject":  "permission",
		"session.fork":       "fork",
	}
	for kind, want := range cases {
		if got := capabilityForCommand(kind); got != want {
			t.Fatalf("capabilityForCommand(%q) = %q, want %q", kind, got, want)
		}
	}
}
