<script setup lang="ts">
// 会话详情页（只读）：展示会话白名单状态与事件序号列表。
// 事件 envelope 是密文，浏览器端不尝试解密；文件/Git 依赖 Daemon 加密
// 只读 RPC，Web 未接入时明确显示 unavailable，不伪造成功。
import { onMounted, onUnmounted, ref } from "vue";
import { useRoute } from "vue-router";
import {
  createDetailSync,
  decodeSessionSnapshot,
  mergeSessionEventMeta,
  readOnlyGet,
  sessionState,
  startAccountEventStream,
  type AccountEventStream,
  type AccountEventStreamStatus,
  type DetailSyncController,
  type DetailSyncState,
  type SessionEventMeta,
} from "../session";

const route = useRoute();
const sessionId = String(route.params.id ?? "");

type DetailState = "loading" | "ready" | "error";
const state = ref<DetailState>("loading");
const message = ref("");
const status = ref("");
const provider = ref("");
const lastSeq = ref(0);
const events = ref<SessionEventMeta[]>([]);
const streamStatus = ref<AccountEventStreamStatus>("stopped");
// V094-27：数据同步状态与 SSE 连接状态分开表达；连接 live 不冒充同步完成。
const syncState = ref<DetailSyncState>("synced");
let stream: AccountEventStream | undefined;
let sync: DetailSyncController | undefined;

async function loadIncremental(): Promise<void> {
  const raw = await readOnlyGet<unknown>(`/v1/sessions/${sessionId}/snapshot?after_seq=${lastSeq.value}`);
  const snapshot = decodeSessionSnapshot(raw);
  status.value = snapshot.session.status;
  provider.value = snapshot.session.provider;
  lastSeq.value = snapshot.session.last_seq;
  events.value = mergeSessionEventMeta(events.value, snapshot.events);
}

function ensureSync(): DetailSyncController {
  sync ??= createDetailSync({
    loadIncremental: () => loadIncremental(),
    isReady: () => state.value === "ready",
  });
  return sync;
}

async function load(afterSeq = 0): Promise<void> {
  const initialLoad = afterSeq === 0;
  if (initialLoad) {
    state.value = "loading";
    message.value = "正在读取会话详情…";
  }
  try {
    const raw = await readOnlyGet<unknown>(`/v1/sessions/${sessionId}/snapshot?after_seq=${afterSeq}`);
    const snapshot = decodeSessionSnapshot(raw);
    status.value = snapshot.session.status;
    provider.value = snapshot.session.provider;
    lastSeq.value = snapshot.session.last_seq;
    events.value = initialLoad ? snapshot.events : mergeSessionEventMeta(events.value, snapshot.events);
    state.value = "ready";
    message.value = "";
  } catch {
    if (initialLoad) {
      state.value = "error";
      message.value = "无法读取会话详情，请检查 Relay 或重新登录。";
    } else {
      // V094-27：增量失败保留最后可信内容，标记同步失败（有界重试由
      // DetailSyncController 驱动），绝不清空页面。
      syncState.value = "error";
    }
  }
}

function refresh(): void {
  ensureSync().refresh();
}

function refreshAfterInvalidation(): void {
  ensureSync().onInvalidate();
}

function startStream(): void {
  stream?.stop();
  stream = startAccountEventStream({
    token: () => sessionState.token,
    onInvalidate: refreshAfterInvalidation,
    onStatus: (nextStatus) => {
      const previous = streamStatus.value;
      streamStatus.value = nextStatus;
      // V094-27：重连恢复 live 时主动补拉一次——已推进的 SSE 游标不代表
      // 本会话 snapshot 已合并，不能仅靠下一次事件兜底。
      if (nextStatus === "live" && previous !== "live") {
        ensureSync().onReconnected();
      }
    },
  });
}

function syncStatusLabel(syncValue: DetailSyncState): string {
  const labels: Record<DetailSyncState, string> = {
    synced: "数据已同步",
    syncing: "正在同步",
    error: "同步失败 · 保留最近内容",
  };
  return labels[syncValue];
}

function streamStatusLabel(statusValue: AccountEventStreamStatus): string {
  const labels: Record<AccountEventStreamStatus, string> = {
    connecting: "正在连接",
    live: "已连接",
    reconnecting: "正在恢复",
    unauthorized: "认证已失效",
    error: "连接暂不可用",
    stopped: "未连接",
  };
  return labels[statusValue];
}

onMounted(() => {
  if (sessionState.token) {
    void load().then(() => {
      if (state.value === "ready") startStream();
    });
  }
  else {
    state.value = "error";
    message.value = "尚未登录。请先在首页完成只读登录。";
  }
});

onUnmounted(() => {
  stream?.stop();
  sync?.dispose();
});
</script>

<template>
  <main class="page page-workflow" aria-labelledby="session-detail-title">
    <header class="page-intro">
      <p class="eyebrow">Agent Sessions</p>
      <h1 id="session-detail-title">会话详情</h1>
      <p class="intro-copy">只读展示 Relay 白名单状态；消息正文与文件内容不在此页出现。</p>
    </header>

    <p class="back-link">
      <a href="#/sessions" data-testid="session-detail-back">← 返回会话列表</a>
    </p>

    <section class="page-section" aria-labelledby="meta-title">
      <div class="section-heading">
        <div>
          <p class="section-kicker">元数据</p>
          <h2 id="meta-title">会话 {{ sessionId.slice(0, 8) }}</h2>
        </div>
        <button
          type="button"
          data-testid="session-detail-refresh"
          :disabled="state === 'loading'"
          @click="refresh"
        >
          刷新
        </button>
      </div>
      <p v-if="state === 'loading'" data-testid="session-detail-loading" class="status" role="status">
        {{ message }}
      </p>
      <p v-else-if="state === 'error'" data-testid="session-detail-error" class="status" role="alert">
        {{ message }}
      </p>
      <template v-else>
        <dl class="meta-list" data-testid="session-detail-meta">
          <div><dt>状态</dt><dd data-testid="session-detail-status">{{ status }}</dd></div>
          <div><dt>Provider</dt><dd>{{ provider }}</dd></div>
          <div><dt>事件序号</dt><dd>{{ lastSeq }}</dd></div>
        </dl>
        <p class="status" role="status" aria-live="polite" data-testid="session-detail-stream-status">
          实时更新：{{ streamStatusLabel(streamStatus) }} · {{ syncStatusLabel(syncState) }}
        </p>

        <h3>事件时间线</h3>
        <ul data-testid="session-detail-events" class="readonly-list">
          <li v-if="events.length === 0" class="status">暂无事件。</li>
          <li v-for="event in events" :key="event.event_seq" class="readonly-item">
            <span class="item-title">#{{ event.event_seq }} {{ event.event_type }}</span>
          </li>
        </ul>

        <h3>只读工具</h3>
        <ul class="readonly-list">
          <li class="readonly-item">
            <a :href="`#/sessions/${sessionId}/files`" data-testid="session-files-link">
              <span class="item-title">工作区文件</span>
              <span class="item-sub">依赖 Daemon 加密只读 RPC</span>
            </a>
          </li>
          <li class="readonly-item">
            <a :href="`#/sessions/${sessionId}/git`" data-testid="session-git-link">
              <span class="item-title">Git Diff</span>
              <span class="item-sub">依赖 Daemon 加密只读 RPC</span>
            </a>
          </li>
        </ul>
      </template>
    </section>
  </main>
</template>
