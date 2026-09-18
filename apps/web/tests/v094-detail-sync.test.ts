// V094-27（计划 §2.6）：Web 只读会话详情增量同步状态机。
// 覆盖：在途最后通知不丢、失败无后续事件仍有界重试、旧内容保留、
// 重连补拉与游标分离、dispose 清理。仅 GET/只读。
import { describe, expect, it, vi } from "vitest";
import { createDetailSync, type DetailSyncCallbacks } from "../src/session";

/// 可编程测试替身：impl 可随时替换；重试定时器登记到局部 handles，
/// dispose 时经由注入的 clearTimeoutImpl 标记清除。
function makeSync(overrides: Partial<DetailSyncCallbacks> = {}) {
  let impl: () => Promise<void> = async () => {};
  const loadIncremental = vi.fn(() => impl());
  const handles: Array<{ run: () => void; cleared: boolean }> = [];
  const sync = createDetailSync({
    loadIncremental: () => loadIncremental(),
    isReady: () => true,
    maxRetries: 3,
    retryBaseMs: 1,
    setTimeoutImpl: (fn) => {
      const entry = { run: fn, cleared: false };
      handles.push(entry);
      return entry;
    },
    clearTimeoutImpl: (handle) => {
      (handle as { cleared: boolean }).cleared = true;
    },
    ...overrides,
  });
  const runPendingTimers = async (): Promise<void> => {
    // 重试期间可能再排新定时器：循环消化到队列清空。
    while (handles.some((entry) => !entry.cleared)) {
      const entry = handles.shift()!;
      if (!entry.cleared) {
        entry.run();
        await flush();
      }
    }
  };
  return { sync, loadIncremental, setImpl: (next: () => Promise<void>) => (impl = next), runPendingTimers };
}

function flush(): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, 0));
}

describe("V094-27 createDetailSync", () => {
  it("在途期间到达的最后一条通知不丢弃：合并完成后补拉一轮", async () => {
    let release!: () => void;
    const { sync, loadIncremental, setImpl } = makeSync();
    setImpl(
      () =>
        new Promise<void>((resolve) => {
          release = resolve;
        }),
    );
    sync.onInvalidate();
    sync.onInvalidate(); // 在途期间再来的通知（含最后一条）
    await flush();
    expect(loadIncremental).toHaveBeenCalledTimes(1);
    release();
    // 释放后把实现换成立即完成：第二轮补拉（pending 消化）可同步收敛。
    setImpl(async () => {});
    await flush();
    await flush();
    await flush();
    // pending 在第一轮结束后必须再驱动一轮增量（最后一通知不丢）。
    expect(loadIncremental).toHaveBeenCalledTimes(2);
    expect(sync.state()).toBe("synced");
    sync.dispose();
  });

  it("失败后无后续事件仍有界重试，超过上限保持失败态", async () => {
    let attempts = 0;
    const { sync, runPendingTimers } = makeSync({
      loadIncremental: async () => {
        attempts += 1;
        throw new Error("relay unreachable");
      },
      maxRetries: 2,
    });
    sync.onInvalidate();
    await flush();
    expect(sync.state()).toBe("error");
    await runPendingTimers();
    expect(attempts).toBe(3); // 首次 + 重试 2 次
    expect(sync.state()).toBe("error");
    sync.dispose();
  });

  it("重连恢复 live 时主动补拉（不依赖下一次事件）", async () => {
    const { sync, loadIncremental } = makeSync();
    sync.onReconnected();
    await flush();
    expect(loadIncremental).toHaveBeenCalledTimes(1);
    expect(sync.state()).toBe("synced");
    sync.dispose();
  });

  it("手动核验重置重试计数并立即拉取", async () => {
    let fail = true;
    const { sync, loadIncremental, setImpl } = makeSync({ maxRetries: 0 });
    setImpl(async () => {
      if (fail) throw new Error("boom");
    });
    sync.onInvalidate();
    await flush();
    expect(sync.state()).toBe("error");
    fail = false;
    sync.refresh();
    await flush();
    expect(loadIncremental).toHaveBeenCalledTimes(2);
    expect(sync.state()).toBe("synced");
    sync.dispose();
  });

  it("未就绪时不拉取（视图 error/loading 态不触发增量）", async () => {
    const { sync, loadIncremental } = makeSync({ isReady: () => false });
    sync.onInvalidate();
    await flush();
    expect(loadIncremental).not.toHaveBeenCalled();
    sync.dispose();
  });

  it("dispose 取消挂起的重试定时器", async () => {
    let attempts = 0;
    const { sync, runPendingTimers } = makeSync({
      loadIncremental: async () => {
        attempts += 1;
        throw new Error("boom");
      },
      maxRetries: 3,
    });
    sync.onInvalidate();
    await flush();
    expect(attempts).toBe(1);
    sync.dispose();
    await runPendingTimers();
    expect(attempts).toBe(1);
  });
});
