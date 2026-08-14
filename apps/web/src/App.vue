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
  </main>
</template>
