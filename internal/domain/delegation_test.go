package domain

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/yubi233/agent-sessions/internal/store"
)

type delegationTestDispatcher struct {
	started []DelegationDispatchRequest
	stopped []string
}

func (d *delegationTestDispatcher) ValidateTarget(_ context.Context, _, targetProvider string) error {
	if targetProvider == "unsupported" {
		return ErrDelegationUnsupported
	}
	return nil
}

func (d *delegationTestDispatcher) Start(_ context.Context, request DelegationDispatchRequest) (DelegationDispatchResult, error) {
	d.started = append(d.started, request)
	return DelegationDispatchResult{InstanceID: "child-instance-fixture"}, nil
}

func (d *delegationTestDispatcher) Stop(_ context.Context, delegationID string) error {
	d.stopped = append(d.stopped, delegationID)
	return nil
}

func delegationEnvelope(ciphertext string) []byte {
	return []byte(`{"alg":"v1-aes256gcm-hkdfsha256","key_id":"fixture-dek","nonce":"fixture-nonce","ciphertext":"` + ciphertext + `","aad_hash":"fixture-aad","payload_version":1}`)
}

// DELEG-01/03：父确认后才创建 child；child 取得独立 lease，parent 事件只包含状态和密文摘要。
func TestDelegationCreatesIndependentChildAndKeepsParentOpaque(t *testing.T) {
	ctx := context.Background()
	repo := newRepo(t)
	sessions := NewSessionService(repo)
	parentID := newSession(t, repo)
	if _, err := sessions.AcquireLease(ctx, parentID, "android-owner", ""); err != nil {
		t.Fatalf("acquire parent lease: %v", err)
	}
	dispatcher := &delegationTestDispatcher{}
	delegations := NewDelegationService(repo, dispatcher)

	proposal, err := delegations.CreateProposal(ctx, DelegationCreateInput{
		AccountID: "acct", DeviceID: "android-owner", Role: RoleAndroidOwner,
		ParentSessionID: parentID, TargetWorkspaceID: "ws", TargetProvider: "codex",
		TaskEnvelope:    delegationEnvelope("opaque-task-ciphertext"),
		SummaryEnvelope: delegationEnvelope("opaque-summary-ciphertext"),
		IdempotencyKey:  "deleg-create-1", LeaseEpoch: 1,
	})
	if err != nil {
		t.Fatalf("create proposal: %v", err)
	}
	if proposal.Status != DelegationProposed || proposal.ChildSessionID != "" {
		t.Fatalf("proposal = %+v", proposal)
	}
	if sessionsAfterProposal, err := repo.ListSessions(ctx, "acct"); err != nil || len(sessionsAfterProposal) != 1 {
		t.Fatalf("proposal must not create child; sessions=%d err=%v", len(sessionsAfterProposal), err)
	}

	running, err := delegations.Decide(ctx, DelegationDecisionInput{
		AccountID: "acct", DeviceID: "android-owner", Role: RoleAndroidOwner,
		DelegationID: proposal.ID, Decision: "approve", IdempotencyKey: "deleg-approve-1", ParentLeaseEpoch: 1,
	})
	if err != nil {
		t.Fatalf("approve proposal: %v", err)
	}
	if running.Status != DelegationRunning || running.ChildSessionID == "" {
		t.Fatalf("approved delegation = %+v", running)
	}
	if len(dispatcher.started) != 1 || dispatcher.started[0].ChildSessionID != running.ChildSessionID {
		t.Fatalf("dispatcher did not receive independent child: %+v", dispatcher.started)
	}
	childLease, err := repo.LeaseBySession(ctx, running.ChildSessionID)
	if err != nil || childLease.Epoch != 1 || childLease.DeviceID != "android-owner" {
		t.Fatalf("child lease = %+v err=%v", childLease, err)
	}
	child, err := repo.SessionByID(ctx, running.ChildSessionID)
	if err != nil || child.WorkspaceID != "ws" || child.Provider != "codex" || child.CurrentInstanceID != "child-instance-fixture" {
		t.Fatalf("child session = %+v err=%v", child, err)
	}

	// 另一设备接管 parent 使 epoch=2；将它带到 child 必须被 fencing，证明 child 写操作不复用 parent lease。
	if parentEpoch, err := sessions.AcquireLease(ctx, parentID, "android-owner-2", ""); err != nil || parentEpoch != 2 {
		t.Fatalf("takeover parent lease = %d err=%v", parentEpoch, err)
	}
	if _, err := sessions.SubmitCommand(ctx, CommandInput{
		AccountID: "acct", DeviceID: "android-owner", Role: RoleAndroidOwner,
		SessionID: running.ChildSessionID, Kind: "session.send", IdempotencyKey: "child-wrong-parent-epoch",
		LeaseEpoch: 2, TargetInstanceID: "child-instance-fixture",
	}); !errors.Is(err, ErrTargetStale) {
		t.Fatalf("child must reject parent epoch, got %v", err)
	}
	if _, err := sessions.SubmitCommand(ctx, CommandInput{
		AccountID: "acct", DeviceID: "android-owner", Role: RoleAndroidOwner,
		SessionID: running.ChildSessionID, Kind: "session.send", IdempotencyKey: "child-own-epoch",
		LeaseEpoch: 1, TargetInstanceID: "child-instance-fixture",
	}); err != nil {
		t.Fatalf("child own lease command: %v", err)
	}

	completed, err := delegations.MarkCompleted(ctx, proposal.ID)
	if err != nil || completed.Status != DelegationCompleted {
		t.Fatalf("mark completed = %+v err=%v", completed, err)
	}
	if len(dispatcher.stopped) != 1 || dispatcher.stopped[0] != proposal.ID {
		t.Fatalf("dispatcher stop = %+v", dispatcher.stopped)
	}
	parentEvents, err := repo.ListEventsAfter(ctx, parentID, 0)
	if err != nil {
		t.Fatalf("parent events: %v", err)
	}
	delegationEvents := 0
	for _, event := range parentEvents {
		if event.EventType != "delegation.changed" {
			continue
		}
		delegationEvents++
		if strings.Contains(event.EnvelopeJSON, "task_envelope") || strings.Contains(event.EnvelopeJSON, "opaque-task-ciphertext") {
			t.Fatalf("parent event leaked task envelope: %s", event.EnvelopeJSON)
		}
		if !strings.Contains(event.EnvelopeJSON, "summary_envelope") {
			t.Fatalf("parent event missing encrypted summary: %s", event.EnvelopeJSON)
		}
	}
	if delegationEvents < 3 {
		t.Fatalf("expected proposed/running/completed parent events, got %d", delegationEvents)
	}
}

