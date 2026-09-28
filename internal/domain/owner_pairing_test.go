// OWN-01/02/05（ADR-017 owner 配对加入）域层契约：
//   - 创建：总开关关闭 → 稳定禁用错误；开启 → TTL 10 分钟 + 单 pending 约束 + 审计；
//   - 批准：第二个 active owner 设备创建、既有设备零变化、claim 令牌可领取；
//   - 撤销：互不牵连；零 active owner 后 bootstrap 在同账号重开放（回到首部署语义）。
package domain

import (
	"context"
	"errors"
	"regexp"
	"testing"
	"time"

	"github.com/yubi233/agent-sessions/internal/store"
)

const (
	opAcct     = "acct-owner-pairing"
	opExisting = "dev-owner-pairing-existing"
)

func setupOwnerPairingAccount(t *testing.T, repo store.Repository) {
	t.Helper()
	if err := repo.CreateAccount(context.Background(), opAcct, "owner-pairing@example.test", []byte("h"), time.Now()); err != nil {
		t.Fatalf("create account: %v", err)
	}
}

func ownerPairingDevice() Device {
	return Device{
		AccountID:           opAcct,
		Role:                RoleAndroidOwner,
		Status:              DeviceActive,
		DisplayName:         "新加入的测试手机",
		Platform:            "android",
		IdentityPublicKey:   "owner-pair-identity",
		EncryptionPublicKey: "owner-pair-encryption",
	}
}

// OWN-01：开关关闭 → 稳定禁用错误；开启 → TTL 10 分钟 + 单 pending 约束 + 审计。
func TestOwnerPairingGateAndSinglePending(t *testing.T) {
	ctx := context.Background()
	repo := newRepo(t)
	setupOwnerPairingAccount(t, repo)
	svc := NewPairingService(repo)
	svc.OwnerPairingEnabled = true

	d := ownerPairingDevice()
	// 开关关闭 → 稳定禁用错误（不受另一实例开关影响）。
	svcOff := NewPairingService(repo)
	if _, _, err := svcOff.CreateOwnerPairingRequest(ctx, d); !errors.Is(err, ErrOwnerPairingDisabled) {
		t.Fatalf("开关关闭应返回 ErrOwnerPairingDisabled: %v", err)
	}

	p, code, err := svc.CreateOwnerPairingRequest(ctx, d)
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	if p.Status != PairingPending || p.Role != RoleAndroidOwner {
		t.Fatalf("配对请求状态/角色不符: %+v", p)
	}
	if !regexp.MustCompile(`^[0-9]{6}$`).MatchString(code) {
		t.Fatalf("比对码必须是 6 位数字: %q", code)
	}
	if ttl := time.Until(p.ExpiresAt); ttl > 10*time.Minute || ttl < 9*time.Minute {
		t.Fatalf("TTL 应为 10 分钟: %v", ttl)
	}
	// 单 pending：同账号第二个 owner 请求必须被拒。
	if _, _, err := svc.CreateOwnerPairingRequest(ctx, d); !errors.Is(err, ErrOwnerPairingPending) {
		t.Fatalf("第二个 owner 请求应返回 ErrOwnerPairingPending: %v", err)
	}
}

