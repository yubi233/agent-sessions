<script setup lang="ts">
// 首页：Relay 健康检查 + 只读登录 + 设备/会话/能力摘要。
// 登录后展示能力列表摘要；完整三态矩阵在独立只读视图（/capabilities）。
// 页面不提供任何会话写控件（docs/zh/项目文档.md「Vue Web App」章节）。
import { onMounted, ref } from "vue";
import { useRouter } from "vue-router";
import { sessionState } from "../session";
import type { ProviderCapabilities } from "../types";

type HealthState = "loading" | "ready" | "error";

const state = ref<HealthState>("loading");
const message = ref("正在连接本地 Relay…");
const relayURL = import.meta.env.VITE_RELAY_URL ?? "http://127.0.0.1:8787";
const router = useRouter();

// 浏览器只读取无鉴权健康端点，不携带账户、设备或会话内容。
async function refreshHealth(): Promise<void> {
  state.value = "loading";
  message.value = "正在连接本地 Relay…";
  try {
    const response = await fetch(`${relayURL}/readyz`);
    if (!response.ok) {
      throw new Error(`Relay returned ${response.status}`);
    }
    state.value = "ready";
    message.value = "Relay 已就绪，可以开始安全配对。";
  } catch {
    state.value = "error";
    message.value = "无法连接 Relay，请检查本地服务是否启动。";
  }
}

// ---- 只读登录与设备查看（P1 headed 回归）----
const email = ref("");
const password = ref("");
const authState = ref<"idle" | "loading" | "ok" | "error">("idle");
const authMessage = ref("");
const devices = ref<
  Array<{ id: string; role: string; display_name: string; status: string }>
>([]);
const sessions = ref<Array<{ id: string; status: string; provider: string }>>(
  [],
);
const capabilities = ref<ProviderCapabilities[]>([]);

// 只读读取：设备、会话与能力矩阵；Web 不提供任何会话写控件。
async function loadReadOnly(): Promise<void> {
  const headers = { Authorization: `Bearer ${sessionState.token}` };
  const [devRes, sessRes, capRes] = await Promise.all([
    fetch(`${relayURL}/v1/devices`, { headers }),
    fetch(`${relayURL}/v1/sessions`, { headers }),
    fetch(`${relayURL}/v1/capabilities`, { headers }),
  ]);
  if (!devRes.ok || !sessRes.ok || !capRes.ok) {
    throw new Error("read-only fetch failed");
  }
  devices.value = (await devRes.json()).devices;
  sessions.value = (await sessRes.json()).sessions;
  capabilities.value = (await capRes.json()).providers;
}

// 登录并拉取只读设备/会话/能力；Web 只读，不提供任何会话写控件。
async function login(): Promise<void> {
  authState.value = "loading";
  authMessage.value = "正在登录…";
  try {
    const loginRes = await fetch(`${relayURL}/v1/auth/login`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ email: email.value, password: password.value }),
    });
    if (!loginRes.ok) {
      throw new Error(`login ${loginRes.status}`);
    }
    const data = (await loginRes.json()) as { access_token: string };
    sessionState.token = data.access_token;
    await loadReadOnly();
    authState.value = "ok";
    authMessage.value = "已登录（只读）。";
  } catch (err) {
    authState.value = "error";
    authMessage.value = `登录失败：${err instanceof Error ? err.message : String(err)}`;
  }
}

// 跳转到能力矩阵只读视图（完整三态表格）。
function openCapabilities(): void {
  void router.push({ name: "capabilities" });
}

onMounted(refreshHealth);
</script>

<template>
  <main class="page" aria-labelledby="page-title">
    <section class="card">
      <p class="eyebrow">Agent Sessions</p>
      <h1 id="page-title">本地 Relay 状态</h1>
      <p :data-testid="`relay-${state}`" class="status" role="status">
        {{ message }}
      </p>
      <button type="button" data-testid="refresh-health" @click="refreshHealth">
        重新检查
      </button>
    </section>

    <section class="card" aria-labelledby="login-title">
      <h2 id="login-title">只读登录</h2>
      <form data-testid="login-form" @submit.prevent="login">
        <label>
          邮箱
          <input
            v-model="email"
            data-testid="login-email"
            type="email"
            autocomplete="username"
          />
        </label>
        <label>
          密码
          <input
            v-model="password"
            data-testid="login-password"
            type="password"
            autocomplete="current-password"
          />
        </label>
        <button
          type="submit"
          data-testid="login-submit"
          :disabled="authState === 'loading'"
        >
          登录
        </button>
      </form>
      <p :data-testid="`auth-${authState}`" class="status" role="status">
        {{ authMessage }}
      </p>

      <ul v-if="devices.length > 0" data-testid="device-list">
        <li v-for="d in devices" :key="d.id" data-testid="device-item">
          {{ d.display_name }}（{{ d.role }}）{{ d.status }}
        </li>
      </ul>

      <h3 v-if="sessions.length > 0" data-testid="sessions-title">只读会话</h3>
      <ul v-if="sessions.length > 0" data-testid="session-list">
        <li v-for="s in sessions" :key="s.id" data-testid="session-item">
          {{ s.provider }} · {{ s.status }}
        </li>
      </ul>

      <h3 v-if="capabilities.length > 0" data-testid="capabilities-title">
        Provider 能力
      </h3>
      <ul v-if="capabilities.length > 0" data-testid="capability-list">
        <li
          v-for="p in capabilities"
          :key="p.kind"
          data-testid="capability-item"
        >
          {{ p.kind }}（{{ p.version || "未配置" }}）
        </li>
      </ul>

      <button
        v-if="authState === 'ok'"
        type="button"
        data-testid="capabilities-link"
        @click="openCapabilities"
      >
        查看完整能力矩阵
      </button>
    </section>
  </main>
</template>
