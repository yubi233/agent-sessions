<script setup lang="ts">
// 会话列表页（只读）：展示账号会话白名单元数据，支持点击进入详情。
// 页面不提供新建/发送/终止等任何写控件；Web 只是 Relay 的只读客户端。
import { onMounted, ref } from "vue";
import { readOnlyGet, sessionState, type SessionMeta } from "../session";

type ListState = "loading" | "ready" | "error";
const state = ref<ListState>("loading");
const message = ref("");
const sessions = ref<SessionMeta[]>([]);

async function load(): Promise<void> {
  state.value = "loading";
  message.value = "正在读取会话列表…";
  try {
    const data = await readOnlyGet<{ sessions: SessionMeta[] }>(
      "/v1/sessions",
    );
    sessions.value = data.sessions;
    state.value = "ready";
    message.value = "";
  } catch {
    state.value = "error";
    message.value = "无法读取会话列表，请检查 Relay 或重新登录。";
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
  <main class="page page-workflow" aria-labelledby="sessions-title">
    <header class="page-intro">
      <p class="eyebrow">Agent Sessions</p>
      <h1 id="sessions-title">会话</h1>
      <p class="intro-copy">当前账号的只读会话列表，按最新事件倒序。</p>
    </header>

    <section class="page-section" aria-labelledby="sessions-list-title">
      <div class="section-heading">
        <div>
          <p class="section-kicker">只读</p>
          <h2 id="sessions-list-title">会话列表</h2>
        </div>
        <button
          type="button"
          data-testid="sessions-refresh"
          :disabled="state === 'loading'"
          @click="load"
        >
          刷新
        </button>
      </div>
      <p
        v-if="state === 'loading'"
        data-testid="sessions-loading"
        class="status"
        role="status"
      >
        {{ message }}
      </p>
      <p
        v-else-if="state === 'error'"
        data-testid="sessions-error"
        class="status"
        role="alert"
      >
        {{ message }}
      </p>
      <ul v-else data-testid="sessions-list" class="readonly-list">
        <li v-if="sessions.length === 0" data-testid="sessions-empty" class="status">
          还没有会话。
        </li>
        <li v-for="item in sessions" :key="item.id" class="readonly-item">
          <a :href="`#/sessions/${item.id}`" :data-testid="`session-link-${item.id}`">
            <span class="item-title">会话 {{ item.id.slice(0, 8) }}</span>
            <span class="item-sub">{{ item.provider }} · {{ item.status }}</span>
            <span class="item-sub">事件序号 {{ item.last_seq }}</span>
          </a>
        </li>
      </ul>
    </section>
  </main>
</template>
