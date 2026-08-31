import { afterEach, describe, expect, it, vi } from "vitest";
import { sessionState } from "./session";
import { fetchChatSnapshot, sendMessage, startSession } from "./chat";

afterEach(() => {
  vi.unstubAllGlobals();
  sessionState.token = "";
});

describe("web chat write/read helpers", () => {
  it("fetchChatSnapshot 只解析本地开发明文信封为对话消息", async () => {
    sessionState.token = "tok";
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue({
        ok: true,
        json: async () => ({
          session: { id: "s1", status: "idle", last_seq: 4 },
          events: [
            {
              event_seq: 2,
              event_type: "message.updated",
              envelope: {
                alg: "local-dev-fixture",
                fixture_payload: { kind: "user_message", text: "你好" },
              },
            },
            {
              event_seq: 3,
              event_type: "message.updated",
              envelope: {
                alg: "local-dev-fixture",
                fixture_payload: {
                  kind: "assistant_message",
                  text: "你好，有什么可以帮你？",
                },
              },
            },
          ],
        }),
      }),
    );

    const snapshot = await fetchChatSnapshot("s1");
    expect(snapshot.messages).toEqual([
      { seq: 2, role: "user", text: "你好", streaming: false },
      { seq: 3, role: "assistant", text: "你好，有什么可以帮你？", streaming: false },
    ]);
  });

  it("startSession/sendMessage 按 Relay command payload 契约提交", async () => {
    sessionState.token = "tok";
    const fetchMock = vi.fn().mockResolvedValue({
      ok: true,
      json: async () => ({ id: "cmd", kind: "session.start", status: "accepted" }),
    });
    vi.stubGlobal("fetch", fetchMock);

    await startSession("s1", 1, "dsh");
    let body = JSON.parse(fetchMock.mock.calls[0][1].body as string);
    expect(body.kind).toBe("session.start");
    expect(body.lease_epoch).toBe(1);
    expect(body.ciphertext.ciphertext.fixture_payload.provider).toBe("dsh");

    await sendMessage("s1", 1, "你好");
    body = JSON.parse(fetchMock.mock.calls[1][1].body as string);
    expect(body.kind).toBe("session.send");
    expect(body.ciphertext.ciphertext.fixture_payload.message).toBe("你好");
  });
});