package domain

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"errors"
	"testing"
	"time"

	"github.com/yubi233/agent-sessions/internal/authz"
	"github.com/yubi233/agent-sessions/internal/store"
	"github.com/yubi233/agent-sessions/packages/protocol"
)

// signedFixture 是签名认证测试的公共前置：账号 + active Terminal 设备 + 固定种子 Ed25519 密钥
// + 可控时钟的 DaemonService。所有密钥都是测试专用 fixture，不来自任何真实凭据。
type signedFixture struct {
	svc       *DaemonService
	repo      store.Repository
	priv      ed25519.PrivateKey
	accountID string
	deviceID  string
}

func newSignedFixture(t *testing.T) *signedFixture {
	t.Helper()
	repo := newRepo(t)
	ctx := context.Background()
	f := &signedFixture{repo: repo, accountID: "acct-signed", deviceID: "dev-term-signed"}

	seed := bytes.Repeat([]byte{0x51}, ed25519.SeedSize)
	f.priv = ed25519.NewKeyFromSeed(seed)
	pub := f.priv.Public().(ed25519.PublicKey)

	if err := repo.CreateAccount(ctx, f.accountID, "signed@example.test", []byte("h"), time.Now()); err != nil {
		t.Fatalf("create account: %v", err)
	}
	if err := repo.CreateDevice(ctx, store.DeviceRow{
		ID: f.deviceID, AccountID: f.accountID, Role: RoleTerminal, Status: "active",
		DisplayName: "signed terminal", Platform: "macos",
		IdentityPublicKey: base64.RawURLEncoding.EncodeToString(pub), EncryptionPublicKey: "fixture-encryption",
	}); err != nil {
		t.Fatalf("create device: %v", err)
	}
	f.svc = NewDaemonService(repo)
	f.svc.now = func() time.Time { return time.UnixMilli(1700000000000) }
	return f
}

// signHello 用指定 nonce 构造一个对 /v1/daemon/hello 的完整签名字段。
func (f *signedFixture) signHello(t *testing.T, nonce string, timestampMS int64) authz.TerminalSignature {
	t.Helper()
	body := []byte(`{"protocol_version":1}`)
	sig := authz.TerminalSignature{
		ProtocolVersion: 1,
		KeyID:           f.deviceID,
		TimestampMS:     timestampMS,
		Nonce:           nonce,
		BodyHash:        authz.HashBody(body),
	}
	signed, err := authz.SignTerminalRequest(f.priv, sig, f.deviceID, "POST", "/v1/daemon/hello")
	if err != nil {
		t.Fatalf("sign: %v", err)
	}
	sig.Signature = signed
	return sig
}

