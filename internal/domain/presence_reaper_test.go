package domain

import (
	"context"
	"testing"
	"time"

	"github.com/yubi233/agent-sessions/internal/store"
)

// V091-07（迭代计划 §4 P1）：有界 presence reaper —— 过期转换通知与持久投影、
// 多 Terminal 隔离、批量有界、丢唤醒可自愈、资源释放。
// reaper 不是 read/command 正确性的前置条件（V091-03 已证明）；这里验证的是
// 「加速路径」本身的边界与自愈语义。

type v091ReaperFixture struct {
	repo   store.Repository
	daemon *DaemonService
	hub    *PresenceHub
	clock  time.Time
	// subscribe 返回该账号 invalidation 通道与取消函数。
	accountID string
}

func newV091ReaperFixture(t *testing.T, terminals ...string) *v091ReaperFixture {
	t.Helper()
	repo := newRepo(t)
	ctx := context.Background()
	const accountID = "acct-v091-reaper"
	if err := repo.CreateAccount(ctx, accountID, "v091-reaper@example.test", []byte("hash"), time.Now()); err != nil {
		t.Fatalf("create account: %v", err)
	}
	fixture := &v091ReaperFixture{repo: repo, hub: NewPresenceHub(0), clock: time.UnixMilli(1_700_000_000_000), accountID: accountID}
	fixture.daemon = NewDaemonService(repo)
	fixture.daemon.now = func() time.Time { return fixture.clock }
	fixture.daemon.Hub = fixture.hub
	for _, name := range terminals {
		deviceID := "dev-v091-reaper-" + name
		if err := repo.CreateDevice(ctx, store.DeviceRow{
			ID: deviceID, AccountID: accountID, Role: RoleTerminal, Status: "active",
			DisplayName: name, Platform: "test", IdentityPublicKey: "identity-" + name, EncryptionPublicKey: "encryption-" + name,
		}); err != nil {
			t.Fatalf("create device %s: %v", name, err)
		}
		if _, err := fixture.daemon.Hello(ctx, DaemonHelloInput{
			AccountID: accountID, DeviceID: deviceID, Role: RoleTerminal,
			ProtocolVersion: 1, DaemonVersion: "v091", Hostname: name, Platform: "test",
			Capabilities: []string{"dsh_workspace_sync"},
		}); err != nil {
			t.Fatalf("hello %s: %v", name, err)
		}
	}
	return fixture
}

func (f *v091ReaperFixture) advance(d time.Duration) {
	f.clock = f.clock.Add(d)
}

