package daemon

// V092 回归（v0.9.2 P2/P3 真机实测暴露的跨层契约缺陷）。
//
// 缺陷链：Relay 把 session_id 作为命令**顶层**字段下行 → daemon 的 Command
// 结构此前没有 SessionID 字段，投递时丢失 → runner 只从 payload 读 session_id
// → session.resume / start / abort / kill / model_select 等全部以
// 「缺少 session_id」失败（真机上表现为「会话恢复未成功，请先手动恢复会话再发送」）。
// 只有 session.send 因为客户端把 session_id 放进 fixture_payload 才"看起来"可用。

import "testing"

// (a) payload 缺失时回退到命令顶层 session_id（本次修复的核心语义）。
func TestV092SessionIDFallsBackToCommandTopLevel(t *testing.T) {
	cmd := Command{Kind: "session.resume", SessionID: "sess_from_relay",
		PayloadJSON: `{"fixture_payload":{"provider":"dsh"}}`}
	env, err := parseEnvelope(cmd.PayloadJSON)
	if err != nil {
		t.Fatalf("parseEnvelope: %v", err)
	}
	if got := sessionIDFrom(cmd, env); got != "sess_from_relay" {
		t.Fatalf("必须回退到命令顶层 session_id，got %q", got)
	}
}

// (b) payload 显式提供时优先（保持应用既有语义，不被顶层覆盖）。
func TestV092SessionIDPrefersPayload(t *testing.T) {
	cmd := Command{Kind: "session.send", SessionID: "sess_from_relay",
		PayloadJSON: `{"session_id":"sess_from_payload","ciphertext":{"fixture_payload":{"message":"hi"}}}`}
	env, err := parseEnvelope(cmd.PayloadJSON)
	if err != nil {
		t.Fatalf("parseEnvelope: %v", err)
	}
	if got := sessionIDFrom(cmd, env); got != "sess_from_payload" {
		t.Fatalf("payload 的 session_id 必须优先，got %q", got)
	}
}

// (c) 两侧都没有时返回空串（由各命令自己的校验报错，不在这里伪造）。
func TestV092SessionIDEmptyWhenAbsent(t *testing.T) {
	if got := sessionIDFrom(Command{}, nil); got != "" {
		t.Fatalf("无来源时必须返回空串，got %q", got)
	}
	env, _ := parseEnvelope(`{"fixture_payload":{}}`)
	if got := sessionIDFrom(Command{}, env); got != "" {
		t.Fatalf("无来源时必须返回空串，got %q", got)
	}
}
