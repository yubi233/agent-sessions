// 会话状态：模块级单例，供首页登录与只读视图共享访问令牌。
// 令牌只存内存，绝不写入 localStorage/IndexedDB（浏览器只读客户端的最小化存储边界）。
import { reactive } from "vue";

export interface SessionState {
  token: string;
}

export const sessionState = reactive<SessionState>({ token: "" });

// 会话白名单元数据（与 Relay /v1/sessions DTO 对齐）。
export interface SessionMeta {
  id: string;
  workspace_id: string;
  status: string;
  provider: string;
  last_seq: number;
  // Optional safe label from a future Relay projection. DSH sessions without
  // an Agent Sessions-owned label must never fall back to their opaque ID.
  display_name?: string;
  last_activity_at_unix_ms?: number;
}

// 会话事件只读投影只保留时间线元数据。snapshot 响应中的 envelope 会在映射时丢弃，
// 浏览器既不缓存也不展示其密文内容。
export interface SessionEventMeta {
  event_seq: number;
  event_type: string;
}

export interface SessionSnapshot {
  session: SessionMeta;
  events: SessionEventMeta[];
}

// 终端白名单投影（/v1/terminals DTO）。
export interface TerminalMeta {
  id: string;
  hostname: string;
  platform: string;
  status: string;
  last_seen_unix_ms?: number;
  protocol_version?: number;
  daemon_version?: string;
}

export const relayURL = import.meta.env.VITE_RELAY_URL ?? "http://127.0.0.1:8787";

