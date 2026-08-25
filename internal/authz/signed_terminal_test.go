package authz

import (
	"bytes"
	"crypto/ed25519"
	"testing"

	"github.com/yubi233/agent-sessions/packages/protocol"
)

func TestTerminalSignatureCanonicalBytesVector(t *testing.T) {
	got := string(CanonicalBytes(
		1,
		"term-device-1",
		"POST",
		"/v1/daemon/hello",
		1700000000000,
		"nonce-001",
		HashBody([]byte(`{"protocol_version":1}`)),
		"key-001",
	))
	want := "1|term-device-1|POST|/v1/daemon/hello|1700000000000|nonce-001|" + HashBody([]byte(`{"protocol_version":1}`)) + "|key-001"
	if got != want {
		t.Fatalf("canonical bytes mismatch:\n got: %q\nwant: %q", got, want)
	}
}

func TestTerminalSignatureSignVerifyAndTamper(t *testing.T) {
	seed := bytes.Repeat([]byte{0x42}, ed25519.SeedSize)
	priv := ed25519.NewKeyFromSeed(seed)
	pub := priv.Public().(ed25519.PublicKey)

	sig := TerminalSignature{
		ProtocolVersion: 1,
		KeyID:           "key-001",
		TimestampMS:     1700000000000,
		Nonce:           "nonce-001",
		BodyHash:        HashBody([]byte(`{"protocol_version":1}`)),
	}
	signed, err := SignTerminalRequest(priv, sig, "term-device-1", "POST", "/v1/daemon/hello")
	if err != nil {
		t.Fatalf("sign: %v", err)
	}
	sig.Signature = signed
	if err := VerifyTerminalRequest(pub, sig, "term-device-1", "POST", "/v1/daemon/hello"); err != nil {
		t.Fatalf("verify: %v", err)
	}

	sig.Signature = signed + "AAAA"
	if err := VerifyTerminalRequest(pub, sig, "term-device-1", "POST", "/v1/daemon/hello"); err == nil {
		t.Fatal("tampered signature must fail")
	} else if code := protocolErrCode(err); code != protocol.ErrSignatureInvalid {
		t.Fatalf("tampered signature code=%q want %q", code, protocol.ErrSignatureInvalid)
	}

	// 交换 body hash 后 canonical bytes 变化，必须拒绝。
	bad := sig
	bad.Signature = signed
	bad.BodyHash = HashBody([]byte("tampered"))
	if err := VerifyTerminalRequest(pub, bad, "term-device-1", "POST", "/v1/daemon/hello"); err == nil {
		t.Fatal("tampered body hash must fail")
	}
}

func protocolErrCode(err error) string {
	apiErr, ok := err.(protocol.APIError)
	if !ok {
		return ""
	}
	return apiErr.Code
}

func TestTerminalSignatureGolden(t *testing.T) {
	seed := bytes.Repeat([]byte{0x42}, ed25519.SeedSize)
	priv := ed25519.NewKeyFromSeed(seed)
	sig := TerminalSignature{
		ProtocolVersion: 1,
		KeyID:           "key-001",
		TimestampMS:     1700000000000,
		Nonce:           "nonce-001",
		BodyHash:        HashBody([]byte(`{"protocol_version":1}`)),
	}
	signed, err := SignTerminalRequest(priv, sig, "term-device-1", "POST", "/v1/daemon/hello")
	if err != nil {
		t.Fatalf("sign golden: %v", err)
	}
	// 该签名由固定 seed 和冻结 canonical bytes 生成，必须保持稳定。
	want := "gnBGL1zi0sX4QnbdfgULpKeUjtYRKvPAG35P5yswV7Z9F3Hgu1i0Th3zPrRZUXp1AWbs/IFsDCkr/ic35iM6Cg"
	if signed != want {
		t.Fatalf("golden signature mismatch:\n got: %s\nwant: %s", signed, want)
	}
}
