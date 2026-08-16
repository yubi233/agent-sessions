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
}

// 会话事件只读投影：envelope 是密文，浏览器端不尝试解密或展示正文。
export interface SessionEventMeta {
  event_seq: number;
  event_type: string;
  envelope: Record<string, unknown>;
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
