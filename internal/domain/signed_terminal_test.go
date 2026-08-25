package domain

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"testing"
	"time"

	"github.com/yubi233/agent-sessions/internal/authz"
	"github.com/yubi233/agent-sessions/internal/store"
	"github.com/yubi233/agent-sessions/packages/protocol"
)

func TestDaemonServiceVerifySignedTerminalRequest(t *testing.T) {
	repo := newRepo(t)
	ctx := context.Background()
	accountID := "acct-signed"
	deviceID := "dev-term-signed"

	seed := bytes.Repeat([]byte{0x51}, ed25519.SeedSize)
	priv := ed25519.NewKeyFromSeed(seed)
	pub := priv.Public().(ed25519.PublicKey)
	pubEncoded := base64.RawURLEncoding.EncodeToString(pub)

	if err := repo.CreateAccount(ctx, accountID, "signed@example.test", []byte("h"), time.Now()); err != nil {
		t.Fatalf("create account: %v", err)
	}
	if err := repo.CreateDevice(ctx, store.DeviceRow{
		ID: deviceID, AccountID: accountID, Role: RoleTerminal, Status: "active",
		DisplayName: "signed terminal", Platform: "macos",
		IdentityPublicKey: pubEncoded, EncryptionPublicKey: "fixture-encryption",
	}); err != nil {
		t.Fatalf("create device: %v", err)
	}

	svc := NewDaemonService(repo)
	svc.now = func() time.Time { return time.UnixMilli(1700000000000) }
	body := []byte(`{"protocol_version":1}`)

	sig := authz.TerminalSignature{
		ProtocolVersion: 1,
		KeyID:           deviceID,
		TimestampMS:     1700000000000,
		Nonce:           "nonce-signed-1",
		BodyHash:        authz.HashBody(body),
	}
	signed, err := authz.SignTerminalRequest(priv, sig, deviceID, "POST", "/v1/daemon/hello")
	if err != nil {
		t.Fatalf("sign: %v", err)
	}
	sig.Signature = signed

	if err := svc.VerifySignedTerminalRequest(ctx, accountID, deviceID, sig, "POST", "/v1/daemon/hello", body); err != nil {
		t.Fatalf("valid signed request rejected: %v", err)
	}

	// 同一个 nonce 再次使用必须失败。
	if err := svc.VerifySignedTerminalRequest(ctx, accountID, deviceID, sig, "POST", "/v1/daemon/hello", body); err == nil {
		t.Fatal("reused nonce must fail")
	} else if code := signedCode(err); code != protocol.ErrNonceReused {
		t.Fatalf("reused nonce error=%T %v code=%q want %q", err, err, code, protocol.ErrNonceReused)
	}

	// 错误签名必须失败；即使换了 nonce，只要签名不是对应 canonical bytes 就拒绝。
	bad := sig
	bad.Nonce = "nonce-signed-2"
	bad.Signature = "not-a-signature"
	if err := svc.VerifySignedTerminalRequest(ctx, accountID, deviceID, bad, "POST", "/v1/daemon/hello", body); err == nil {
		t.Fatal("tampered signature must fail")
	} else if code := signedCode(err); code != protocol.ErrSignatureInvalid {
		t.Fatalf("tampered signature code=%q want %q", code, protocol.ErrSignatureInvalid)
	}

	// 过期时间戳必须失败，且不消费 nonce。
	expired := sig
	expired.Nonce = "nonce-signed-3"
	expired.TimestampMS = 1700000000000 - int64((terminalAuthTimeWindow + time.Minute).Milliseconds())
	expired.Signature, err = authz.SignTerminalRequest(priv, expired, deviceID, "POST", "/v1/daemon/hello")
	if err != nil {
		t.Fatalf("sign expired: %v", err)
	}
	if err := svc.VerifySignedTerminalRequest(ctx, accountID, deviceID, expired, "POST", "/v1/daemon/hello", body); err == nil {
		t.Fatal("expired timestamp must fail")
	} else if code := signedCode(err); code != protocol.ErrTimestampExpired {
		t.Fatalf("expired timestamp code=%q want %q", code, protocol.ErrTimestampExpired)
	}

	// 旧 bearer 不携带签名时仍通过兼容路径。
	if err := svc.VerifySignedTerminalRequest(ctx, accountID, deviceID, authz.TerminalSignature{}, "POST", "/v1/daemon/hello", body); err != nil {
		t.Fatalf("bearer compatibility path failed: %v", err)
	}
}

func signedCode(err error) string {
	apiErr, ok := err.(protocol.APIError)
	if !ok {
		return ""
	}
	return apiErr.Code
}
