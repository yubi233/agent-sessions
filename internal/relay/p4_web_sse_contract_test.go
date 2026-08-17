package relay

import (
	"bufio"
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"
)

type accountSSEFrame struct {
	ID    int64
	Event string
	Data  string
}

type accountSSEStream struct {
	response *http.Response
	scanner  *bufio.Scanner
	cancel   context.CancelFunc
}

func (s *accountSSEStream) close() {
	s.cancel()
	_ = s.response.Body.Close()
}

// openAccountSSE 建立真实 HTTP SSE 连接。响应头返回即代表 handler 已订阅账号 Hub，随后
// 可以安全触发业务写入来验证实时通知；测试不解析 opaque data 的业务内容。
func openAccountSSE(t *testing.T, baseURL, token string, afterCursor int64, useLastEventID bool) *accountSSEStream {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	request, err := http.NewRequestWithContext(ctx, http.MethodGet,
		baseURL+"/v1/events?after_seq=0", nil)
	if err != nil {
		cancel()
		t.Fatalf("create account SSE request: %v", err)
	}
	request.Header.Set("Authorization", "Bearer "+token)
	if useLastEventID {
		request.Header.Set("Last-Event-ID", strconv.FormatInt(afterCursor, 10))
	} else {
		request.URL.RawQuery = "after_seq=" + strconv.FormatInt(afterCursor, 10)
	}
	response, err := (&http.Client{}).Do(request)
	if err != nil {
		cancel()
		t.Fatalf("open account SSE: %v", err)
	}
	if response.StatusCode != http.StatusOK {
		_ = response.Body.Close()
		cancel()
		t.Fatalf("open account SSE status=%d", response.StatusCode)
	}
	stream := &accountSSEStream{response: response, scanner: bufio.NewScanner(response.Body), cancel: cancel}
	t.Cleanup(stream.close)
	return stream
}

func readAccountSSEFrame(t *testing.T, stream *accountSSEStream) accountSSEFrame {
	t.Helper()
	var frame accountSSEFrame
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
			cursor, err := strconv.ParseInt(value, 10, 64)
			if err != nil {
				t.Fatalf("parse SSE cursor %q: %v", value, err)
			}
			frame.ID = cursor
		case "event":
			frame.Event = value
		case "data":
			frame.Data = value
		}
	}
	if err := stream.scanner.Err(); err != nil && err != context.Canceled && err != io.EOF {
		t.Fatalf("read account SSE: %v", err)
	}
	t.Fatal("account SSE closed before an event frame")
	return accountSSEFrame{}
}

// WEB-02：账号恢复游标由 account_event_log 生成，不能复用不同 session 都可能为 1 的
// event_seq。Last-Event-ID 优先于 query；同账号回放不会混入其他账号事件。
func TestP4AccountSSECursorRecoveryAndIsolation(t *testing.T) {
	env := newTestEnv(t)
	owner := env.registerAs(t, "p4-sse-owner@fixture.test")
	firstSessionID, _ := env.createSessionForProject(t, owner.AccessToken, owner.AccountID, "p4-sse-first")
	secondSessionID, _ := env.createSessionForProject(t, owner.AccessToken, owner.AccountID, "p4-sse-second")
	firstEvents, err := env.repo.ListEventsAfter(t.Context(), firstSessionID, 0)
	if err != nil || len(firstEvents) != 1 {
		t.Fatalf("first session events=%+v err=%v", firstEvents, err)
	}
	secondEvents, err := env.repo.ListEventsAfter(t.Context(), secondSessionID, 0)
	if err != nil || len(secondEvents) != 1 {
		t.Fatalf("second session events=%+v err=%v", secondEvents, err)
	}
	first, second := firstEvents[0], secondEvents[0]
	if first.EventSeq != 1 || second.EventSeq != 1 || first.AccountEventCursor <= 0 || second.AccountEventCursor <= first.AccountEventCursor {
		t.Fatalf("session-local seq must overlap while account cursor stays ordered: first=%+v second=%+v", first, second)
	}

	server := httptest.NewServer(env.router)
	t.Cleanup(server.Close)
	// query 故意传 0，验证 Last-Event-ID 才是恢复 cursor 的优先来源。
	recovered := openAccountSSE(t, server.URL, owner.AccessToken, first.AccountEventCursor, true)
	frame := readAccountSSEFrame(t, recovered)
	if frame.ID != second.AccountEventCursor || frame.Event != "session.created" || !strings.Contains(frame.Data, secondSessionID) || strings.Contains(frame.Data, firstSessionID) {
		t.Fatalf("Last-Event-ID recovery frame=%+v, want only second session event", frame)
	}

	other := env.provisionAdditionalAccount(t, "p4-sse-other@fixture.test")
	otherSessionID, _ := env.createSessionForProject(t, other.AccessToken, other.AccountID, "p4-sse-other")
	isolated := openAccountSSE(t, server.URL, other.AccessToken, 0, false)
	otherFrame := readAccountSSEFrame(t, isolated)
	if !strings.Contains(otherFrame.Data, otherSessionID) || strings.Contains(otherFrame.Data, firstSessionID) || strings.Contains(otherFrame.Data, secondSessionID) {
		t.Fatalf("account SSE scope leaked another account: frame=%+v", otherFrame)
	}

	invalid := env.do(t, http.MethodGet, "/v1/events?after_seq=-1", nil, owner.AccessToken)
	if invalid.Code != http.StatusBadRequest || relayErrorCode(t, invalid.Body.Bytes()) != "INVALID_REQUEST" {
		t.Fatalf("negative account cursor must fail closed: status=%d body=%s", invalid.Code, invalid.Body.String())
	}
}