// DELEG-01/04：没有完整密文 envelope 或目标 capability 不支持时，不能留下 proposal、command 或 child。
func TestDelegationRejectsPlaintextAndUnsupportedTarget(t *testing.T) {
	ctx := context.Background()
	repo := newRepo(t)
	sessions := NewSessionService(repo)
	parentID := newSession(t, repo)
	if _, err := sessions.AcquireLease(ctx, parentID, "android-owner", ""); err != nil {
		t.Fatalf("acquire parent lease: %v", err)
	}
	delegations := NewDelegationService(repo, &delegationTestDispatcher{})

	_, err := delegations.CreateProposal(ctx, DelegationCreateInput{
		AccountID: "acct", DeviceID: "android-owner", Role: RoleAndroidOwner,
		ParentSessionID: parentID, TargetWorkspaceID: "ws", TargetProvider: "codex",
		TaskEnvelope: []byte(`{"plaintext":"must-not-reach-relay"}`), SummaryEnvelope: delegationEnvelope("summary"),
		IdempotencyKey: "deleg-plaintext", LeaseEpoch: 1,
	})
	if err == nil {
		t.Fatal("plaintext task envelope must be rejected")
	}
	_, err = delegations.CreateProposal(ctx, DelegationCreateInput{
		AccountID: "acct", DeviceID: "android-owner", Role: RoleAndroidOwner,
		ParentSessionID: parentID, TargetWorkspaceID: "ws", TargetProvider: "unsupported",
		TaskEnvelope: delegationEnvelope("task"), SummaryEnvelope: delegationEnvelope("summary"),
		IdempotencyKey: "deleg-unsupported", LeaseEpoch: 1,
	})
	if !errors.Is(err, ErrDelegationUnsupported) {
		t.Fatalf("unsupported provider err=%v", err)
	}
	rows, err := repo.ListDelegationsByParent(ctx, parentID)
	if err != nil || len(rows) != 0 {
		t.Fatalf("rejected proposals must not persist; rows=%d err=%v", len(rows), err)
	}
}

var _ store.DelegationRow
