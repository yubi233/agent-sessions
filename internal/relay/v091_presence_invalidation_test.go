package relay

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
)

// v0.9.1 P1（迭代计划 §4 P1）：presence invalidation 与账号 SSE 契约回归（V091-06）。
// reaper 根因层回归（V091-07）见 internal/domain/presence_reaper_test.go。

// v091SSEFrame 是一条 SSE 帧；HasID 区分「进入 cursor 空间」的会话事件帧与
// 「无 id」的轻量 presence invalidation 帧。
type v091SSEFrame struct {
	ID     int64
	HasID  bool
	Event  string
	Data   string
	RawIDL string
}

// v091ReadFrame 读取下一帧（忽略注释/心跳行）；不要求 id 存在。
func v091ReadFrame(t *testing.T, stream *accountSSEStream) v091SSEFrame {
	t.Helper()
	frame := v091SSEFrame{}
	for stream.scanner.Scan() {
		line := stream.scanner.Text()
		if line == "" {
			if frame.Event != "" || frame.HasID {
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
			frame.HasID = true
			frame.RawIDL = value
			if cursor, parseErr := strconv.ParseInt(value, 10, 64); parseErr == nil {
				frame.ID = cursor
			}
		case "event":
			frame.Event = value
		case "data":
			frame.Data = value
		}
	}
	t.Fatalf("account SSE closed before a frame (scanner err=%v)", stream.scanner.Err())
	return v091SSEFrame{}
}

// V091-06：heartbeat 恢复触发恰好一次轻量 terminal.presence.changed 失效通知；
// 通知帧无 id（不进入账号 cursor 空间），快照重拉按 /v1/terminals 进行；
// 重复心跳不产生重复通知；既有会话事件帧（带 id、cursor 回放）契约不变。
func TestV091PresenceInvalidationOnAccountSSE(t *testing.T) {
	env := newTestEnv(t)
	owner := env.registerAs(t, "v091-invalidation@test.dev")
	terminal := env.pairTerminal(t, owner, "v091-invalidation-terminal")
	terminalID := daemonHello(t, env, terminal.AccessToken)

	server := httptest.NewServer(env.router)
	t.Cleanup(server.Close)
	stream := openAccountSSE(t, server.URL, owner.AccessToken, 0, false)

	// 第一步：把目标拨过 60s deadline，再用真实 heartbeat 恢复 —— 服务端
	// prev 投影为 offline，恢复转换必须恰好发布一次 invalidation（revision=1）。
	v091AgeLastHeartbeat(t, env, terminalID, 61_000)
	heartbeat := env.do(t, http.MethodPost, "/v1/daemon/heartbeat", map[string]any{
		"protocol_version": 1,
	}, terminal.AccessToken)
	if heartbeat.Code != http.StatusOK {
		t.Fatalf("recovery heartbeat status=%d body=%s", heartbeat.Code, heartbeat.Body.String())
	}

	frame := v091ReadFrame(t, stream)
	if frame.Event != "terminal.presence.changed" {
		t.Fatalf("first frame event=%q, want terminal.presence.changed", frame.Event)
	}
	if frame.HasID {
		t.Fatalf("presence invalidation must not carry id (cursor space unchanged), got id=%q", frame.RawIDL)
	}
	var payload struct {
		TerminalID       string `json:"terminal_id"`
		Availability     string `json:"availability"`
		PresenceRevision int64  `json:"presence_revision"`
	}
	if err := json.Unmarshal([]byte(frame.Data), &payload); err != nil {
		t.Fatalf("decode presence invalidation %q: %v", frame.Data, err)
	}
	if payload.TerminalID != terminalID || payload.Availability != "online" || payload.PresenceRevision != 1 {
		t.Fatalf("invalidation payload=%+v, want online@revision 1", payload)
	}

	// 第二步：重复 heartbeat（无状态变化）—— 不得再发布 presence 帧。
	// 用一条 cursor 空间的会话事件做界标：界标之前只允许出现刚才那一次 presence 帧。
	for i := 0; i < 2; i++ {
		again := env.do(t, http.MethodPost, "/v1/daemon/heartbeat", map[string]any{
			"protocol_version": 1,
		}, terminal.AccessToken)
		if again.Code != http.StatusOK {
			t.Fatalf("repeat heartbeat status=%d", again.Code)
		}
	}
	env.createSessionForProject(t, owner.AccessToken, owner.AccountID, "v091-invalidation-probe")
	sawBoundary := false
	for !sawBoundary {
		next := v091ReadFrame(t, stream)
		switch next.Event {
		case "terminal.presence.changed":
			t.Fatalf("duplicate presence invalidation after stateless heartbeats: %+v", next)
		case "session.created":
			if !next.HasID || next.ID <= 0 {
				t.Fatalf("session event frame lost cursor contract: %+v", next)
			}
			sawBoundary = true
		default:
			// 其它 cursor 帧继续等待界标。
		}
	}

	// 第三步：断线恢复用 Last-Event-ID 重放 —— presence 帧不在 cursor 空间，
	// 重放只含会话事件；账号 SSE 授权与 cursor 语义不变（错误 cursor 仍 400）。
	replay := openAccountSSE(t, server.URL, owner.AccessToken, 0, false)
	replayFrame := v091ReadFrame(t, replay)
	if replayFrame.Event != "session.created" || !replayFrame.HasID {
		t.Fatalf("cursor replay must not include presence frames: %+v", replayFrame)
	}
	invalid := env.do(t, http.MethodGet, "/v1/events?after_seq=-1", nil, owner.AccessToken)
	if invalid.Code != http.StatusBadRequest {
		t.Fatalf("negative cursor contract changed: status=%d", invalid.Code)
	}
}
