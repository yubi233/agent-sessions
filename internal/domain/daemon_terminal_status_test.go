package domain

import (
	"context"
	"testing"
	"time"

	"github.com/yubi233/agent-sessions/internal/id"
	"github.com/yubi233/agent-sessions/internal/store"
)

// newDaemonEventStatusFixture builds the smallest command/lease/terminal graph
// accepted by UploadEvent. Keeping this setup local makes the status assertions
// exercise the real transaction and fencing path instead of only a helper.
func newDaemonEventStatusFixture(t *testing.T) (*DaemonService, store.Repository, string, string) {
	t.Helper()
	repo := newRepo(t)
	ctx := context.Background()
	const accountID = "acct-daemon-status"
	const deviceID = "dev-daemon-status"
	const terminalID = "term-daemon-status"
	const projectID = "proj-daemon-status"
	const workspaceID = "ws-daemon-status"
	if err := repo.CreateAccount(ctx, accountID, "daemon-status@example.test", []byte("hash"), time.Now()); err != nil {
		t.Fatalf("create account: %v", err)
	}
	if err := repo.CreateDevice(ctx, store.DeviceRow{
		ID: deviceID, AccountID: accountID, Role: RoleTerminal, Status: "active",
		DisplayName: "status terminal", Platform: "test",
		IdentityPublicKey: "identity", EncryptionPublicKey: "encryption",
	}); err != nil {
		t.Fatalf("create device: %v", err)
	}
	if err := repo.UpsertDaemonTerminal(ctx, store.TerminalRow{
		ID: terminalID, DeviceID: deviceID, AccountID: accountID, Status: "online",
		Hostname: "status-host", Platform: "test", ProtocolVersion: 1,
		DaemonVersion: "fixture", CapabilitiesJSON: "[]", LastHeartbeatUnixMS: time.Now().UnixMilli(),
	}); err != nil {
		t.Fatalf("create terminal: %v", err)
	}
	if err := repo.CreateProject(ctx, store.ProjectRow{ID: projectID, AccountID: accountID, Fingerprint: "status-fp"}); err != nil {
		t.Fatalf("create project: %v", err)
	}
	if err := repo.CreateWorkspace(ctx, store.WorkspaceRow{
		ID: workspaceID, ProjectID: projectID, TerminalID: terminalID,
		CanonicalRoot: "/fixture/status", Status: "active",
	}); err != nil {
		t.Fatalf("create workspace: %v", err)
	}
	sessions := NewSessionService(repo)
	session, err := sessions.CreateSession(ctx, accountID, workspaceID, "fixture")
	if err != nil {
		t.Fatalf("create session: %v", err)
	}
	if _, err := sessions.AcquireLease(ctx, session.ID, deviceID, "inst-daemon-status"); err != nil {
		t.Fatalf("acquire lease: %v", err)
	}
	commandID := id.New("cmd-status")
	if err := repo.CreateCommand(ctx, store.CommandRow{
		ID: commandID, AccountID: accountID, SessionID: session.ID, Kind: "session.start",
		Status: CommandRunning, ScopeHash: hashScope(accountID, session.ID),
		IdempotencyKey: "status-command", LeaseEpoch: 1,
		TargetInstanceID: "inst-daemon-status", TargetTerminalID: terminalID,
		CiphertextJSON: "{}",
	}); err != nil {
		t.Fatalf("create command: %v", err)
	}
	if _, err := repo.CreateDaemonDelivery(ctx, store.DaemonDeliveryRow{TerminalID: terminalID, CommandID: commandID}); err != nil {
		t.Fatalf("create delivery: %v", err)
	}
	return NewDaemonService(repo), repo, session.ID, commandID
}

func daemonStatusEventInputForEvent(sessionID, commandID, eventType, terminalStatus, eventID string) DaemonEventInput {
	return DaemonEventInput{
		AccountID: "acct-daemon-status", DeviceID: "dev-daemon-status", Role: RoleTerminal,
		ProtocolVersion: 1, EventID: eventID, CommandID: commandID, SessionID: sessionID,
		EventType: eventType, TerminalStatus: terminalStatus,
		EnvelopeJSON: `{"alg":"fixture-aead","key_id":"fixture-key","nonce":"fixture-nonce","ciphertext":"opaque","aad_hash":"fixture-aad","payload_version":1}`,
	}
}

func daemonStatusEventInput(sessionID, commandID, terminalStatus, eventID string) DaemonEventInput {
	return daemonStatusEventInputForEvent(sessionID, commandID, "turn.completed", terminalStatus, eventID)
}

