package daemon

// V092 回归（v0.9.2 P2/P3 真机实测暴露的跨层契约缺陷）：Relay 下行命令的 payload
// 必须让 runner 能解析出 session_id 与 fixture 载荷。
//
// 缺陷（两处同源错位）：
//   1. Relay 把 session_id/workspace_id 放在 command 的**顶层**，而 runner 从
//      payload 顶层读它 → 除 session.send 外的会话命令一律「缺少 session_id」；
//   2. Relay 下发的 ciphertext 是命令**子对象**（fixture_payload 形态），而
//      parseEnvelope 期望完整 envelope → model/effort 等字段读不到。
//
// 修复口径：Daemon 侧补 envelope 层 + 注入顶层字段（不覆盖已有值），并在
// Command 上保留 SessionID 作为字段级兜底（sessionIDFrom）。

import (
	"encoding/json"
	"testing"
)

// (a) Relay 只给命令子对象时：必须补 envelope 层，且 session_id 与 fixture 载荷可用。
func TestV092CommandPayloadBuildsEnvelopeForRunner(t *testing.T) {
	wire := RelayCommandWire{
		ID: "cmd_1", SessionID: "sess_1", WorkspaceID: "ws_1", Kind: "session.model_select",
		Ciphertext: json.RawMessage(`{"fixture_payload":{"model":"dsh:model:x:y"}}`),
	}
	payload := commandPayloadJSON(wire)
	env, err := parseEnvelope(payload)
	if err != nil {
		t.Fatalf("合并后的 payload 必须可解析: %v (%s)", err, payload)
	}
	if got := sessionIDFrom(Command{SessionID: "sess_1"}, env); got != "sess_1" {
		t.Fatalf("session_id 必须可用，got %q（payload=%s）", got, payload)
	}
	if env.Ciphertext == nil || env.Ciphertext.FixturePayload == nil {
		t.Fatalf("必须补出 ciphertext.fixture_payload 层: %s", payload)
	}
	if got := env.model(); got != "dsh:model:x:y" {
		t.Fatalf("fixture 载荷的 model 必须可读，got %q（payload=%s）", got, payload)
	}
}

// (b) 已经是完整 envelope 的输入必须原样使用（幂等，重复投递安全）。
func TestV092CommandPayloadKeepsExistingEnvelope(t *testing.T) {
	raw := `{"session_id":"sess_payload","ciphertext":{"fixture_payload":{"message":"hi"}}}`
	payload := commandPayloadJSON(RelayCommandWire{SessionID: "sess_relay", Ciphertext: json.RawMessage(raw)})
	env, err := parseEnvelope(payload)
	if err != nil {
		t.Fatalf("parseEnvelope: %v", err)
	}
	if env.sessionID() != "sess_payload" {
		t.Fatalf("payload 已有 session_id 必须优先，got %q", env.sessionID())
	}
	if env.Ciphertext == nil || env.Ciphertext.FixturePayload == nil || env.Ciphertext.FixturePayload.Message != "hi" {
		t.Fatalf("既有 envelope 不得被再次包裹: %s", payload)
	}
}

// (c) 边界：空 / 非 JSON / 非对象输入原样返回，交由既有解析路径报错。
func TestV092CommandPayloadPassesThroughInvalidInput(t *testing.T) {
	if got := commandPayloadJSON(RelayCommandWire{SessionID: "s"}); got != "" {
		t.Fatalf("空 ciphertext 必须原样返回空串，got %q", got)
	}
	for _, raw := range []string{"not-json", "[1,2,3]"} {
		if got := commandPayloadJSON(RelayCommandWire{SessionID: "s", Ciphertext: json.RawMessage(raw)}); got != raw {
			t.Fatalf("非对象输入 %q 必须原样返回，got %q", raw, got)
		}
	}
}
