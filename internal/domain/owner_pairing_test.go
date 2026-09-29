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

// OWN-06 云端实证（阶段 4）：同机撤销后重新配对——批准不得撞
// devices_account_identity_public_key 唯一索引（云端 v0100c 实测 500
// internal error），应原地复激活设备并重签 claim 令牌；复激活时旧令牌族
// 全部作废（防撤销前泄露的令牌复活）。
func TestOwnerPairingRejoinAfterRevoke(t *testing.T) {
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
	owner := AuthSubject{AccountID: opAcct, DeviceID: opExisting, Role: RoleAndroidOwner, DeviceOK: true}

	p1, _, err := svc.CreateOwnerPairingRequest(ctx, ownerPairingDevice())
	if err != nil {
		t.Fatalf("first create: %v", err)
	}
	dev1, err := svc.ApprovePairing(ctx, owner, p1.ID)
	if err != nil {
		t.Fatalf("first approve: %v", err)
	}
	if err := svc.RevokeDevice(ctx, owner, dev1.ID); err != nil {
		t.Fatalf("revoke: %v", err)
	}

	// 同 identity 重新发起并批准：必须走复激活路径成功。
	p2, _, err := svc.CreateOwnerPairingRequest(ctx, ownerPairingDevice())
	if err != nil {
		t.Fatalf("rejoin create: %v", err)
	}
	dev2, err := svc.ApprovePairing(ctx, owner, p2.ID)
	if err != nil {
		t.Fatalf("rejoin approve（复激活路径）: %v", err)
	}
	if dev2.ID != dev1.ID {
		t.Fatalf("同 identity 重新加入必须复用原设备行: got %s want %s", dev2.ID, dev1.ID)
	}
	row, err := repo.DeviceByID(ctx, dev2.ID)
	if err != nil || row.Status != DeviceActive {
		t.Fatalf("复激活后设备应为 active: %+v err=%v", row, err)
	}

	// 第二轮 claim 令牌完整且 device_id 正确回填。
	status, tokens, err := svc.OwnerPairingStatus(ctx, p2.ID)
	if err != nil || status.Status != PairingApproved || tokens == nil || tokens.DeviceID != dev1.ID {
		t.Fatalf("重join轮询应返回完整领取载荷: %+v tokens=%+v err=%v", status, tokens, err)
	}

	// 第一轮签发的旧令牌族必须已随复激活作废。
	oldRow, err := repo.PairingByID(ctx, p1.ID)
	if err != nil {
		t.Fatalf("read old pairing: %v", err)
	}
	familyID, _, ok := splitRefreshToken(oldRow.ClaimRefreshToken)
	if !ok {
		t.Fatalf("旧 claim refresh 形状非法: %q", oldRow.ClaimRefreshToken)
	}
	tf, err := repo.TokenFamilyByID(ctx, familyID)
	if err != nil {
		t.Fatalf("read old token family: %v", err)
	}
	if !tf.Revoked {
		t.Fatal("复激活必须撤销设备旧令牌族")
	}
}
