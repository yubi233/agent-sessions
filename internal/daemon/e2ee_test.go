package daemon

import (
	"encoding/base64"
	"encoding/json"
	"io"
	"log/slog"
	"path/filepath"
	"strings"
	"testing"

	"github.com/yubi233/agent-sessions/internal/adapter"
	contentcrypto "github.com/yubi233/agent-sessions/packages/crypto"
)

func testEventDEK() []byte {
	dek := make([]byte, 32)
	for i := range dek {
		dek[i] = byte(i + 1)
	}
	return dek
}

func eventAAD(sessionID string, event adapter.Event) contentcrypto.AAD {
	return contentcrypto.AAD{
		EntityID:        sessionID,
		EventType:       relayEventType(event.Type),
		ProtocolVersion: daemonProtocolVersion,
		EventSeq:        event.Seq,
	}
}

// P2-C：生产 envelope 必须隐藏 canonical payload，并且可由持有相同 DEK 的端侧按完整 AAD 解密。
func TestE2EEEventEncoderEncryptsVersionedCanonicalEvent(t *testing.T) {
	dek := testEventDEK()
	encoder, err := NewE2EEEventEncoder(dek, "event-key-2026-08")
	if err != nil {
		t.Fatal(err)
	}
	defer encoder.Destroy()
	event := adapter.Event{
		Type: adapter.EventMessageDelta,
		Seq:  7,
		Payload: map[string]any{
			"text": "only-ciphertext-may-contain-this-provider-body",
		},
	}
	raw, err := encoder.Encode("sess-e2ee", event)
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	if strings.Contains(raw, "only-ciphertext-may-contain-this-provider-body") {
		t.Fatalf("event envelope 泄漏 Provider 正文: %s", raw)
	}

	var envelope contentcrypto.Envelope
	if err := json.Unmarshal([]byte(raw), &envelope); err != nil {
		t.Fatalf("decode envelope JSON: %v", err)
	}
	if envelope.PayloadVer != eventPayloadVersion || envelope.KeyID != "event-key-2026-08" {
		t.Fatalf("envelope version/key ID = %d/%q", envelope.PayloadVer, envelope.KeyID)
	}
	plaintext, err := contentcrypto.Open(dek, envelope, eventAAD("sess-e2ee", event))
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	var decoded eventEnvelopePayload
	if err := json.Unmarshal(plaintext, &decoded); err != nil {
		t.Fatalf("decode plaintext: %v", err)
	}
	if decoded.Version != eventPayloadVersion || decoded.Event.Type != event.Type || decoded.Event.Seq != event.Seq || decoded.Event.Payload["text"] != event.Payload["text"] {
		t.Fatalf("decoded canonical event = %+v", decoded)
	}

	// 每条 event 都从 crypto/rand 取得独立 nonce，禁止重放同一个密文包装。
	next, err := encoder.Encode("sess-e2ee", event)
	if err != nil {
		t.Fatalf("second encode: %v", err)
	}
	var nextEnvelope contentcrypto.Envelope
	if err := json.Unmarshal([]byte(next), &nextEnvelope); err != nil {
		t.Fatal(err)
	}
	if nextEnvelope.Nonce == envelope.Nonce {
		t.Fatal("两条生产 event 复用了 nonce")
	}
}

// P2-C：密文不能被移动到其他 session、Relay 事件类型或 canonical 序列。
func TestE2EEEventEncoderRejectsAlteredAAD(t *testing.T) {
	dek := testEventDEK()
	encoder, err := NewE2EEEventEncoder(dek, "event-key-2026-08")
	if err != nil {
		t.Fatal(err)
	}
	defer encoder.Destroy()
	event := adapter.Event{Type: adapter.EventMessageDelta, Seq: 11, Payload: map[string]any{"text": "opaque"}}
	raw, err := encoder.Encode("sess-original", event)
	if err != nil {
		t.Fatal(err)
	}
	var envelope contentcrypto.Envelope
	if err := json.Unmarshal([]byte(raw), &envelope); err != nil {
		t.Fatal(err)
	}

	for name, aad := range map[string]contentcrypto.AAD{
		"session":    eventAAD("sess-other", event),
		"event type": {EntityID: "sess-original", EventType: "message.completed", ProtocolVersion: daemonProtocolVersion, EventSeq: event.Seq},
		"sequence":   {EntityID: "sess-original", EventType: relayEventType(event.Type), ProtocolVersion: daemonProtocolVersion, EventSeq: event.Seq + 1},
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := contentcrypto.Open(dek, envelope, aad); err == nil {
				t.Fatal("篡改 AAD 后仍成功解密")
			}
		})
	}
}

