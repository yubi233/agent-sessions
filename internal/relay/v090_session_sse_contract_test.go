package relay

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/yubi233/agent-sessions/internal/domain"
	"github.com/yubi233/agent-sessions/internal/store"
)

// v0.9.0 C5/V090-08：会话级 SSE 契约（GET /v1/sessions/{id}/events）。
// 与账号级 /v1/events 严格分离：cursor 是 session-local event_seq，事件帧仅作
// 失效通知（event: invalidated, data: {}），Hub 丢唤醒由 heartbeat 从 SQLite
// 补缺口自愈，心跳先复核 token/设备（fail-closed），断开即释放订阅。

type sessionSSEFrame struct {
	ID    int64
	Event string
	Data  string
}

type sessionSSEStream struct {
	response *http.Response
	scanner  *bufio.Scanner
	cancel   context.CancelFunc
}

func (s *sessionSSEStream) close() {
	s.cancel()
	_ = s.response.Body.Close()
}

// openSessionSSE 建立真实 HTTP 会话 SSE 连接。响应头返回即代表 handler 已订阅
// 会话 Hub 并完成初始连接注释 flush。
func openSessionSSE(t *testing.T, baseURL, token, sessionID string, afterSeq int64, useLastEventID bool) *sessionSSEStream {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	request, err := http.NewRequestWithContext(ctx, http.MethodGet,
		fmt.Sprintf("%s/v1/sessions/%s/events", baseURL, sessionID), nil)
	if err != nil {
		cancel()
		t.Fatalf("create session SSE request: %v", err)
	}
	request.Header.Set("Authorization", "Bearer "+token)
	if useLastEventID {
		request.Header.Set("Last-Event-ID", fmt.Sprintf("%d", afterSeq))
	} else if afterSeq > 0 {
		request.URL.RawQuery = fmt.Sprintf("after_seq=%d", afterSeq)
	}
	response, err := (&http.Client{}).Do(request)
	if err != nil {
		cancel()
		t.Fatalf("open session SSE: %v", err)
	}
	if response.StatusCode != http.StatusOK {
		_ = response.Body.Close()
		cancel()
		t.Fatalf("open session SSE status=%d", response.StatusCode)
	}
	if got := response.Header.Get("Content-Type"); got != "text/event-stream" {
		t.Fatalf("session SSE content-type=%q", got)
	}
	if got := response.Header.Get("Cache-Control"); got != "no-cache" {
		t.Fatalf("session SSE cache-control=%q", got)
	}
	if got := response.Header.Get("X-Accel-Buffering"); got != "no" {
		t.Fatalf("session SSE x-accel-buffering=%q", got)
	}
	stream := &sessionSSEStream{response: response, scanner: bufio.NewScanner(response.Body), cancel: cancel}
	t.Cleanup(stream.close)
	return stream
}

// nextLine 读取一行（注释或帧字段），供显式断言初始注释与心跳。
func (s *sessionSSEStream) nextLine(t *testing.T) string {
	t.Helper()
	if s.scanner.Scan() {
		return s.scanner.Text()
	}
	t.Fatalf("session SSE closed while reading line")
	return ""
}

func readSessionSSEFrame(t *testing.T, stream *sessionSSEStream) sessionSSEFrame {
	t.Helper()
	var frame sessionSSEFrame
	for stream.scanner.Scan() {
		line := stream.scanner.Text()
		if line == "" {
			if frame.ID > 0 {
				return frame
			}
			continue
		}
		if strings.HasPrefix(line, ":") {
			continue
		}
		key, value, ok := strings.Cut(line, ":")
		if !ok {
			continue
		}
		value = strings.TrimPrefix(value, " ")
		switch key {
		case "id":
			var seq int64
			if _, err := fmt.Sscanf(value, "%d", &seq); err != nil {
				t.Fatalf("parse session SSE id %q: %v", value, err)
			}
			frame.ID = seq
		case "event":
			frame.Event = value
		case "data":
			frame.Data = value
		}
	}
	if err := stream.scanner.Err(); err != nil && err != context.Canceled && err != io.EOF {
		t.Fatalf("read session SSE: %v", err)
	}
	t.Fatal("session SSE closed before an invalidation frame")
	return sessionSSEFrame{}
}