// OWN-02：批准 → 第二个 active owner 设备 + 既有设备零变化 + claim 令牌可领取。
func TestOwnerPairingApproveKeepsExistingDevices(t *testing.T) {
	ctx := context.Background()
	repo := newRepo(t)
	setupOwnerPairingAccount(t, repo)
	svc := NewPairingService(repo)
	svc.OwnerPairingEnabled = true

	// 现役 owner 设备（日常机）。
	if err := repo.CreateDevice(ctx, store.DeviceRow{
		ID: opExisting, AccountID: opAcct, Role: RoleAndroidOwner,
		Status: DeviceActive, DisplayName: "日常机", Platform: "android",
		IdentityPublicKey: "existing-identity", EncryptionPublicKey: "existing-encryption",
	}); err != nil {
		t.Fatalf("create existing owner device: %v", err)
	}

	p, code, err := svc.CreateOwnerPairingRequest(ctx, ownerPairingDevice())
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	if code == "" {
		t.Fatal("比对码不能为空")
	}
	owner := AuthSubject{AccountID: opAcct, DeviceID: opExisting, Role: RoleAndroidOwner, DeviceOK: true}
	approved, err := svc.ApprovePairing(ctx, owner, p.ID)
	if err != nil {
		t.Fatalf("approve: %v", err)
	}
	if approved.Status != DeviceActive || approved.Role != RoleAndroidOwner {
		t.Fatalf("批准产物角色/状态不符: %+v", approved)
	}

	// 硬不变量：既有设备零变化（仍 active）。
	existing, err := repo.DeviceByID(ctx, opExisting)
	if err != nil {
		t.Fatalf("read existing device: %v", err)
	}
	if existing.Status != DeviceActive {
		t.Fatalf("既有 owner 设备不得被配对加入影响: %+v", existing)
	}

	// claim 令牌已签发并可领取。
	row, err := repo.PairingByID(ctx, p.ID)
	if err != nil {
		t.Fatalf("read pairing: %v", err)
	}
	if row.ClaimAccessToken == "" || row.ClaimRefreshToken == "" {
		t.Fatalf("批准后必须写入 claim 令牌对: %+v", row)
	}
	status, tokens, err := svc.OwnerPairingStatus(ctx, p.ID)
	if err != nil {
		t.Fatalf("status: %v", err)
	}
	if status.Status != PairingApproved || tokens == nil || tokens.AccessToken != row.ClaimAccessToken {
		t.Fatalf("轮询应返回已批准状态与同一对令牌: %+v tokens=%+v", status, tokens)
	}

	// 重复批准幂等：不产生第二台设备。
	if again, err := svc.ApprovePairing(ctx, owner, p.ID); err != nil || again.ID != approved.ID {
		t.Fatalf("重复批准应幂等: dev=%+v err=%v", again, err)
	}
}

// OWN-05：撤销语义（第二个 owner 可被撤销且不影响第一个）与
// bootstrap 重开放（零 active owner 时同账号重建）。
func TestOwnerPairingRevokeAndBootstrapReopen(t *testing.T) {
	ctx := context.Background()
	repo := newRepo(t)
	setupOwnerPairingAccount(t, repo)
	svc := NewPairingService(repo)
	svc.OwnerPairingEnabled = true

	if err := repo.CreateDevice(ctx, store.DeviceRow{
		ID: opExisting, AccountID: opAcct, Role: RoleAndroidOwner,
		Status: DeviceActive, DisplayName: "日常机", Platform: "android",
		IdentityPublicKey: "existing-identity", EncryptionPublicKey: "existing-encryption",
	}); err != nil {
		t.Fatalf("create existing owner device: %v", err)
	}
	p, _, err := svc.CreateOwnerPairingRequest(ctx, ownerPairingDevice())
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	owner := AuthSubject{AccountID: opAcct, DeviceID: opExisting, Role: RoleAndroidOwner, DeviceOK: true}
	approved, err := svc.ApprovePairing(ctx, owner, p.ID)
	if err != nil {
		t.Fatalf("approve: %v", err)
	}

	// 撤销第二个 owner（测试机）：不影响第一个。
	if err := svc.RevokeDevice(ctx, owner, approved.ID); err != nil {
		t.Fatalf("revoke joined: %v", err)
	}
	joined, err := repo.DeviceByID(ctx, approved.ID)
	if err != nil {
		t.Fatalf("read joined device: %v", err)
	}
	if joined.Status != DeviceRevoked {
		t.Fatalf("第二个 owner 应为 revoked: %+v", joined)
	}
	existing, err := repo.DeviceByID(ctx, opExisting)
	if err != nil {
		t.Fatalf("read existing device: %v", err)
	}
	if existing.Status != DeviceActive {
		t.Fatalf("日常机不得被连带撤销: %+v", existing)
	}

	// 零 active owner（模拟全部撤销后的存量形态）→ bootstrap 在同账号重开放。
	if err := repo.SetDeviceStatus(ctx, opExisting, DeviceRevoked); err != nil {
		t.Fatalf("revoke last owner: %v", err)
	}
	auth := NewAuthService(repo)
	reborn, tokens, err := auth.BootstrapInitialOwnerDevice(ctx, Device{
		AccountID:           opAcct,
		Role:                RoleAndroidOwner,
		Status:              DeviceActive,
		DisplayName:         "重开放后的控制端",
		Platform:            "android",
		IdentityPublicKey:   "reopened-identity",
		EncryptionPublicKey: "reopened-encryption",
	})
	if err != nil {
		t.Fatalf("bootstrap reopen: %v", err)
	}
	if reborn.AccountID != opAcct {
		t.Fatalf("重开放必须留在原账号: %q want %q", reborn.AccountID, opAcct)
	}
	if tokens.AccessToken == "" {
		t.Fatal("重开放必须签发令牌")
	}
}
