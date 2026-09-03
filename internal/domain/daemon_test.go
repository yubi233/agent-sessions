package domain

import (
	"context"
	"testing"
	"time"

	"github.com/yubi233/agent-sessions/internal/id"
	"github.com/yubi233/agent-sessions/internal/store"
	"github.com/yubi233/agent-sessions/packages/protocol"
)

// P2-F：只读投影只能消费协议登记的错误码；Terminal 的自由文本不得离开受限执行边界。
func TestSafeErrorCodeAllowsOnlyPublicDaemonCodes(t *testing.T) {
	if got := safeErrorCode(protocol.ErrDaemonRestartRecovery); got != protocol.ErrDaemonRestartRecovery {
		t.Fatalf("restart recovery code=%q", got)
	}
	if got := safeErrorCode("adapter raw stderr: /private/workspace"); got != protocol.ErrDaemonExecutionFailed {
		t.Fatalf("unknown daemon code=%q want %q", got, protocol.ErrDaemonExecutionFailed)
	}
	if got := safeErrorCode("  "); got != "" {
		t.Fatalf("empty daemon code=%q", got)
	}
	for _, code := range []string{
		protocol.ErrInvalidRequest,
		protocol.ErrPayloadTooLarge,
		protocol.ErrScopeDenied,
	} {
		if got := safeErrorCode(code); got != code {
			t.Fatalf("safe P2 read error %q = %q", code, got)
		}
	}
}

// 契约：Relay 对已收敛（expired）命令的重复 result 提交必须回显权威终态 expired
// （HTTP 成功），而不是拒绝或回空状态——Daemon 重启恢复依赖回显状态落盘收敛。
// 这是 v0.8 同步卡死的 Relay 侧契约测试（对称于 daemon 的 validRelayResultStatus）。
func TestDaemonResolveEchoesAuthorityWhenCommandAlreadyExpired(t *testing.T) {
	ctx := context.Background()
	repo := newRepo(t)
	svc := NewDaemonService(repo)
	const accountID = "acct-daemon-resolve-expired"
	const deviceID = "dev-daemon-resolve-expired"
	const terminalID = "term-daemon-resolve-expired"
	const projectID = "proj-daemon-resolve-expired"
	const workspaceID = "ws-daemon-resolve-expired"
	if err := repo.CreateAccount(ctx, accountID, "daemon-resolve@example.test", []byte("hash"), time.Now()); err != nil {
		t.Fatalf("create account: %v", err)
	}
	if err := repo.CreateDevice(ctx, store.DeviceRow{
		ID: deviceID, AccountID: accountID, Role: RoleTerminal, Status: "active",
		DisplayName: "resolve terminal", Platform: "test",
		IdentityPublicKey: "identity", EncryptionPublicKey: "encryption",
	}); err != nil {
		t.Fatalf("create device: %v", err)
	}
	if err := repo.UpsertDaemonTerminal(ctx, store.TerminalRow{
		ID: terminalID, DeviceID: deviceID, AccountID: accountID, Status: "online",
		Hostname: "resolve-host", Platform: "test", ProtocolVersion: 1,
		DaemonVersion: "fixture", CapabilitiesJSON: "[]", LastHeartbeatUnixMS: time.Now().UnixMilli(),
	}); err != nil {
		t.Fatalf("create terminal: %v", err)
	}
	if err := repo.CreateProject(ctx, store.ProjectRow{ID: projectID, AccountID: accountID, Fingerprint: "resolve-fp"}); err != nil {
		t.Fatalf("create project: %v", err)
	}
	if err := repo.CreateWorkspace(ctx, store.WorkspaceRow{
		ID: workspaceID, ProjectID: projectID, TerminalID: terminalID,
		CanonicalRoot: "/fixture/resolve", Status: "active",
	}); err != nil {
		t.Fatalf("create workspace: %v", err)
	}
	sessions := NewSessionService(repo)
	session, err := sessions.CreateSession(ctx, accountID, workspaceID, "fixture")
	if err != nil {
		t.Fatalf("create session: %v", err)
	}
	if _, err := sessions.AcquireLease(ctx, session.ID, deviceID, "inst-resolve-expired"); err != nil {
		t.Fatalf("acquire lease: %v", err)
	}
	commandID := id.New("cmd-resolve-expired")
	if err := repo.CreateCommand(ctx, store.CommandRow{
		ID: commandID, AccountID: accountID, SessionID: session.ID, Kind: "session.send",
		Status: CommandExpired, ScopeHash: hashScope(accountID, session.ID),
		IdempotencyKey: "resolve-expired-command", LeaseEpoch: 1,
		TargetInstanceID: "inst-resolve-expired", TargetTerminalID: terminalID,
		CiphertextJSON: "{}",
	}); err != nil {
		t.Fatalf("create command: %v", err)
	}
	delivery, err := repo.CreateDaemonDelivery(ctx, store.DaemonDeliveryRow{TerminalID: terminalID, CommandID: commandID})
	if err != nil {
		t.Fatalf("create delivery: %v", err)
	}
	// Daemon 重启恢复提交 failed；Relay 看到命令已 expired，必须回显 expired 终态。
	receipt, err := svc.Resolve(ctx, accountID, deviceID, RoleTerminal, commandID,
		delivery.DeliverySeq, 1, CommandFailed, protocol.ErrDaemonRestartRecovery)
	if err != nil {
		t.Fatalf("Resolve 必须成功回显权威终态而非报错: %v", err)
	}
	if receipt.Status != CommandExpired {
		t.Fatalf("回显 status=%q，want %q（Relay 权威终态）", receipt.Status, CommandExpired)
	}
	if receipt.CommandID != commandID || receipt.DeliverySeq != delivery.DeliverySeq {
		t.Fatalf("回显收据不完整: %+v", receipt)
	}
	// 再次提交仍回显同一终态（幂等，供重试收敛）。
	again, err := svc.Resolve(ctx, accountID, deviceID, RoleTerminal, commandID,
		delivery.DeliverySeq, 1, CommandFailed, protocol.ErrDaemonRestartRecovery)
	if err != nil || again.Status != CommandExpired {
		t.Fatalf("重复提交未收敛: err=%v receipt=%+v", err, again)
	}
}
