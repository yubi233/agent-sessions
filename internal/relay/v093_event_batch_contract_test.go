package relay

import (
	"encoding/json"
	"fmt"
	"net/http"
	"testing"

	"github.com/yubi233/agent-sessions/internal/domain"
)

// V093-02 契约回归（v0.9.3 P1）：/v1/daemon/events/batch 批量事件上传。
// 冻结契约（迭代计划 v0.9.3 §3.2）：批量化不得放松 event_seq 严格递增、
// 重复投递幂等与终态语义；本文件把三条契约逐一钉在 HTTP 边界上。

// v093BatchContractSetup 构造「owner + 已配对 Terminal + 已绑定会话 + started 命令」
// 的最小事件上传前置（与 terminal_status_contract_test 同一基建）。
func v093BatchContractSetup(t *testing.T, name string) (*testEnv, string, string, string) {
	t.Helper()
	env := newTestEnv(t)
	owner := env.registerAs(t, "v093-batch-"+name+"@test.dev")
	terminal := env.pairTerminal(t, owner, "v093-batch-"+name+"-terminal")
	terminalID := daemonHello(t, env, terminal.AccessToken)
	sessionID, _ := env.createBoundSession(t, owner, terminalID, "v093-batch-"+name)
	epoch := p2SessionLeaseEpoch(t, env, owner.AccessToken, sessionID)
	commandResponse := env.do(t, http.MethodPost, "/v1/sessions/"+sessionID+"/commands", map[string]any{
		"kind": "session.start", "idempotency_key": "v093-batch-" + name,
		"lease_epoch": epoch, "target_terminal_id": terminalID,
		"ciphertext": map[string]any{"kind": "session.start", "session_id": sessionID},
	}, owner.AccessToken)
	if commandResponse.Code != http.StatusAccepted {
		t.Fatalf("submit command status=%d body=%s", commandResponse.Code, commandResponse.Body.String())
	}
	var command struct {
		ID string
	}
	if err := json.Unmarshal(commandResponse.Body.Bytes(), &command); err != nil || command.ID == "" {
		t.Fatalf("decode command=%+v err=%v", command, err)
	}
	ack := env.do(t, http.MethodPost, "/v1/daemon/commands/"+command.ID+"/ack", map[string]any{
		"protocol_version": 1, "delivery_seq": 1, "ack_kind": "started",
	}, terminal.AccessToken)
	if ack.Code != http.StatusOK {
		t.Fatalf("started ack status=%d body=%s", ack.Code, ack.Body.String())
	}
	return env, terminal.AccessToken, sessionID, command.ID
}

// v093BatchEvent 构造批量请求内的单条事件 map。
func v093BatchEvent(eventID, commandID, sessionID, eventType string) map[string]any {
	return map[string]any{
		"event_id": eventID, "command_id": commandID, "session_id": sessionID,
		"event_type": eventType, "envelope": opaqueFixtureEnvelope(eventID),
	}
}

// 契约 1：批量按数组顺序分配严格递增 event_seq；重复投递整批幂等（回执逐条一致、
// 不重复落库）；终态帧（turn.completed + terminal_status=idle）在批量内同样驱动会话投影。
func TestV093EventBatchUploadOrderIdempotencyAndTerminal(t *testing.T) {
	env, token, sessionID, commandID := v093BatchContractSetup(t, "order")

	batch := []map[string]any{
		v093BatchEvent("v093-batch-delta-1", commandID, sessionID, "message.delta"),
		v093BatchEvent("v093-batch-delta-2", commandID, sessionID, "message.delta"),
		func() map[string]any {
			event := v093BatchEvent("v093-batch-terminal", commandID, sessionID, "turn.completed")
			event["terminal_status"] = domain.SessionIdle
			return event
		}(),
	}
	first := env.do(t, http.MethodPost, "/v1/daemon/events/batch", map[string]any{
		"protocol_version": 1, "events": batch,
	}, token)
	if first.Code != http.StatusOK {
		t.Fatalf("batch upload status=%d body=%s", first.Code, first.Body.String())
	}
	var receipts struct {
		Results []struct {
			EventID    string `json:"event_id"`
			EventSeq   int64  `json:"event_seq"`
			Idempotent bool   `json:"idempotent"`
		} `json:"results"`
	}
	decodeW1(t, first.Body.Bytes(), &receipts)
	if len(receipts.Results) != 3 {
		t.Fatalf("batch receipts len=%d, want 3", len(receipts.Results))
	}
	for i, receipt := range receipts.Results {
		if receipt.Idempotent {
			t.Fatalf("receipt %d unexpectedly idempotent on first upload", i)
		}
		if receipt.EventID != batch[i]["event_id"] {
			t.Fatalf("receipt %d event_id=%q, want %q（回执必须与请求顺序一一对应）", i, receipt.EventID, batch[i]["event_id"])
		}
		if i > 0 && receipt.EventSeq <= receipts.Results[i-1].EventSeq {
			t.Fatalf("event_seq not strictly increasing: %v", receipts.Results)
		}
	}

	// 重放同一批：全部幂等返回既有 seq，不重复落库（ListEventsAfter 计数不变）。
	replay := env.do(t, http.MethodPost, "/v1/daemon/events/batch", map[string]any{
		"protocol_version": 1, "events": batch,
	}, token)
	if replay.Code != http.StatusOK {
		t.Fatalf("batch replay status=%d body=%s", replay.Code, replay.Body.String())
	}
	var replayReceipts struct {
		Results []struct {
			EventSeq   int64  `json:"event_seq"`
			Idempotent bool   `json:"idempotent"`
			EventID    string `json:"event_id"`
		} `json:"results"`
	}
	decodeW1(t, replay.Body.Bytes(), &replayReceipts)
	for i, receipt := range replayReceipts.Results {
		if !receipt.Idempotent || receipt.EventSeq != receipts.Results[i].EventSeq {
			t.Fatalf("replay receipt %d=%+v, want idempotent with seq %d", i, receipt, receipts.Results[i].EventSeq)
		}
	}

	events, err := env.repo.ListEventsAfter(t.Context(), sessionID, 0)
	if err != nil {
		t.Fatalf("list events: %v", err)
	}
	// 事件流第 1 条是会话创建的既有事件（与 terminal_status_contract 同口径），
	// 批量 3 条落库后共 4 条；幂等重放不得重复落库。
	if len(events) != 4 {
		t.Fatalf("stored events len=%d, want 4（幂等重放不得重复落库）", len(events))
	}
	events = events[1:]
	for i, event := range events {
		if event.EventType != batch[i]["event_type"] {
			t.Fatalf("stored order broken at %d: %q != %q", i, event.EventType, batch[i]["event_type"])
		}
		if i > 0 && event.EventSeq <= events[i-1].EventSeq {
			t.Fatalf("stored event_seq not increasing at %d", i)
		}
	}
	// 终态语义：批量内最后一个事件是 turn.completed(idle)，会话投影必须是 idle。
	session, err := env.repo.SessionByID(t.Context(), sessionID)
	if err != nil {
		t.Fatalf("read session: %v", err)
	}
	if session.Status != domain.SessionIdle {
		t.Fatalf("session status=%q, want idle（终态帧顺序不得被批量化改变）", session.Status)
	}
}