// P2-C：生产密钥配置只允许完整且合法的环境输入；完全缺失才保留旧的事件扣留语义。
func TestLoadE2EEEventEncoderFromEnvFailsClosed(t *testing.T) {
	validDEK := base64.RawStdEncoding.EncodeToString(testEventDEK())
	tests := []struct {
		name    string
		env     map[string]string
		wantNil bool
		wantErr bool
	}{
		{name: "both absent retains withheld events", wantNil: true},
		{name: "DEK without key ID", env: map[string]string{EventDEKEnvironment: validDEK}, wantErr: true},
		{name: "key ID without DEK", env: map[string]string{EventKeyIDEnvironment: "event-key"}, wantErr: true},
		{name: "invalid base64", env: map[string]string{EventDEKEnvironment: "%%%", EventKeyIDEnvironment: "event-key"}, wantErr: true},
		{name: "wrong DEK length", env: map[string]string{EventDEKEnvironment: base64.RawStdEncoding.EncodeToString([]byte("too-short")), EventKeyIDEnvironment: "event-key"}, wantErr: true},
		{name: "invalid key ID", env: map[string]string{EventDEKEnvironment: validDEK, EventKeyIDEnvironment: "line\nbreak"}, wantErr: true},
		{name: "valid raw base64", env: map[string]string{EventDEKEnvironment: validDEK, EventKeyIDEnvironment: "event-key.2026-08"}},
		{name: "valid padded base64", env: map[string]string{EventDEKEnvironment: base64.StdEncoding.EncodeToString(testEventDEK()), EventKeyIDEnvironment: "event-key.2026-08"}},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			encoder, err := LoadE2EEEventEncoderFromEnv(func(key string) string { return tc.env[key] })
			if (err != nil) != tc.wantErr {
				t.Fatalf("err = %v, wantErr=%v", err, tc.wantErr)
			}
			if (encoder == nil) != tc.wantNil && !tc.wantErr {
				t.Fatalf("encoder nil = %v, wantNil=%v", encoder == nil, tc.wantNil)
			}
			if encoder != nil {
				encoder.Destroy()
			}
		})
	}
}

// P2-C：Relay event outbox 只能保存 opaque AES-GCM envelope，不能保存 canonical payload。
func TestRelayEventOutboxStoresOnlyEncryptedEnvelope(t *testing.T) {
	store, err := OpenStore(filepath.Join(t.TempDir(), "daemon.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	encoder, err := NewE2EEEventEncoder(testEventDEK(), "event-key-outbox")
	if err != nil {
		t.Fatal(err)
	}
	defer encoder.Destroy()
	loop := NewRelayLoop(store, nil, nil, encoder, slog.New(slog.NewTextHandler(io.Discard, nil)))
	loop.bindCommand("sess-outbox", "cmd-outbox")
	loop.enqueueCanonicalEvent("sess-outbox", adapter.Event{
		Type: adapter.EventToolResult,
		Seq:  3,
		Payload: map[string]any{
			"output": "provider-body-must-never-reach-relay-outbox-in-plaintext",
		},
	})
	events, err := store.PendingRelayEvents()
	if err != nil {
		t.Fatal(err)
	}
	if len(events) != 1 {
		t.Fatalf("pending event count = %d, want 1", len(events))
	}
	stored := events[0]
	if strings.Contains(stored.EnvelopeJSON, "provider-body-must-never-reach-relay-outbox-in-plaintext") {
		t.Fatalf("relay event outbox 泄漏明文: %s", stored.EnvelopeJSON)
	}
	var envelope contentcrypto.Envelope
	if err := json.Unmarshal([]byte(stored.EnvelopeJSON), &envelope); err != nil {
		t.Fatalf("outbox envelope JSON: %v", err)
	}
	if envelope.Ciphertext == "" || envelope.Nonce == "" || envelope.AADHash == "" {
		t.Fatalf("outbox 不包含完整 opaque envelope: %+v", envelope)
	}
	if _, err := contentcrypto.Open(testEventDEK(), envelope, eventAAD("sess-outbox", adapter.Event{Type: adapter.EventToolResult, Seq: 3})); err != nil {
		t.Fatalf("outbox envelope 不能按正确 AAD 解密: %v", err)
	}

	// 该断言刻意读取 SQLite 原始列，防止 Store API 未来无意把明文扩展进 outbox schema。
	var raw string
	if err := store.db.QueryRow(`SELECT envelope_json FROM relay_event_outbox WHERE event_id=?`, stored.EventID).Scan(&raw); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(raw, "provider-body-must-never-reach-relay-outbox-in-plaintext") {
		t.Fatal("SQLite relay_event_outbox 包含 Provider 明文")
	}
}