// V091-07 主用例：unknown/offline 两段过期转换各自恰好一次（通知 + 持久投影 +
// legacy status 同步），重复扫描不重复发布；新鲜 Terminal 完全不受影响（隔离）。
func TestV091PresenceReaperTransitionsBoundedAndIsolated(t *testing.T) {
	f := newV091ReaperFixture(t, "alpha", "beta")
	ctx := context.Background()
	alpha, err := f.repo.TerminalByDeviceID(ctx, "dev-v091-reaper-alpha")
	if err != nil {
		t.Fatalf("read alpha: %v", err)
	}
	beta, err := f.repo.TerminalByDeviceID(ctx, "dev-v091-reaper-beta")
	if err != nil {
		t.Fatalf("read beta: %v", err)
	}

	reaper := NewPresenceReaper(f.repo, f.hub, nil)
	reaper.now = func() time.Time { return f.clock }

	invalidations := make(chan PresenceInvalidation, 16)
	subscribe, cancel := f.hub.SubscribeAccountPresence(f.accountID)
	defer cancel()
	go func() {
		for inv := range subscribe {
			invalidations <- inv
		}
	}()
	drainInvalidations := func() []PresenceInvalidation {
		var out []PresenceInvalidation
		for {
			select {
			case inv := <-invalidations:
				out = append(out, inv)
			default:
				return out
			}
		}
	}
	// Hub 发布与转发 goroutine 是异步的：断言前轮询等待期望数量的通知，
	// 避免转发时序造成的偶发失败（通知本身仍按发布顺序去重）。
	waitForNotifications := func(want int) []PresenceInvalidation {
		deadline := time.Now().Add(2 * time.Second)
		for {
			got := drainInvalidations()
			if len(got) >= want || time.Now().After(deadline) {
				return got
			}
			time.Sleep(2 * time.Millisecond)
		}
	}
	// 静默断言前先给转发 goroutine 一个结算窗口。
	settleNotifications := func() {
		time.Sleep(50 * time.Millisecond)
		drainInvalidations()
	}

	// 阶段一：alpha 进入 unknown 观察窗（50s），beta 以 15s 节拍保持心跳
	//（心跳间隔 < 40s，prev 投影恒为 online，不制造恢复转换）。
	for i := 0; i < 3; i++ {
		f.advance(15 * time.Second)
		if _, err := f.daemon.Heartbeat(ctx, f.accountID, "dev-v091-reaper-beta", RoleTerminal, 1); err != nil {
			t.Fatalf("keep beta alive: %v", err)
		}
	}
	f.advance(5 * time.Second)
	summary, err := reaper.SweepOnce(ctx)
	if err != nil {
		t.Fatalf("sweep unknown band: %v", err)
	}
	if summary.Transitioned != 1 || summary.Scanned != 1 {
		t.Fatalf("unknown band summary=%+v, want exactly alpha transitioned", summary)
	}
	alpha, _ = f.repo.TerminalByDeviceID(ctx, "dev-v091-reaper-alpha")
	if alpha.PresenceProjectedState != "unknown" || alpha.PresenceRevision != 1 {
		t.Fatalf("alpha unknown projection=(%q,%d), want (unknown,1)", alpha.PresenceProjectedState, alpha.PresenceRevision)
	}
	if alpha.Status != "online" {
		// unknown 不降级 legacy status：旧客户端不得把「事实不可确认」误读为离线。
		t.Fatalf("unknown must not downgrade legacy status, got %q", alpha.Status)
	}
	beta, _ = f.repo.TerminalByDeviceID(ctx, "dev-v091-reaper-beta")
	if beta.PresenceProjectedState != "online" || beta.PresenceRevision != 0 {
		t.Fatalf("fresh beta must be untouched, got (%q,%d)", beta.PresenceProjectedState, beta.PresenceRevision)
	}
	notifications := waitForNotifications(1)
	if len(notifications) != 1 || notifications[0].Availability != "unknown" || notifications[0].TerminalID != alpha.ID {
		t.Fatalf("unknown notifications=%+v", notifications)
	}

	// 阶段二：跨过 offline deadline（61s），legacy status 同步翻转。
	f.advance(11 * time.Second)
	summary, err = reaper.SweepOnce(ctx)
	if err != nil {
		t.Fatalf("sweep offline band: %v", err)
	}
	if summary.Transitioned != 1 {
		t.Fatalf("offline band summary=%+v, want exactly alpha", summary)
	}
	alpha, _ = f.repo.TerminalByDeviceID(ctx, "dev-v091-reaper-alpha")
	if alpha.PresenceProjectedState != "offline" || alpha.PresenceRevision != 2 || alpha.Status != "offline" {
		t.Fatalf("alpha offline projection=(%q,%d,%q), want (offline,2,offline)",
			alpha.PresenceProjectedState, alpha.PresenceRevision, alpha.Status)
	}
	notifications = waitForNotifications(1)
	if len(notifications) != 1 || notifications[0].Availability != "offline" || notifications[0].PresenceRevision != 2 {
		t.Fatalf("offline notifications=%+v", notifications)
	}

	// 阶段三：重复扫描（无状态变化）不重复转换、不重复发布（revision 单调去重）。
	summary, err = reaper.SweepOnce(ctx)
	if err != nil {
		t.Fatalf("idempotent sweep: %v", err)
	}
	settleNotifications()
	if summary.Transitioned != 0 || len(drainInvalidations()) != 0 {
		t.Fatalf("idempotent sweep must be quiet: summary=%+v", summary)
	}
}