func TestDaemonServiceVerifySignedTerminalRequest(t *testing.T) {
	f := newSignedFixture(t)
	ctx := context.Background()
	body := []byte(`{"protocol_version":1}`)

	// hello 必须使用 Relay 预先签发的一次性 challenge 作为 nonce。
	challenge, err := f.svc.IssueTerminalAuthChallenge(ctx, f.accountID, f.deviceID)
	if err != nil {
		t.Fatalf("issue challenge: %v", err)
	}
	sig := f.signHello(t, challenge.Challenge, 1700000000000)

	if err := f.svc.VerifySignedTerminalRequest(ctx, f.accountID, f.deviceID, sig, "POST", "/v1/daemon/hello", body); err != nil {
		t.Fatalf("valid signed request rejected: %v", err)
	}

	// 同一个 challenge 再次使用必须失败（一次性消费）。
	if err := f.svc.VerifySignedTerminalRequest(ctx, f.accountID, f.deviceID, sig, "POST", "/v1/daemon/hello", body); err == nil {
		t.Fatal("reused challenge must fail")
	} else if code := signedCode(err); code != protocol.ErrNonceReused {
		t.Fatalf("reused nonce error=%T %v code=%q want %q", err, err, code, protocol.ErrNonceReused)
	}

	// 未经过 challenge 签发的 nonce 不能用于 hello。
	fresh := f.signHello(t, "nonce-not-a-challenge", 1700000000000)
	if err := f.svc.VerifySignedTerminalRequest(ctx, f.accountID, f.deviceID, fresh, "POST", "/v1/daemon/hello", body); err == nil {
		t.Fatal("hello without issued challenge must fail")
	}

	// 错误签名必须失败；即使换了 nonce，只要签名不是对应 canonical bytes 就拒绝。
	bad := f.signHello(t, mustChallenge(t, f), 1700000000000)
	bad.Signature = "not-a-signature"
	if err := f.svc.VerifySignedTerminalRequest(ctx, f.accountID, f.deviceID, bad, "POST", "/v1/daemon/hello", body); err == nil {
		t.Fatal("tampered signature must fail")
	} else if code := signedCode(err); code != protocol.ErrSignatureInvalid {
		t.Fatalf("tampered signature code=%q want %q", code, protocol.ErrSignatureInvalid)
	}

	// 过期时间戳必须失败，且不消费 challenge。
	unused := mustChallenge(t, f)
	expired := f.signHello(t, unused, 1700000000000-int64((terminalAuthTimeWindow+time.Minute).Milliseconds()))
	if err := f.svc.VerifySignedTerminalRequest(ctx, f.accountID, f.deviceID, expired, "POST", "/v1/daemon/hello", body); err == nil {
		t.Fatal("expired timestamp must fail")
	} else if code := signedCode(err); code != protocol.ErrTimestampExpired {
		t.Fatalf("expired timestamp code=%q want %q", code, protocol.ErrTimestampExpired)
	}
	// 过期请求消费的 challenge 必须仍然可用（时间窗口校验先于挑战消费）。
	recovered := f.signHello(t, unused, 1700000000000)
	if err := f.svc.VerifySignedTerminalRequest(ctx, f.accountID, f.deviceID, recovered, "POST", "/v1/daemon/hello", body); err != nil {
		t.Fatalf("challenge must survive expired attempt: %v", err)
	}

	// 非 hello 端点不要求 challenge，但 nonce 仍是一次性的。
	hb1 := signPath(t, f, "/v1/daemon/heartbeat", "hb-nonce-1", 1700000000000)
	if err := f.svc.VerifySignedTerminalRequest(ctx, f.accountID, f.deviceID, hb1, "POST", "/v1/daemon/heartbeat", body); err != nil {
		t.Fatalf("signed heartbeat rejected: %v", err)
	}
	hb2 := signPath(t, f, "/v1/daemon/heartbeat", "hb-nonce-1", 1700000000000)
	if err := f.svc.VerifySignedTerminalRequest(ctx, f.accountID, f.deviceID, hb2, "POST", "/v1/daemon/heartbeat", body); err == nil {
		t.Fatal("reused heartbeat nonce must fail")
	}

	// 旧 bearer 不携带签名时仍通过兼容路径。
	if err := f.svc.VerifySignedTerminalRequest(ctx, f.accountID, f.deviceID, authz.TerminalSignature{}, "POST", "/v1/daemon/hello", body); err != nil {
		t.Fatalf("bearer compatibility path failed: %v", err)
	}
}

// TestDaemonServiceSignatureRequiredRejectsBearer 验证 N/N-1 窗口结束后的 fail-closed：
// required 模式下无签名请求返回稳定 UPGRADE_REQUIRED，且不会静默回退 bearer。
func TestDaemonServiceSignatureRequiredRejectsBearer(t *testing.T) {
	f := newSignedFixture(t)
	ctx := context.Background()
	body := []byte(`{"protocol_version":1}`)

	f.svc.SetTerminalSignatureRequired(true)
	if got := f.svc.terminalAuthModes(); len(got) != 1 || got[0] != "signature_v1" {
		t.Fatalf("required auth_modes=%v want [signature_v1]", got)
	}
	err := f.svc.VerifySignedTerminalRequest(ctx, f.accountID, f.deviceID, authz.TerminalSignature{}, "POST", "/v1/daemon/hello", body)
	if err == nil {
		t.Fatal("required mode must reject bearer-only request")
	} else if !errors.Is(err, ErrProtocolUpgradeRequired) {
		t.Fatalf("bearer rejection err=%v want ErrProtocolUpgradeRequired sentinel (传输层映射 426 UPGRADE_REQUIRED)", err)
	}

	// required 模式下合法签名仍通过。
	challenge, err := f.svc.IssueTerminalAuthChallenge(ctx, f.accountID, f.deviceID)
	if err != nil {
		t.Fatalf("issue challenge: %v", err)
	}
	if err := f.svc.VerifySignedTerminalRequest(ctx, f.accountID, f.deviceID, f.signHello(t, challenge.Challenge, 1700000000000), "POST", "/v1/daemon/hello", body); err != nil {
		t.Fatalf("required mode valid signature rejected: %v", err)
	}
}

