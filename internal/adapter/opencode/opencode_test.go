package opencode

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/yubi233/agent-sessions/internal/adapter"
)

// fixtureServer 是 OpenCode 1.17 server 的 httptest 模拟。
// 只暴露本轮 transport 用到的端点：health/session/message/prompt_async/abort/event。
type fixtureServer struct {
	*httptest.Server
	mu       sync.Mutex
	sessions map[string]fixtureSession
	seq      int
	// events 是按 session 追加的原始事件（测试注入）。
	events map[string][]string
}

type fixtureSession struct {
	id       string
	messages int
	// 最近一次 prompt_async 收到的 model（验证透传）。
	lastModel string
}

// newFixtureServer 构造 fixture server；authRequired 为 true 时校验 Basic Auth。
func newFixtureServer(t *testing.T, authRequired bool) *fixtureServer {
	t.Helper()
	f := &fixtureServer{
		sessions: map[string]fixtureSession{},
		events:   map[string][]string{},
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/global/health", func(w http.ResponseWriter, r *http.Request) {
		if !f.authorize(w, r, authRequired) {
			return
		}
		writeJSON(w, map[string]any{"healthy": true, "version": "1.17.13"})
	})
	mux.HandleFunc("/session", func(w http.ResponseWriter, r *http.Request) {
		if !f.authorize(w, r, authRequired) {
			return
		}
		switch r.Method {
		case http.MethodPost:
			f.mu.Lock()
			f.seq++
			id := fmt.Sprintf("ses_fixture_%d", f.seq)
			f.sessions[id] = fixtureSession{id: id}
			f.events[id] = nil
			f.mu.Unlock()
			writeJSON(w, map[string]any{
				"id": id, "title": "probe", "version": "1.17.13",
				"tokens": map[string]int64{"input": 0, "output": 0, "reasoning": 0},
			})
		case http.MethodGet:
			writeJSON(w, map[string]any{"all": []any{}, "default": map[string]any{}, "connected": []string{}})
		default:
			w.WriteHeader(http.StatusMethodNotAllowed)
		}
	})
	mux.HandleFunc("/session/status", func(w http.ResponseWriter, r *http.Request) {
		if !f.authorize(w, r, authRequired) {
			return
		}
		writeJSON(w, map[string]any{})
	})
	mux.HandleFunc("/session/", func(w http.ResponseWriter, r *http.Request) {
		if !f.authorize(w, r, authRequired) {
			return
		}
		path := strings.TrimPrefix(r.URL.Path, "/session/")
		id, rest, _ := strings.Cut(path, "/")
		if rest == "" {
			f.handleSession(w, r, id)
			return
		}
		switch rest {
		case "message":
			f.handleMessages(w, r, id)
		case "prompt_async":
			f.handlePromptAsync(w, r, id)
		case "abort":
			f.handleAbort(w, r, id)
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	})
	mux.HandleFunc("/event", func(w http.ResponseWriter, r *http.Request) {
		if !f.authorize(w, r, authRequired) {
			return
		}
		f.handleEvents(w, r)
	})
	f.Server = httptest.NewServer(mux)
	t.Cleanup(f.Server.Close)
	return f
}

// authorize 校验 Basic Auth（fixture 凭据固定为 opencode/fixture-password）。
func (f *fixtureServer) authorize(w http.ResponseWriter, r *http.Request, required bool) bool {
	if !required {
		return true
	}
	user, pass, ok := r.BasicAuth()
	if ok && user == "opencode" && pass == "fixture-password" {
		return true
	}
	w.Header().Set("WWW-Authenticate", `Basic realm="Secure Area"`)
	w.WriteHeader(http.StatusUnauthorized)
	return false
}

func (f *fixtureServer) handleSession(w http.ResponseWriter, r *http.Request, id string) {
	f.mu.Lock()
	s, ok := f.sessions[id]
	f.mu.Unlock()
	if !ok {
		w.WriteHeader(http.StatusNotFound)
		return
	}
	writeJSON(w, map[string]any{"id": s.id, "title": "probe", "version": "1.17.13"})
}

func (f *fixtureServer) handleMessages(w http.ResponseWriter, r *http.Request, id string) {
	f.mu.Lock()
	s, ok := f.sessions[id]
	f.mu.Unlock()
	if !ok {
		w.WriteHeader(http.StatusNotFound)
		return
	}
	msgs := []any{}
	if s.messages > 0 {
		msgs = append(msgs, map[string]any{
			"info": map[string]any{"id": "msg_1", "role": "assistant", "sessionID": id},
			"parts": []any{map[string]any{
				"id": "prt_1", "type": "text", "text": "hello",
			}},
		})
	}
	writeJSON(w, msgs)
}

func (f *fixtureServer) handlePromptAsync(w http.ResponseWriter, r *http.Request, id string) {
	f.mu.Lock()
	s, ok := f.sessions[id]
	f.mu.Unlock()
	if !ok {
		w.WriteHeader(http.StatusNotFound)
		return
	}
	// 记录消息数与模型透传（Resume 判断上下文用）。
	var body struct {
		Model map[string]string `json:"model"`
	}
	_ = json.NewDecoder(r.Body).Decode(&body)
	f.mu.Lock()
	s.messages++
	s.lastModel = body.Model["providerID"] + "/" + body.Model["modelID"]
	f.sessions[id] = s
	f.mu.Unlock()
	w.WriteHeader(http.StatusNoContent)
}

