<script setup lang="ts">
// 能力矩阵只读视图：登录后展示 Relay /v1/capabilities 的真实探测结果，
// 覆盖 E2E-OPENCODE-01 的验收面——opencode 的 available/version/start/resume/abort
// 与 Detect 一致，且页面无任何写入口（无发送、无审批）。
// 口径见 docs/zh/项目文档.md「8. 统一能力模型」与「Vue Web App」章节。
import { onMounted, ref } from "vue";
import CapabilitiesMatrix from "../components/CapabilitiesMatrix.vue";
import { sessionState } from "../session";
import type { ProviderCapabilities } from "../types";

const relayURL = import.meta.env.VITE_RELAY_URL ?? "http://127.0.0.1:8787";

const loadState = ref<"loading" | "ok" | "error" | "no-token">("loading");
const loadMessage = ref("");
const providers = ref<ProviderCapabilities[]>([]);

// 拉取能力矩阵；token 缺失时不发请求，只提示登录（页面仍无写入口）。
async function loadCapabilities(): Promise<void> {
  if (!sessionState.token) {
    loadState.value = "no-token";
    loadMessage.value = "请先在首页完成只读登录。";
    return;
  }
  loadState.value = "loading";
  loadMessage.value = "正在读取能力矩阵…";
  try {
    const response = await fetch(`${relayURL}/v1/capabilities`, {
      headers: { Authorization: `Bearer ${sessionState.token}` },
    });
    if (!response.ok) {
      throw new Error(`capabilities ${response.status}`);
    }
    providers.value = (await response.json()).providers;
    loadState.value = "ok";
    loadMessage.value = "";
  } catch (err) {
    loadState.value = "error";
    loadMessage.value = `能力矩阵读取失败：${err instanceof Error ? err.message : String(err)}`;
  }
}

onMounted(loadCapabilities);
</script>

<template>
  <main class="page" aria-labelledby="matrix-title">
    <header class="page-intro">
      <p class="eyebrow">Agent Sessions</p>
      <h1 id="matrix-title">Provider 能力矩阵</h1>
      <p class="intro-copy">
        能力来自 Relay 探测结果，未声明的能力默认不可用。
      </p>
    </header>
    <section class="page-section capability-section">
      <p
        :data-testid="`matrix-${loadState}`"
        class="status"
        role="status"
        aria-live="polite"
      >
        {{ loadMessage }}
      </p>

      <div v-if="loadState === 'ok'" data-testid="capability-matrix-view">
        <CapabilitiesMatrix :providers="providers" />
      </div>

      <button
        v-if="loadState === 'error' || loadState === 'no-token'"
        type="button"
        data-testid="matrix-retry"
        @click="loadCapabilities"
      >
        重新加载
      </button>
      <RouterLink
        v-if="loadState === 'ok'"
        to="/"
        data-testid="matrix-back"
        class="text-link"
      >
        返回首页
      </RouterLink>
    </section>
  </main>
</template>
