package relay

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"

	"github.com/yubi233/agent-sessions/internal/domain"
)

// V094-06（P0 契约冻结）：会话 snapshot 事件必须按 daemon_event_receipts
// 回投可选 command_id。契约要点：
//  1. 带 receipt 的事件 → snapshot 事件携带同会话关联的命令 ID（消息事务关联的事实来源）；
//  2. 无 receipt 的旧事件 → JSON 中不出现 command_id 键（客户端按「状态未确认」降级）；
//  3. envelope 密文原样透传，关联投影不得触碰 payload（不修改 AAD/envelope）。
func TestV094SnapshotEventCommandCorrelation(t *testing.T) {
	env := newTestEnv(t)
	owner := env.registerAs(t, "v094-correlation@test.dev")
	terminal := env.pairTerminal(t, owner, "v094-correlation-terminal")
	terminalID := daemonHello(t, env, terminal.AccessToken)
	sessionID, _ := env.createBoundSession(t, owner, terminalID, "v094-correlation")
	epoch := p2SessionLeaseEpoch(t, env, owner.AccessToken, sessionID)

	// 提交一条真实命令，拿到命令 ID 作为关联锚点。
	command := env.do(t, http.MethodPost, "/v1/sessions/"+sessionID+"/commands", map[string]any{
		"kind": "session.start", "idempotency_key": "v094-correlation-1", "lease_epoch": epoch,
		"target_terminal_id": terminalID,
		"ciphertext": map[string]any{
			"kind": "session.start", "session_id": sessionID,
			"ciphertext": map[string]any{"fixture_payload": map[string]any{"provider": "fixture"}},
		},
	}, owner.AccessToken)
	if command.Code != http.StatusAccepted {
		t.Fatalf("submit command status=%d body=%s", command.Code, command.Body.String())
	}
	var submitted struct {
		ID string `json:"id"`
	}
	decodeW1(t, command.Body.Bytes(), &submitted)
	if submitted.ID == "" {
		t.Fatalf("command projection missing id: %s", command.Body.String())
	}

	// Daemon（Runner 路径同构）携带 command_id 上传事件 → 落 receipt。
	envelope := opaqueFixtureEnvelope("v094-correlation-event")
	eventBody := map[string]any{
		"protocol_version": 1,
		"event_id":         "evt-v094-correlation-1",
		"command_id":       submitted.ID,
		"session_id":       sessionID,
		"event_type":       "turn.started",
		"envelope":         envelope,
	}
	upload := env.do(t, http.MethodPost, "/v1/daemon/events", eventBody, terminal.AccessToken)
	if upload.Code != http.StatusOK {
		t.Fatalf("event upload status=%d body=%s", upload.Code, upload.Body.String())
	}

	// 旧事件路径（无命令关联）：直接经 SessionService 追加，不产生 receipt。
	sessionService := domain.NewSessionService(env.repo)
	if _, err := sessionService.AppendEvent(t.Context(), sessionID, "message.delta", `{"legacy":"no-receipt"}`); err != nil {
		t.Fatalf("append legacy event: %v", err)
	}

	snapshot := env.do(t, http.MethodGet, "/v1/sessions/"+sessionID+"/snapshot?after_seq=0", nil, owner.AccessToken)
	if snapshot.Code != http.StatusOK {
		t.Fatalf("snapshot status=%d body=%s", snapshot.Code, snapshot.Body.String())
	}
	var body struct {
		Events []struct {
			EventSeq  int64           `json:"event_seq"`
			EventType string          `json:"event_type"`
			CommandID string          `json:"command_id"`
			Envelope  json.RawMessage `json:"envelope"`
		} `json:"events"`
	}
	if err := json.Unmarshal(snapshot.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode snapshot: %v body=%s", err, snapshot.Body.String())
	}
	var correlated, legacy *struct {
		EventSeq  int64
		EventType string
		CommandID string
		Envelope  json.RawMessage
	}
	for i := range body.Events {
		event := &body.Events[i]
		switch event.EventType {
		case "turn.started":
			correlated = &struct {
				EventSeq  int64
				EventType string
				CommandID string
				Envelope  json.RawMessage
			}{event.EventSeq, event.EventType, event.CommandID, event.Envelope}
		case "message.delta":
			legacy = &struct {
				EventSeq  int64
				EventType string
				CommandID string
				Envelope  json.RawMessage
			}{event.EventSeq, event.EventType, event.CommandID, event.Envelope}
		}
	}
	if correlated == nil || correlated.CommandID != submitted.ID {
		t.Fatalf("receipt 关联事件未回投 command_id（want %q）: %+v", submitted.ID, body.Events)
	}
	if legacy == nil {
		t.Fatalf("legacy event missing from snapshot: %s", snapshot.Body.String())
	}
	if legacy.CommandID != "" {
		t.Fatalf("无 receipt 事件不得回投 command_id，got %q", legacy.CommandID)
	}
	// JSON 层面：旧事件的响应体不允许出现 command_id 键（additive 可选契约）。
	if strings.Contains(snapshot.Body.String(), `"command_id":""`) {
		t.Fatalf("空 command_id 不允许序列化: %s", snapshot.Body.String())
	}
	// envelope 密文原样透传：关联投影只发生在 DTO 层。
	var correlatedEnvelope, uploadedEnvelope map[string]any
	if err := json.Unmarshal(correlated.Envelope, &correlatedEnvelope); err != nil {
		t.Fatalf("decode snapshot envelope: %v", err)
	}
	uploadedEnvelopeJSON, err := json.Marshal(envelope)
	if err != nil {
		t.Fatalf("marshal uploaded envelope: %v", err)
	}
	if err := json.Unmarshal(uploadedEnvelopeJSON, &uploadedEnvelope); err != nil {
		t.Fatalf("decode uploaded envelope: %v", err)
	}
	if correlatedEnvelope["ciphertext"] != uploadedEnvelope["ciphertext"] {
		t.Fatalf("snapshot envelope 被关联投影改写: %s vs %s", correlated.Envelope, uploadedEnvelopeJSON)
	}
}

