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
});