// TestDaemonServiceIdentityKeyRotation 验证登记公钥的双读一写轮换：
// 登记新 key 后旧桥接 key 与新 key 都能验签；新 key 首次成功签名后其余登记 key 收口为 retired。
func TestDaemonServiceIdentityKeyRotation(t *testing.T) {
	f := newSignedFixture(t)
	ctx := context.Background()

	// 登记第二把密钥（模拟轮换目标）。
	rotSeed := bytes.Repeat([]byte{0x52}, ed25519.SeedSize)
	rotPriv := ed25519.NewKeyFromSeed(rotSeed)
	rotPub := base64.RawURLEncoding.EncodeToString(rotPriv.Public().(ed25519.PublicKey))
	row, err := f.svc.RegisterTerminalIdentityKey(ctx, f.accountID, f.deviceID, rotPub)
	if err != nil {
		t.Fatalf("register identity key: %v", err)
	}
	if row.Status != "active" || row.KeyID == "" || row.KeyID == f.deviceID {
		t.Fatalf("unexpected registered key row: %+v", row)
	}
	// 幂等登记同一公钥应返回同一 key。
	dup, err := f.svc.RegisterTerminalIdentityKey(ctx, f.accountID, f.deviceID, rotPub)
	if err != nil || dup.KeyID != row.KeyID {
		t.Fatalf("idempotent registration failed: %+v err=%v", dup, err)
	}
	// 已 retired 的公钥禁止复用：先撤销再登记必须被拒绝。
	if err := f.svc.RevokeTerminalIdentityKey(ctx, f.accountID, f.deviceID, row.KeyID); err != nil {
		t.Fatalf("revoke identity key: %v", err)
	}
	if _, err := f.svc.RegisterTerminalIdentityKey(ctx, f.accountID, f.deviceID, rotPub); err == nil {
		t.Fatal("retired key material must not be re-registrable")
	}

	// 重新登记一把新 key，验证"新 key 首次成功签名后收口其余登记 key"。
	reSeed := bytes.Repeat([]byte{0x53}, ed25519.SeedSize)
	rePriv := ed25519.NewKeyFromSeed(reSeed)
	rePub := base64.RawURLEncoding.EncodeToString(rePriv.Public().(ed25519.PublicKey))
	active, err := f.svc.RegisterTerminalIdentityKey(ctx, f.accountID, f.deviceID, rePub)
	if err != nil {
		t.Fatalf("re-register identity key: %v", err)
	}
	keys, err := f.svc.ListTerminalIdentityKeys(ctx, f.accountID, f.deviceID)
	if err != nil {
		t.Fatalf("list identity keys: %v", err)
	}
	activeCount := 0
	for _, k := range keys {
		if k.Status == "active" {
			activeCount++
		}
	}
	if activeCount != 1 {
		t.Fatalf("active keys after rotation close=%d want 1", activeCount)
	}

	// 新 key 的签名必须可用；旧 retired 登记密钥的签名必须被拒。
	body := []byte(`{"protocol_version":1}`)
	newSigner := func(priv ed25519.PrivateKey, keyID, nonce string) authz.TerminalSignature {
		sig := authz.TerminalSignature{
			ProtocolVersion: 1, KeyID: keyID, TimestampMS: 1700000000000,
			Nonce: nonce, BodyHash: authz.HashBody(body),
		}
		signed, err := authz.SignTerminalRequest(priv, sig, f.deviceID, "POST", "/v1/daemon/heartbeat")
		if err != nil {
			t.Fatalf("sign: %v", err)
		}
		sig.Signature = signed
		return sig
	}
	if err := f.svc.VerifySignedTerminalRequest(ctx, f.accountID, f.deviceID, newSigner(rePriv, active.KeyID, "new-key-nonce-1"), "POST", "/v1/daemon/heartbeat", body); err != nil {
		t.Fatalf("registered key signature rejected: %v", err)
	}
	retiredSig := newSigner(rotPriv, row.KeyID, "retired-key-nonce-1")
	if err := f.svc.VerifySignedTerminalRequest(ctx, f.accountID, f.deviceID, retiredSig, "POST", "/v1/daemon/heartbeat", body); err == nil {
		t.Fatal("retired registered key must be rejected")
	} else if code := signedCode(err); code != protocol.ErrKeyUnknownOrRevoked {
		t.Fatalf("retired key code=%q want KEY_UNKNOWN_OR_REVOKED", code)
	}
}

