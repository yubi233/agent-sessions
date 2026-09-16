package domain

import (
	"context"
	"testing"
	"time"

	"github.com/yubi233/agent-sessions/internal/store"
)

// v0.9.1 P0（迭代计划 §4 P0）：Presence 事实源、契约和命令安全门的根因层回归。
// 覆盖 V091-01/02/05；HTTP 集成口径（V091-03/04）见 internal/relay/v091_presence_gate_contract_test.go。

// v091Terminal 构造一个协议窗口内的在线 Terminal 行模板。
func v091Terminal(accountID, deviceID string, lastHeartbeatMS int64) store.TerminalRow {
	return store.TerminalRow{
		ID: "term-v091", DeviceID: deviceID, AccountID: accountID,
		Hostname: "v091-host", Platform: "test", Status: "online",
		ProtocolVersion: 1, DaemonVersion: "fixture", CapabilitiesJSON: `["dsh_workspace_sync","workspace_create","start"]`,
		LastHeartbeatUnixMS: lastHeartbeatMS,
	}
}

// V091-01：availability 契约由服务端时间与 15/40/60 秒集中阈值唯一决定。
// 边界（39/40/59/60/60+1ms）语义稳定：<=40s online，(40,60] unknown 观察窗，
// >60s offline；协议越界为 unsupported；无心跳事实为 unknown；
// next_check 给出下一个投影边界。测试只显式传入服务端时钟——投影函数不读进程时间，
// 因此客户端墙钟（无论偏差多少）不可能改变授权结果（裁决 T2）。
func TestV091PresenceAvailabilityContractBoundaries(t *testing.T) {
	policy := DefaultPresencePolicy()
	if policy.HeartbeatInterval != 15*time.Second || policy.SuspectWindow != 40*time.Second ||
		policy.OfflineDeadline != 60*time.Second {
		t.Fatalf("default policy drifted: %+v", policy)
	}
	const t0MS = int64(1_700_000_000_000)
	base := v091Terminal("acct-v091", "dev-v091", t0MS)

	cases := []struct {
		name            string
		deltaMS         int64
		want            PresenceAvailability
		wantNextDeltaMS int64 // next_check - t0；-1 表示无边界
	}{
		{name: "39s 仍在线", deltaMS: 39_000, want: PresenceOnline, wantNextDeltaMS: 40_000},
		{name: "40s 恰好进入观察窗边界仍在线", deltaMS: 40_000, want: PresenceOnline, wantNextDeltaMS: 40_000},
		{name: "59s unknown 观察窗", deltaMS: 59_000, want: PresenceUnknown, wantNextDeltaMS: 60_000},
		{name: "60s 观察窗边界仍 unknown", deltaMS: 60_000, want: PresenceUnknown, wantNextDeltaMS: 60_000},
		{name: "60s+1ms 权威 offline", deltaMS: 60_001, want: PresenceOffline, wantNextDeltaMS: -1},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			now := t0MS + tc.deltaMS
			if got := policy.Project(base, now); got != tc.want {
				t.Fatalf("Project(delta=%dms)=%q, want %q", tc.deltaMS, got, tc.want)
			}
			next := policy.NextCheckUnixMS(base, now)
			if tc.wantNextDeltaMS < 0 {
				if next != 0 {
					t.Fatalf("offline/unsupported 不应有 next_check，得到 %d", next)
				}
			} else if want := t0MS + tc.wantNextDeltaMS; next != want {
				t.Fatalf("next_check=%d, want %d", next, want)
			}
		})
	}

	t.Run("协议越窗口 unsupported 优先于活性", func(t *testing.T) {
		staleProtocol := base
		staleProtocol.ProtocolVersion = 0
		if got := policy.Project(staleProtocol, t0MS); got != PresenceUnsupported {
			t.Fatalf("protocol_version=0 投影=%q, want unsupported", got)
		}
		future := base
		future.ProtocolVersion = currentDaemonProtocolVersion + 1
		if got := policy.Project(future, t0MS); got != PresenceUnsupported {
			t.Fatalf("protocol_version 越上界投影=%q, want unsupported", got)
		}
	})

	t.Run("无心跳事实 unknown 且显式 offline 优先", func(t *testing.T) {
		noFact := base
		noFact.LastHeartbeatUnixMS = 0
		if got := policy.Project(noFact, t0MS); got != PresenceUnknown {
			t.Fatalf("无心跳投影=%q, want unknown", got)
		}
		offline := base
		offline.Status = "offline"
		if got := policy.Project(offline, t0MS); got != PresenceOffline {
			t.Fatalf("显式 offline 投影=%q, want offline", got)
		}
	})

	t.Run("写门控三分类稳定且不依赖客户端墙钟", func(t *testing.T) {
		if err := policy.TerminalWriteGate(base, t0MS+40_000, "dsh_workspace_sync"); err != nil {
			t.Fatalf("online 目标不应被门控拦截: %v", err)
		}
		if err := policy.TerminalWriteGate(base, t0MS+59_000, "dsh_workspace_sync"); err == nil {
			t.Fatal("unknown 目标必须被拒绝")
		} else if err.Error() != ErrTerminalUnreachable.Error() {
			t.Fatalf("unknown 目标错误=%v, want %v", err, ErrTerminalUnreachable)
		}
		if err := policy.TerminalWriteGate(base, t0MS+60_001, "dsh_workspace_sync"); err == nil {
			t.Fatal("offline 目标必须被拒绝")
		} else if err.Error() != ErrTerminalOffline.Error() {
			t.Fatalf("offline 目标错误=%v, want %v", err, ErrTerminalOffline)
		}
		noCap := base
		noCap.CapabilitiesJSON = `[]`
		if err := policy.TerminalWriteGate(noCap, t0MS, "dsh_workspace_sync"); err == nil {
			t.Fatal("能力不满足必须被拒绝")
		}
	})
}