func (f *fixtureServer) handleAbort(w http.ResponseWriter, r *http.Request, id string) {
	f.mu.Lock()
	_, ok := f.sessions[id]
	f.mu.Unlock()
	if !ok {
		w.WriteHeader(http.StatusNotFound)
		return
	}
	writeJSON(w, true)
}

// emitEvent 向指定会话追加一条 SSE 事件（测试注入，序列化后经 /event 流出）。
func (f *fixtureServer) emitEvent(t *testing.T, sessionID, eventType string, props any) {
	t.Helper()
	raw, err := json.Marshal(props)
	if err != nil {
		t.Fatalf("marshal props: %v", err)
	}
	event := map[string]any{
		"id":         fmt.Sprintf("evt_fixture_%d", len(f.events[sessionID])),
		"type":       eventType,
		"properties": json.RawMessage(raw),
	}
	line, _ := json.Marshal(event)
	f.mu.Lock()
	f.events[sessionID] = append(f.events[sessionID], string(line))
	f.mu.Unlock()
}

func (f *fixtureServer) handleEvents(w http.ResponseWriter, r *http.Request) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		w.WriteHeader(http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	// 首帧 server.connected（与真实服务一致）。
	fmt.Fprintf(w, "data: {\"id\":\"evt_conn\",\"type\":\"server.connected\",\"properties\":{}}\n\n")
	flusher.Flush()
	stop := r.Context().Done()
	ticker := time.NewTicker(50 * time.Millisecond)
	defer ticker.Stop()
	lastCount := -1
	for {
		select {
		case <-stop:
			return
		case <-ticker.C:
			f.mu.Lock()
			total := 0
			for _, evs := range f.events {
				total += len(evs)
			}
			if total != lastCount {
				lastCount = total
				// 输出所有会话的新事件（按注入顺序）。
				for _, evs := range f.events {
					for _, line := range evs {
						fmt.Fprintf(w, "data: %s\n\n", line)
					}
				}
				f.mu.Unlock()
				flusher.Flush()
				continue
			}
			f.mu.Unlock()
			// 心跳保持连接（真实服务 ~10s 一次；fixture 缩短以快速验证不阻塞）。
			fmt.Fprintf(w, "data: {\"id\":\"evt_hb\",\"type\":\"server.heartbeat\",\"properties\":{}}\n\n")
			flusher.Flush()
		}
	}
}

// writeJSON 写 JSON 响应。
func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
}

// newFixtureClient 构造指向 fixture 的客户端（带凭据）。
func newFixtureClient(t *testing.T, f *fixtureServer) *Client {
	t.Helper()
	t.Setenv(EnvURL, f.Server.URL)
	t.Setenv(EnvUsername, "opencode")
	t.Setenv(EnvPassword, "fixture-password")
	c, err := NewClient()
	if err != nil {
		t.Fatalf("client: %v", err)
	}
	return c
}

// mustEvent 等待 handle 事件流中的下一条事件。
func mustEvent(t *testing.T, h adapter.Handle, timeout time.Duration) adapter.Event {
	t.Helper()
	select {
	case ev, ok := <-h.Events():
		if !ok {
			t.Fatalf("event channel closed")
		}
		return ev
	case <-time.After(timeout):
		t.Fatalf("timeout waiting for event")
		return adapter.Event{}
	}
}

// ---- ADPT-OPENCODE-01：服务发现与 fail-closed ----

// 未配置 URL 时能力必须全部 unsupported 并带中文原因，且不写 Version。
func TestDetectFailsClosedWithoutURL(t *testing.T) {
	t.Setenv(EnvURL, "")
	t.Setenv(EnvPassword, "")
	a := New()
	caps, err := a.Detect(context.Background())
	if err != nil {
		t.Fatalf("detect: %v", err)
	}
	if caps.Version != "" {
		t.Fatalf("version = %q, want empty", caps.Version)
	}
	if len(caps.Capabilities) != len(adapter.CapabilityNames) {
		t.Fatalf("capabilities len = %d, want %d", len(caps.Capabilities), len(adapter.CapabilityNames))
	}
	for _, c := range caps.Capabilities {
		if c.Status != adapter.CapabilityUnsupported {
			t.Fatalf("%s status = %q, want unsupported", c.Name, c.Status)
		}
		if c.Reason == "" {
			t.Fatalf("%s must explain unavailable transport", c.Name)
		}
	}
	// 未探测成功时 Start/Resume 必须与能力声明一致。
	if _, err := a.Start(context.Background(), adapter.StartRequest{WorkspaceRoot: "/tmp/x"}); err == nil {
		t.Fatalf("start must fail without transport")
	}
	resume, err := a.Resume(context.Background(), adapter.ResumeRequest{InstanceID: "ses_x"})
	if err != nil {
		t.Fatalf("resume: %v", err)
	}
	if resume.Result != adapter.WakeUnsupported {
		t.Fatalf("resume result = %q, want unsupported", resume.Result)
	}
}

// 配置了不可达 URL 时同样 fail-closed：探测失败不能单独把能力升为 native。
func TestDetectFailsClosedWithUnreachableURL(t *testing.T) {
	t.Setenv(EnvURL, "http://127.0.0.1:1")
	t.Setenv(EnvUsername, "opencode")
	t.Setenv(EnvPassword, "whatever")
	a := New()
	caps, err := a.Detect(context.Background())
	if err != nil {
		t.Fatalf("detect: %v", err)
	}
	if caps.Version != "" {
		t.Fatalf("version = %q, want empty", caps.Version)
	}
	for _, c := range caps.Capabilities {
		if c.Status != adapter.CapabilityUnsupported {
			t.Fatalf("%s status = %q, want unsupported", c.Name, c.Status)
		}
	}
}

