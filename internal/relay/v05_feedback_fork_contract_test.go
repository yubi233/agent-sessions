package relay

import (
	"net/http"
	"testing"
	"time"
)

type v05FeedbackItem struct {
	MessageID string `json:"message_id"`
	Rating    string `json:"rating"`
	Note      string `json:"note"`
	Version   int64  `json:"version"`
}

type v05FeedbackMutation struct {
	OK        bool             `json:"ok"`
	ErrorCode string           `json:"error_code"`
	Item      *v05FeedbackItem `json:"item"`
	Current   *v05FeedbackItem `json:"current"`
}

type v05SessionView struct {
	ID                  string `json:"id"`
	WorkspaceID         string `json:"workspace_id"`
	Provider            string `json:"provider"`
	Model               string `json:"model"`
	LastSeq             int64  `json:"last_seq"`
	ParentSessionID     string `json:"parent_session_id"`
	ForkedFromMessageID string `json:"forked_from_message_id"`
}

// MOBILE-V05-19/P2-F：真实 Relay message feedback 使用 lazy-read + CAS version 协议。
// 本测试只覆盖本地 HTTP/SQLite 契约；不保存消息正文，也不调用真实 Provider。
func TestV05MessageFeedbackHTTPContract(t *testing.T) {
	env := newTestEnv(t)
	owner := env.registerAs(t, "v05-feedback-owner@test.dev")
	sessionID, _ := env.createSession(t, owner.AccessToken, owner.AccountID)

	list := env.do(t, http.MethodGet, "/v1/sessions/"+sessionID+"/feedback", nil, owner.AccessToken)
	if list.Code != http.StatusOK {
		t.Fatalf("list feedback status=%d body=%s", list.Code, list.Body.String())
	}
	var listBody struct {
		Items []v05FeedbackItem `json:"items"`
	}
	decodeW1(t, list.Body.Bytes(), &listBody)
	if len(listBody.Items) != 0 {
		t.Fatalf("initial feedback list must be empty: %+v", listBody.Items)
	}

	getEmpty := env.do(t, http.MethodGet, "/v1/sessions/"+sessionID+"/feedback/msg-1", nil, owner.AccessToken)
	if getEmpty.Code != http.StatusOK {
		t.Fatalf("get empty feedback status=%d", getEmpty.Code)
	}
	if !containsStr(getEmpty.Body.String(), `"item":null`) {
		t.Fatalf("empty feedback should return item:null, body=%s", getEmpty.Body.String())
	}

	create := env.do(t, http.MethodPut, "/v1/sessions/"+sessionID+"/feedback/msg-1", map[string]any{
		"rating": "positive",
		"note":   "useful",
	}, owner.AccessToken)
	if create.Code != http.StatusOK {
		t.Fatalf("create feedback status=%d body=%s", create.Code, create.Body.String())
	}
	var created v05FeedbackMutation
	decodeW1(t, create.Body.Bytes(), &created)
	if !created.OK || created.Item == nil || created.Item.Version != 1 || created.Item.Rating != "positive" || created.Item.Note != "useful" {
		t.Fatalf("created feedback unexpected: %+v", created)
	}

	update := env.do(t, http.MethodPut, "/v1/sessions/"+sessionID+"/feedback/msg-1", map[string]any{
		"rating":  "negative",
		"note":    "needs more detail",
		"version": created.Item.Version,
	}, owner.AccessToken)
	if update.Code != http.StatusOK {
		t.Fatalf("update feedback status=%d body=%s", update.Code, update.Body.String())
	}
	var updated v05FeedbackMutation
	decodeW1(t, update.Body.Bytes(), &updated)
	if !updated.OK || updated.Item == nil || updated.Item.Version != 2 || updated.Item.Rating != "negative" {
		t.Fatalf("updated feedback unexpected: %+v", updated)
	}

	conflict := env.do(t, http.MethodPut, "/v1/sessions/"+sessionID+"/feedback/msg-1", map[string]any{
		"rating":  "positive",
		"version": int64(1),
	}, owner.AccessToken)
	if conflict.Code != http.StatusOK {
		t.Fatalf("feedback conflict carrier status=%d body=%s", conflict.Code, conflict.Body.String())
	}
	var conflictBody v05FeedbackMutation
	decodeW1(t, conflict.Body.Bytes(), &conflictBody)
	if conflictBody.OK || conflictBody.ErrorCode != "version-conflict" || conflictBody.Current == nil || conflictBody.Current.Version != 2 {
		t.Fatalf("feedback conflict response unexpected: %+v", conflictBody)
	}

	deleteResponse := env.do(t, http.MethodDelete, "/v1/sessions/"+sessionID+"/feedback/msg-1", map[string]any{
		"version": updated.Item.Version,
	}, owner.AccessToken)
	if deleteResponse.Code != http.StatusOK {
		t.Fatalf("delete feedback status=%d body=%s", deleteResponse.Code, deleteResponse.Body.String())
	}
	var deleted v05FeedbackMutation
	decodeW1(t, deleteResponse.Body.Bytes(), &deleted)
	if !deleted.OK || deleted.Item != nil {
		t.Fatalf("delete feedback response unexpected: %+v", deleted)
	}

	afterDelete := env.do(t, http.MethodGet, "/v1/sessions/"+sessionID+"/feedback", nil, owner.AccessToken)
	decodeW1(t, afterDelete.Body.Bytes(), &listBody)
	if len(listBody.Items) != 0 {
		t.Fatalf("feedback list after delete must be empty: %+v", listBody.Items)
	}

	webLogin := env.do(t, http.MethodPost, "/v1/auth/login", map[string]any{
		"email": "v05-feedback-owner@test.dev", "password": "test-pass-123",
	}, "")
	if webLogin.Code != http.StatusOK {
		t.Fatalf("web login status=%d body=%s", webLogin.Code, webLogin.Body.String())
	}
	var webTokens w1TokenPair
	decodeW1(t, webLogin.Body.Bytes(), &webTokens)
	if denied := env.do(t, http.MethodPut, "/v1/sessions/"+sessionID+"/feedback/msg-1", map[string]any{
		"rating": "positive",
	}, webTokens.AccessToken); denied.Code != http.StatusForbidden {
		t.Fatalf("readonly feedback write status=%d want 403", denied.Code)
	}

	other := env.provisionAdditionalAccount(t, "v05-feedback-other@test.dev")
	if denied := env.do(t, http.MethodGet, "/v1/sessions/"+sessionID+"/feedback", nil, other.AccessToken); denied.Code != http.StatusForbidden {
		t.Fatalf("cross-account feedback list status=%d want 403", denied.Code)
	}
}

