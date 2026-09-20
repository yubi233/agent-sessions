package domain

import (
	"context"
	"database/sql"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/yubi233/agent-sessions/internal/authz"
	"github.com/yubi233/agent-sessions/internal/store"
)

// authFixture 创建一个已绑定 Android owner 的 token family，供 refresh 根因回归共用。
func authFixture(t *testing.T, now time.Time) (*AuthService, store.Repository, TokenPair) {
	t.Helper()
	ctx := context.Background()
	repo := newRepo(t)
	if err := repo.CreateAccount(ctx, "acct-auth", "auth@example.test", []byte("hash"), now); err != nil {
		t.Fatalf("create account: %v", err)
	}
	if err := repo.CreateDevice(ctx, store.DeviceRow{
		ID: "dev-auth", AccountID: "acct-auth", Role: RoleAndroidOwner, Status: DeviceActive,
		DisplayName: "test owner", Platform: "android", IdentityPublicKey: "identity-auth", EncryptionPublicKey: "encryption-auth",
	}); err != nil {
		t.Fatalf("create device: %v", err)
	}
	svc := NewAuthService(repo)
	svc.now = func() time.Time { return now }
	pair, err := svc.IssueForDevice(ctx, "acct-auth", "dev-auth")
	if err != nil {
		t.Fatalf("issue device pair: %v", err)
	}
	return svc, repo, pair
}

// AUTH-01 根因：两个并发 refresh 只能轮换一次；输家触发 reuse 撤销 family。
func TestRefreshRotationUsesCompareAndSwap(t *testing.T) {
	now := time.Date(2026, 8, 14, 12, 0, 0, 0, time.UTC)
	svc, _, pair := authFixture(t, now)

	start := make(chan struct{})
	results := make(chan error, 2)
	var wg sync.WaitGroup
	for range 2 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			_, err := svc.Refresh(context.Background(), pair.RefreshToken)
			results <- err
		}()
	}
	close(start)
	wg.Wait()
	close(results)

	successes := 0
	reuses := 0
	for err := range results {
		switch {
		case err == nil:
			successes++
		case errors.Is(err, ErrTokenReused):
			reuses++
		default:
			t.Fatalf("unexpected concurrent refresh error: %v", err)
		}
	}
	if successes != 1 || reuses != 1 {
		t.Fatalf("refresh CAS results success=%d reuse=%d, want 1/1", successes, reuses)
	}
	// reuse 检测撤销整个 family，成功支路刚签发的 token 也不能继续扩展会话。
	if _, err := svc.Refresh(context.Background(), pair.RefreshToken); err == nil {
		t.Fatal("revoked refresh family unexpectedly accepted the original token")
	}
}

// AUTH-01 根因：refresh TTL 到期后不可继续轮换，即使哈希与设备仍然有效。
func TestRefreshRejectsExpiredFamily(t *testing.T) {
	issuedAt := time.Date(2026, 8, 14, 12, 0, 0, 0, time.UTC)
	svc, _, pair := authFixture(t, issuedAt)
	svc.now = func() time.Time { return issuedAt.Add(authz.RefreshTTL) }

	if _, err := svc.Refresh(context.Background(), pair.RefreshToken); !errors.Is(err, ErrUnauthenticated) {
		t.Fatalf("expired refresh error=%v want unauthenticated", err)
	}
}

var errAccessTokenPersistence = errors.New("fixture access token persistence failed")

// failTokenWriteRepository 在事务内拒绝 access token 写入，用于证明复合身份链路不会部分提交。
type failTokenWriteRepository struct {
	store.Repository
}

func (r failTokenWriteRepository) PutAccessToken(context.Context, store.AccessTokenRow) error {
	return errAccessTokenPersistence
}

func (r failTokenWriteRepository) WithTx(ctx context.Context, fn func(context.Context, store.Repository) error) error {
	return r.Repository.WithTx(ctx, func(ctx context.Context, tx store.Repository) error {
		return fn(ctx, failTokenWriteRepository{Repository: tx})
	})
}