func TestDaemonUploadEventMapsIdleAndStoppedTerminalStatus(t *testing.T) {
	ctx := context.Background()
	for _, tc := range []struct {
		name           string
		terminalStatus string
		wantSession    string
	}{
		{name: "explicit idle", terminalStatus: SessionIdle, wantSession: SessionIdle},
		{name: "explicit stopped", terminalStatus: SessionStopped, wantSession: SessionStopped},
		{name: "legacy omitted defaults idle", terminalStatus: "", wantSession: SessionIdle},
	} {
		t.Run(tc.name, func(t *testing.T) {
			svc, repo, sessionID, commandID := newDaemonEventStatusFixture(t)
			if _, err := svc.UploadEvent(ctx, daemonStatusEventInput(sessionID, commandID, tc.terminalStatus, "evt-"+tc.name)); err != nil {
				t.Fatalf("upload terminal event: %v", err)
			}
			session, err := repo.SessionByID(ctx, sessionID)
			if err != nil {
				t.Fatalf("read session: %v", err)
			}
			if session.Status != tc.wantSession {
				t.Fatalf("session status=%q, want %q", session.Status, tc.wantSession)
			}
		})
	}
}

func TestDaemonUploadEventRejectsInvalidTerminalStatusProjection(t *testing.T) {
	for _, tc := range []struct {
		name      string
		eventType string
		status    string
	}{
		{name: "unknown status", eventType: "turn.completed", status: "running"},
		{name: "status on nonterminal event", eventType: "message.completed", status: SessionStopped},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if err := validateDaemonTerminalStatus(tc.eventType, tc.status); err == nil {
				t.Fatalf("validateDaemonTerminalStatus(%q, %q) unexpectedly succeeded", tc.eventType, tc.status)
			}
		})
	}
}

// V085-18/24：session.aborted 是 Abort 成功的非敏感停止事实。validateDaemonTerminalStatus
// 必须放行 session.aborted+stopped（Relay 不解密 payload 即可投影 stopped），但拒绝
// session.aborted+idle 与在非终态事件上携带任意 status（保持 fail-closed 白名单）。
func TestDaemonUploadEventSessionAbortedStatusProjection(t *testing.T) {
	for _, tc := range []struct {
		name        string
		eventType   string
		status      string
		wantAllowed bool
	}{
		{name: "aborted stopped allowed", eventType: "session.aborted", status: SessionStopped, wantAllowed: true},
		{name: "aborted idle rejected", eventType: "session.aborted", status: SessionIdle, wantAllowed: false},
		{name: "aborted running rejected", eventType: "session.aborted", status: "running", wantAllowed: false},
		{name: "nonterminal stopped still rejected", eventType: "message.completed", status: SessionStopped, wantAllowed: false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			err := validateDaemonTerminalStatus(tc.eventType, tc.status)
			if tc.wantAllowed && err != nil {
				t.Fatalf("validate(%q, %q) unexpectedly rejected: %v", tc.eventType, tc.status, err)
			}
			if !tc.wantAllowed && err == nil {
				t.Fatalf("validate(%q, %q) unexpectedly succeeded", tc.eventType, tc.status)
			}
		})
	}

	// 端到端：真实 UploadEvent 上传 session.aborted(stopped) 后，会话状态收敛为 stopped。
	ctx := context.Background()
	svc, repo, sessionID, commandID := newDaemonEventStatusFixture(t)
	if _, err := svc.UploadEvent(ctx, daemonStatusEventInputForEvent(sessionID, commandID, "session.aborted", SessionStopped, "evt-aborted")); err != nil {
		t.Fatalf("upload session.aborted: %v", err)
	}
	session, err := repo.SessionByID(ctx, sessionID)
	if err != nil {
		t.Fatalf("read session: %v", err)
	}
	if session.Status != SessionStopped {
		t.Fatalf("session status=%q, want %q", session.Status, SessionStopped)
	}
}

func TestDaemonUploadEventDoesNotReopenTerminalTurnForCommandUpdate(t *testing.T) {
	ctx := context.Background()
	svc, repo, sessionID, commandID := newDaemonEventStatusFixture(t)
	for _, event := range []DaemonEventInput{
		daemonStatusEventInputForEvent(sessionID, commandID, "user.message", "", "evt-user"),
		daemonStatusEventInput(sessionID, commandID, SessionStopped, "evt-stopped"),
		daemonStatusEventInputForEvent(sessionID, commandID, "command.updated", "", "evt-command-update"),
	} {
		if _, err := svc.UploadEvent(ctx, event); err != nil {
			t.Fatalf("upload %s: %v", event.EventType, err)
		}
	}
	session, err := repo.SessionByID(ctx, sessionID)
	if err != nil {
		t.Fatalf("read session: %v", err)
	}
	if session.Status != SessionStopped {
		t.Fatalf("session status=%q, want %q after command.updated", session.Status, SessionStopped)
	}
}
