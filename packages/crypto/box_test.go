package crypto

import (
	"crypto/ecdh"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func testdata(name string) string {
	_, file, _, _ := runtime.Caller(0)
	return filepath.Join(filepath.Dir(file), "testdata", name)
}

func TestGoldenVectors(t *testing.T) {
	raw, err := os.ReadFile(testdata("vectors.json"))
	if err != nil {
		t.Fatal(err)
	}
	var vectors []Vector
	if err := json.Unmarshal(raw, &vectors); err != nil {
		t.Fatal(err)
	}
	if len(vectors) < 4 {
		t.Fatalf("need at least 4 vectors, got %d", len(vectors))
	}
	for _, v := range vectors {
		t.Run(v.Name, func(t *testing.T) {
			// dek-wrap-v1 向量由 TestDEKWrapGoldenVector 单独消费（无 DEKHex/Envelope）。
			if v.DEKHex == "" {
				return
			}
			dek, err := hex.DecodeString(v.DEKHex)
			if err != nil {
				t.Fatal(err)
			}
			env := v.Envelope
			switch v.TamperField {
			case "ciphertext":
				env.Ciphertext = env.Ciphertext + "AA"
			case "aad":
				v.AAD.EventSeq++
			case "key_id":
				v.AAD.KeyID = "wrong-key"
				env.KeyID = "wrong-key"
			}
			pt, err := Open(dek, env, v.AAD)
			if v.ExpectOK {
				if err != nil {
					t.Fatalf("expected ok: %v", err)
				}
				if string(pt) != v.Plaintext {
					t.Fatalf("plaintext mismatch: %q", pt)
				}
				return
			}
			if err == nil {
				t.Fatal("expected decrypt failure")
			}
		})
	}
}

func TestWrapUnwrapDEK(t *testing.T) {
	alice, err := GenerateDeviceKeys()
	if err != nil {
		t.Fatal(err)
	}
	bob, err := GenerateDeviceKeys()
	if err != nil {
		t.Fatal(err)
	}
	dek, err := RandomDEK()
	if err != nil {
		t.Fatal(err)
	}
	nonce, wrapped, err := WrapDEK(alice.EncryptPrivate, bob.EncryptPublic, dek)
	if err != nil {
		t.Fatal(err)
	}
	got, err := UnwrapDEK(bob.EncryptPrivate, alice.EncryptPublic, nonce, wrapped)
	if err != nil {
		t.Fatal(err)
	}
	if hex.EncodeToString(got) != hex.EncodeToString(dek) {
		t.Fatal("dek wrap mismatch")
	}
}

// TestDEKWrapGoldenVector 验证共享 vectors.json 的 dek-wrap-v1 载荷：
// owner 私钥（base64url）解开 wrapped payload 还原期望 DEK——同一向量被
// 移动端 crypto_box_test 消费，保证 Go wrap 与 Dart unwrap 跨端互操作。
func TestDEKWrapGoldenVector(t *testing.T) {
	raw, err := os.ReadFile(testdata("vectors.json"))
	if err != nil {
		t.Fatal(err)
	}
	var all []struct {
		Name        string `json:"name"`
		OwnerPriv   string `json:"owner_private_key_b64url"`
		Payload     string `json:"wrapped_dek_payload_b64url"`
		ExpectedDEK string `json:"expected_dek"`
	}
	if err := json.Unmarshal(raw, &all); err != nil {
		t.Fatal(err)
	}
	for _, v := range all {
		if v.Name != "dek-wrap-v1" {
			continue
		}
		ownerPrivBytes, err := base64.RawURLEncoding.DecodeString(v.OwnerPriv)
		if err != nil {
			t.Fatal(err)
		}
		payload, err := base64.RawURLEncoding.DecodeString(v.Payload)
		if err != nil {
			t.Fatal(err)
		}
		ownerPriv, err := ecdh.X25519().NewPrivateKey(ownerPrivBytes)
		if err != nil {
			t.Fatal(err)
		}
		senderPub, err := ecdh.X25519().NewPublicKey(payload[:32])
		if err != nil {
			t.Fatal(err)
		}
		dek, err := UnwrapDEK(ownerPriv, senderPub, payload[32:44], payload[44:])
		if err != nil {
			t.Fatalf("unwrap: %v", err)
		}
		if string(dek) != v.ExpectedDEK {
			t.Fatalf("dek mismatch: %q", dek)
		}
	}
}

func TestSealOpenRoundtrip(t *testing.T) {
	dek := make([]byte, 32)
	for i := range dek {
		dek[i] = byte(i + 1)
	}
	aad := AAD{EntityID: "sess-1", EventType: "message.delta", ProtocolVersion: 1, EventSeq: 1}
	nonce := make([]byte, 12)
	env, err := Seal(dek, "k1", 1, aad, []byte("hello"), nonce)
	if err != nil {
		t.Fatal(err)
	}
	pt, err := Open(dek, env, aad)
	if err != nil {
		t.Fatal(err)
	}
	if string(pt) != "hello" {
		t.Fatalf("got %q", pt)
	}
}