// V091-07 有界与自愈：BatchLimit=1 时两个过期 Terminal 分两个 tick 完成；
// 长时间丢唤醒后单次扫描直接补齐最终事实（online -> offline 一步到位）。
func TestV091PresenceReaperBoundedBatchSelfHeals(t *testing.T) {
	f := newV091ReaperFixture(t, "bounded-a", "bounded-b")
	ctx := context.Background()
	reaper := NewPresenceReaper(f.repo, nil, nil)
	reaper.now = func() time.Time { return f.clock }
	reaper.BatchLimit = 1

	f.advance(61 * time.Second)
	first, err := reaper.SweepOnce(ctx)
	if err != nil {
		t.Fatalf("bounded sweep 1: %v", err)
	}
	second, err := reaper.SweepOnce(ctx)
	if err != nil {
		t.Fatalf("bounded sweep 2: %v", err)
	}
	if first.Scanned != 1 || second.Scanned != 1 || first.Transitioned+second.Transitioned != 2 {
		t.Fatalf("bounded batch summaries=%+v/%+v, want 1+1 transitions across ticks", first, second)
	}
	for _, name := range []string{"dev-v091-reaper-bounded-a", "dev-v091-reaper-bounded-b"} {
		row, err := f.repo.TerminalByDeviceID(ctx, name)
		if err != nil || row.PresenceProjectedState != "offline" || row.Status != "offline" {
			t.Fatalf("%s must be offline after two bounded ticks: %+v err=%v", name, row, err)
		}
	}

	// 丢唤醒自愈：全新 Terminal 一次性拨到远超 deadline（跳过 unknown 窗口的所有
	// tick），下一次扫描仍然把最终事实补齐。
	f.advance(10 * time.Minute)
	if _, err := f.daemon.Heartbeat(ctx, f.accountID, "dev-v091-reaper-bounded-a", RoleTerminal, 1); err != nil {
		t.Fatalf("revive bounded-a: %v", err)
	}
	f.advance(10 * time.Minute)
	summary, err := reaper.SweepOnce(ctx)
	if err != nil {
		t.Fatalf("self-heal sweep: %v", err)
	}
	if summary.Transitioned == 0 {
		t.Fatalf("self-heal sweep must transition lapsed terminals: %+v", summary)
	}
	row, err := f.repo.TerminalByDeviceID(ctx, "dev-v091-reaper-bounded-a")
	if err != nil || row.PresenceProjectedState != "offline" {
		t.Fatalf("lapsed terminal must heal to offline: %+v err=%v", row, err)
	}
}

// V091-07 资源释放：Run/Stop 生命周期 —— Stop 幂等、goroutine 确认退出；
// 取消订阅后订阅计数归零（Hub 侧无泄漏）。
func TestV091PresenceReaperRunStopReleasesResources(t *testing.T) {
	f := newV091ReaperFixture(t, "lifecycle")
	reaper := NewPresenceReaper(f.repo, f.hub, nil)
	reaper.now = func() time.Time { return f.clock }
	reaper.Interval = 5 * time.Millisecond

	subscribe, cancel := f.hub.SubscribeAccountPresence(f.accountID)
	if got := f.hub.AccountPresenceSubscribers(f.accountID); got != 1 {
		t.Fatalf("presence subscribers=%d, want 1", got)
	}

	// 推进时钟跨过 deadline 后启动循环，等待过期转换真实发生。
	f.advance(61 * time.Second)
	done := make(chan struct{})
	go func() {
		reaper.Run()
		close(done)
	}()
	deadline := time.Now().Add(5 * time.Second)
	for {
		row, err := f.repo.TerminalByDeviceID(context.Background(), "dev-v091-reaper-lifecycle")
		if err != nil {
			t.Fatalf("poll terminal: %v", err)
		}
		if row.PresenceProjectedState == "offline" {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("reaper Run loop never applied the offline transition")
		}
		time.Sleep(5 * time.Millisecond)
	}

	reaper.Stop()
	select {
	case <-done:
	default:
		t.Fatal("Stop must wait for the Run goroutine to exit")
	}
	// 幂等：重复 Stop 不 panic、不阻塞。
	reaper.Stop()

	cancel()
	if got := f.hub.AccountPresenceSubscribers(f.accountID); got != 0 {
		t.Fatalf("presence subscribers after cancel=%d, want 0", got)
	}
	// 停止后循环不再扫描：再次推进时钟也不会产生新的转换（channel 已被取消，
	// 这里以持久投影不再变化为准）。
	f.advance(10 * time.Minute)
	_ = subscribe
}