// 配置健康 fixture 后：Version 写入，已实现能力 native，其余 unsupported 带中文原因。
func TestDetectUpgradesCapabilitiesFromHealth(t *testing.T) {
	f := newFixtureServer(t, true)
	c := newFixtureClient(t, f)
	a := NewWithClient(c)
	caps, err := a.Detect(context.Background())
	if err != nil {
		t.Fatalf("detect: %v", err)
	}
	if caps.Provider != "opencode" || caps.Version != "1.17.13" {
		t.Fatalf("provider/version = %q/%q", caps.Provider, caps.Version)
	}
	byName := map[string]adapter.Capability{}
	for _, cap := range caps.Capabilities {
		byName[cap.Name] = cap
	}
	// 已实现并通过契约：start/resume/abort/usage native。
	for _, name := range []string{"start", "resume", "abort", "usage"} {
		if byName[name].Status != adapter.CapabilityNative {
			t.Fatalf("%s status = %q, want native", name, byName[name].Status)
		}
	}
	// 未实现能力保持 unsupported 且带中文原因（ADPT-OPENCODE-07：permission_mode 未实现必须 fail-closed）。
	for _, name := range []string{"permission", "permission_mode", "question", "plan", "goal",
		"skill_catalog", "invoke_skill", "model_select", "effort_select", "attachments",
		"file_read", "git_read", "delegate_session", "delegate_cross_provider"} {
		if byName[name].Status != adapter.CapabilityUnsupported {
			t.Fatalf("%s status = %q, want unsupported", name, byName[name].Status)
		}
		if byName[name].Reason == "" {
			t.Fatalf("%s must explain why unsupported", name)
		}
	}
}

// 凭据缺失（401）时探测失败：不写 Version、全部 unsupported。
func TestDetectFailsClosedOnAuthFailure(t *testing.T) {
	f := newFixtureServer(t, true)
	t.Setenv(EnvURL, f.Server.URL)
	t.Setenv(EnvPassword, "") // 无凭据
	c, err := NewClient()
	if err != nil {
		t.Fatalf("client: %v", err)
	}
	a := NewWithClient(c)
	caps, err := a.Detect(context.Background())
	if err != nil {
		t.Fatalf("detect: %v", err)
	}
	if caps.Version != "" {
		t.Fatalf("version = %q, want empty", caps.Version)
	}
	for _, cap := range caps.Capabilities {
		if cap.Status != adapter.CapabilityUnsupported {
			t.Fatalf("%s status = %q, want unsupported", cap.Name, cap.Status)
		}
	}
}

// ---- ADPT-OPENCODE-02：session 映射与恢复语义 ----

