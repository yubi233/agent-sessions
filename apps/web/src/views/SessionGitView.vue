<script setup lang="ts">
// Git 页面只展示当前浏览器临时密钥解开的结构化状态和 diff；不把内容写入共享 store 或本地缓存。
import { onBeforeUnmount, onMounted, ref } from "vue";
import { useRoute } from "vue-router";
import { WebReadTransportError, requestWebRead } from "../read_transport";
import { sessionState } from "../session";

interface GitFile {
  path: string;
  type: string;
  staged: boolean;
  unstaged: boolean;
  binary: boolean;
  additions: number;
  deletions: number;
}

interface GitStatus {
  branch: string;
  snapshot_token: string;
  files: GitFile[];
  truncated: boolean;
}

interface DiffHunk {
  header: string;
  lines: string[];
}

interface GitDiff {
  path: string;
  has_more: boolean;
  next_offset: number;
  binary: boolean;
  truncated: boolean;
  hunks: DiffHunk[];
}

const route = useRoute();
const sessionId = String(route.params.id ?? "");
const status = ref<GitStatus | null>(null);
const diff = ref<GitDiff | null>(null);
const loading = ref(false);
const error = ref("");

async function loadStatus(): Promise<void> {
  if (!sessionState.token) {
    error.value = "请先完成只读登录。";
    return;
  }
  loading.value = true;
  error.value = "";
  diff.value = null;
  try {
    status.value = await requestWebRead<GitStatus>(sessionId, "git.status", {});
  } catch (cause) {
    status.value = null;
    error.value = messageFor(cause);
  } finally {
    loading.value = false;
  }
}

async function openDiff(file: GitFile): Promise<void> {
  if (!status.value || file.binary) return;
  loading.value = true;
  error.value = "";
  try {
    diff.value = await requestWebRead<GitDiff>(sessionId, "git.diff", {
      path: file.path,
      snapshot_token: status.value.snapshot_token,
      offset: 0,
      limit: 100,
    });
  } catch (cause) {
    diff.value = null;
    error.value = messageFor(cause);
  } finally {
    loading.value = false;
  }
}

function messageFor(cause: unknown): string {
  if (cause instanceof WebReadTransportError && cause.code === "SNAPSHOT_STALE") {
    return "工作区已变化，请刷新 Git 状态后重试。";
  }
  return "无法读取 Git 状态，请检查终端连接后重试。";
}

onMounted(() => void loadStatus());
onBeforeUnmount(() => {
  status.value = null;
  diff.value = null;
});
</script>

<template>
  <main class="page page-workflow" aria-labelledby="git-title">
    <header class="page-intro">
      <p class="eyebrow">Agent Sessions</p>
      <h1 id="git-title">Git 变更</h1>
      <p class="intro-copy">会话 {{ sessionId.slice(0, 8) }} 的加密只读变更视图。</p>
    </header>

    <p class="back-link">
      <a :href="`#/sessions/${sessionId}`" data-testid="git-back">← 返回会话详情</a>
    </p>

    <section class="page-section" aria-labelledby="git-status-title">
      <div class="section-heading">
        <div>
          <p class="section-kicker">只读</p>
          <h2 id="git-status-title">{{ status?.branch || "工作区状态" }}</h2>
        </div>
        <button type="button" data-testid="git-refresh" :disabled="loading" @click="loadStatus">刷新</button>
      </div>

      <p v-if="loading" data-testid="git-loading" class="status" role="status">正在通过终端读取…</p>
      <p v-else-if="error" data-testid="git-error" class="status status-error" role="alert">{{ error }}</p>
      <p v-else-if="status && status.files.length === 0" data-testid="git-empty" class="empty-state">当前工作区没有变更。</p>
      <ul v-else-if="status" data-testid="git-changes" class="readonly-list">
        <li v-for="file in status.files" :key="file.path" class="readonly-list-item">
          <button
            type="button"
            class="list-action"
            :data-testid="`git-file-${file.path}`"
            :disabled="loading || file.binary"
            @click="openDiff(file)"
          >
            <span>{{ file.binary ? "二进制" : file.type }}</span>
            <strong>{{ file.path }}</strong>
            <small>+{{ file.additions }} −{{ file.deletions }}</small>
          </button>
        </li>
      </ul>
      <p v-if="status?.truncated" class="status" role="status">变更列表已受限显示。</p>
    </section>

    <section v-if="diff" class="page-section" aria-labelledby="diff-title">
      <div class="section-heading">
        <div>
          <p class="section-kicker">只读 Diff</p>
          <h2 id="diff-title">{{ diff.path }}</h2>
        </div>
      </div>
      <p v-if="diff.binary || diff.truncated" class="status" role="status">该 diff 不能完整显示。</p>
      <pre v-else data-testid="git-diff" class="code-preview"><code v-for="hunk in diff.hunks" :key="hunk.header">{{ hunk.header }}
{{ hunk.lines.join("\n") }}
</code></pre>
    </section>
  </main>
</template>
