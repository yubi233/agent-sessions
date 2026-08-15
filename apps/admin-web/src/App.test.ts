import { flushPromises, mount } from "@vue/test-utils";
import { afterEach, describe, expect, it, vi } from "vitest";
import App from "./App.vue";
import { clearThemePreferenceForTest } from "./theme";

describe("Admin 运维只读控制台", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
    clearThemePreferenceForTest();
  });

  it("ADMIN-01：就绪后展示健康状态", async () => {
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue({ ok: true }));
    const wrapper = mount(App);
    await flushPromises();
    expect(wrapper.get('[data-testid="relay-ready"]').text()).toContain("就绪");
  });

  it("ADMIN-01/02：登录后只展示脱敏设备与会话元数据", async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce({ ok: true }) // readyz
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({ access_token: "tok" }),
      }) // login
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({
          devices: [
            {
              id: "d1",
              role: "android_owner",
              display_name: "Android",
              status: "active",
            },
          ],
        }),
      }) // devices
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({
          sessions: [{ id: "s1", provider: "mock", status: "running" }],
        }),
      }); // sessions
    vi.stubGlobal("fetch", fetchMock);
    const wrapper = mount(App);

    await wrapper.get('[data-testid="login-email"]').setValue("admin@b.dev");
    await wrapper.get('[data-testid="login-password"]').setValue("pw");
    await wrapper.get('form[data-testid="login-form"]').trigger("submit");
    await flushPromises();

    expect(wrapper.get('[data-testid="auth-ok"]').text()).toContain("运维只读");
    expect(wrapper.get('[data-testid="device-list"]').text()).toContain(
      "Android",
    );
    expect(wrapper.get('[data-testid="session-list"]').text()).toContain(
      "mock",
    );
  });

  it("ADMIN-01：空状态展示占位", async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce({ ok: true }) // readyz
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({ access_token: "tok" }),
      }) // login
      .mockResolvedValueOnce({ ok: true, json: async () => ({ devices: [] }) }) // devices
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({ sessions: [] }),
      }); // sessions
    vi.stubGlobal("fetch", fetchMock);
    const wrapper = mount(App);
    await wrapper.get('[data-testid="login-email"]').setValue("a@b.dev");
    await wrapper.get('[data-testid="login-password"]').setValue("pw");
    await wrapper.get('form[data-testid="login-form"]').trigger("submit");
    await flushPromises();
    expect(wrapper.find('[data-testid="device-empty"]').exists()).toBe(true);
    expect(wrapper.find('[data-testid="session-empty"]').exists()).toBe(true);
  });

  it("ADMIN-06：主题菜单有可访问名称并切换语义主题", async () => {
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue({ ok: true }));
    const wrapper = mount(App);
    await flushPromises();

    const control = wrapper.get('[data-testid="theme-select"]');
    expect(control.attributes("aria-label")).toBe("外观");
    await control.setValue("dark");
    await flushPromises();

    expect(document.documentElement.dataset.theme).toBe("dark");
    expect(document.documentElement.dataset.themePreference).toBe("dark");
  });
});