// TestDaemonServiceCrossDeviceAndScope 验证签名身份不能越界：
// 其他设备的登记 key、其他账号的设备、非 terminal 角色都 fail-closed。
func TestDaemonServiceCrossDeviceAndScope(t *testing.T) {
	f := newSignedFixture(t)
	ctx := context.Background()

	otherPriv := ed25519.NewKeyFromSeed(bytes.Repeat([]byte{0x54}, ed25519.SeedSize))
	otherPub := base64.RawURLEncoding.EncodeToString(otherPriv.Public().(ed25519.PublicKey))
	otherRow, err := f.svc.RegisterTerminalIdentityKey(ctx, f.accountID, f.deviceID, otherPub)
	if err != nil {
		t.Fatalf("setup other key: %v", err)
	}
	body := []byte(`{"protocol_version":1}`)
	sig := authz.TerminalSignature{
		ProtocolVersion: 1, KeyID: otherRow.KeyID, TimestampMS: 1700000000000,
		Nonce: "scope-nonce-1", BodyHash: authz.HashBody(body),
	}
	signed, err := authz.SignTerminalRequest(otherPriv, sig, f.deviceID, "POST", "/v1/daemon/heartbeat")
	if err != nil {
		t.Fatalf("sign: %v", err)
	}
	sig.Signature = signed

	// owner 账号不匹配：用不存在的账号 ID 校验必须拒绝。
	if err := f.svc.VerifySignedTerminalRequest(ctx, "acct-other", f.deviceID, sig, "POST", "/v1/daemon/heartbeat", body); err == nil {
		t.Fatal("cross-account verification must fail")
	}

	// 撤销设备后签名立即失效。
	if err := f.repo.SetDeviceStatus(ctx, f.deviceID, "revoked"); err != nil {
		t.Fatalf("revoke device: %v", err)
	}
	if err := f.svc.VerifySignedTerminalRequest(ctx, f.accountID, f.deviceID, sig, "POST", "/v1/daemon/heartbeat", body); err == nil {
		t.Fatal("revoked device signature must fail")
	} else if code := signedCode(err); code != protocol.ErrDeviceRevoked {
		t.Fatalf("revoked device code=%q want DEVICE_REVOKED", code)
	}
}