// Start 创建会话、Send 走 prompt_async、SSE 事件按 canonical 映射。
func TestStartSendAbortAndEventMapping(t *testing.T) {
	f := newFixtureServer(t, true)
	c := newFixtureClient(t, f)
	a := NewWithClient(c)

	h, err := a.Start(context.Background(), adapter.StartRequest{
		WorkspaceRoot: "/tmp/ws", Provider: "opencode", Prompt: "初始消息",
		Model: "opencode-go/deepseek-v4-flash",
	})
	if err != nil {
		t.Fatalf("start: %v", err)
	}
	defer h.Dispose(context.Background())

	handle := h.(*handle)
	if handle.sessionID == "" || !strings.HasPrefix(handle.sessionID, "ses_fixture_") {
		t.Fatalf("unexpected session id %q", handle.sessionID)
	}
	// Start 的初始 prompt 必须把模型选择透传给服务端。
	f.mu.Lock()
	startModel := f.sessions[handle.sessionID].lastModel
	f.mu.Unlock()
	if startModel != "opencode-go/deepseek-v4-flash" {
		t.Fatalf("start model = %q, want 透传 opencode-go/deepseek-v4-flash", startModel)
	}

	// Send 命中 prompt_async（204）且保持模型透传。
	if err := h.Send(context.Background(), "继续"); err != nil {
		t.Fatalf("send: %v", err)
	}
	f.mu.Lock()
	sendModel := f.sessions[handle.sessionID].lastModel
	f.mu.Unlock()
	if sendModel != "opencode-go/deepseek-v4-flash" {
		t.Fatalf("send model = %q, want 保持模型透传", sendModel)
	}

	// 注入流式事件序列：busy -> part.delta -> part.updated(text) -> tool -> step-finish -> session.error。
	// session.error 还应自动追发唯一的 turn_completed(error) 终态。
	sid := handle.sessionID
	f.emitEvent(t, sid, "session.status", map[string]any{"sessionID": sid, "status": map[string]string{"type": "busy"}})
	f.emitEvent(t, sid, "message.part.delta", map[string]any{
		"sessionID": sid, "messageID": "msg_1", "partID": "prt_1", "field": "text", "delta": "你好",
	})
	f.emitEvent(t, sid, "message.part.delta", map[string]any{
		"sessionID": sid, "messageID": "msg_1", "partID": "prt_1", "field": "text", "delta": "世界",
	})
	f.emitEvent(t, sid, "message.part.updated", map[string]any{
		"sessionID": sid,
		"part": map[string]any{
			"id": "prt_1", "messageID": "msg_1", "sessionID": sid,
			"type": "text", "text": "你好世界",
		},
	})
	f.emitEvent(t, sid, "message.part.updated", map[string]any{
		"sessionID": sid,
		"part": map[string]any{
			"id": "prt_2", "messageID": "msg_1", "sessionID": sid,
			"type": "tool", "tool": "read", "state": "running", "input": map[string]string{"path": "a.txt"},
		},
	})
	f.emitEvent(t, sid, "message.part.updated", map[string]any{
		"sessionID": sid,
		"part": map[string]any{
			"id": "prt_2", "messageID": "msg_1", "sessionID": sid,
			"type": "tool", "tool": "read", "state": "completed", "output": "file content",
		},
	})
	f.emitEvent(t, sid, "message.part.updated", map[string]any{
		"sessionID": sid,
		"part": map[string]any{
			"id": "prt_3", "messageID": "msg_1", "sessionID": sid,
			"type": "step-finish", "reason": "stop",
			"tokens": map[string]int64{"total": 100, "input": 60, "output": 40},
		},
	})
	f.emitEvent(t, sid, "session.error", map[string]any{"sessionID": sid, "error": "provider exhausted"})

	timeout := 5 * time.Second
	seen := map[adapter.EventType]bool{}
	for i := 0; i < 9; i++ {
		ev := mustEvent(t, h, timeout)
		seen[ev.Type] = true
		switch ev.Type {
		case adapter.EventTurnStarted:
			if ev.Payload["instance_id"] != sid {
				t.Fatalf("turn_started instance = %v", ev.Payload["instance_id"])
			}
		case adapter.EventMessageDelta:
			text, _ := ev.Payload["text"].(string)
			if text != "你好" && text != "世界" {
				t.Fatalf("delta text = %q", text)
			}
		case adapter.EventMessageCompleted:
			if ev.Payload["text"] != "你好世界" {
				t.Fatalf("completed text = %v", ev.Payload["text"])
			}
		case adapter.EventToolCall:
			if ev.Payload["tool_name"] != "read" {
				t.Fatalf("tool_call name = %v", ev.Payload["tool_name"])
			}
		case adapter.EventToolResult:
			if ev.Payload["tool_name"] != "read" || ev.Payload["output"] != "file content" {
				t.Fatalf("tool_result = %v", ev.Payload)
			}
		case adapter.EventUsage:
			if ev.Payload["total_tokens"] != int64(100) {
				t.Fatalf("usage = %v", ev.Payload)
			}
		case adapter.EventSessionError:
			if !strings.Contains(ev.Payload["message"].(string), "provider") {
				t.Fatalf("session_error message = %v", ev.Payload["message"])
			}
		case adapter.EventTurnCompleted:
			if ev.Payload["instance_id"] != sid || ev.Payload["stop_reason"] != "error" {
				t.Fatalf("turn_completed = %v", ev.Payload)
			}
		default:
			t.Fatalf("unexpected event type %q", ev.Type)
		}
	}
	if !seen[adapter.EventTurnStarted] || !seen[adapter.EventMessageDelta] ||
		!seen[adapter.EventMessageCompleted] || !seen[adapter.EventToolCall] ||
		!seen[adapter.EventToolResult] || !seen[adapter.EventUsage] || !seen[adapter.EventSessionError] ||
		!seen[adapter.EventTurnCompleted] {
		t.Fatalf("missing mapped events: %v", seen)
	}

	// Abort 命中 /abort。
	if err := h.Abort(context.Background()); err != nil {
		t.Fatalf("abort: %v", err)
	}
}

// Resume 三态：有消息 -> resumed；空会话 -> restarted_with_context；404 -> unsupported。
func TestResumeThreeStates(t *testing.T) {
	f := newFixtureServer(t, true)
	c := newFixtureClient(t, f)
	a := NewWithClient(c)

	// 创建两个会话：一个发过消息（有上下文），一个为空。
	h1, err := a.Start(context.Background(), adapter.StartRequest{WorkspaceRoot: "/tmp/ws"})
	if err != nil {
		t.Fatalf("start: %v", err)
	}
	sidWithContext := h1.(*handle).sessionID
	if err := h1.Send(context.Background(), "hello"); err != nil {
		t.Fatalf("send: %v", err)
	}
	_ = h1.Dispose(context.Background())

	h2, err := a.Start(context.Background(), adapter.StartRequest{WorkspaceRoot: "/tmp/ws"})
	if err != nil {
		t.Fatalf("start: %v", err)
	}
	sidEmpty := h2.(*handle).sessionID
	_ = h2.Dispose(context.Background())

	// resumed
	r, err := a.Resume(context.Background(), adapter.ResumeRequest{InstanceID: sidWithContext, WorkspaceRoot: "/tmp/ws"})
	if err != nil {
		t.Fatalf("resume: %v", err)
	}
	if r.Result != adapter.WakeResumed || r.InstanceID != sidWithContext {
		t.Fatalf("resume result = %+v, want resumed", r)
	}
	if h, ok := a.handles[sidWithContext]; ok {
		_ = h.Dispose(context.Background())
	}

	// restarted_with_context（服务端上下文丢失）
	r, err = a.Resume(context.Background(), adapter.ResumeRequest{InstanceID: sidEmpty, WorkspaceRoot: "/tmp/ws"})
	if err != nil {
		t.Fatalf("resume: %v", err)
	}
	if r.Result != adapter.WakeRestartedWithContext {
		t.Fatalf("resume result = %q, want restarted_with_context", r.Result)
	}
	if h, ok := a.handles[sidEmpty]; ok {
		_ = h.Dispose(context.Background())
	}

	// 404 -> unsupported，禁止伪装 resumed
	r, err = a.Resume(context.Background(), adapter.ResumeRequest{InstanceID: "ses_does_not_exist", WorkspaceRoot: "/tmp/ws"})
	if err != nil {
		t.Fatalf("resume: %v", err)
	}
	if r.Result != adapter.WakeUnsupported {
		t.Fatalf("resume result = %q, want unsupported", r.Result)
	}
}