// V091-02：hello/heartbeat 幂等推进活性；重复/乱序旧心跳不能把 last_heartbeat
// 拉回过去；无真实状态变化不重复制造 presence_revision；/v1/terminals 投影
// （此处以 repo 行 + 同一 Project 函数验证）与存储事实一致。
func TestV091HeartbeatIdempotentMonotonicRevision(t *testing.T) {
	repo := newRepo(t)
	ctx := context.Background()
	const accountID = "acct-v091-hb"
	const deviceID = "dev-v091-hb"
	if err := repo.CreateAccount(ctx, accountID, "v091-hb@example.test", []byte("hash"), time.Now()); err != nil {
		t.Fatalf("create account: %v", err)
	}
	if err := repo.CreateDevice(ctx, store.DeviceRow{
		ID: deviceID, AccountID: accountID, Role: RoleTerminal, Status: "active",
		DisplayName: "v091 hb", Platform: "test", IdentityPublicKey: "identity", EncryptionPublicKey: "encryption",
	}); err != nil {
		t.Fatalf("create device: %v", err)
	}

	// 可注入服务端时钟：从 t0 起步，按步推进/回拨。
	now := time.UnixMilli(1_700_000_000_000)
	svc := NewDaemonService(repo)
	svc.now = func() time.Time { return now }

	if _, err := svc.Hello(ctx, DaemonHelloInput{
		AccountID: accountID, DeviceID: deviceID, Role: RoleTerminal,
		ProtocolVersion: 1, DaemonVersion: "v091", Hostname: "hb-host", Platform: "test",
		Capabilities: []string{"dsh_workspace_sync"},
	}); err != nil {
		t.Fatalf("hello: %v", err)
	}
	assertTerminal := func(wantLastHBMS, wantRevision int64, wantAvailability PresenceAvailability) store.TerminalRow {
		t.Helper()
		row, err := repo.TerminalByDeviceID(ctx, deviceID)
		if err != nil {
			t.Fatalf("read terminal: %v", err)
		}
		if row.LastHeartbeatUnixMS != wantLastHBMS {
			t.Fatalf("last_heartbeat=%d, want %d", row.LastHeartbeatUnixMS, wantLastHBMS)
		}
		if row.PresenceRevision != wantRevision {
			t.Fatalf("presence_revision=%d, want %d", row.PresenceRevision, wantRevision)
		}
		if got := svc.Presence.Project(row, now.UnixMilli()); got != wantAvailability {
			t.Fatalf("availability=%q, want %q", got, wantAvailability)
		}
		if row.PresenceProjectedState != string(wantAvailability) {
			t.Fatalf("持久投影=%q 与当前投影 %q 不一致", row.PresenceProjectedState, wantAvailability)
		}
		return row
	}

	t0 := now.UnixMilli()
	row := assertTerminal(t0, 0, PresenceOnline)

	// 连续推进的心跳：活性前进、无状态变化、revision 不增长。
	now = now.Add(1 * time.Second)
	if _, err := svc.Heartbeat(ctx, accountID, deviceID, RoleTerminal, 1, nil, false); err != nil {
		t.Fatalf("heartbeat t+1s: %v", err)
	}
	now = now.Add(1 * time.Second)
	if _, err := svc.Heartbeat(ctx, accountID, deviceID, RoleTerminal, 1, nil, false); err != nil {
		t.Fatalf("heartbeat t+2s: %v", err)
	}
	row = assertTerminal(t0+2_000, 0, PresenceOnline)

	// 乱序/更旧的 heartbeat（时钟回拨视角）：last_heartbeat 不能倒退。
	backdated := time.UnixMilli(t0 - 5_000)
	now = backdated
	if _, err := svc.Heartbeat(ctx, accountID, deviceID, RoleTerminal, 1, nil, false); err != nil {
		t.Fatalf("stale heartbeat: %v", err)
	}
	row = assertTerminal(t0+2_000, 0, PresenceOnline)

	// 回到最新时间继续在线心跳，revision 仍不无界增长。
	now = time.UnixMilli(t0 + 15_000)
	if _, err := svc.Heartbeat(ctx, accountID, deviceID, RoleTerminal, 1, nil, false); err != nil {
		t.Fatalf("heartbeat t+15s: %v", err)
	}
	row = assertTerminal(t0+15_000, 0, PresenceOnline)

	// 重复 hello（同一事实）同样不制造 revision。
	if _, err := svc.Hello(ctx, DaemonHelloInput{
		AccountID: accountID, DeviceID: deviceID, Role: RoleTerminal,
		ProtocolVersion: 1, DaemonVersion: "v091", Hostname: "hb-host", Platform: "test",
		Capabilities: []string{"dsh_workspace_sync"},
	}); err != nil {
		t.Fatalf("repeated hello: %v", err)
	}
	assertTerminal(t0+15_000, 0, PresenceOnline)
	_ = row
}