// 统一只读 API 封装：只做 GET 白名单元数据读取，不注册任何写请求。
export async function readOnlyGet<T>(path: string): Promise<T> {
  const response = await fetch(`${relayURL}${path}`, {
    headers: { Authorization: `Bearer ${sessionState.token}` },
  });
  if (!response.ok) {
    throw new Error(`read-only GET ${path} failed: ${response.status}`);
  }
  return (await response.json()) as T;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function requiredString(value: unknown, field: string): string {
  if (typeof value !== "string") throw new Error(`invalid session snapshot ${field}`);
  return value;
}

function requiredNonNegativeNumber(value: unknown, field: string): number {
  if (typeof value !== "number" || !Number.isInteger(value) || value < 0) {
    throw new Error(`invalid session snapshot ${field}`);
  }
  return value;
}

// decodeSessionSnapshot 只复制 Web 白名单字段。服务端依然可返回 opaque envelope 给其他
// 客户端，但该只读 UI 不保留、展示或尝试解释它。
export function decodeSessionSnapshot(raw: unknown): SessionSnapshot {
  if (!isRecord(raw) || !isRecord(raw.session) || !Array.isArray(raw.events)) {
    throw new Error("invalid session snapshot");
  }
  const session = raw.session;
  const events = raw.events.map((event, index) => {
    if (!isRecord(event)) throw new Error(`invalid session event ${index}`);
    return {
      event_seq: requiredNonNegativeNumber(event.event_seq, `events[${index}].event_seq`),
      event_type: requiredString(event.event_type, `events[${index}].event_type`),
    };
  });
  return {
    session: {
      id: requiredString(session.id, "session.id"),
      workspace_id: requiredString(session.workspace_id, "session.workspace_id"),
      status: requiredString(session.status, "session.status"),
      provider: requiredString(session.provider, "session.provider"),
      last_seq: requiredNonNegativeNumber(session.last_seq, "session.last_seq"),
    },
    events,
  };
}

// mergeSessionEventMeta 以 session-local event_seq 去重。账号 SSE cursor 只用于触发刷新，
// 不能替代单会话 snapshot 的 event_seq。
export function mergeSessionEventMeta(
  current: SessionEventMeta[],
  incoming: SessionEventMeta[],
): SessionEventMeta[] {
  const bySequence = new Map<number, SessionEventMeta>();
  for (const event of current) bySequence.set(event.event_seq, event);
  for (const event of incoming) bySequence.set(event.event_seq, event);
  return [...bySequence.values()].sort((left, right) => left.event_seq - right.event_seq);
}

export type AccountEventStreamStatus =
  | "connecting"
  | "live"
  | "reconnecting"
  | "unauthorized"
  | "error"
  | "stopped";

export interface AccountEventStreamOptions {
  token: () => string;
  onInvalidate: () => void;
  onStatus?: (status: AccountEventStreamStatus) => void;
  fetchImpl?: typeof fetch;
  maxRetries?: number;
  retryBaseMs?: number;
}

export interface AccountEventStream {
  stop(): void;
}

// startAccountEventStream 用带 Authorization 的 fetch 流替代原生 EventSource。解析器只读取
// SSE id，并明确忽略 data 字段，因此 opaque envelope 不会进入页面状态、缓存或渲染路径。
export function startAccountEventStream(options: AccountEventStreamOptions): AccountEventStream {
  const fetchImpl = options.fetchImpl ?? fetch;
  const maxRetries = options.maxRetries ?? 3;
  const retryBaseMs = options.retryBaseMs ?? 200;
  let stopped = false;
  let retries = 0;
  let lastCursor = 0;
  let controller: AbortController | undefined;

  const setStatus = (status: AccountEventStreamStatus): void => options.onStatus?.(status);
  const waitForRetry = async (): Promise<boolean> => {
    retries += 1;
    if (retries > maxRetries) {
      setStatus("error");
      return false;
    }
    setStatus("reconnecting");
    const delay = retryBaseMs * 2 ** (retries - 1);
    if (delay > 0) await new Promise<void>((resolve) => window.setTimeout(resolve, delay));
    return !stopped;
  };

  const consume = async (body: ReadableStream<Uint8Array>): Promise<void> => {
    const reader = body.getReader();
    const decoder = new TextDecoder();
    let buffered = "";
    let frameCursor: number | undefined;
    const consumeLine = (line: string): void => {
      if (line === "") {
        if (frameCursor !== undefined && frameCursor > lastCursor) {
          lastCursor = frameCursor;
          options.onInvalidate();
        }
        frameCursor = undefined;
        return;
      }
      if (line.startsWith(":")) return;
      const separator = line.indexOf(":");
      const field = separator === -1 ? line : line.slice(0, separator);
      // data 的内容从不读取或保存；只能由下一次 snapshot 的白名单映射进入 UI。
      if (field !== "id") return;
      const rawCursor = (separator === -1 ? "" : line.slice(separator + 1)).trimStart();
      if (!/^(0|[1-9][0-9]*)$/.test(rawCursor)) return;
      const cursor = Number(rawCursor);
      if (Number.isSafeInteger(cursor)) frameCursor = cursor;
    };
    try {
      while (!stopped) {
        const next = await reader.read();
        if (next.done) break;
        buffered += decoder.decode(next.value, { stream: true });
        let lineEnd = buffered.indexOf("\n");
        while (lineEnd >= 0) {
          const line = buffered.slice(0, lineEnd).replace(/\r$/, "");
          buffered = buffered.slice(lineEnd + 1);
          consumeLine(line);
          lineEnd = buffered.indexOf("\n");
        }
      }
    } finally {
      reader.releaseLock();
    }
  };

  const run = async (): Promise<void> => {
    while (!stopped) {
      controller = new AbortController();
      try {
        setStatus(retries === 0 ? "connecting" : "reconnecting");
        const headers: Record<string, string> = { Authorization: `Bearer ${options.token()}` };
        if (lastCursor > 0) headers["Last-Event-ID"] = String(lastCursor);
        const response = await fetchImpl(`${relayURL}/v1/events`, {
          headers,
          signal: controller.signal,
          cache: "no-store",
        });
        if (response.status === 401 || response.status === 403) {
          setStatus("unauthorized");
          return;
        }
        if (!response.ok || !response.body) throw new Error(`account SSE failed: ${response.status}`);
        setStatus("live");
        await consume(response.body);
        if (stopped) break;
      } catch {
        if (stopped) break;
      }
      if (!(await waitForRetry())) return;
    }
    if (stopped) setStatus("stopped");
  };

  // Chrome 在已有 fetch stream 上切换离线状态时不会保证主动断开连接。显式中止当前读取
  // 后走同一受限 backoff，在线恢复时仍会携带内存中的 Last-Event-ID 补齐缺口。
  const reconnectAfterOffline = (): void => {
    if (!stopped) controller?.abort();
  };
  if (typeof window !== "undefined") {
    window.addEventListener("offline", reconnectAfterOffline);
  }
  void run();
  return {
    stop(): void {
      if (stopped) return;
      stopped = true;
      if (typeof window !== "undefined") {
        window.removeEventListener("offline", reconnectAfterOffline);
      }
      controller?.abort();
    },
  };
}

// ── V094-27（计划 §2.6）：会话只读增量同步状态机 ────────────────────────────
// 契约冻结：
// 1. 收到账号通知不等于本会话 snapshot 已合并——在途期间到达的通知记为
//    pending，本轮合并完成后必须再补一轮，最后一条通知绝不丢弃；
// 2. 增量失败保留最后可信内容，进入"同步失败"态并有界重试；连接恢复
//    （SSE live）时主动补拉一次，不依赖下一次事件；
// 3. 连接状态（SSE）与数据同步状态分开表达，连接 live 不冒充同步完成。
export type DetailSyncState = "synced" | "syncing" | "error";

export interface DetailSyncCallbacks {
  /** 拉取指定 after_seq 之后的增量；由视图执行白名单解码与合并。 */
  loadIncremental(): Promise<void>;
  /** 是否具备同步前提（已就绪且已登录）。 */
  isReady(): boolean;
  maxRetries?: number;
  retryBaseMs?: number;
  setTimeoutImpl?: (fn: () => void, ms: number) => unknown;
  clearTimeoutImpl?: (handle: unknown) => void;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
}

export interface DetailSyncController {
  /** 账号 SSE 通知入口（幂等；在途期间标记 pending）。 */
  onInvalidate(): void;
  /** SSE 重连恢复为 live 时的主动补拉入口。 */
  onReconnected(): void;
  /** 手动核验入口。 */
  refresh(): void;
  /** 当前数据同步状态。 */
  state(): DetailSyncState;
  /** 视图卸载时取消挂起的重试定时器。 */
  dispose(): void;
}

export function createDetailSync(callbacks: DetailSyncCallbacks): DetailSyncController {
  const maxRetries = callbacks.maxRetries ?? 3;
  const retryBaseMs = callbacks.retryBaseMs ?? 500;
  const setTimeoutImpl = callbacks.setTimeoutImpl ?? ((fn, ms) => window.setTimeout(fn, ms));
  const clearTimeoutImpl = callbacks.clearTimeoutImpl ?? ((handle: unknown) => window.clearTimeout(handle as number));

  let inFlight = false;
  let pendingInvalidation = false;
  let retries = 0;
  let syncState: DetailSyncState = "synced";
  let retryHandle: unknown;

  const clearRetry = (): void => {
    if (retryHandle !== undefined) {
      clearTimeoutImpl(retryHandle);
      retryHandle = undefined;
    }
  };

  const drain = async (): Promise<void> => {
    if (inFlight) return;
    if (!callbacks.isReady()) {
      pendingInvalidation = false;
      return;
    }
    inFlight = true;
    pendingInvalidation = false;
    syncState = "syncing";
    try {
      await callbacks.loadIncremental();
      syncState = "synced";
      retries = 0;
    } catch {
      syncState = "error";
      retries += 1;
      if (retries <= maxRetries) {
        const delay = retryBaseMs * 2 ** (retries - 1);
        retryHandle = setTimeoutImpl(() => {
          retryHandle = undefined;
          void drain();
        }, delay);
      }
      // 超过有界重试后保持"同步失败"态，等待下一次事件或手动核验；
      // 旧内容已保留，不因此清空页面。
    } finally {
      inFlight = false;
    }
    // 在途期间到达的通知绝不丢弃：本轮合并完成后继续消化 pending。
    if (pendingInvalidation) {
      pendingInvalidation = false;
      void drain();
    }
  };

  return {
    onInvalidate(): void {
      pendingInvalidation = true;
      void drain();
    },
    onReconnected(): void {
      // 重连/重新进入必须主动补拉：SSE 游标推进不代表本会话 snapshot 已合并。
      pendingInvalidation = true;
      retries = 0;
      clearRetry();
      void drain();
    },
    refresh(): void {
      pendingInvalidation = true;
      retries = 0;
      clearRetry();
      void drain();
    },
    state: () => syncState,
    dispose(): void {
      clearRetry();
    },
  };
}