// appendSessionEvent 直接向 SQLite 追加一条会话事件（绕过 Hub 发布），用于
// 演练"Hub 丢唤醒/绕过发布"后 heartbeat 从 SQLite 补缺口自愈。
func appendSessionEvent(t *testing.T, repo store.Repository, sessionID string, seq int64) store.SessionEventRow {
	t.Helper()
	if _, err := repo.AppendEvent(t.Context(), store.SessionEventRow{
		SessionID: sessionID, EventSeq: seq, EventType: "session.appended",
		EnvelopeJSON: `{"fixture":"v090"}`, CreatedAtUnixMS: time.Now().UnixMilli(),
	}); err != nil {
		t.Fatalf("append session event: %v", err)
	}
	events, err := repo.ListEventsAfter(t.Context(), sessionID, seq-1)
	if err != nil || len(events) == 0 {
		t.Fatalf("appended event not visible: n=%d err=%v", len(events), err)
	}
	return events[len(events)-1]
}

// 契约 1：初始回放按 session-local event_seq 升序发失效通知帧（id/事件类型/data 逐帧断言），
// 且 Last-Event-ID 优先于 after_seq；响应头含 text/event-stream + no-cache + X-Accel-Buffering。
func TestV090SessionSSEReplayCursorAndInvalidationFrames(t *testing.T) {
	t.Setenv("AGENT_SESSIONS_SESSION_SSE_HEARTBEAT_SECONDS", "1")
	env := newTestEnv(t)
	owner := env.registerAs(t, "v090-sse-owner@fixture.test")
	sessionID, _ := env.createSessionForProject(t, owner.AccessToken, owner.AccountID, "v090-sse-first")
	// 追加第二条事件：session-local event_seq 与账号级 cursor 不同值。
	appendSessionEvent(t, env.repo, sessionID, 2)
	events, err := env.repo.ListEventsAfter(t.Context(), sessionID, 0)
	if err != nil || len(events) != 2 {
		t.Fatalf("events=%d err=%v", len(events), err)
	}

	server := httptest.NewServer(env.router)
	t.Cleanup(server.Close)

	// Last-Event-ID=1 优先：只回放 event_seq=2 的失效通知。
	stream := openSessionSSE(t, server.URL, owner.AccessToken, sessionID, 1, true)
	if line := stream.nextLine(t); line != ": connected" {
		t.Fatalf("initial comment=%q, want `: connected`", line)
	}
	frame := readSessionSSEFrame(t, stream)
	if frame.ID != 2 || frame.Event != "invalidated" || frame.Data != "{}" {
		t.Fatalf("invalidation frame=%+v, want id=2 event=invalidated data={}", frame)
	}
	stream.close()
}

// 契约 2：Hub 丢唤醒自愈——绕过 Hub 直接落库的事件在下一心跳由 SQLite 回放补齐。
func TestV090SessionSSEHubDropoutHealsByHeartbeat(t *testing.T) {
	t.Setenv("AGENT_SESSIONS_SESSION_SSE_HEARTBEAT_SECONDS", "1")
	env := newTestEnv(t)
	owner := env.registerAs(t, "v090-sse-heal@fixture.test")
	sessionID, _ := env.createSessionForProject(t, owner.AccessToken, owner.AccountID, "v090-sse-heal")

	server := httptest.NewServer(env.router)
	t.Cleanup(server.Close)
	stream := openSessionSSE(t, server.URL, owner.AccessToken, sessionID, 0, false)
	if line := stream.nextLine(t); line != ": connected" {
		t.Fatalf("initial comment=%q", line)
	}
	// 排干初始回放（session.created 帧）。
	_ = readSessionSSEFrame(t, stream)

	// 绕过 Hub 直接落库：hub 不会唤醒，heartbeat 必须从 SQLite 补缺口。
	appended := appendSessionEvent(t, env.repo, sessionID, 2)
	frame := readSessionSSEFrame(t, stream)
	if frame.ID != appended.EventSeq || frame.Event != "invalidated" {
		t.Fatalf("heal frame=%+v, want id=%d via heartbeat replay", frame, appended.EventSeq)
	}
	stream.close()
}