// AUTH-02 根因：首账号、初始 owner 与首个 token 是一个原子提交，token 落库失败不能关闭后续注册入口。
func TestRegisterInitialOwnerRollsBackWhenTokenPersistenceFails(t *testing.T) {
	ctx := context.Background()
	base := newRepo(t)
	svc := NewAuthService(failTokenWriteRepository{Repository: base})
	svc.now = func() time.Time { return time.Date(2026, 8, 14, 12, 0, 0, 0, time.UTC) }

	_, _, err := svc.RegisterInitialOwner(ctx, "first-owner@example.test", "fixture-password", Device{
		DisplayName: "Android owner", Platform: "android",
	})
	if !errors.Is(err, errAccessTokenPersistence) {
		t.Fatalf("register initial owner error=%v want token persistence error", err)
	}
	count, err := base.CountAccounts(ctx)
	if err != nil {
		t.Fatalf("count accounts: %v", err)
	}
	if count != 0 {
		t.Fatalf("partial first account was committed: count=%d", count)
	}
}

// RECOVERY-01 根因：恢复码消费、旧 Android 撤销与新 owner token 签发必须同一事务，避免 5xx 后失去控制权。
func TestRestoreOwnerRollsBackWhenTokenPersistenceFails(t *testing.T) {
	ctx := context.Background()
	now := time.Date(2026, 8, 14, 12, 0, 0, 0, time.UTC)
	base := newRepo(t)
	if err := base.CreateAccount(ctx, "acct-recovery", "recover@example.test", []byte("hash"), now); err != nil {
		t.Fatalf("create account: %v", err)
	}
	if err := base.CreateDevice(ctx, store.DeviceRow{
		ID: "dev-old-owner", AccountID: "acct-recovery", Role: RoleAndroidOwner, Status: DeviceActive,
		DisplayName: "old owner", Platform: "android", IdentityPublicKey: "old-identity", EncryptionPublicKey: "old-encryption",
	}); err != nil {
		t.Fatalf("create old owner: %v", err)
	}
	const recoveryCode = "recovery-code-for-transaction-test"
	if err := base.UpsertRecoveryCode(ctx, store.RecoveryRow{
		AccountID: "acct-recovery", CodeHash: authz.HashToken(recoveryCode), CreatedAt: now,
	}); err != nil {
		t.Fatalf("store recovery code: %v", err)
	}

	failingRepo := failTokenWriteRepository{Repository: base}
	auth := NewAuthService(failingRepo)
	pairing := NewPairingService(failingRepo)
	auth.now = func() time.Time { return now }
	pairing.now = func() time.Time { return now }
	_, _, err := auth.RestoreOwnerWithRecoveryCode(ctx, pairing, "recover@example.test", recoveryCode, Device{
		DisplayName: "new owner", Platform: "android", IdentityPublicKey: "new-identity", EncryptionPublicKey: "new-encryption",
	})
	if !errors.Is(err, errAccessTokenPersistence) {
		t.Fatalf("restore error=%v want token persistence error", err)
	}

	// 失败后恢复码和旧 owner 都必须仍可用；随后用正常 repository 复跑可完成恢复。
	if _, err := base.RecoveryByAccount(ctx, "acct-recovery"); err != nil {
		t.Fatalf("recovery code was consumed on rolled-back restore: %v", err)
	}
	oldOwner, err := base.DeviceByID(ctx, "dev-old-owner")
	if err != nil || oldOwner.Status != DeviceActive {
		t.Fatalf("old owner changed after rolled-back restore: status=%q err=%v", oldOwner.Status, err)
	}

	healthyAuth := NewAuthService(base)
	healthyPairing := NewPairingService(base)
	healthyAuth.now = func() time.Time { return now }
	healthyPairing.now = func() time.Time { return now }
	restored, tokens, err := healthyAuth.RestoreOwnerWithRecoveryCode(ctx, healthyPairing, "recover@example.test", recoveryCode, Device{
		DisplayName: "new owner", Platform: "android", IdentityPublicKey: "new-identity", EncryptionPublicKey: "new-encryption",
	})
	if err != nil {
		t.Fatalf("healthy restore after rollback: %v", err)
	}
	if tokens.DeviceID != restored.ID || tokens.AccessToken == "" {
		t.Fatalf("healthy restore did not return a bound owner token")
	}
	if _, err := base.RecoveryByAccount(ctx, "acct-recovery"); !errors.Is(err, sql.ErrNoRows) {
		t.Fatalf("healthy restore did not consume recovery code: %v", err)
	}
	oldOwner, err = base.DeviceByID(ctx, "dev-old-owner")
	if err != nil || oldOwner.Status != DeviceRevoked {
		t.Fatalf("healthy restore did not revoke old owner: status=%q err=%v", oldOwner.Status, err)
	}
}

