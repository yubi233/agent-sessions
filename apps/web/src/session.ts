// 会话状态：模块级单例，供首页登录与能力矩阵视图共享访问令牌。
// 令牌只存内存，绝不写入 localStorage/IndexedDB（浏览器只读客户端的最小化存储边界）。
import { reactive } from "vue";

export interface SessionState {
  token: string;
}

export const sessionState = reactive<SessionState>({ token: "" });