// 契约 3：设备被撤销后最多一个心跳周期内关闭连接（fail-closed），并释放 Hub 订阅。
func TestV090SessionSSERevocationClosesAndReleases(t *testing.T) {
	t.Setenv("AGENT_SESSIONS_SESSION_SSE_HEARTBEAT_SECONDS", "1")
	env := newTestEnv(t)
	owner := env.registerAs(t, "v090-sse-revoke@fixture.test")
	sessionID, _ := env.createSessionForProject(t, owner.AccessToken, owner.AccountID, "v090-sse-revoke")

	router, hub := NewServerWithPresence(env.db, nil)
	server := httptest.NewServer(router)
	t.Cleanup(server.Close)

	stream := openSessionSSE(t, server.URL, owner.AccessToken, sessionID, 0, false)
	if line := stream.nextLine(t); line != ": connected" {
		t.Fatalf("initial comment=%q", line)
	}
	_ = readSessionSSEFrame(t, stream)
	if hub.SessionSubscribers(sessionID) != 1 {
		t.Fatalf("subscribers=%d, want 1 while stream open", hub.SessionSubscribers(sessionID))
	}

	// 直接把设备置为 revoked（等价于被其他 owner 撤销本机设备）。
	devices, err := env.repo.ListDevices(t.Context(), owner.AccountID)
	if err != nil || len(devices) == 0 {
		t.Fatalf("list devices: n=%d err=%v", len(devices), err)
	}
	if err := env.repo.SetDeviceStatus(t.Context(), devices[0].ID, domain.DeviceRevoked); err != nil {
		t.Fatalf("revoke device: %v", err)
	}
	// 最多一个心跳周期（1s + 余量）内连接必须被服务端关闭：
	// drain goroutine 在 Scanner 返回 false（连接关闭）时发出信号。
	closed := make(chan struct{})
	go func() {
		for stream.scanner.Scan() {
		}
		close(closed)
	}()
	select {
	case <-closed:
	case <-time.After(3 * time.Second):
		t.Fatalf("session SSE not closed within one heartbeat after revocation")
	}
	stream.close()
	deadline := time.Now().Add(2 * time.Second)
	for hub.SessionSubscribers(sessionID) != 0 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if hub.SessionSubscribers(sessionID) != 0 {
		t.Fatalf("subscribers=%d after close, want 0 (断开即释放)", hub.SessionSubscribers(sessionID))
	}
}

// 契约 4：kill switch（AGENT_SESSIONS_SESSION_SSE_ENABLED=0）返回 501/CAPABILITY_UNSUPPORTED，
// 不得伪装资源 404；鉴权错误码沿用 snapshot 语义（跨账号 403/SCOPE_DENIED、不存在 404/INVALID_REQUEST）。
func TestV090SessionSSEKillSwitchAndAuthorizationMatrix(t *testing.T) {
	env := newTestEnv(t)
	owner := env.registerAs(t, "v090-sse-auth-owner@fixture.test")
	// 注册窗口在首 owner 后关闭；第二账号走测试专用注入 helper。
	stranger := env.provisionAdditionalAccount(t, "v090-sse-stranger@fixture.test")
	sessionID, _ := env.createSessionForProject(t, owner.AccessToken, owner.AccountID, "v090-sse-auth")
	server := httptest.NewServer(env.router)
	t.Cleanup(server.Close)

	// kill switch。
	t.Setenv("AGENT_SESSIONS_SESSION_SSE_ENABLED", "0")
	response := env.do(t, http.MethodGet, fmt.Sprintf("/v1/sessions/%s/events", sessionID), nil, owner.AccessToken)
	if response.Code != http.StatusNotImplemented {
		t.Fatalf("kill switch status=%d, want 501", response.Code)
	}
	var apiErr struct {
		Code string `json:"code"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &apiErr); err != nil || apiErr.Code != "CAPABILITY_UNSUPPORTED" {
		t.Fatalf("kill switch body=%s err=%v", response.Body.String(), err)
	}
	t.Setenv("AGENT_SESSIONS_SESSION_SSE_ENABLED", "1")

	// 跨账号 → 403/SCOPE_DENIED。
	cross := env.do(t, http.MethodGet, fmt.Sprintf("/v1/sessions/%s/events", sessionID), nil, stranger.AccessToken)
	if cross.Code != http.StatusForbidden {
		t.Fatalf("cross-account status=%d, want 403", cross.Code)
	}
	if err := json.Unmarshal(cross.Body.Bytes(), &apiErr); err != nil || apiErr.Code != "SCOPE_DENIED" {
		t.Fatalf("cross-account body=%s err=%v", cross.Body.String(), err)
	}

	// 不存在 → 404/INVALID_REQUEST。
	missing := env.do(t, http.MethodGet, "/v1/sessions/sess-missing/events", nil, owner.AccessToken)
	if missing.Code != http.StatusNotFound {
		t.Fatalf("missing status=%d, want 404", missing.Code)
	}
	if err := json.Unmarshal(missing.Body.Bytes(), &apiErr); err != nil || apiErr.Code != "INVALID_REQUEST" {
		t.Fatalf("missing body=%s err=%v", missing.Body.String(), err)
	}

	// 非法 cursor → 400/INVALID_REQUEST。
	negative := env.do(t, http.MethodGet, fmt.Sprintf("/v1/sessions/%s/events?after_seq=-1", sessionID), nil, owner.AccessToken)
	if negative.Code != http.StatusBadRequest {
		t.Fatalf("negative cursor status=%d, want 400", negative.Code)
	}
}