// 无关会话的事件不会泄漏到当前 handle。
func TestEventStreamIsolationPerSession(t *testing.T) {
	f := newFixtureServer(t, true)
	c := newFixtureClient(t, f)
	a := NewWithClient(c)

	h1, err := a.Start(context.Background(), adapter.StartRequest{WorkspaceRoot: "/tmp/ws1"})
	if err != nil {
		t.Fatalf("start: %v", err)
	}
	defer h1.Dispose(context.Background())
	h2, err := a.Start(context.Background(), adapter.StartRequest{WorkspaceRoot: "/tmp/ws2"})
	if err != nil {
		t.Fatalf("start: %v", err)
	}
	defer h2.Dispose(context.Background())

	sid2 := h2.(*handle).sessionID
	// 只有会话2的事件。
	f.emitEvent(t, sid2, "message.part.delta", map[string]any{
		"sessionID": sid2, "messageID": "msg_2", "partID": "prt_2", "field": "text", "delta": "只属于会话2",
	})
	ev := mustEvent(t, h2, 5*time.Second)
	if ev.Type != adapter.EventMessageDelta || ev.Payload["text"] != "只属于会话2" {
		t.Fatalf("h2 event = %+v", ev)
	}
	// h1 不应收到任何事件。
	select {
	case ev := <-h1.Events():
		t.Fatalf("h1 received foreign event: %+v", ev)
	case <-time.After(300 * time.Millisecond):
	}
}

// ---- ADPT-OPENCODE-03：交互能力探测 ----

// 能力矩阵只反映实现过的能力；permission 等未实现能力保持 unsupported。
func TestCapabilityMatrixExplicitStates(t *testing.T) {
	f := newFixtureServer(t, true)
	c := newFixtureClient(t, f)
	a := NewWithClient(c)
	caps, err := a.Detect(context.Background())
	if err != nil {
		t.Fatalf("detect: %v", err)
	}
	byName := map[string]string{}
	for _, cap := range caps.Capabilities {
		byName[cap.Name] = cap.Status
	}
	// 三态约束：所有值必须是合法三态之一。
	for _, status := range byName {
		if status != adapter.CapabilityNative && status != adapter.CapabilityEmulated && status != adapter.CapabilityUnsupported {
			t.Fatalf("invalid status %q", status)
		}
	}
	// 明确声明：permission/plan/goal/skill/attachments 均未实现。
	for _, name := range []string{"permission", "permission_mode", "plan", "goal", "skill_catalog",
		"invoke_skill", "model_select", "effort_select", "attachments"} {
		if byName[name] != adapter.CapabilityUnsupported {
			t.Fatalf("%s = %q, want unsupported", name, byName[name])
		}
	}
}

// ADPT-OPENCODE-07：Detect 能力清单必须与 SPI CapabilityNames 完全一致（含 permission_mode）。
func TestCapabilityListMatchesSPI(t *testing.T) {
	f := newFixtureServer(t, true)
	c := newFixtureClient(t, f)
	a := NewWithClient(c)
	caps, err := a.Detect(context.Background())
	if err != nil {
		t.Fatalf("detect: %v", err)
	}
	if len(caps.Capabilities) != len(adapter.CapabilityNames) {
		t.Fatalf("capabilities len = %d, want %d（与 SPI 一致）", len(caps.Capabilities), len(adapter.CapabilityNames))
	}
	seen := map[string]bool{}
	for _, cap := range caps.Capabilities {
		if seen[cap.Name] {
			t.Fatalf("duplicate capability %q", cap.Name)
		}
		seen[cap.Name] = true
	}
	for _, name := range adapter.CapabilityNames {
		if !seen[name] {
			t.Fatalf("missing capability %q", name)
		}
	}
	// permission_mode 尚未实现：必须 unsupported 且带中文原因。
	entry := byCapabilityName(caps, "permission_mode")
	if entry.Status != adapter.CapabilityUnsupported || entry.Reason == "" {
		t.Fatalf("permission_mode = %q/%q, want unsupported with reason", entry.Status, entry.Reason)
	}
}

// byCapabilityName 按名称取能力项。
func byCapabilityName(caps adapter.Capabilities, name string) adapter.Capability {
	for _, cap := range caps.Capabilities {
		if cap.Name == name {
			return cap
		}
	}
	return adapter.Capability{}
}

