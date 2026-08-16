import { flushPromises, mount } from "@vue/test-utils";
import { afterEach, describe, expect, it, vi } from "vitest";
import SessionsView from "./views/SessionsView.vue";
import SessionDetailView from "./views/SessionDetailView.vue";
import SessionFilesView from "./views/SessionFilesView.vue";
import SessionGitView from "./views/SessionGitView.vue";
import TerminalsView from "./views/TerminalsView.vue";
import { router } from "./router";
import { sessionState } from "./session";

// P4 Web 只读闭环的组件级回归（WEB-01/WEB-03/WEB-05）：
// 会话列表/详情/文件/Git 降级与终端状态全部只读展示白名单元数据。

describe("P4 会话列表页", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
    sessionState.token = "";
  });

  it("WEB-01：未登录时提示先完成只读登录，不发起任何请求", async () => {
    const fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);
    const wrapper = mount(SessionsView, { global: { plugins: [router] } });
    await flushPromises();
    expect(wrapper.get('[data-testid="sessions-error"]').text()).toContain(
      "尚未登录",
    );
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("WEB-01：登录后展示会话白名单列表并可刷新", async () => {
    sessionState.token = "tok";
    const fetchMock = vi.fn().mockResolvedValue({
      ok: true,
      json: async () => ({
        sessions: [
          { id: "s1", workspace_id: "w1", status: "streaming", provider: "codex", last_seq: 12 },
          { id: "s2", workspace_id: "w2", status: "idle", provider: "claude", last_seq: 3 },
        ],
      }),
    });
    vi.stubGlobal("fetch", fetchMock);
    const wrapper = mount(SessionsView, { global: { plugins: [router] } });
    await flushPromises();
    expect(wrapper.find('[data-testid="sessions-list"]').exists()).toBe(true);
    expect(wrapper.get('[data-testid="session-link-s1"]').text()).toContain(
      "codex",
    );
    expect(wrapper.get('[data-testid="session-link-s2"]').text()).toContain(
      "claude",
    );
    // 无写入口：列表页不渲染任何按钮（除刷新）或表单。
    expect(wrapper.find("input").exists()).toBe(false);
    expect(wrapper.find("textarea").exists()).toBe(false);
  });

  it("WEB-01：空列表显示空态", async () => {
    sessionState.token = "tok";
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue({ ok: true, json: async () => ({ sessions: [] }) }),
    );
    const wrapper = mount(SessionsView, { global: { plugins: [router] } });
    await flushPromises();
    expect(wrapper.find('[data-testid="sessions-empty"]').exists()).toBe(true);
  });

  it("WEB-01：读取失败显示可重试错误", async () => {
    sessionState.token = "tok";
    vi.stubGlobal("fetch", vi.fn().mockRejectedValue(new Error("offline")));
    const wrapper = mount(SessionsView, { global: { plugins: [router] } });
    await flushPromises();
    expect(wrapper.get('[data-testid="sessions-error"]').text()).toContain(
      "无法读取会话列表",
    );
  });
});

describe("P4 会话详情页", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
    sessionState.token = "";
  });

  it("WEB-01：展示白名单元数据与密文事件序号，不解密 envelope", async () => {
    sessionState.token = "tok";
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue({
        ok: true,
        json: async () => ({
          status: "streaming",
          provider: "codex",
          last_seq: 5,
          events: [
            { event_seq: 4, event_type: "message.updated", envelope: { opaque: true } },
            { event_seq: 5, event_type: "command.updated", envelope: { opaque: true } },
          ],
        }),
      }),
    );
    const wrapper = mount(SessionDetailView, {
      global: { plugins: [router] },
    });
    // 手动设置路由参数（hash 路由下直接 mount 时 params 为空）。
    router.push("/sessions/abc");
    await router.isReady();
    await flushPromises();
    expect(wrapper.get('[data-testid="session-detail-status"]').text()).toBe(
      "streaming",
    );
    expect(wrapper.get('[data-testid="session-detail-events"]').text()).toContain(
      "#4 message.updated",
    );
    // 不展示 envelope 正文（密文不泄露）。
    expect(wrapper.text()).not.toContain("opaque");
    // 无写控件。
    expect(wrapper.find("textarea").exists()).toBe(false);
  });

  it("WEB-03：文件与 Git 入口明确 unavailable，不伪造列表", async () => {
    sessionState.token = "tok";
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue({
        ok: true,
        json: async () => ({ status: "idle", provider: "codex", last_seq: 0, events: [] }),
      }),
    );
    const files = mount(SessionFilesView, {
      global: { plugins: [router] },
    });
    const git = mount(SessionGitView, { global: { plugins: [router] } });
    await flushPromises();
    expect(files.get('[data-testid="files-unavailable"]').text()).toContain(
      "尚未接入该 transport",
    );
    expect(git.get('[data-testid="git-unavailable"]').text()).toContain(
      "尚未接入该 transport",
    );
    expect(files.text()).not.toContain("README.md");
  });
});

describe("P4 终端状态页", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
    sessionState.token = "";
  });

  it("WEB-01：展示终端白名单状态，无写入口", async () => {
    sessionState.token = "tok";
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue({
        ok: true,
        json: async () => ({
          terminals: [
            {
              id: "t1",
              hostname: "MacBook",
              platform: "macos",
              status: "online",
              protocol_version: 1,
              daemon_version: "0.4.0",
            },
          ],
        }),
      }),
    );
    const wrapper = mount(TerminalsView, { global: { plugins: [router] } });
    await flushPromises();
    const list = wrapper.get('[data-testid="terminals-list"]');
    expect(list.text()).toContain("MacBook");
    expect(list.text()).toContain("macos");
    expect(list.text()).toContain("0.4.0");
    // 只允许「刷新」按钮；无登录表单或任何写控件。
    expect(wrapper.find("input").exists()).toBe(false);
    expect(wrapper.find("textarea").exists()).toBe(false);
  });

  it("WEB-01：读取失败显示错误", async () => {
    sessionState.token = "tok";
    vi.stubGlobal("fetch", vi.fn().mockRejectedValue(new Error("offline")));
    const wrapper = mount(TerminalsView, { global: { plugins: [router] } });
    await flushPromises();
    expect(wrapper.get('[data-testid="terminals-error"]').text()).toContain(
      "无法读取终端状态",
    );
  });
});