// WEB-02：持久化的 delegation.changed 在事务提交后立即通知已连接的同账号 SSE；事件内容
// 仍是 opaque envelope，Web 只将其用作刷新 snapshot 的失效信号。
func TestP4AccountSSEPublishesCommittedDelegationEvent(t *testing.T) {
	env := newTestEnv(t)
	owner := env.registerAs(t, "p4-sse-live@fixture.test")
	parentSessionID, workspaceID := env.createSessionForProject(t, owner.AccessToken, owner.AccountID, "p4-sse-live")
	existing, err := env.repo.ListAccountEventsAfter(t.Context(), owner.AccountID, 0)
	if err != nil || len(existing) != 1 {
		t.Fatalf("initial account events=%+v err=%v", existing, err)
	}

	server := httptest.NewServer(env.router)
	t.Cleanup(server.Close)
	stream := openAccountSSE(t, server.URL, owner.AccessToken, existing[0].AccountEventCursor, false)
	epoch := sessionLeaseEpoch(t, env, owner.AccessToken, parentSessionID)
	created := env.do(t, http.MethodPost, "/v1/sessions/"+parentSessionID+"/delegations", delegationCreatePayload(
		workspaceID, "codex", "p4-sse-live-proposal", epoch,
	), owner.AccessToken)
	if created.Code != http.StatusAccepted {
		t.Fatalf("create delegation status=%d body=%s", created.Code, created.Body.String())
	}
	frame := readAccountSSEFrame(t, stream)
	if frame.ID <= existing[0].AccountEventCursor || frame.Event != "delegation.changed" || !strings.Contains(frame.Data, parentSessionID) || strings.Contains(frame.Data, "opaque-task-ciphertext") {
		t.Fatalf("live delegation SSE frame=%+v", frame)
	}
}

// WEB-02：浏览器 fetch 重连需要携带自定义 Last-Event-ID，预检白名单必须显式允许该头。
func TestP4AccountSSECORSAllowsLastEventID(t *testing.T) {
	env := newTestEnv(t)
	request := httptest.NewRequest(http.MethodOptions, "/v1/events", nil)
	request.Header.Set("Origin", "http://127.0.0.1:15173")
	request.Header.Set("Access-Control-Request-Headers", "Authorization, Last-Event-ID")
	recorder := httptest.NewRecorder()
	env.router.ServeHTTP(recorder, request)
	if recorder.Code != http.StatusNoContent || !strings.Contains(recorder.Header().Get("Access-Control-Allow-Headers"), "Last-Event-ID") {
		t.Fatalf("SSE CORS preflight status=%d headers=%q", recorder.Code, recorder.Header().Get("Access-Control-Allow-Headers"))
	}
}