// SSE 行解析器验证：多 data 行事件与 heartbeat 被正确忽略/解析。
func TestSSEParserLineHandling(t *testing.T) {
	lines := []string{
		"data: {\"id\":\"a\",\"type\":\"server.connected\",\"properties\":{}}",
		"data: {\"id\":\"b\",\"type\":\"message.part.delta\",\"properties\":{\"sessionID\":\"s1\",\"messageID\":\"m\",\"partID\":\"p\",\"field\":\"text\",\"delta\":\"x\"}}",
		":comment",
		"",
	}
	var raws []RawEvent
	for _, line := range lines {
		if !strings.HasPrefix(line, "data:") {
			continue
		}
		data := strings.TrimSpace(strings.TrimPrefix(line, "data:"))
		var raw RawEvent
		if err := json.Unmarshal([]byte(data), &raw); err == nil {
			raws = append(raws, raw)
		}
	}
	if len(raws) != 2 {
		t.Fatalf("parsed %d events, want 2", len(raws))
	}
	if raws[1].Type != "message.part.delta" {
		t.Fatalf("type = %q", raws[1].Type)
	}
	// 心跳与 connected 不产生 canonical 事件。
	heartbeat := RawEvent{ID: "h", Type: "server.heartbeat", Properties: json.RawMessage(`{}`)}
	if _, ok := mapRawEvent(heartbeat); ok {
		t.Fatalf("heartbeat must be ignored")
	}
	connected := RawEvent{ID: "c", Type: "server.connected", Properties: json.RawMessage(`{}`)}
	if _, ok := mapRawEvent(connected); ok {
		t.Fatalf("server.connected must be ignored")
	}
}

// bufio 读取器：验证 client 层能消费真实格式的 SSE 帧（空行分隔）。
func TestStreamReadLoopConsumesFrames(t *testing.T) {
	body := `data: {"id":"1","type":"server.connected","properties":{}}

data: {"id":"2","type":"message.part.delta","properties":{"sessionID":"s1","messageID":"m","partID":"p","field":"text","delta":"a"}}

data: {"id":"3","type":"server.heartbeat","properties":{}}
`
	sr := &streamReader{raw: make(chan RawEvent, 8), closed: make(chan struct{})}
	go sr.readLoop(io.NopCloser(strings.NewReader(body)))
	var got []RawEvent
	timeout := time.After(2 * time.Second)
	for len(got) < 2 {
		select {
		case raw, ok := <-sr.raw:
			if !ok {
				t.Fatalf("channel closed early, got %d events", len(got))
			}
			got = append(got, raw)
		case <-timeout:
			t.Fatalf("timeout, got %d events", len(got))
		}
	}
	if got[0].Type != "server.connected" || got[1].Type != "message.part.delta" {
		t.Fatalf("unexpected events: %+v", got)
	}
}

// 用户输入不能作为助手事件回显：message.updated 声明角色后，同 messageID 的文本
// delta/completed 必须被过滤；助手消息正常通过并携带 message_id。
func TestUserMessagePartsAreNotEchoedAsAssistantEvents(t *testing.T) {
	f := newFixtureServer(t, true)
	c := newFixtureClient(t, f)
	a := NewWithClient(c)

	h, err := a.Start(context.Background(), adapter.StartRequest{
		WorkspaceRoot: "/tmp/ws", Provider: "opencode",
	})
	if err != nil {
		t.Fatalf("start: %v", err)
	}
	defer h.Dispose(context.Background())
	sid := handleSessionID(t, h)

	f.emitEvent(t, sid, "message.updated", map[string]any{
		"sessionID": sid,
		"info":      map[string]any{"id": "msg_user", "role": "user", "sessionID": sid},
	})
	f.emitEvent(t, sid, "message.updated", map[string]any{
		"sessionID": sid,
		"info":      map[string]any{"id": "msg_asst", "role": "assistant", "sessionID": sid},
	})
	// 用户输入的 delta 与 completed 都必须被丢弃。
	f.emitEvent(t, sid, "message.part.delta", map[string]any{
		"sessionID": sid, "messageID": "msg_user", "partID": "prt_u1", "field": "text", "delta": "用户输入",
	})
	f.emitEvent(t, sid, "message.part.updated", map[string]any{
		"sessionID": sid,
		"part":      map[string]any{"id": "prt_u2", "messageID": "msg_user", "sessionID": sid, "type": "text", "text": "用户输入"},
	})
	// 助手消息正常映射。
	f.emitEvent(t, sid, "message.part.delta", map[string]any{
		"sessionID": sid, "messageID": "msg_asst", "partID": "prt_a1", "field": "text", "delta": "回",
	})
	f.emitEvent(t, sid, "message.part.updated", map[string]any{
		"sessionID": sid,
		"part":      map[string]any{"id": "prt_a2", "messageID": "msg_asst", "sessionID": sid, "type": "text", "text": "回复内容"},
	})

	timeout := 5 * time.Second
	first := mustEvent(t, h, timeout)
	if first.Type != adapter.EventMessageDelta || first.Payload["text"] != "回" {
		t.Fatalf("first event = %+v, want assistant delta 回", first)
	}
	if first.Payload["message_id"] != "msg_asst" {
		t.Fatalf("delta message_id = %v, want msg_asst", first.Payload["message_id"])
	}
	second := mustEvent(t, h, timeout)
	if second.Type != adapter.EventMessageCompleted || second.Payload["text"] != "回复内容" {
		t.Fatalf("second event = %+v, want assistant completed 回复内容", second)
	}
	// 两条 user 文本事件被过滤后不应再有事件到达。
	select {
	case ev := <-h.Events():
		t.Fatalf("unexpected extra event: %+v", ev)
	case <-time.After(300 * time.Millisecond):
	}
}

