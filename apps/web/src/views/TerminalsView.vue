<script setup lang="ts">
// 终端状态页（只读）：展示 Relay 白名单终端投影（hostname/平台/状态/版本）。
// 不显示终端 ID 之外的敏感字段，不提供重启或任何写入口。
import { onMounted, ref } from "vue";
import { readOnlyGet, sessionState, type TerminalMeta } from "../session";

type State = "loading" | "ready" | "error";
const state = ref<State>("loading");
const message = ref("");
const terminals = ref<TerminalMeta[]>([]);

async function load(): Promise<void> {
  state.value = "loading";
  message.value = "正在读取终端状态…";
  try {
    const data = await readOnlyGet<{ terminals: TerminalMeta[] }>(
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

onMounted(() => {
  if (sessionState.token) void load();
  else {
    state.value = "error";
    message.value = "尚未登录。请先在首页完成只读登录。";
  }
});
</script>

<template>
  <main class="page page-workflow" aria-labelledby="terminals-title">
    <header class="page-intro">
      <p class="eyebrow">Agent Sessions</p>
      <h1 id="terminals-title">终端状态</h1>
      <p class="intro-copy">已配对终端的白名单状态；不展示路径、日志或命令正文。</p>
    </header>

    <section class="page-section" aria-labelledby="terminals-list-title">
      <div class="section-heading">
        <div>
          <p class="section-kicker">只读</p>
          <h2 id="terminals-list-title">终端列表</h2>
        </div>
        <button
          type="button"
          data-testid="terminals-refresh"
          :disabled="state === 'loading'"
          @click="load"
        >
          刷新
        </button>
      </div>
      <p v-if="state === 'loading'" data-testid="terminals-loading" class="status" role="status">
        {{ message }}
      </p>
      <p v-else-if="state === 'error'" data-testid="terminals-error" class="status" role="alert">
        {{ message }}
      </p>
      <ul v-else data-testid="terminals-list" class="readonly-list">
        <li v-if="terminals.length === 0" data-testid="terminals-empty" class="status">
          还没有已确认的终端。
        </li>
        <li v-for="item in terminals" :key="item.id" class="readonly-item">
          <span class="item-title">{{ item.hostname || "未命名终端" }}</span>
          <span class="item-sub">{{ item.platform || "未知平台" }} · {{ item.status }}</span>
          <span class="item-sub">
            Daemon {{ item.daemon_version || "版本未知" }} · 协议 v{{ item.protocol_version ?? 0 }}
          </span>
        </li>
      </ul>
    </section>
  </main>
</template>