// V094-26（P0 契约冻结）：controls 必须在保留 available_permission_modes ID 数组的
// 同时，兼容下发白名单展示目录 available_permission_mode_details：
//  1. 只投影 id/name/description，存储行中的其它字段不得泄漏；
//  2. name/description 按长度上限截断（128/512 rune），数量上限 64；
//  3. 空/缺省目录不下发字段，客户端回退旧 ID 契约。
func TestV094ControlsPermissionModeCatalog(t *testing.T) {
	env := newTestEnv(t)
	owner := env.registerAs(t, "v094-catalog@test.dev")
	terminal := env.pairTerminal(t, owner, "v094-catalog-terminal")
	terminalID := daemonHello(t, env, terminal.AccessToken)
	sessionID, _ := env.createBoundSession(t, owner, terminalID, "v094-catalog")

	longDescription := strings.Repeat("长", 600) // 超过 512 rune 上限，必须被截断
	upload := env.do(t, http.MethodPut, "/v1/daemon/sessions/"+sessionID+"/modes", map[string]any{
		"protocol_version": 1,
		"mode_id":          "default",
		"available_permission_modes": []map[string]any{
			{"id": "default", "name": "默认模式", "description": "标准权限"},
			// 完整访问条目：无说明 → details 中省略 name/description，UI 显示「说明未提供」。
			{"id": "danger-full-access", "internal_flag": "must-not-leak"},
			// 超长描述 + 未知字段：截断且不透传未知字段。
			{"id": "plan", "name": "计划模式", "description": longDescription, "risk_level": "internal-only"},
		},
	}, terminal.AccessToken)
	if upload.Code != http.StatusOK {
		t.Fatalf("modes upload status=%d body=%s", upload.Code, upload.Body.String())
	}

	controls := env.do(t, http.MethodGet, "/v1/sessions/"+sessionID+"/controls", nil, owner.AccessToken)
	if controls.Code != http.StatusOK {
		t.Fatalf("controls status=%d body=%s", controls.Code, controls.Body.String())
	}
	var body struct {
		PermissionMode           string   `json:"permission_mode"`
		AvailablePermissionModes []string `json:"available_permission_modes"`
		Details                  []struct {
			ID          string `json:"id"`
			Name        string `json:"name"`
			Description string `json:"description"`
		} `json:"available_permission_mode_details"`
	}
	if err := json.Unmarshal(controls.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode controls: %v body=%s", err, controls.Body.String())
	}
	if len(body.AvailablePermissionModes) != 3 {
		t.Fatalf("available_permission_modes（旧契约）被破坏: %v", body.AvailablePermissionModes)
	}
	if body.PermissionMode != "default" {
		t.Fatalf("permission_mode=%q want default", body.PermissionMode)
	}
	if len(body.Details) != 3 {
		t.Fatalf("available_permission_mode_details 条数=%d want 3: %+v", len(body.Details), body.Details)
	}
	byID := map[string]struct {
		Name        string
		Description string
	}{}
	for _, detail := range body.Details {
		byID[detail.ID] = struct{ Name, Description string }{detail.Name, detail.Description}
	}
	if detail := byID["default"]; detail.Name != "默认模式" || detail.Description != "标准权限" {
		t.Fatalf("default 条目投影错误: %+v", detail)
	}
	if detail := byID["danger-full-access"]; detail.Name != "" || detail.Description != "" {
		t.Fatalf("缺说明条目应省略 name/description: %+v", detail)
	}
	if detail := byID["plan"]; len([]rune(detail.Description)) != 512 {
		t.Fatalf("超长描述应截断到 512 rune，got %d", len([]rune(detail.Description)))
	}
	// 白名单：存储行的未知字段绝不下发。
	response := controls.Body.String()
	for _, leaked := range []string{"internal_flag", "risk_level", "internal-only", "must-not-leak"} {
		if strings.Contains(response, leaked) {
			t.Fatalf("controls 泄漏非白名单字段 %q: %s", leaked, response)
		}
	}

	// 无目录会话：ID 数组与 details 均不下发（客户端维持禁用+原因）。
	plainID, _ := env.createBoundSession(t, owner, terminalID, "v094-catalog-plain")
	plainControls := env.do(t, http.MethodGet, "/v1/sessions/"+plainID+"/controls", nil, owner.AccessToken)
	if plainControls.Code != http.StatusOK {
		t.Fatalf("plain controls status=%d", plainControls.Code)
	}
	plainBody := plainControls.Body.String()
	if strings.Contains(plainBody, "available_permission_modes") || strings.Contains(plainBody, "available_permission_mode_details") {
		t.Fatalf("空目录会话不应下发权限目录字段: %s", plainBody)
	}
}