// ADPT-OPENCODE-02 terminal mapping regression: OpenCode exposes both
// session.idle and session.status(type=idle) in different server versions.
// Both must become the public turn_completed event with a deterministic
// stop_reason; session.error remains a user-visible session_error and is
// closed by the subscription layer (covered below).
func TestTerminalRawEventMappings(t *testing.T) {
	tests := []struct {
		name       string
		raw        RawEvent
		wantType   adapter.EventType
		wantReason string
	}{
		{
			name:       "session.idle",
			raw:        RawEvent{Type: evSessionIdle, Properties: json.RawMessage(`{"sessionID":"ses_idle"}`)},
			wantType:   adapter.EventTurnCompleted,
			wantReason: "session_idle",
		},
		{
			name:       "session.status idle",
			raw:        RawEvent{Type: evSessionStatus, Properties: json.RawMessage(`{"sessionID":"ses_status","status":{"type":"idle"}}`)},
			wantType:   adapter.EventTurnCompleted,
			wantReason: "status_idle",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			mapped, ok := mapRawEvent(tt.raw)
			if !ok {
				t.Fatalf("mapRawEvent returned ok=false")
			}
			if mapped.Event.Type != tt.wantType {
				t.Fatalf("event type=%q, want %q", mapped.Event.Type, tt.wantType)
			}
			if got := mapped.Event.Payload["instance_id"]; got == nil || got == "" {
				t.Fatalf("instance_id missing: %+v", mapped.Event.Payload)
			}
			if got := mapped.Event.Payload["stop_reason"]; got != tt.wantReason {
				t.Fatalf("stop_reason=%v, want %q", got, tt.wantReason)
			}
		})
	}

	// A malformed/empty idle payload must never manufacture a terminal event
	// with an empty instance id.
	for _, raw := range []RawEvent{
		{Type: evSessionIdle, Properties: json.RawMessage(`{}`)},
		{Type: evSessionIdle, Properties: json.RawMessage(`{"sessionID":123}`)},
		{Type: evSessionStatus, Properties: json.RawMessage(`{"status":{"type":"idle"}}`)},
		{Type: evSessionStatus, Properties: json.RawMessage(`{"sessionID":123,"status":{"type":"idle"}}`)},
	} {
		if _, ok := mapRawEvent(raw); ok {
			t.Fatalf("malformed idle payload unexpectedly mapped: %+v", raw)
		}
	}

	errEvent, ok := mapRawEvent(RawEvent{
		Type:       evSessionError,
		Properties: json.RawMessage(`{"sessionID":"ses_err","error":"provider failed"}`),
	})
	if !ok || errEvent.Event.Type != adapter.EventSessionError {
		t.Fatalf("session.error mapping=%+v ok=%v, want session_error", errEvent.Event, ok)
	}
	if errEvent.Event.Payload["instance_id"] != "ses_err" {
		t.Fatalf("session.error instance_id=%v", errEvent.Event.Payload["instance_id"])
	}
	for _, raw := range []RawEvent{
		{Type: evSessionError, Properties: json.RawMessage("{\"error\":\"missing session\"}")},
		{Type: evSessionError, Properties: json.RawMessage("{\"sessionID\":123,\"error\":\"invalid session\"}")},
	} {
		if _, ok := mapRawEvent(raw); ok {
			t.Fatalf("malformed session.error payload unexpectedly mapped: %+v", raw)
		}
	}
}

// The Provider can emit duplicate idle notifications, and failures may omit
// idle entirely. Verify per-turn deduplication and the synthetic error terminal
// event in the subscription forwarder. A subsequent busy starts a new turn.
func TestSubscriptionTerminalEventsAreDeduplicated(t *testing.T) {
	sr := &streamReader{closed: make(chan struct{})}
	sub := &subscription{
		raw:   make(chan RawEvent, 16),
		ev:    make(chan adapter.Event, 16),
		roles: map[string]string{},
	}
	go sr.forward(sub, "ses_terminal")

	props := func(v string) json.RawMessage { return json.RawMessage(v) }
	for _, raw := range []RawEvent{
		{Type: evSessionStatus, Properties: props(`{"sessionID":"ses_terminal","status":{"type":"busy"}}`)},
		{Type: evSessionIdle, Properties: props(`{"sessionID":"ses_terminal"}`)},
		{Type: evSessionStatus, Properties: props(`{"sessionID":"ses_terminal","status":{"type":"idle"}}`)},
		// Since the first turn is already closed, this error is only a visible
		// session_error and must not add a second terminal marker.
		{Type: evSessionError, Properties: props(`{"sessionID":"ses_terminal","error":"late failure"}`)},
		{Type: evSessionStatus, Properties: props(`{"sessionID":"ses_terminal","status":{"type":"busy"}}`)},
		// This turn has no idle; session.error must synthesize turn_completed.
		{Type: evSessionError, Properties: props(`{"sessionID":"ses_terminal","error":"provider down"}`)},
		// A repeated error remains an error notification but must not synthesize
		// another turn terminal for the already-closed turn.
		{Type: evSessionError, Properties: props(`{"sessionID":"ses_terminal","error":"provider down again"}`)},
		{Type: evSessionIdle, Properties: props(`{"sessionID":"ses_terminal"}`)},
	} {
		sub.raw <- raw
	}
	close(sub.raw)

	var got []adapter.Event
	for ev := range sub.ev {
		got = append(got, ev)
	}
	if len(got) != 7 {
		t.Fatalf("got %d events, want 7: %+v", len(got), got)
	}
	wantTypes := []adapter.EventType{
		adapter.EventTurnStarted, adapter.EventTurnCompleted, adapter.EventSessionError,
		adapter.EventTurnStarted, adapter.EventSessionError, adapter.EventTurnCompleted,
		adapter.EventSessionError,
	}
	for i, want := range wantTypes {
		if got[i].Type != want {
			t.Fatalf("event[%d] type=%q, want %q; all=%+v", i, got[i].Type, want, got)
		}
	}
	if got[1].Payload["stop_reason"] != "session_idle" {
		t.Fatalf("first terminal payload=%+v", got[1].Payload)
	}
	if got[5].Payload["stop_reason"] != "error" {
		t.Fatalf("synthetic terminal payload=%+v", got[5].Payload)
	}
	if got[2].Payload["message"] != "late failure" || got[4].Payload["message"] != "provider down" || got[6].Payload["message"] != "provider down again" {
		t.Fatalf("error payloads=%+v / %+v / %+v", got[2].Payload, got[4].Payload, got[6].Payload)
	}
}

