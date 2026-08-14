<script setup lang="ts">
import { onMounted, ref } from "vue";

// Admin 只读运维投影：展示设备、Terminal、版本与健康等脱敏元数据。
// 绝不显示消息正文、文件内容、diff、工具参数、token、恢复码或会话密文。

type HealthState = "loading" | "ready" | "error";

const state = ref<HealthState>("loading");
const message = ref("正在连接 Relay…");
const relayURL = import.meta.env.VITE_RELAY_URL ?? "http://127.0.0.1:8787";

const email = ref("");
const password = ref("");
const authState = ref<"idle" | "loading" | "ok" | "error">("idle");
const authMessage = ref("");
const token = ref("");
// 只读元数据白名单字段；不含任何正文/密钥。
const devices = ref<Array<{ id: string; role: string; display_name: string; status: string }>>([]);
const sessions = ref<Array<{ id: string; status: string; provider: string }>>([]);

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

// 只读加载设备与会话元数据；Admin 无配对/撤销/写入口。
async function loadReadOnly(): Promise<void> {
  const headers = { Authorization: `Bearer ${token.value}` };
  const [devRes, sessRes] = await Promise.all([
    fetch(`${relayURL}/v1/devices`, { headers }),
    fetch(`${relayURL}/v1/sessions`, { headers }),
  ]);
  if (!devRes.ok || !sessRes.ok) throw new Error("read-only fetch failed");
  devices.value = (await devRes.json()).devices;
  sessions.value = (await sessRes.json()).sessions;
}

async function login(): Promise<void> {
  authState.value = "loading";
  authMessage.value = "正在登录…";
  try {
    const loginRes = await fetch(`${relayURL}/v1/auth/login`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ email: email.value, password: password.value, device_id: "admin", role: "admin" }),
    });
    if (!loginRes.ok) throw new Error(`login ${loginRes.status}`);
    const data = (await loginRes.json()) as { access_token: string };
    token.value = data.access_token;
    await loadReadOnly();
    authState.value = "ok";
    authMessage.value = "已登录（运维只读）。";
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
      <h1 id="page-title">运维只读控制台</h1>
      <p :data-testid="`relay-${state}`" class="status" role="status">{{ message }}</p>
      <button type="button" data-testid="refresh-health" @click="refreshHealth">重新检查</button>
    </section>

    <section class="card" aria-labelledby="login-title">
      <h2 id="login-title">管理员登录</h2>
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
    </section>

    <section class="card" aria-labelledby="devices-title">
      <h2 id="devices-title">设备（脱敏元数据）</h2>
      <ul v-if="devices.length > 0" data-testid="device-list">
        <li v-for="d in devices" :key="d.id" data-testid="device-item">
          {{ d.display_name }}（{{ d.role }}）{{ d.status }}
        </li>
      </ul>
      <p v-else data-testid="device-empty" class="muted">无设备。</p>
    </section>

    <section class="card" aria-labelledby="sessions-title">
      <h2 id="sessions-title">会话（脱敏元数据）</h2>
      <ul v-if="sessions.length > 0" data-testid="session-list">
        <li v-for="s in sessions" :key="s.id" data-testid="session-item">
          {{ s.provider }} · {{ s.status }}
        </li>
      </ul>
      <p v-else data-testid="session-empty" class="muted">无会话。</p>
    </section>
  </main>
</template>
