<script setup lang="ts">
import { onMounted, ref } from "vue";

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

// ---- 只读登录与设备查看（P1 headed 回归）----
const email = ref("");
const password = ref("");
const authState = ref<"idle" | "loading" | "ok" | "error">("idle");
const authMessage = ref("");
const devices = ref<Array<{ id: string; role: string; display_name: string; status: string }>>([]);
const token = ref("");

// 登录并拉取只读设备列表；Web 只读，不提供任何会话写控件。
async function login(): Promise<void> {
  authState.value = "loading";
  authMessage.value = "正在登录…";
  try {
    const loginRes = await fetch(`${relayURL}/v1/auth/login`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ email: email.value, password: password.value, device_id: "web", role: "web" }),
    });
    if (!loginRes.ok) {
      throw new Error(`login ${loginRes.status}`);
    }
    const data = (await loginRes.json()) as { access_token: string };
    token.value = data.access_token;

    const devRes = await fetch(`${relayURL}/v1/devices`, {
      headers: { Authorization: `Bearer ${token.value}` },
    });
    if (!devRes.ok) {
      throw new Error(`devices ${devRes.status}`);
    }
    const devData = (await devRes.json()) as { devices: typeof devices.value };
    devices.value = devData.devices;
    authState.value = "ok";
    authMessage.value = "已登录（只读）。";
  } catch (err) {
    authState.value = "error";
    authMessage.value = `登录失败：${err instanceof Error ? err.message : String(err)}`;
  }
}

onMounted(refreshHealth);
</script>

<template>
  <main class="page" aria-labelledby="page-title">
    <section class="card">
      <p class="eyebrow">Agent Sessions</p>
      <h1 id="page-title">本地 Relay 状态</h1>
      <p :data-testid="`relay-${state}`" class="status" role="status">{{ message }}</p>
      <button type="button" data-testid="refresh-health" @click="refreshHealth">重新检查</button>
    </section>

    <section class="card" aria-labelledby="login-title">
      <h2 id="login-title">只读登录</h2>
      <form data-testid="login-form" @submit.prevent="login">
        <label>
          邮箱
          <input v-model="email" data-testid="login-email" type="email" autocomplete="username" />
        </label>
        <label>
          密码
          <input v-model="password" data-testid="login-password" type="password" autocomplete="current-password" />
        </label>
        <button type="submit" data-testid="login-submit" :disabled="authState === 'loading'">登录</button>
      </form>
      <p :data-testid="`auth-${authState}`" class="status" role="status">{{ authMessage }}</p>

      <ul v-if="devices.length > 0" data-testid="device-list">
        <li v-for="d in devices" :key="d.id" data-testid="device-item">
          {{ d.display_name }}（{{ d.role }}）{{ d.status }}
        </li>
      </ul>
    </section>
  </main>
</template>