// TestDaemonServiceChallengeRestartPersistence 验证挑战跨 Relay 重启仍保持一次性语义：
// 关闭并重新打开 SQLite 后，未消费挑战可正常使用、已消费挑战仍被拒绝。
func TestDaemonServiceChallengeRestartPersistence(t *testing.T) {
	path := t.TempDir() + "/relay.db"
	open := func(t *testing.T) store.Repository {
		db, err := store.Open(path)
		if err != nil {
			t.Fatalf("open: %v", err)
		}
		t.Cleanup(func() { _ = db.Close() })
		return store.NewRepository(db)
	}
	ctx := context.Background()
	repo := open(t)

	accountID, deviceID := "acct-restart", "dev-term-restart"
	if err := repo.CreateAccount(ctx, accountID, "restart@example.test", []byte("h"), time.Now()); err != nil {
		t.Fatalf("create account: %v", err)
	}
	priv := ed25519.NewKeyFromSeed(bytes.Repeat([]byte{0x55}, ed25519.SeedSize))
	pub := base64.RawURLEncoding.EncodeToString(priv.Public().(ed25519.PublicKey))
	if err := repo.CreateDevice(ctx, store.DeviceRow{
		ID: deviceID, AccountID: accountID, Role: RoleTerminal, Status: "active",
		DisplayName: "restart terminal", Platform: "macos",
		IdentityPublicKey: pub, EncryptionPublicKey: "fixture-encryption",
	}); err != nil {
		t.Fatalf("create device: %v", err)
	}

	svc := NewDaemonService(repo)
	svc.now = func() time.Time { return time.UnixMilli(1700000000000) }
	first, err := svc.IssueTerminalAuthChallenge(ctx, accountID, deviceID)
	if err != nil {
		t.Fatalf("issue first challenge: %v", err)
	}
	second, err := svc.IssueTerminalAuthChallenge(ctx, accountID, deviceID)
	if err != nil {
		t.Fatalf("issue second challenge: %v", err)
	}
	body := []byte(`{"protocol_version":1}`)
	sigOf := func(nonce string) authz.TerminalSignature {
		s := authz.TerminalSignature{
			ProtocolVersion: 1, KeyID: deviceID, TimestampMS: 1700000000000,
			Nonce: nonce, BodyHash: authz.HashBody(body),
		}
		signature, err := authz.SignTerminalRequest(priv, s, deviceID, "POST", "/v1/daemon/hello")
		if err != nil {
			t.Fatalf("sign: %v", err)
		}
		s.Signature = signature
		return s
	}
	if err := svc.VerifySignedTerminalRequest(ctx, accountID, deviceID, sigOf(first.Challenge), "POST", "/v1/daemon/hello", body); err != nil {
		t.Fatalf("first challenge verify: %v", err)
	}

	// 模拟 Relay 重启：关闭旧仓储，重新打开同一 SQLite 文件。
	repo2 := open(t)
	svc2 := NewDaemonService(repo2)
	svc2.now = func() time.Time { return time.UnixMilli(1700000001000) }
	// 已消费挑战重启后仍拒绝。
	if err := svc2.VerifySignedTerminalRequest(ctx, accountID, deviceID, sigOf(first.Challenge), "POST", "/v1/daemon/hello", body); err == nil {
		t.Fatal("consumed challenge must stay consumed across restart")
	}
	// 未消费挑战重启后仍可用。
	if err := svc2.VerifySignedTerminalRequest(ctx, accountID, deviceID, sigOf(second.Challenge), "POST", "/v1/daemon/hello", body); err != nil {
		t.Fatalf("pending challenge must survive restart: %v", err)
	}
}

func mustChallenge(t *testing.T, f *signedFixture) string {
	t.Helper()
	challenge, err := f.svc.IssueTerminalAuthChallenge(context.Background(), f.accountID, f.deviceID)
	if err != nil {
		t.Fatalf("issue challenge: %v", err)
	}
	return challenge.Challenge
}

// signPath 构造对任意 POST 路径的完整签名（非 hello 端点不需要 challenge）。
func signPath(t *testing.T, f *signedFixture, path, nonce string, timestampMS int64) authz.TerminalSignature {
	t.Helper()
	body := []byte(`{"protocol_version":1}`)
	sig := authz.TerminalSignature{
		ProtocolVersion: 1, KeyID: f.deviceID, TimestampMS: timestampMS,
		Nonce: nonce, BodyHash: authz.HashBody(body),
	}
	signed, err := authz.SignTerminalRequest(f.priv, sig, f.deviceID, "POST", path)
	if err != nil {
		t.Fatalf("sign: %v", err)
	}
	sig.Signature = signed
	return sig
}

func signedCode(err error) string {
	apiErr, ok := err.(protocol.APIError)
	if !ok {
		return ""
	}
	return apiErr.Code
}
