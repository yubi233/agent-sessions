<script setup lang="ts">
// 运维概览：Relay 健康 + 管理员只读登录 + 资源摘要。
// 只展示脱敏元数据，无任何写入口。
import { onMounted, ref } from "vue";
import { adminReadOnlyGet, adminSessionState, relayURL } from "../session";

type HealthState = "loading" | "ready" | "error";
type DataState = "idle" | "loading" | "ready" | "error";

const state = ref<HealthState>("loading");
const message = ref("正在连接 Relay…");
const email = ref("");
const password = ref("");
const authState = ref<"idle" | "loading" | "ok" | "error">("idle");
const authMessage = ref("");
const dataState = ref<DataState>("idle");
const dataMessage = ref("");
const devices = ref<
  Array<{ id: string; role: string; display_name: string; status: string }>
>([]);
const sessions = ref<Array<{ id: string; status: string; provider: string }>>(
  [],
);

async function refreshHealth(): Promise<void> {
  state.value = "loading";
  message.value = "正在连接 Relay…";
  try {
    const response = await fetch(`${relayURL}/readyz`);
    if (!response.ok) throw new Error(`Relay ${response.status}`);
    state.value = "ready";
    message.value = "Relay 就绪（运维只读）。";
  } catch {
    state.value = "error";
    message.value = "无法连接 Relay。";
  }
}

async function loadReadOnly(): Promise<void> {
  dataState.value = "loading";
  dataMessage.value = "正在读取脱敏元数据…";
  try {
    const [devData, sessData] = await Promise.all([
      adminReadOnlyGet<{ devices: typeof devices.value }>("/v1/devices"),
      adminReadOnlyGet<{ sessions: typeof sessions.value }>("/v1/sessions"),
    ]);
    devices.value = devData.devices;
    sessions.value = sessData.sessions;
    dataState.value = "ready";
    dataMessage.value = "脱敏元数据已更新。";
  } catch {
    dataState.value = "error";
    dataMessage.value = "无法读取脱敏元数据，请重新登录或检查 Relay。";
  }
}

async function login(): Promise<void> {
  authState.value = "loading";
  authMessage.value = "正在登录…";
  try {
    const loginRes = await fetch(`${relayURL}/v1/auth/login`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ email: email.value, password: password.value }),
    });
    if (!loginRes.ok) throw new Error(`login ${loginRes.status}`);
    const data = (await loginRes.json()) as { access_token: string };
    adminSessionState.token = data.access_token;
    await loadReadOnly();
    authState.value = "ok";
    authMessage.value = "已登录（运维只读）。";
  } catch {
    authState.value = "error";
    authMessage.value = "登录或只读数据读取失败，请检查凭据和 Relay。";
  }
}

onMounted(refreshHealth);
</script>

<template>
  <main class="admin-page" aria-labelledby="page-title">
    <header class="page-intro">
      <h1 id="page-title">运维概览</h1>
      <p>仅显示 Relay、设备与会话的脱敏元数据。</p>
    </header>

    <section class="admin-section" aria-labelledby="health-title">
      <div class="section-heading">
        <div>
          <p class="section-kicker">连接</p>
          <h2 id="health-title">Relay 健康</h2>
        </div>
        <button type="button" data-testid="refresh-health" @click="refreshHealth">
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

    <section class="admin-section" aria-labelledby="login-title">
      <div class="section-heading">
        <div>
          <p class="section-kicker">账户</p>
          <h2 id="login-title">管理员登录</h2>
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
    </section>

    <p
      v-if="dataState === 'loading'"
      data-testid="readonly-loading"
      class="status"
      role="status"
    >
      {{ dataMessage }}
    </p>
    <p
      v-if="dataState === 'error'"
      data-testid="readonly-error"
      class="status status-error"
      role="alert"
    >
      {{ dataMessage }}
    </p>

    <div v-if="authState === 'ok' && dataState === 'ready'" class="metadata-grid">
      <section class="admin-section metadata-section" aria-labelledby="devices-title">
        <p class="section-kicker">资源</p>
        <h2 id="devices-title">设备</h2>
        <ul v-if="devices.length > 0" data-testid="device-list" class="metadata-list">
          <li v-for="d in devices" :key="d.id" data-testid="device-item">
            <strong>{{ d.display_name }}</strong>
            <span>{{ d.role }} · {{ d.status }}</span>
          </li>
        </ul>
        <p v-else data-testid="device-empty" class="empty-state">无设备。</p>
      </section>

      <section class="admin-section metadata-section" aria-labelledby="sessions-title">
        <p class="section-kicker">资源</p>
        <h2 id="sessions-title">会话</h2>
        <ul v-if="sessions.length > 0" data-testid="session-list" class="metadata-list">
          <li v-for="s in sessions" :key="s.id" data-testid="session-item">
            <strong>{{ s.provider }}</strong>
            <span>{{ s.status }}</span>
          </li>
        </ul>
        <p v-else data-testid="session-empty" class="empty-state">无会话。</p>
      </section>
    </div>
  </main>
</template>
