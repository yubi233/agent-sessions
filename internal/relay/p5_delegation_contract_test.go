package relay

import (
	"encoding/json"
	"net/http"
	"testing"

	"github.com/yubi233/agent-sessions/internal/store"
)

type delegationHTTPView struct {
	ID                    string          `json:"id"`
	ParentSessionID       string          `json:"parent_session_id"`
	ChildSessionID        string          `json:"child_session_id"`
	TargetProvider        string          `json:"target_provider"`
	Status                string          `json:"status"`
	SummaryEnvelope       json.RawMessage `json:"summary_envelope"`
	SummaryEnvelopeSHA256 string          `json:"summary_envelope_sha256"`
}

func delegationEnvelopePayload(ciphertext string) map[string]any {
	return map[string]any{
		"alg": "v1-aes256gcm-hkdfsha256", "key_id": "fixture-dek", "nonce": "fixture-nonce",
		"ciphertext": ciphertext, "aad_hash": "fixture-aad", "payload_version": 1,
	}
}

func delegationCreatePayload(workspaceID, provider, idempotencyKey string, epoch int64) map[string]any {
	return map[string]any{
		"target_workspace_id": workspaceID,
		"target_provider":     provider,
		"task_envelope":       delegationEnvelopePayload("opaque-task-ciphertext"),
		"summary_envelope":    delegationEnvelopePayload("opaque-summary-ciphertext"),
		"idempotency_key":     idempotencyKey,
		"lease_epoch":         epoch,
	}
}

