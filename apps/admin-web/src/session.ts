// Admin 会话状态：模块级单例，供各分区共享登录 token 与账号信息。
// token 只存内存，绝不写入 localStorage/IndexedDB。
import { reactive } from "vue";

export interface AdminSessionState {
  token: string;
}

export const adminSessionState = reactive<AdminSessionState>({ token: "" });

export const relayURL = import.meta.env.VITE_RELAY_URL ?? "http://127.0.0.1:8787";

// Admin 只读 API 封装：只做 GET 白名单元数据读取，不注册任何写请求。
export async function adminReadOnlyGet<T>(path: string): Promise<T> {
  const response = await fetch(`${relayURL}${path}`, {
    headers: { Authorization: `Bearer ${adminSessionState.token}` },
  });
  if (!response.ok) {
    throw new Error(`admin read-only GET ${path} failed: ${response.status}`);
  }
  return (await response.json()) as T;
}
