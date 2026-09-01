<script setup lang="ts">
// 首页：Relay 健康检查 + 登录 + 设备/会话/能力摘要。
// 登录后展示能力列表摘要；完整三态矩阵在独立视图（/capabilities）。
import { onMounted, ref } from "vue";
import { sessionState } from "../session";
import type { ProviderCapabilities } from "../types";

type HealthState = "loading" | "ready" | "error";

const state = ref<HealthState>("loading");
const message = ref("正在连接本地 Relay…");
const relayURL = import.meta.env.VITE_RELAY_URL ?? "http://127.0.0.1:8787";

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

// ---- 登录与设备查看（P1 headed 回归）----
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
type ReadState = "idle" | "loading" | "ready" | "error";
const readState = ref<ReadState>("idle");
const readMessage = ref("");

// 读取设备、会话与能力矩阵的安全只读投影。
async function loadReadOnly(): Promise<void> {
  readState.value = "loading";
  readMessage.value = "正在读取只读摘要…";
  const headers = { Authorization: `Bearer ${sessionState.token}` };
  try {
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
    readState.value = "ready";
    readMessage.value = "只读摘要已更新。";
  } catch {
    readState.value = "error";
    readMessage.value = "无法读取只读摘要，请检查 Relay 或重新登录。";
    throw new Error("read-only fetch failed");
  }
}

// 登录并拉取设备、会话与能力投影。
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
    authMessage.value = "已登录。";
  } catch (err) {
    authState.value = "error";
    authMessage.value = `登录失败：${err instanceof Error ? err.message : String(err)}`;
  }
}

onMounted(refreshHealth);
</script>

<template>
  <main class="page page-workflow" aria-labelledby="page-title">
    <header class="page-intro">
      <p class="eyebrow">Agent Sessions</p>
      <h1 id="page-title">本地 Relay 状态</h1>
      <p class="intro-copy">查看连接、账户与已授权设备，并可进入 LLM 对话。</p>
    </header>

    <section class="page-section health-section" aria-labelledby="health-title">
      <div class="section-heading">
        <div>
          <p class="section-kicker">连接</p>
          <h2 id="health-title">Relay 健康</h2>
        </div>
        <button
          type="button"
          data-testid="refresh-health"
          @click="refreshHealth"
        >
          重新检查
        </button>
      </div>
      <p
        :data-testid="`relay-${state}`"
        class="status"
        role="status"
        aria-live="polite"
      >
        {{ message }}
      </p>
    </section>

    <section class="page-section auth-section" aria-labelledby="login-title">
      <div class="section-heading">
        <div>
          <p class="section-kicker">账户</p>
          <h2 id="login-title">登录</h2>
        </div>
      </div>
      <form
        class="credentials-form"
        data-testid="login-form"
        @submit.prevent="login"
      >
        <label for="login-email">
          邮箱
          <input
            id="login-email"
            v-model="email"
            data-testid="login-email"
            type="email"
            autocomplete="username"
          />
        </label>
        <label for="login-password">
          密码
          <input
            id="login-password"
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
      <p
        :data-testid="`auth-${authState}`"
        class="status"
        role="status"
        aria-live="polite"
      >
        {{ authMessage }}
      </p>

      <p
        v-if="readState === 'loading'"
        data-testid="readonly-loading"
        class="status"
        role="status"
      >
        {{ readMessage }}
      </p>
      <p
        v-if="readState === 'error'"
        data-testid="readonly-error"
        class="status status-error"
        role="alert"
      >
        {{ readMessage }}
      </p>

      <div
        v-if="authState === 'ok' && readState === 'ready'"
        class="summary-grid"
      >
        <section class="summary-section" aria-labelledby="devices-title">
          <h3 id="devices-title">设备</h3>
          <ul
            v-if="devices.length > 0"
            data-testid="device-list"
            class="summary-list"
          >
            <li v-for="d in devices" :key="d.id" data-testid="device-item">
              <strong>{{ d.display_name }}</strong>
              <span>{{ d.role }} · {{ d.status }}</span>
            </li>
          </ul>
          <p v-else data-testid="device-empty" class="empty-state">
            没有可查看的设备。
          </p>
        </section>

        <section class="summary-section" aria-labelledby="sessions-title">
          <h3 id="sessions-title" data-testid="sessions-title">只读会话</h3>
          <ul
            v-if="sessions.length > 0"
            data-testid="session-list"
            class="summary-list"
          >
            <li v-for="s in sessions" :key="s.id" data-testid="session-item">
              <strong>{{ s.provider }}</strong>
              <span>{{ s.status }}</span>
            </li>
          </ul>
          <p v-else data-testid="session-empty" class="empty-state">
            没有可查看的会话。
          </p>
        </section>

        <section class="summary-section" aria-labelledby="capabilities-title">
          <h3 id="capabilities-title" data-testid="capabilities-title">
            Provider 能力
          </h3>
          <ul
            v-if="capabilities.length > 0"
            data-testid="capability-list"
            class="summary-list"
          >
            <li
              v-for="p in capabilities"
              :key="p.kind"
              data-testid="capability-item"
            >
              <strong>{{ p.kind }}</strong>
              <span>{{ p.version || "未配置" }}</span>
            </li>
          </ul>
          <p v-else data-testid="capability-empty" class="empty-state">
            尚未探测到 Provider。
          </p>
          <RouterLink
            to="/capabilities"
            data-testid="capabilities-link"
            class="text-link"
          >
            查看完整能力矩阵
          </RouterLink>
        </section>
      </div>
    </section>
  </main>
</template>