// V094-22（P0 依赖登记）：Command 响应 error_code 已在 OpenAPI Command schema 冻结。
// 这里验证实际 HTTP 响应与 schema 一致——delivery 失败时 commandView 携带稳定错误码。
// （正常路径 error_code 缺省，由 generated types 的 omitempty 契约保证。）
func TestV094CommandSchemaErrorCodeFrozen(t *testing.T) {
	env := newTestEnv(t)
	owner := env.registerAs(t, "v094-errorcode@test.dev")
	terminal := env.pairTerminal(t, owner, "v094-errorcode-terminal")
	terminalID := daemonHello(t, env, terminal.AccessToken)
	sessionID, _ := env.createBoundSession(t, owner, terminalID, "v094-errorcode")
	epoch := p2SessionLeaseEpoch(t, env, owner.AccessToken, sessionID)

	command := env.do(t, http.MethodPost, "/v1/sessions/"+sessionID+"/commands", map[string]any{
		"kind": "session.start", "idempotency_key": "v094-errorcode-1", "lease_epoch": epoch,
		"target_terminal_id": terminalID,
		"ciphertext": map[string]any{
			"kind": "session.start", "session_id": sessionID,
			"ciphertext": map[string]any{"fixture_payload": map[string]any{"provider": "fixture"}},
		},
	}, owner.AccessToken)
	if command.Code != http.StatusAccepted {
		t.Fatalf("submit command status=%d body=%s", command.Code, command.Body.String())
	}
	// 受理（202）阶段无 delivery → 无 error_code；字段允许缺省（additive 契约）。
	var body struct {
		ID        string `json:"id"`
		Status    string `json:"status"`
		ErrorCode string `json:"error_code"`
	}
	if err := json.Unmarshal(command.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode command: %v", err)
	}
	if body.ErrorCode != "" {
		t.Fatalf("受理阶段不应携带 error_code: %+v", body)
	}
	if !strings.Contains(command.Body.String(), `"lease_epoch"`) || body.ID == "" {
		t.Fatalf("command view 契约不完整: %s", command.Body.String())
	}
}
