import { flushPromises, mount } from "@vue/test-utils";
import { afterEach, describe, expect, it, vi } from "vitest";
import App from "./App.vue";

describe("Relay 状态页", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("P0-DEPLOY-01：Relay 就绪后展示成功状态，重试会再次请求", async () => {
    const fetchMock = vi.fn().mockResolvedValue({ ok: true });
    vi.stubGlobal("fetch", fetchMock);
    const wrapper = mount(App);

    await flushPromises();
    expect(wrapper.get('[data-testid="relay-ready"]').text()).toContain("Relay 已就绪");
    await wrapper.get('[data-testid="refresh-health"]').trigger("click");
    await flushPromises();
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  it("P0-DEPLOY-01：Relay 不可用时展示可恢复错误", async () => {
    vi.stubGlobal("fetch", vi.fn().mockRejectedValue(new Error("offline")));
    const wrapper = mount(App);

    await flushPromises();
    expect(wrapper.get('[data-testid="relay-error"]').text()).toContain("无法连接 Relay");
  });

  it("WEB-01：登录后只读展示设备、会话与能力矩阵", async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce({ ok: true }) // readyz
      .mockResolvedValueOnce({ ok: true, json: async () => ({ access_token: "tok" }) }) // login
      .mockResolvedValueOnce({ ok: true, json: async () => ({ devices: [{ id: "d1", role: "android_owner", display_name: "Android", status: "active" }] }) }) // devices
      .mockResolvedValueOnce({ ok: true, json: async () => ({ sessions: [{ id: "s1", provider: "mock", status: "running" }] }) }) // sessions
      .mockResolvedValueOnce({ ok: true, json: async () => ({ providers: [{ kind: "claude", version: "", capabilities: [] }] }) }); // capabilities
    vi.stubGlobal("fetch", fetchMock);
    const wrapper = mount(App);

    await wrapper.get('[data-testid="login-email"]').setValue("a@b.dev");
    await wrapper.get('[data-testid="login-password"]').setValue("pw");
    await wrapper.get('form[data-testid="login-form"]').trigger("submit");
    await flushPromises();

    expect(wrapper.get('[data-testid="auth-ok"]').text()).toContain("已登录");
    expect(wrapper.get('[data-testid="device-list"]').text()).toContain("Android");
    expect(wrapper.get('[data-testid="session-list"]').text()).toContain("mock");
    expect(wrapper.get('[data-testid="capability-list"]').text()).toContain("claude");
  });
});