// MOBILE-V05-19/P2-G：真实 Relay fork 创建 child session 元数据和 parent/child lineage 事件。
// Relay 不复制正文、不启动 Provider、不制造 seeded transcript。
func TestV05SessionForkHTTPContract(t *testing.T) {
	env := newTestEnv(t)
	owner := env.registerAs(t, "v05-fork-owner@test.dev")
	parentID, workspaceID := env.createSession(t, owner.AccessToken, owner.AccountID)
	epoch := p2SessionLeaseEpoch(t, env, owner.AccessToken, parentID)

	fork := env.do(t, http.MethodPost, "/v1/sessions/"+parentID+"/forks", map[string]any{
		"message_id":      "assistant-msg-9",
		"idempotency_key": "fork-key-1",
		"lease_epoch":     epoch,
	}, owner.AccessToken)
	if fork.Code != http.StatusCreated {
		t.Fatalf("fork status=%d body=%s", fork.Code, fork.Body.String())
	}
	var child v05SessionView
	decodeW1(t, fork.Body.Bytes(), &child)
	if child.ID == "" || child.WorkspaceID != workspaceID || child.ParentSessionID != parentID || child.ForkedFromMessageID != "assistant-msg-9" {
		t.Fatalf("child fork projection unexpected: %+v", child)
	}

	replay := env.do(t, http.MethodPost, "/v1/sessions/"+parentID+"/forks", map[string]any{
		"message_id":      "assistant-msg-9",
		"idempotency_key": "fork-key-1",
		"lease_epoch":     epoch,
	}, owner.AccessToken)
	if replay.Code != http.StatusCreated {
		t.Fatalf("fork replay status=%d body=%s", replay.Code, replay.Body.String())
	}
	var replayed v05SessionView
	decodeW1(t, replay.Body.Bytes(), &replayed)
	if replayed.ID != child.ID {
		t.Fatalf("fork idempotency returned different child: first=%s replay=%s", child.ID, replayed.ID)
	}

	parentSnapshot := env.do(t, http.MethodGet, "/v1/sessions/"+parentID+"/snapshot", nil, owner.AccessToken)
	if parentSnapshot.Code != http.StatusOK || !containsStr(parentSnapshot.Body.String(), `"event_type":"session.forked"`) || !containsStr(parentSnapshot.Body.String(), child.ID) {
		t.Fatalf("parent snapshot missing session.forked: status=%d body=%s", parentSnapshot.Code, parentSnapshot.Body.String())
	}
	childSnapshot := env.do(t, http.MethodGet, "/v1/sessions/"+child.ID+"/snapshot", nil, owner.AccessToken)
	if childSnapshot.Code != http.StatusOK || !containsStr(childSnapshot.Body.String(), `"event_type":"session.created"`) || containsStr(childSnapshot.Body.String(), "assistant-msg-9 transcript") {
		t.Fatalf("child snapshot contract unexpected: status=%d body=%s", childSnapshot.Code, childSnapshot.Body.String())
	}

	nextEpoch := p2SessionLeaseEpoch(t, env, owner.AccessToken, parentID)
	if stale := env.do(t, http.MethodPost, "/v1/sessions/"+parentID+"/forks", map[string]any{
		"message_id":      "assistant-msg-10",
		"idempotency_key": "fork-key-stale",
		"lease_epoch":     epoch,
	}, owner.AccessToken); stale.Code != http.StatusConflict {
		t.Fatalf("stale fork status=%d want 409 currentEpoch=%d body=%s", stale.Code, nextEpoch, stale.Body.String())
	}
	if missing := env.do(t, http.MethodPost, "/v1/sessions/"+parentID+"/forks", map[string]any{
		"message_id":      "assistant-msg-11",
		"idempotency_key": "fork-key-missing",
		"lease_epoch":     int64(0),
	}, owner.AccessToken); missing.Code != http.StatusBadRequest {
		t.Fatalf("missing lease fork status=%d want 400", missing.Code)
	}
}

