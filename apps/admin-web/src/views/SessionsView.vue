<script setup lang="ts">
// 会话分区：展示会话白名单元数据（status/provider/last_seq）。
// 不展示消息正文、密文或任何写控件。
import { onMounted, ref } from "vue";
import { adminReadOnlyGet, adminSessionState } from "../session";

type State = "idle" | "loading" | "ready" | "error";
const state = ref<State>("idle");
const message = ref("");
const sessions = ref<
  Array<{ id: string; status: string; provider: string; last_seq: number }>
>([]);

async function load(): Promise<void> {
  if (!adminSessionState.token) {
    state.value = "error";
    message.value = "尚未登录。请先在概览完成管理员登录。";
    return;
  }
  state.value = "loading";
  message.value = "正在读取会话元数据…";
  try {
    const data = await adminReadOnlyGet<{ sessions: typeof sessions.value }>(
      "/v1/sessions",
    );
    sessions.value = data.sessions;
    state.value = "ready";
    message.value = "";
  } catch {
    state.value = "error";
    message.value = "无法读取会话元数据，请检查 Relay 或重新登录。";
  }
}

onMounted(load);
</script>

<template>
  <main class="admin-page" aria-labelledby="sessions-title">
    <header class="page-intro">
      <h1 id="sessions-title">会话</h1>
      <p>仅显示会话白名单元数据；正文、token 与密文不在此页出现。</p>
    </header>

    <section class="admin-section" aria-labelledby="sessions-list-title">
      <div class="section-heading">
        <div>
          <p class="section-kicker">资源</p>
          <h2 id="sessions-list-title">会话列表</h2>
        </div>
        <button type="button" data-testid="sessions-refresh" @click="load">
          刷新
        </button>
      </div>
      <p v-if="state === 'loading'" data-testid="sessions-loading" class="status" role="status">
        {{ message }}
      </p>
      <p v-else-if="state === 'error'" data-testid="sessions-error" class="status" role="alert">
        {{ message }}
      </p>
      <ul v-else data-testid="sessions-list" class="metadata-list">
        <li v-if="sessions.length === 0" data-testid="sessions-empty" class="empty-state">
          无会话。
        </li>
        <li v-for="item in sessions" :key="item.id" data-testid="session-item">
          <strong>{{ item.provider }}</strong>
          <span>{{ item.status }}</span>
          <span>事件序号 {{ item.last_seq }}</span>
        </li>
      </ul>
    </section>
  </main>
</template>
