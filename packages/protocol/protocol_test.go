package protocol

import (
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func fixture(t *testing.T, name string) []byte {
	t.Helper()
	_, file, _, _ := runtime.Caller(0)
	path := filepath.Join(filepath.Dir(file), "testdata", name)
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

func TestParseEnvelopeGolden(t *testing.T) {
	env, err := ParseEnvelope(fixture(t, "envelope-ok.json"))
	if err != nil {
		t.Fatal(err)
	}
	if env.MessageType != MessageTypeEvent || env.LeaseEpoch != 3 {
		t.Fatalf("unexpected envelope: %+v", env)
	}
}

func TestRejectUnknownProtocolVersion(t *testing.T) {
	_, err := ParseEnvelope(fixture(t, "envelope-bad-version.json"))
	if err == nil {
		t.Fatal("expected protocol version mismatch")
	}
}

func TestRejectUnknownPayloadVersion(t *testing.T) {
	env := Envelope{
		ProtocolVersion: 1,
		MessageType:     MessageTypeEvent,
		MessageID:       "m1",
		TraceID:         "t1",
		PayloadVersion:  0,
		Payload:         map[string]any{},
	}
	if err := env.Validate(); err == nil {
		t.Fatal("expected unknown payload version")
	}
}

func TestDeviceRoleCanWrite(t *testing.T) {
	if !DeviceRoleCanWrite(RoleAndroidOwner) || !DeviceRoleCanWrite(RoleWeb) || DeviceRoleCanWrite(RoleAdmin) {
		t.Fatal("write role contract broken")
	}
}