func sessionLeaseEpoch(t *testing.T, env *testEnv, token, sessionID string) int64 {
	t.Helper()
	response := env.do(t, http.MethodPost, "/v1/sessions/"+sessionID+"/lease", nil, token)
	if response.Code != http.StatusOK {
		t.Fatalf("acquire lease status=%d body=%s", response.Code, response.Body.String())
	}
	var payload struct {
		LeaseEpoch int64 `json:"lease_epoch"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &payload); err != nil || payload.LeaseEpoch <= 0 {
		t.Fatalf("decode lease: epoch=%d err=%v", payload.LeaseEpoch, err)
	}
	return payload.LeaseEpoch
}

func relayErrorCode(t *testing.T, body []byte) string {
	t.Helper()
	var payload struct {
		Code string `json:"code"`
	}
	if err := json.Unmarshal(body, &payload); err != nil {
		t.Fatalf("decode error payload: %v", err)
	}
	return payload.Code
}

// DELEG-02/03/06：Relay 只保存密文索引；approve 后 child 是独立 Session，parent 投影只含摘要和状态。
func TestDelegationProposalApprovalAndParentReadProjection(t *testing.T) {
	env := newTestEnv(t)
	pair := env.registerAs(t, "delegation-owner@fixture.test")
	parentID, workspaceID := env.createSession(t, pair.AccessToken, pair.AccountID)
	parentEpoch := sessionLeaseEpoch(t, env, pair.AccessToken, parentID)

	proposalResponse := env.do(t, http.MethodPost, "/v1/sessions/"+parentID+"/delegations", delegationCreatePayload(
		workspaceID, "codex", "delegation-create-1", parentEpoch,
	), pair.AccessToken)
	if proposalResponse.Code != http.StatusAccepted {
		t.Fatalf("proposal status=%d body=%s", proposalResponse.Code, proposalResponse.Body.String())
	}
	if containsStr(proposalResponse.Body.String(), "task_envelope") || containsStr(proposalResponse.Body.String(), "opaque-task-ciphertext") {
		t.Fatalf("proposal response leaked task envelope: %s", proposalResponse.Body.String())
	}
	var proposal delegationHTTPView
	if err := json.Unmarshal(proposalResponse.Body.Bytes(), &proposal); err != nil {
		t.Fatalf("decode proposal: %v", err)
	}
	if proposal.Status != "proposed" || proposal.ChildSessionID != "" || proposal.ID == "" {
		t.Fatalf("proposal = %+v", proposal)
	}
	if len(proposal.SummaryEnvelope) == 0 || proposal.SummaryEnvelopeSHA256 == "" {
		t.Fatalf("proposal must expose encrypted summary only: %+v", proposal)
	}

	listResponse := env.do(t, http.MethodGet, "/v1/sessions/"+parentID+"/delegations", nil, pair.AccessToken)
	if listResponse.Code != http.StatusOK {
		t.Fatalf("list status=%d body=%s", listResponse.Code, listResponse.Body.String())
	}
	if containsStr(listResponse.Body.String(), "task_envelope") || containsStr(listResponse.Body.String(), "opaque-task-ciphertext") {
		t.Fatalf("parent list leaked task envelope: %s", listResponse.Body.String())
	}
	var listPayload struct {
		Delegations []delegationHTTPView `json:"delegations"`
	}
	if err := json.Unmarshal(listResponse.Body.Bytes(), &listPayload); err != nil || len(listPayload.Delegations) != 1 {
		t.Fatalf("decode list: count=%d err=%v", len(listPayload.Delegations), err)
	}

	approved := env.do(t, http.MethodPost, "/v1/delegations/"+proposal.ID+"/decision", map[string]any{
		"decision": "approve", "idempotency_key": "delegation-approve-1", "lease_epoch": parentEpoch,
	}, pair.AccessToken)
	if approved.Code != http.StatusOK {
		t.Fatalf("approve status=%d body=%s", approved.Code, approved.Body.String())
	}
	var running delegationHTTPView
	if err := json.Unmarshal(approved.Body.Bytes(), &running); err != nil {
		t.Fatalf("decode running delegation: %v", err)
	}
	if running.Status != "running" || running.ChildSessionID == "" || running.TargetProvider != "codex" {
		t.Fatalf("approved delegation = %+v", running)
	}

	stored, err := env.repo.DelegationByID(t.Context(), proposal.ID)
	if err != nil {
		t.Fatalf("read stored delegation: %v", err)
	}
	if stored.TaskEnvelopeSHA256 == "" || stored.SummaryEnvelopeSHA256 == "" || containsStr(stored.TaskEnvelopeJSON, "plaintext") {
		t.Fatalf("stored delegation broke encrypted boundary: %+v", stored)
	}
	child, err := env.repo.SessionByID(t.Context(), running.ChildSessionID)
	if err != nil || child.WorkspaceID != workspaceID || child.Provider != "codex" || child.CurrentInstanceID == "" {
		t.Fatalf("child session = %+v err=%v", child, err)
	}
	childLease, err := env.repo.LeaseBySession(t.Context(), running.ChildSessionID)
	if err != nil || childLease.Epoch != 1 {
		t.Fatalf("child independent lease = %+v err=%v", childLease, err)
	}
	parentEvents, err := env.repo.ListEventsAfter(t.Context(), parentID, 0)
	if err != nil {
		t.Fatalf("parent events: %v", err)
	}
	for _, event := range parentEvents {
		if event.EventType == "delegation.changed" && (containsStr(event.EnvelopeJSON, "task_envelope") || containsStr(event.EnvelopeJSON, "opaque-task-ciphertext")) {
			t.Fatalf("parent event leaked child task: %s", event.EnvelopeJSON)
		}
	}

	// 同一决策幂等键必须返回已有 child，而不是创建第二条派发图。
	again := env.do(t, http.MethodPost, "/v1/delegations/"+proposal.ID+"/decision", map[string]any{
		"decision": "approve", "idempotency_key": "delegation-approve-1", "lease_epoch": parentEpoch,
	}, pair.AccessToken)
	if again.Code != http.StatusOK {
		t.Fatalf("idempotent approve status=%d body=%s", again.Code, again.Body.String())
	}
	var replay delegationHTTPView
	_ = json.Unmarshal(again.Body.Bytes(), &replay)
	if replay.ChildSessionID != running.ChildSessionID || replay.ID != running.ID {
		t.Fatalf("decision retry created a new child: first=%+v replay=%+v", running, replay)
	}
}

// DELEG-04/05/06：只读端、未知 Provider、跨 Workspace、旧 epoch 和 reject 都不得产生未授权 child。
func TestDelegationRejectsUnsafeBoundariesAndReadOnlyWrites(t *testing.T) {
	env := newTestEnv(t)
	pair := env.registerAs(t, "delegation-boundary@fixture.test")
	parentID, workspaceID := env.createSession(t, pair.AccessToken, pair.AccountID)
	firstEpoch := sessionLeaseEpoch(t, env, pair.AccessToken, parentID)

	adminLogin := env.do(t, http.MethodPost, "/v1/auth/login", map[string]any{
		"email": "delegation-boundary@fixture.test", "password": "test-pass-123", "device_role": "admin",
	}, "")
	if adminLogin.Code != http.StatusOK {
		t.Fatalf("admin login status=%d", adminLogin.Code)
	}
	var admin struct {
		AccessToken string `json:"access_token"`
	}
	_ = json.Unmarshal(adminLogin.Body.Bytes(), &admin)
	readOnly := env.do(t, http.MethodPost, "/v1/sessions/"+parentID+"/delegations", delegationCreatePayload(
		workspaceID, "codex", "delegation-admin-write", firstEpoch,
	), admin.AccessToken)
	if readOnly.Code != http.StatusForbidden || relayErrorCode(t, readOnly.Body.Bytes()) != "READ_ONLY_DEVICE" {
		t.Fatalf("read-only delegation write status=%d body=%s", readOnly.Code, readOnly.Body.String())
	}

	unsupported := env.do(t, http.MethodPost, "/v1/sessions/"+parentID+"/delegations", delegationCreatePayload(
		workspaceID, "not-authorized", "delegation-unsupported", firstEpoch,
	), pair.AccessToken)
	if unsupported.Code != http.StatusConflict || relayErrorCode(t, unsupported.Body.Bytes()) != "CAPABILITY_UNSUPPORTED" {
		t.Fatalf("unsupported delegation status=%d body=%s", unsupported.Code, unsupported.Body.String())
	}

	_, otherWorkspaceID := env.createSessionForProject(t, pair.AccessToken, pair.AccountID, "delegation-other-project")
	crossWorkspace := env.do(t, http.MethodPost, "/v1/sessions/"+parentID+"/delegations", delegationCreatePayload(
		otherWorkspaceID, "codex", "delegation-cross-workspace", firstEpoch,
	), pair.AccessToken)
	if crossWorkspace.Code != http.StatusForbidden || relayErrorCode(t, crossWorkspace.Body.Bytes()) != "SCOPE_DENIED" {
		t.Fatalf("cross workspace status=%d body=%s", crossWorkspace.Code, crossWorkspace.Body.String())
	}

	secondEpoch := sessionLeaseEpoch(t, env, pair.AccessToken, parentID)
	stale := env.do(t, http.MethodPost, "/v1/sessions/"+parentID+"/delegations", delegationCreatePayload(
		workspaceID, "codex", "delegation-stale", firstEpoch,
	), pair.AccessToken)
	if stale.Code != http.StatusConflict || relayErrorCode(t, stale.Body.Bytes()) != "TARGET_INSTANCE_STALE" {
		t.Fatalf("stale epoch status=%d body=%s", stale.Code, stale.Body.String())
	}

	before, err := env.repo.ListSessions(t.Context(), pair.AccountID)
	if err != nil {
		t.Fatalf("list before reject: %v", err)
	}
	proposal := env.do(t, http.MethodPost, "/v1/sessions/"+parentID+"/delegations", delegationCreatePayload(
		workspaceID, "codex", "delegation-reject", secondEpoch,
	), pair.AccessToken)
	if proposal.Code != http.StatusAccepted {
		t.Fatalf("reject proposal status=%d body=%s", proposal.Code, proposal.Body.String())
	}
	var proposed delegationHTTPView
	_ = json.Unmarshal(proposal.Body.Bytes(), &proposed)
	rejected := env.do(t, http.MethodPost, "/v1/delegations/"+proposed.ID+"/decision", map[string]any{
		"decision": "reject", "idempotency_key": "delegation-reject-decision", "lease_epoch": secondEpoch,
	}, pair.AccessToken)
	if rejected.Code != http.StatusOK {
		t.Fatalf("reject status=%d body=%s", rejected.Code, rejected.Body.String())
	}
	var rejectedView delegationHTTPView
	_ = json.Unmarshal(rejected.Body.Bytes(), &rejectedView)
	if rejectedView.Status != "rejected" || rejectedView.ChildSessionID != "" {
		t.Fatalf("rejected view = %+v", rejectedView)
	}
	after, err := env.repo.ListSessions(t.Context(), pair.AccountID)
	if err != nil || len(after) != len(before) {
		t.Fatalf("reject must not create child; before=%d after=%d err=%v", len(before), len(after), err)
	}

	rows, err := env.repo.ListDelegationsByParent(t.Context(), parentID)
	if err != nil || len(rows) != 1 || rows[0].Status != "rejected" {
		t.Fatalf("only safe rejected node expected; rows=%+v err=%v", rows, err)
	}
	_ = store.DelegationRow{}
}
