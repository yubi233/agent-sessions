<script setup lang="ts">
// 审计分区：脱敏审计分页（ADMIN-04）。只显示 action 与白名单 metadata，
// 不包含正文、token、路径或密钥。
import { onMounted, ref } from "vue";
import { adminReadOnlyGet, adminSessionState } from "../session";

type State = "idle" | "loading" | "ready" | "error";
const state = ref<State>("idle");
const message = ref("");
const entries = ref<Array<{ id: number; action: string; metadata: string }>>(
  [],
);
const offset = ref(0);
const limit = 20;

async function load(nextOffset = 0): Promise<void> {
  if (!adminSessionState.token) {
    state.value = "error";
    message.value = "尚未登录。请先在概览完成管理员登录。";
    return;
  }
  state.value = "loading";
  message.value = "正在读取审计记录…";
  try {
    const data = await adminReadOnlyGet<{ audit: typeof entries.value }>(
      `/v1/audit?limit=${limit}&offset=${nextOffset}`,
    );
    entries.value = data.audit;
    offset.value = nextOffset;
    state.value = "ready";
    message.value = "";
  } catch {
    state.value = "error";
    message.value = "无法读取审计记录，请检查 Relay 或重新登录。";
  }
}

function nextPage(): void {
  void load(offset.value + limit);
}

function prevPage(): void {
  if (offset.value <= 0) return;
  void load(Math.max(0, offset.value - limit));
}

onMounted(() => void load(0));
</script>

<template>
  <main class="admin-page" aria-labelledby="audit-title">
    <header class="page-intro">
      <h1 id="audit-title">审计</h1>
      <p>脱敏审计记录分页；不包含正文、token、路径或密钥。</p>
    </header>

    <section class="admin-section" aria-labelledby="audit-list-title">
      <div class="section-heading">
        <div>
          <p class="section-kicker">审计</p>
          <h2 id="audit-list-title">记录</h2>
        </div>
        <button type="button" data-testid="audit-refresh" @click="load(0)">
          刷新
        </button>
      </div>
      <p v-if="state === 'loading'" data-testid="audit-loading" class="status" role="status">
        {{ message }}
      </p>
      <p v-else-if="state === 'error'" data-testid="audit-error" class="status" role="alert">
        {{ message }}
      </p>
      <template v-else>
        <ul data-testid="audit-list" class="metadata-list">
          <li v-if="entries.length === 0" data-testid="audit-empty" class="empty-state">
            暂无审计记录。
          </li>
          <li v-for="item in entries" :key="item.id" data-testid="audit-item">
            <strong>{{ item.action }}</strong>
            <span>{{ item.metadata }}</span>
          </li>
        </ul>
        <div class="pagination" data-testid="audit-pagination">
          <button
            type="button"
            data-testid="audit-prev"
            :disabled="offset <= 0"
            @click="prevPage"
          >
            上一页
          </button>
          <span>偏移 {{ offset }}</span>
          <button
            type="button"
            data-testid="audit-next"
            :disabled="entries.length < limit"
            @click="nextPage"
          >
            下一页
          </button>
        </div>
      </template>
    </section>
  </main>
</template>