// handleSessionID 从已启动 handle 提取 opencode session id（测试辅助）。
func handleSessionID(t *testing.T, h adapter.Handle) string {
	t.Helper()
	identified, ok := h.(adapter.InstanceIDHandle)
	if !ok {
		t.Fatal("handle does not expose instance id")
	}
	return identified.InstanceID()
}

// ---- 空模型兜底：prompt 永不携带空 model，绝不落到 opencode 服务端默认 ----

// Start 未指定模型且 catalog.Default 为空时，回退到目录排序首项；
// prompt_async 请求体必须显式携带 model，不能缺省让服务端自行回退。
func TestStartWithoutModelFallsBackToCatalogOption(t *testing.T) {
	f := newFixtureServer(t, true)
	c := newFixtureClient(t, f)
	a := NewWithClient(c)
	a.mu.Lock()
	a.modelCatalog = ModelCatalog{Options: []string{"opencode/big-pickle", "opencode/hy3-free"}}
	a.mu.Unlock()

	h, err := a.Start(context.Background(), adapter.StartRequest{
		WorkspaceRoot: "/tmp/ws", Provider: "opencode", Prompt: "初始消息",
	})
	if err != nil {
		t.Fatalf("start: %v", err)
	}
	defer h.Dispose(context.Background())

	handle := h.(*handle)
	f.mu.Lock()
	startModel := f.sessions[handle.sessionID].lastModel
	f.mu.Unlock()
	if startModel != "opencode/big-pickle" {
		t.Fatalf("start model = %q, want 目录首项 opencode/big-pickle", startModel)
	}
}

// handle 模型为空时 Send 走目录兜底；SetModel 应用运行期覆盖。
func TestSendModelFallbackAndOverride(t *testing.T) {
	f := newFixtureServer(t, true)
	c := newFixtureClient(t, f)
	a := NewWithClient(c)
	a.mu.Lock()
	a.modelCatalog = ModelCatalog{Options: []string{"opencode/big-pickle", "opencode/hy3-free"}}
	a.mu.Unlock()

	h, err := a.Start(context.Background(), adapter.StartRequest{
		WorkspaceRoot: "/tmp/ws", Provider: "opencode",
		Model: "opencode/go-deepseek",
	})
	if err != nil {
		t.Fatalf("start: %v", err)
	}
	defer h.Dispose(context.Background())
	handle := h.(*handle)
	// 模拟存量 handle 的模型漂移：模型为空时 Send 必须走目录兜底而非缺省。
	handle.mu.Lock()
	handle.model = ""
	handle.mu.Unlock()
	if err := h.Send(context.Background(), "继续"); err != nil {
		t.Fatalf("send: %v", err)
	}
	f.mu.Lock()
	sendModel := f.sessions[handle.sessionID].lastModel
	f.mu.Unlock()
	if sendModel != "opencode/big-pickle" {
		t.Fatalf("send model = %q, want 目录首项 opencode/big-pickle", sendModel)
	}

	// SetModel 覆盖后 Send 沿用覆盖值；空覆盖被忽略。
	handle.SetModel("opencode/hy3-free")
	if err := h.Send(context.Background(), "再试"); err != nil {
		t.Fatalf("send after SetModel: %v", err)
	}
	f.mu.Lock()
	sendModel = f.sessions[handle.sessionID].lastModel
	f.mu.Unlock()
	if sendModel != "opencode/hy3-free" {
		t.Fatalf("send model = %q, want 覆盖值 opencode/hy3-free", sendModel)
	}
}

// opencode 1.17 异步模型调用失败的真实 session.error 是嵌套对象
// （error:{name, data:{message}}）；适配器必须提取 data.message 为
// EventSessionError 文本，不能因反序列化失败把模型错误整个吞掉。
func TestSessionErrorNestedObjectMapsToVisibleError(t *testing.T) {
	f := newFixtureServer(t, false)
	c := newFixtureClient(t, f)
	a := NewWithClient(c)
	h, err := a.Start(context.Background(), adapter.StartRequest{
		WorkspaceRoot: "/tmp/ws", Provider: "opencode",
		Model: "opencode/big-pickle",
	})
	if err != nil {
		t.Fatalf("start: %v", err)
	}
	defer h.Dispose(context.Background())
	handle := h.(*handle)

	f.emitEvent(t, handle.sessionID, "session.error", map[string]any{
		"sessionID": handle.sessionID,
		"error": map[string]any{
			"name": "UnknownError",
			"data": map[string]any{
				"message": "ProviderModelNotFoundError: Model not found: opencode/definitely-not-a-model.",
			},
		},
	})

	ev := mustEvent(t, h, 5*time.Second)
	if ev.Type != adapter.EventSessionError {
		t.Fatalf("event type = %v, want session_error", ev.Type)
	}
	message, _ := ev.Payload["message"].(string)
	if !strings.Contains(message, "Model not found") {
		t.Fatalf("error message = %q, want 含 Model not found", message)
	}
}
