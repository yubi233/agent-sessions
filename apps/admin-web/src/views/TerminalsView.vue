<script setup lang="ts">
// 终端分区：展示 Relay 白名单终端投影（hostname/平台/状态/版本）。
// 不显示终端 ID、路径、日志；无重启或任何写入口。
import { onMounted, ref } from "vue";
import { adminReadOnlyGet, adminSessionState } from "../session";

type State = "idle" | "loading" | "ready" | "error";
const state = ref<State>("idle");
const message = ref("");
const terminals = ref<
  Array<{
    id: string;
    hostname: string;
    platform: string;
    status: string;
    protocol_version?: number;
    daemon_version?: string;
  }>
>([]);

async function load(): Promise<void> {
  if (!adminSessionState.token) {
    state.value = "error";
    message.value = "尚未登录。请先在概览完成管理员登录。";
    return;
  }
  state.value = "loading";
  message.value = "正在读取终端状态…";
  try {
    const data = await adminReadOnlyGet<{ terminals: typeof terminals.value }>(
      "/v1/terminals",
    );
    terminals.value = data.terminals;
    state.value = "ready";
    message.value = "";
  } catch {
    state.value = "error";
    message.value = "无法读取终端状态，请检查 Relay 或重新登录。";
  }
}

onMounted(load);
</script>

<template>
  <main class="admin-page" aria-labelledby="terminals-title">
    <header class="page-intro">
      <h1 id="terminals-title">终端</h1>
      <p>已配对终端的白名单状态；不展示路径、日志或命令正文。</p>
    </header>

    <section class="admin-section" aria-labelledby="terminals-list-title">
      <div class="section-heading">
        <div>
          <p class="section-kicker">资源</p>
          <h2 id="terminals-list-title">终端列表</h2>
        </div>
        <button type="button" data-testid="terminals-refresh" @click="load">
          刷新
        </button>
      </div>
      <p v-if="state === 'loading'" data-testid="terminals-loading" class="status" role="status">
        {{ message }}
      </p>
      <p v-else-if="state === 'error'" data-testid="terminals-error" class="status" role="alert">
        {{ message }}
      </p>
      <ul v-else data-testid="terminals-list" class="metadata-list">
        <li v-if="terminals.length === 0" data-testid="terminals-empty" class="empty-state">
          还没有已确认的终端。
        </li>
        <li v-for="item in terminals" :key="item.id" data-testid="terminal-item">
          <strong>{{ item.hostname || "未命名终端" }}</strong>
          <span>{{ item.platform || "未知平台" }} · {{ item.status }}</span>
          <span>Daemon {{ item.daemon_version || "版本未知" }} · 协议 v{{ item.protocol_version ?? 0 }}</span>
        </li>
      </ul>
    </section>
  </main>
</template>