// V091-05：漏 heartbeat 进入 offline 后，恢复的有效 hello/heartbeat 使列表投影
// 与命令门控一致回到 online；presence_revision 单调且重复心跳不重复 +1。
func TestV091HeartbeatRecoveryRestoresOnlineConsistently(t *testing.T) {
	repo := newRepo(t)
	ctx := context.Background()
	const accountID = "acct-v091-rec"
	const deviceID = "dev-v091-rec"
	if err := repo.CreateAccount(ctx, accountID, "v091-rec@example.test", []byte("hash"), time.Now()); err != nil {
		t.Fatalf("create account: %v", err)
	}
	if err := repo.CreateDevice(ctx, store.DeviceRow{
		ID: deviceID, AccountID: accountID, Role: RoleTerminal, Status: "active",
		DisplayName: "v091 rec", Platform: "test", IdentityPublicKey: "identity", EncryptionPublicKey: "encryption",
	}); err != nil {
		t.Fatalf("create device: %v", err)
	}
	now := time.UnixMilli(1_700_000_000_000)
	daemons := NewDaemonService(repo)
	daemons.now = func() time.Time { return now }
	sessions := NewSessionService(repo)
	sessions.now = func() time.Time { return now }

	if _, err := daemons.Hello(ctx, DaemonHelloInput{
		AccountID: accountID, DeviceID: deviceID, Role: RoleTerminal,
		ProtocolVersion: 1, DaemonVersion: "v091", Hostname: "rec-host", Platform: "test",
		Capabilities: []string{"dsh_workspace_sync", "workspace_create", "start"},
	}); err != nil {
		t.Fatalf("hello: %v", err)
	}
	t0 := now.UnixMilli()
	const staleThresholdMS = int64(61_000)

	offlineGate := func() error {
		row, err := repo.TerminalByDeviceID(ctx, deviceID)
		if err != nil {
			t.Fatalf("read terminal: %v", err)
		}
		return sessions.Presence.TerminalWriteGate(row, now.UnixMilli(), "start")
	}

	// 阶段一：漏 heartbeat 跨过 60s deadline，列表与命令门控一致判定不可投递。
	now = time.UnixMilli(t0 + staleThresholdMS)
	row, err := repo.TerminalByDeviceID(ctx, deviceID)
	if err != nil {
		t.Fatalf("read terminal: %v", err)
	}
	if got := sessions.Presence.Project(row, now.UnixMilli()); got != PresenceOffline {
		t.Fatalf("deadline 后列表投影=%q, want offline", got)
	}
	if err := offlineGate(); err == nil {
		t.Fatal("offline 目标的命令门控必须拒绝")
	}

	// 阶段二：恢复 hello/heartbeat —— 列表与门控一致回到 online，revision 恰好 +1。
	if _, err := daemons.Hello(ctx, DaemonHelloInput{
		AccountID: accountID, DeviceID: deviceID, Role: RoleTerminal,
		ProtocolVersion: 1, DaemonVersion: "v091", Hostname: "rec-host", Platform: "test",
		Capabilities: []string{"dsh_workspace_sync", "workspace_create", "start"},
	}); err != nil {
		t.Fatalf("recovery hello: %v", err)
	}
	row, err = repo.TerminalByDeviceID(ctx, deviceID)
	if err != nil {
		t.Fatalf("read terminal after recovery: %v", err)
	}
	if got := sessions.Presence.Project(row, now.UnixMilli()); got != PresenceOnline {
		t.Fatalf("恢复后列表投影=%q, want online", got)
	}
	if row.PresenceRevision != 1 {
		t.Fatalf("恢复转换 revision=%d, want 1（offline->online 恰好一次）", row.PresenceRevision)
	}
	if err := offlineGate(); err != nil {
		t.Fatalf("恢复后命令门控必须放行: %v", err)
	}

	// 阶段三：恢复后的重复心跳不产生重复状态变化。
	now = now.Add(15 * time.Second)
	if _, err := daemons.Heartbeat(ctx, accountID, deviceID, RoleTerminal, 1, nil, false); err != nil {
		t.Fatalf("post-recovery heartbeat: %v", err)
	}
	row, err = repo.TerminalByDeviceID(ctx, deviceID)
	if err != nil {
		t.Fatalf("read terminal: %v", err)
	}
	if row.PresenceRevision != 1 {
		t.Fatalf("重复心跳 revision=%d, want 仍为 1（不重复 +1）", row.PresenceRevision)
	}
}