// MOBILE-V05-12/P7-B：真实 Relay controls 投影只消费 Daemon usage 白名单字段，
// TTFT/decode throughput 缺失时不补假值。
func TestV05SessionControlsUsageTimingHTTPContract(t *testing.T) {
	env := newTestEnv(t)
	owner := env.registerAs(t, "v05-controls-owner@test.dev")
	terminal := env.pairTerminal(t, owner, "v05-controls-terminal")
	terminalID := daemonHello(t, env, terminal.AccessToken)
	sessionID, _ := env.createBoundSession(t, owner, terminalID, "v05-controls")

	emptyControls := env.do(t, http.MethodGet, "/v1/sessions/"+sessionID+"/controls", nil, owner.AccessToken)
	if emptyControls.Code != http.StatusOK {
		t.Fatalf("empty controls status=%d body=%s", emptyControls.Code, emptyControls.Body.String())
	}
	if containsStr(emptyControls.Body.String(), "input_tokens") || containsStr(emptyControls.Body.String(), "ttft_ms") {
		t.Fatalf("empty controls must not fake usage/timing: %s", emptyControls.Body.String())
	}

	day := time.Now().UTC().Format("2006-01-02")
	upload := env.do(t, http.MethodPost, "/v1/daemon/usage/events", map[string]any{
		"usage_key":          "v05-session-usage-1",
		"session_id":         sessionID,
		"provider":           "fixture",
		"model":              "fixture-model-real-projection",
		"utc_day":            day,
		"input_tokens":       120,
		"output_tokens":      80,
		"cache_read_tokens":  30,
		"cache_write_tokens": 10,
		"ttft_ms":            640,
		"decode_throughput":  42.5,
	}, terminal.AccessToken)
	if upload.Code != http.StatusOK {
		t.Fatalf("session usage upload status=%d body=%s", upload.Code, upload.Body.String())
	}

	controls := env.do(t, http.MethodGet, "/v1/sessions/"+sessionID+"/controls", nil, owner.AccessToken)
	if controls.Code != http.StatusOK {
		t.Fatalf("controls status=%d body=%s", controls.Code, controls.Body.String())
	}
	var body struct {
		Model string `json:"model"`
		Usage struct {
			InputTokens      int64   `json:"input_tokens"`
			OutputTokens     int64   `json:"output_tokens"`
			CacheReadTokens  int64   `json:"cache_read_tokens"`
			CacheWriteTokens int64   `json:"cache_write_tokens"`
			ContextTokens    int64   `json:"context_tokens"`
			TTFTMS           int64   `json:"ttft_ms"`
			DecodeThroughput float64 `json:"decode_throughput"`
		} `json:"usage"`
	}
	decodeW1(t, controls.Body.Bytes(), &body)
	if body.Model != "fixture-model-real-projection" ||
		body.Usage.InputTokens != 120 ||
		body.Usage.OutputTokens != 80 ||
		body.Usage.CacheReadTokens != 30 ||
		body.Usage.CacheWriteTokens != 10 ||
		body.Usage.ContextTokens != 240 ||
		body.Usage.TTFTMS != 640 ||
		body.Usage.DecodeThroughput != 42.5 {
		t.Fatalf("controls usage projection unexpected: %+v", body)
	}

	invalid := env.do(t, http.MethodPost, "/v1/daemon/usage/events", map[string]any{
		"usage_key":         "v05-session-usage-invalid",
		"session_id":        sessionID,
		"provider":          "fixture",
		"utc_day":           day,
		"input_tokens":      1,
		"output_tokens":     1,
		"decode_throughput": -1.0,
	}, terminal.AccessToken)
	if invalid.Code != http.StatusBadRequest {
		t.Fatalf("invalid throughput status=%d want 400 body=%s", invalid.Code, invalid.Body.String())
	}
}