// authz 不反向依赖 domain；该测试钉住角色字面量与 TTL 映射的一致性，
// 防止两处字符串漂移导致 Terminal 拿不到长寿命令牌。
func TestTerminalRoleLiteralMatchesAuthzTTLSelection(t *testing.T) {
	if RoleTerminal != "terminal" {
		t.Fatalf("RoleTerminal = %q, want %q", RoleTerminal, "terminal")
	}
	if authz.AccessTTLOf(RoleTerminal) != authz.TerminalAccessTTL {
		t.Fatalf("AccessTTLOf(%q) must return TerminalAccessTTL", RoleTerminal)
	}
}

// V094（2026-09-21 用户报告）：本地开发拓扑里 Mac 侧 `restart.sh` bootstrap 的
// owner（platform=local）与手机 owner 同账号共存。恢复码接管曾把 local 桌面 owner
// 一并撤销，导致下次 `restart.sh start` 缓存刷新 401 → 自愈重置 Relay DB → 手机
// 令牌随之失效，每次都要恢复码重新接管。修复：接管的撤销范围收窄为**移动平台**
// 的 Android 写设备；platform=local 的桌面开发 owner 保留活跃（私钥在本机 0600
// state 目录，不扩大移动 key-admin 风险面）。未知/空 platform 的历史设备保持
// fail-safe：仍按 Android 写设备撤销。
func TestRestoreOwnerKeepsLocalDesktopOwnerActive(t *testing.T) {
	ctx := context.Background()
	now := time.Date(2026, 9, 21, 3, 0, 0, 0, time.UTC)
	repo := newRepo(t)
	if err := repo.CreateAccount(ctx, "acct-local", "local@example.test", []byte("hash"), now); err != nil {
		t.Fatalf("create account: %v", err)
	}
	// 旧设备两台：手机 Android owner（应被撤销）+ Mac 桌面开发 owner（应保留）。
	if err := repo.CreateDevice(ctx, store.DeviceRow{
		ID: "dev-phone-owner", AccountID: "acct-local", Role: RoleAndroidOwner, Status: DeviceActive,
		DisplayName: "phone", Platform: "android", IdentityPublicKey: "phone-identity", EncryptionPublicKey: "phone-encryption",
	}); err != nil {
		t.Fatalf("create phone owner: %v", err)
	}
	if err := repo.CreateDevice(ctx, store.DeviceRow{
		ID: "dev-mac-local", AccountID: "acct-local", Role: RoleAndroidOwner, Status: DeviceActive,
		DisplayName: "mac localdev", Platform: "local", IdentityPublicKey: "mac-identity", EncryptionPublicKey: "mac-encryption",
	}); err != nil {
		t.Fatalf("create mac local owner: %v", err)
	}
	const recoveryCode = "recovery-code-local-desktop-test"
	if err := repo.UpsertRecoveryCode(ctx, store.RecoveryRow{
		AccountID: "acct-local", CodeHash: authz.HashToken(recoveryCode), CreatedAt: now,
	}); err != nil {
		t.Fatalf("store recovery code: %v", err)
	}

	auth := NewAuthService(repo)
	pairing := NewPairingService(repo)
	auth.now = func() time.Time { return now }
	pairing.now = func() time.Time { return now }
	restored, _, err := auth.RestoreOwnerWithRecoveryCode(ctx, pairing, "local@example.test", recoveryCode, Device{
		DisplayName: "restored phone", Platform: "android", IdentityPublicKey: "new-phone-identity", EncryptionPublicKey: "new-phone-encryption",
	})
	if err != nil {
		t.Fatalf("restore: %v", err)
	}
	if restored.Platform != "android" {
		t.Fatalf("restored device platform=%q, want android", restored.Platform)
	}
	phone, err := repo.DeviceByID(ctx, "dev-phone-owner")
	if err != nil || phone.Status != DeviceRevoked {
		t.Fatalf("旧手机 owner 必须被撤销: status=%q err=%v", phone.Status, err)
	}
	local, err := repo.DeviceByID(ctx, "dev-mac-local")
	if err != nil || local.Status != DeviceActive {
		t.Fatalf("platform=local 桌面开发 owner 必须保留活跃: status=%q err=%v", local.Status, err)
	}
}
