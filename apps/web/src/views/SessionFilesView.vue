<script setup lang="ts">
// 工作区文件只读页：所有文件请求都通过 Web 临时密钥 transport。页面状态只存在当前 Vue
// 实例；路由离开或刷新后不会保留解密内容或临时私钥。
import { onBeforeUnmount, onMounted, ref } from "vue";
import { useRoute } from "vue-router";
import { WebReadTransportError, requestWebRead } from "../read_transport";
import { sessionState } from "../session";

interface FileEntry {
  path: string;
  is_dir: boolean;
  size: number;
}

interface CodeRead {
  path: string;
  content: string;
}

const route = useRoute();
const sessionId = String(route.params.id ?? "");
const entries = ref<FileEntry[]>([]);
const currentPath = ref(".");
const code = ref<CodeRead | null>(null);
const loading = ref(false);
const error = ref("");

async function loadTree(path = "."): Promise<void> {
  if (!sessionState.token) {
    error.value = "请先完成只读登录。";
    return;
  }
  loading.value = true;
  error.value = "";
  code.value = null;
  try {
    entries.value = await requestWebRead<FileEntry[]>(sessionId, "file.tree", { path });
    currentPath.value = path;
  } catch (cause) {
    error.value = messageFor(cause);
  } finally {
    loading.value = false;
  }
}

async function openEntry(entry: FileEntry): Promise<void> {
  if (entry.is_dir) {
    await loadTree(entry.path);
    return;
  }
  loading.value = true;
  error.value = "";
  try {
    code.value = await requestWebRead<CodeRead>(sessionId, "code.read", { path: entry.path });
  } catch (cause) {
    code.value = null;
    error.value = messageFor(cause);
  } finally {
    loading.value = false;
  }
}

function messageFor(cause: unknown): string {
  if (cause instanceof WebReadTransportError) {
    if (cause.code === "CONTENT_UNAVAILABLE") return "该文件不能作为文本读取。";
    if (cause.code === "PAYLOAD_TOO_LARGE") return "该文件超过只读大小限制。";
    if (cause.code === "WORKSPACE_PATH_DENIED") return "该路径不在已确认工作区内。";
  }
  return "无法读取工作区内容，请检查终端连接后重试。";
}

function displaySize(size: number): string {
  if (size < 1024) return `${size} B`;
  return `${Math.ceil(size / 1024)} KiB`;
}

onMounted(() => void loadTree());
onBeforeUnmount(() => {
  // 清空已解密文本，避免被保存在组件缓存或浏览器前进/后退状态中。
  entries.value = [];
  code.value = null;
});
</script>

<template>
  <main class="page page-workflow" aria-labelledby="files-title">
    <header class="page-intro">
      <p class="eyebrow">Agent Sessions</p>
      <h1 id="files-title">工作区文件</h1>
      <p class="intro-copy">会话 {{ sessionId.slice(0, 8) }} 的加密只读文件浏览。</p>
    </header>

    <p class="back-link">
      <a :href="`#/sessions/${sessionId}`" data-testid="files-back">← 返回会话详情</a>
    </p>

    <section class="page-section" aria-labelledby="files-list-title">
      <div class="section-heading">
        <div>
          <p class="section-kicker">只读</p>
          <h2 id="files-list-title">{{ currentPath }}</h2>
        </div>
        <button type="button" data-testid="files-refresh" :disabled="loading" @click="loadTree(currentPath)">
          刷新
        </button>
      </div>

      <p v-if="loading" data-testid="files-loading" class="status" role="status">正在通过终端读取…</p>
      <p v-else-if="error" data-testid="files-error" class="status status-error" role="alert">{{ error }}</p>
      <p v-else-if="entries.length === 0" data-testid="files-empty" class="empty-state">当前目录没有可显示的条目。</p>
      <ul v-else data-testid="files-tree" class="readonly-list">
        <li v-for="entry in entries" :key="entry.path" class="readonly-list-item">
          <button
            type="button"
            class="list-action"
            :data-testid="`file-entry-${entry.path}`"
            :disabled="loading"
            @click="openEntry(entry)"
          >
            <span>{{ entry.is_dir ? "目录" : "文件" }}</span>
            <strong>{{ entry.path }}</strong>
            <small>{{ entry.is_dir ? "" : displaySize(entry.size) }}</small>
          </button>
        </li>
      </ul>
    </section>

    <section v-if="code" class="page-section" aria-labelledby="code-title">
      <div class="section-heading">
        <div>
          <p class="section-kicker">文本只读</p>
          <h2 id="code-title">{{ code.path }}</h2>
        </div>
      </div>
      <pre data-testid="files-code" class="code-preview"><code>{{ code.content }}</code></pre>
    </section>
  </main>
</template>
