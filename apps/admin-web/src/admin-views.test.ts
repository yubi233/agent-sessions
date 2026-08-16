import { flushPromises, mount } from "@vue/test-utils";
import { afterEach, describe, expect, it, vi } from "vitest";
import TerminalsView from "./views/TerminalsView.vue";
import SessionsView from "./views/SessionsView.vue";
import AuditView from "./views/AuditView.vue";
import { router } from "./router";
import { adminSessionState } from "./session";

// P4 Admin 分区组件回归（ADMIN-03/ADMIN-04）：
// 终端/会话/审计分区只读展示白名单脱敏元数据，无写入口。

describe("ADMIN-03 终端分区", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
    adminSessionState.token = "";
  });

  it("未登录时提示，不发起请求", async () => {
    const fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);
    const wrapper = mount(TerminalsView, { global: { plugins: [router] } });
    await flushPromises();
    expect(wrapper.get('[data-testid="terminals-error"]').text()).toContain(
      "尚未登录",
    );
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("登录后展示终端白名单，无重启写入口", async () => {
    adminSessionState.token = "tok";
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
    expect(list.text()).toContain("0.4.0");
    expect(
      wrapper.find('[data-testid*="restart"], [data-testid*="reboot"]').exists(),
    ).toBe(false);
    expect(wrapper.find("input").exists()).toBe(false);
  });
});

describe("ADMIN-01 会话分区", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
    adminSessionState.token = "";
  });

  it("展示会话白名单元数据，无正文", async () => {
    adminSessionState.token = "tok";
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue({
        ok: true,
        json: async () => ({
          sessions: [{ id: "s1", status: "running", provider: "codex", last_seq: 7 }],
        }),
      }),
    );
    const wrapper = mount(SessionsView, { global: { plugins: [router] } });
    await flushPromises();
    const list = wrapper.get('[data-testid="sessions-list"]');
    expect(list.text()).toContain("codex");
    expect(list.text()).toContain("running");
    expect(wrapper.text()).not.toContain("secret");
    expect(wrapper.find("textarea").exists()).toBe(false);
  });
});

describe("ADMIN-04 审计分区", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
    adminSessionState.token = "";
  });

  it("分页展示脱敏审计记录并可翻页", async () => {
    adminSessionState.token = "tok";
    // 第一页 25 条（>= limit 20），第二页 5 条；下一页按钮随数据长度启用/禁用。
    const makeEntries = (start: number, count: number) =>
      Array.from({ length: count }, (_, i) => ({
        id: start + i,
        action: `session.updated`,
        metadata: `{"seq":${start + i}}`,
      }));
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({ audit: makeEntries(0, 25) }),
      })
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({ audit: makeEntries(20, 5) }),
      });
    vi.stubGlobal("fetch", fetchMock);
    const wrapper = mount(AuditView, { global: { plugins: [router] } });
    await flushPromises();
    expect(wrapper.get('[data-testid="audit-list"]').text()).toContain(
      "session.updated",
    );
    // 首页不允许上一页，下一页可用（25 条 >= limit 20）。
    expect(
      wrapper.get('[data-testid="audit-prev"]').attributes("disabled"),
    ).toBeDefined();
    expect(
      wrapper.get('[data-testid="audit-next"]').attributes("disabled"),
    ).toBeUndefined();
    await wrapper.get('[data-testid="audit-next"]').trigger("click");
    await flushPromises();
    expect(fetchMock).toHaveBeenCalledTimes(2);
    expect(wrapper.get('[data-testid="audit-list"]').text()).toContain('"seq":20');
  });

  it("审计页不展示密钥、路径或消息正文", async () => {
    adminSessionState.token = "tok";
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue({
        ok: true,
        json: async () => ({
          audit: [{ id: 1, action: "session.updated", metadata: '{"seq":1}' }],
        }),
      }),
    );
    const wrapper = mount(AuditView, { global: { plugins: [router] } });
    await flushPromises();
    expect(wrapper.text()).not.toContain("password");
    expect(wrapper.text()).not.toContain("/Users/");
    expect(wrapper.text()).not.toContain("Bearer");
    expect(wrapper.find("input").exists()).toBe(false);
  });
});