// 契约 2：批量内任一事件非法 → 整批原子拒绝，不产生部分提交；
// 之后单条上传合法事件仍成功（批量回滚没有留下任何状态残迹）。
func TestV093EventBatchUploadAtomicReject(t *testing.T) {
	env, token, sessionID, commandID := v093BatchContractSetup(t, "atomic")

	batch := []map[string]any{
		v093BatchEvent("v093-atomic-good", commandID, sessionID, "message.delta"),
		func() map[string]any {
			// terminal_status 只允许附着 turn.completed（与单条端点同一白名单）。
			event := v093BatchEvent("v093-atomic-poison", commandID, sessionID, "message.completed")
			event["terminal_status"] = domain.SessionStopped
			return event
		}(),
	}
	response := env.do(t, http.MethodPost, "/v1/daemon/events/batch", map[string]any{
		"protocol_version": 1, "events": batch,
	}, token)
	if response.Code != http.StatusBadRequest {
		t.Fatalf("atomic reject status=%d body=%s, want 400", response.Code, response.Body.String())
	}
	events, err := env.repo.ListEventsAfter(t.Context(), sessionID, 0)
	if err != nil {
		t.Fatalf("list events: %v", err)
	}
	if len(events) != 1 {
		t.Fatalf("stored events len=%d after rejected batch, want 1（整批原子回滚，仅保留会话创建事件）", len(events))
	}
	// 被拒绝批中的合法事件随后单条上传成功——证明失败不是它造成的，也没有副作用残留。
	single := env.do(t, http.MethodPost, "/v1/daemon/events", map[string]any{
		"protocol_version": 1, "event_id": "v093-atomic-good", "command_id": commandID,
		"session_id": sessionID, "event_type": "message.delta",
		"envelope": opaqueFixtureEnvelope("v093-atomic-good"),
	}, token)
	if single.Code != http.StatusOK {
		t.Fatalf("single upload after batch reject status=%d body=%s", single.Code, single.Body.String())
	}
}

// 契约 3：超上限（>200 条）整批拒绝；空批拒绝。
// daemon 侧据此做「按条数+字节分块」，正常路径永远不会触达该边界。
func TestV093EventBatchUploadRejectsOversizeAndEmpty(t *testing.T) {
	env, token, sessionID, commandID := v093BatchContractSetup(t, "oversize")

	batch := make([]map[string]any, 0, domain.MaxDaemonEventBatchSize+1)
	for i := 0; i < domain.MaxDaemonEventBatchSize+1; i++ {
		batch = append(batch, v093BatchEvent(fmt.Sprintf("v093-oversize-%d", i), commandID, sessionID, "message.delta"))
	}
	response := env.do(t, http.MethodPost, "/v1/daemon/events/batch", map[string]any{
		"protocol_version": 1, "events": batch,
	}, token)
	if response.Code != http.StatusBadRequest {
		t.Fatalf("oversize batch status=%d, want 400", response.Code)
	}
	empty := env.do(t, http.MethodPost, "/v1/daemon/events/batch", map[string]any{
		"protocol_version": 1, "events": []map[string]any{},
	}, token)
	if empty.Code != http.StatusBadRequest {
		t.Fatalf("empty batch status=%d, want 400", empty.Code)
	}
}
