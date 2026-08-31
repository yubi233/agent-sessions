import { flushPromises, mount } from "@vue/test-utils";
import { afterEach, describe, expect, it, vi } from "vitest";
import SessionsView from "./views/SessionsView.vue";
import SessionDetailView from "./views/SessionDetailView.vue";
import SessionFilesView from "./views/SessionFilesView.vue";
import SessionGitView from "./views/SessionGitView.vue";
import TerminalsView from "./views/TerminalsView.vue";
import { router } from "./router";
import { requestWebRead } from "./read_transport";
import {
  decodeSessionSnapshot,
  mergeSessionEventMeta,
  sessionState,
  startAccountEventStream,
} from "./session";

vi.mock("./read_transport", async () => {
  const actual = await vi.importActual<typeof import("./read_transport")>("./read_transport");
  return { ...actual, requestWebRead: vi.fn() };
});

const requestWebReadMock = vi.mocked(requestWebRead);

// P4 Web 只读闭环的组件级回归（WEB-01/WEB-03/WEB-05）：
// 会话列表/详情/文件/Git 降级与终端状态全部只读展示白名单元数据。

describe("P4 会话列表页", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
    requestWebReadMock.mockReset();
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

  it("V08-11/V08-15：DSH 模式按工作区分组且无写入口", async () => {
    sessionState.token = "tok";
    const fetchMock = vi.fn().mockImplementation(async (url: string) => {
      if (url.includes("/v1/workspaces")) {
        return {
          ok: true,
          json: async () => ({
            workspaces: [
              { id: "w-dsh-1", project_id: "project-alpha", terminal_id: "t1" },
              { id: "w-dsh-2", project_id: "project-beta", terminal_id: "t1" },
            ],
          }),
        };
      }
      return {
        ok: true,
        json: async () => ({
          sessions: [
            { id: "s1", workspace_id: "w-dsh-1", status: "idle", provider: "dsh", last_seq: 1 },
            { id: "s2", workspace_id: "w-dsh-1", status: "idle", provider: "dsh", last_seq: 2 },
            { id: "s3", workspace_id: "w-dsh-2", status: "idle", provider: "dsh", last_seq: 1 },
            { id: "s4", workspace_id: "w-other", status: "idle", provider: "codex", last_seq: 1 },
          ],
        }),
      };
    });
    vi.stubGlobal("fetch", fetchMock);
    const wrapper = mount(SessionsView, { global: { plugins: [router] } });
    await flushPromises();
    expect(wrapper.find('[data-testid="sessions-list"]').exists()).toBe(true);
    await wrapper.get('[data-testid="dsh-mode-toggle"]').trigger("click");
    await flushPromises();
    expect(wrapper.find('[data-testid="dsh-sessions-list"]').exists()).toBe(true);
    const titles = wrapper.findAll('[data-testid="dsh-group-title"]').map((n) => n.text());
    expect(titles).toEqual(["project-alpha", "project-beta"]);
    // 非 dsh 会话不进入 DSH 分组。
    expect(wrapper.text()).not.toContain("s4");
    // 只读：没有输入框/写按钮。
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

  it("WEB-01/WEB-02：展示嵌套快照白名单元数据，不保留 envelope", async () => {
    sessionState.token = "tok";
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue({
        ok: true,
        json: async () => ({
          session: {
            id: "abc", workspace_id: "w1", status: "streaming", provider: "codex", last_seq: 5,
          },
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
    wrapper.unmount();
  });

  it("WEB-03：文件树和代码读取仅展示当前请求的解密结果，刷新后清空旧文本", async () => {
    sessionState.token = "tok";
    requestWebReadMock
      .mockResolvedValueOnce([{ path: "src", is_dir: true, size: 0 }, { path: "src/main.go", is_dir: false, size: 22 }])
      .mockResolvedValueOnce({ path: "src/main.go", content: "package webfixture\n" })
      .mockResolvedValueOnce([{ path: "src", is_dir: true, size: 0 }]);
    await router.push("/sessions/web-read/files");
    await router.isReady();
    const files = mount(SessionFilesView, {
      global: { plugins: [router] },
    });
    await flushPromises();
    expect(files.get('[data-testid="files-tree"]').text()).toContain("src/main.go");
    await files.get('[data-testid="file-entry-src/main.go"]').trigger("click");
    await flushPromises();
    expect(files.get('[data-testid="files-code"]').text()).toContain("package webfixture");
    expect(files.find("textarea").exists()).toBe(false);
    await files.get('[data-testid="files-refresh"]').trigger("click");
    await flushPromises();
    expect(files.find('[data-testid="files-code"]').exists()).toBe(false);
    files.unmount();
  });

  it("WEB-03：文件读取失败展示脱敏错误，不保留旧代码", async () => {
    sessionState.token = "tok";
    requestWebReadMock.mockRejectedValue(new Error("offline"));
    await router.push("/sessions/web-read-error/files");
    await router.isReady();
    const files = mount(SessionFilesView, { global: { plugins: [router] } });
    await flushPromises();
    expect(files.get('[data-testid="files-error"]').text()).toContain("无法读取工作区内容");
    expect(files.find('[data-testid="files-code"]').exists()).toBe(false);
    files.unmount();
  });

  it("WEB-03：Git 状态与 Diff 只读展示，失败时清空旧 Diff", async () => {
    sessionState.token = "tok";
    requestWebReadMock
      .mockResolvedValueOnce({
        branch: "main", snapshot_token: "snapshot-web", files: [
          { path: "src/main.go", type: "modified", staged: false, unstaged: true, binary: false, additions: 1, deletions: 0 },
        ],
      })
      .mockResolvedValueOnce({ path: "src/main.go", binary: false, truncated: false, hunks: [{ header: "@@ -1 +1 @@", lines: ["+package webfixture"] }] })
      .mockRejectedValueOnce(new Error("offline"));
    await router.push("/sessions/web-read/git");
    await router.isReady();
    const git = mount(SessionGitView, { global: { plugins: [router] } });
    await flushPromises();
    expect(git.get('[data-testid="git-changes"]').text()).toContain("src/main.go");
    await git.get('[data-testid="git-file-src/main.go"]').trigger("click");
    await flushPromises();
    expect(git.get('[data-testid="git-diff"]').text()).toContain("package webfixture");
    await git.get('[data-testid="git-refresh"]').trigger("click");
    await flushPromises();
    expect(git.get('[data-testid="git-error"]').text()).toContain("无法读取 Git 状态");
    expect(git.find('[data-testid="git-diff"]').exists()).toBe(false);
    expect(git.find("textarea").exists()).toBe(false);
    git.unmount();
  });
});

describe("P4 SSE cursor 客户端", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("WEB-02：嵌套 snapshot 丢弃 envelope，并按 session event_seq 去重", () => {
    const snapshot = decodeSessionSnapshot({
      session: { id: "s1", workspace_id: "w1", status: "running", provider: "codex", last_seq: 3 },
      events: [
        { event_seq: 2, event_type: "message.updated", envelope: { ciphertext: "opaque-never-stored" } },
        { event_seq: 3, event_type: "command.updated", envelope: { ciphertext: "opaque-never-stored" } },
      ],
    });
    expect(snapshot.events).toEqual([
      { event_seq: 2, event_type: "message.updated" },
      { event_seq: 3, event_type: "command.updated" },
    ]);
    expect(JSON.stringify(snapshot)).not.toContain("opaque-never-stored");
    expect(mergeSessionEventMeta(snapshot.events, [
      { event_seq: 3, event_type: "command.updated" },
      { event_seq: 4, event_type: "delegation.changed" },
    ])).toEqual([
      { event_seq: 2, event_type: "message.updated" },
      { event_seq: 3, event_type: "command.updated" },
      { event_seq: 4, event_type: "delegation.changed" },
    ]);
  });

  it("WEB-02：SSE 只读取单调 id，重连带 Last-Event-ID，忽略 opaque data", async () => {
    const encoder = new TextEncoder();
    const body = (text: string): ReadableStream<Uint8Array> => new ReadableStream({
      start(controller) {
        controller.enqueue(encoder.encode(text));
        controller.close();
      },
    });
    const fetchMock = vi.fn()
      .mockResolvedValueOnce({
        ok: true,
        status: 200,
        body: body('id: 7\nevent: delegation.changed\ndata: {"ciphertext":"opaque-never-rendered"}\n\n'),
      })
      .mockResolvedValueOnce({
        ok: true,
        status: 200,
        body: body('id: 7\ndata: {"ciphertext":"duplicate"}\n\nid: 8\ndata: {"ciphertext":"opaque-again"}\n\n'),
      });
    const invalidations: string[] = [];
    const statuses: string[] = [];
    const stream = startAccountEventStream({
      token: () => "read-only-token",
      onInvalidate: () => invalidations.push("snapshot"),
      onStatus: (status) => statuses.push(status),
      fetchImpl: fetchMock,
      retryBaseMs: 0,
      maxRetries: 2,
    });
    await vi.waitFor(() => expect(invalidations).toHaveLength(2));
    expect(fetchMock.mock.calls.length).toBeGreaterThanOrEqual(2);
    expect(fetchMock.mock.calls[1][1]?.headers).toMatchObject({ "Last-Event-ID": "7" });
    expect(invalidations).toEqual(["snapshot", "snapshot"]);
    expect(JSON.stringify({ invalidations, statuses })).not.toContain("opaque-never-rendered");
    stream.stop();
  });

  it("WEB-02：认证失效停止重连", async () => {
    const fetchMock = vi.fn().mockResolvedValue({ ok: false, status: 401, body: null });
    const statuses: string[] = [];
    const stream = startAccountEventStream({
      token: () => "expired-token",
      onInvalidate: vi.fn(),
      onStatus: (status) => statuses.push(status),
      fetchImpl: fetchMock,
      retryBaseMs: 0,
    });
    await vi.waitFor(() => expect(statuses).toContain("unauthorized"));
    expect(fetchMock).toHaveBeenCalledTimes(1);
    stream.stop();
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
