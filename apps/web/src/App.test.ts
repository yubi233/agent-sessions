import { flushPromises, mount } from "@vue/test-utils";
import { afterEach, describe, expect, it, vi } from "vitest";
import App from "./App.vue";
import HomeView from "./views/HomeView.vue";
import CapabilitiesView from "./views/CapabilitiesView.vue";
import { router } from "./router";
import { sessionState } from "./session";
import { clearThemePreferenceForTest } from "./theme";

describe("Relay 状态页", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
    sessionState.token = "";
    clearThemePreferenceForTest();
  });

  function mountHome() {
    return mount(HomeView, { global: { plugins: [router] } });
  }

  it("P0-DEPLOY-01：Relay 就绪后展示成功状态，重试会再次请求", async () => {
    const fetchMock = vi.fn().mockResolvedValue({ ok: true });
    vi.stubGlobal("fetch", fetchMock);
    const wrapper = mountHome();

    await flushPromises();
    expect(wrapper.get('[data-testid="relay-ready"]').text()).toContain(
      "Relay 已就绪",
    );
    await wrapper.get('[data-testid="refresh-health"]').trigger("click");
    await flushPromises();
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  it("P0-DEPLOY-01：Relay 不可用时展示可恢复错误", async () => {
    vi.stubGlobal("fetch", vi.fn().mockRejectedValue(new Error("offline")));
    const wrapper = mountHome();

    await flushPromises();
    expect(wrapper.get('[data-testid="relay-error"]').text()).toContain(
      "无法连接 Relay",
    );
  });

  it("WEB-01：登录后只读展示设备、会话与能力矩阵摘要", async () => {
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
      }) // sessions
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({
          providers: [{ kind: "claude", version: "", capabilities: [] }],
        }),
      }); // capabilities
    vi.stubGlobal("fetch", fetchMock);
    const wrapper = mountHome();

    await wrapper.get('[data-testid="login-email"]').setValue("a@b.dev");
    await wrapper.get('[data-testid="login-password"]').setValue("pw");
    await wrapper.get('form[data-testid="login-form"]').trigger("submit");
    await flushPromises();

    expect(wrapper.get('[data-testid="auth-ok"]').text()).toContain("已登录");
    expect(wrapper.get('[data-testid="device-list"]').text()).toContain(
      "Android",
    );
    expect(wrapper.get('[data-testid="session-list"]').text()).toContain(
      "mock",
    );
    expect(wrapper.get('[data-testid="capability-list"]').text()).toContain(
      "claude",
    );
    expect(wrapper.find('[data-testid="capabilities-link"]').exists()).toBe(
      true,
    );
  });

  it("WEB-06：主题菜单使用语义选择器并保持可访问标签", async () => {
    await router.push("/");
    await router.isReady();
    const wrapper = mount(App, { global: { plugins: [router] } });
    await flushPromises();

    const control = wrapper.get('[data-testid="theme-select"]');
    expect(control.attributes("aria-label")).toBe("外观");
    await control.setValue("dark");
    await flushPromises();

    expect(document.documentElement.dataset.theme).toBe("dark");
    expect(document.documentElement.dataset.themePreference).toBe("dark");
  });

  it("V081-08：Web 不注册对话写入路由或导航入口", async () => {
    await router.push("/");
    await router.isReady();
    const wrapper = mount(App, { global: { plugins: [router] } });
    await flushPromises();

    expect(wrapper.find('a[href="#/chat"]').exists()).toBe(false);
    expect(wrapper.get('a[href="#/sessions"]').text()).toBe("工作区");
    expect(router.getRoutes().some((route) => route.path === "/chat")).toBe(
      false,
    );
  });
});

describe("能力矩阵视图", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
    sessionState.token = "";
  });

  it("E2E-OPENCODE-01：矩阵展示 provider/version/available 与三态 capability", async () => {
    sessionState.token = "tok";
    const providers = [
      {
        kind: "opencode",
        version: "1.17.13",
        available: true,
        capabilities: [
          { name: "start", status: "native" },
          { name: "resume", status: "native" },
          { name: "abort", status: "native" },
          { name: "permission", status: "unsupported", reason: "未实现" },
        ],
      },
    ];
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce({ ok: true, json: async () => ({ providers }) });
    vi.stubGlobal("fetch", fetchMock);
    const wrapper = mount(CapabilitiesView, { global: { plugins: [router] } });
    await flushPromises();

    expect(wrapper.find('[data-testid="matrix-ok"]').exists()).toBe(true);
    expect(wrapper.find('[data-testid="capability-matrix"]').exists()).toBe(
      true,
    );
    expect(
      wrapper.find('[data-testid="matrix-provider-row-opencode"]').exists(),
    ).toBe(true);
    expect(wrapper.get('[data-testid="matrix-version-opencode"]').text()).toBe(
      "1.17.13",
    );
    expect(
      wrapper.get('[data-testid="matrix-available-opencode"]').text(),
    ).toBe("可用");
    expect(
      wrapper
        .get('[data-testid="matrix-cap-opencode-start"]')
        .attributes("data-status"),
    ).toBe("native");
    expect(
      wrapper
        .get('[data-testid="matrix-cap-opencode-resume"]')
        .attributes("data-status"),
    ).toBe("native");
    expect(
      wrapper
        .get('[data-testid="matrix-cap-opencode-abort"]')
        .attributes("data-status"),
    ).toBe("native");
    expect(
      wrapper
        .get('[data-testid="matrix-cap-opencode-permission"]')
        .attributes("data-status"),
    ).toBe("unsupported");
  });

  it("E2E-OPENCODE-01：矩阵页没有任何写入口（无发送/审批按钮）", async () => {
    sessionState.token = "tok";
    vi.stubGlobal(
      "fetch",
      vi
        .fn()
        .mockResolvedValue({ ok: true, json: async () => ({ providers: [] }) }),
    );
    const wrapper = mount(CapabilitiesView, { global: { plugins: [router] } });
    await flushPromises();

    for (const testId of [
      "session-send",
      "approve-pairing",
      "revoke-device",
      "delegation-approve",
      "command-submit",
    ]) {
      expect(wrapper.find(`[data-testid="${testId}"]`).exists()).toBe(false);
    }
  });

  it("E2E-OPENCODE-01：未登录时提示登录且不发请求", async () => {
    const fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);
    const wrapper = mount(CapabilitiesView, { global: { plugins: [router] } });
    await flushPromises();

    expect(wrapper.find('[data-testid="matrix-no-token"]').exists()).toBe(true);
    expect(fetchMock).not.toHaveBeenCalled();
  });
});
