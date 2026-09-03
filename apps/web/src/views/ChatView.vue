<script setup lang="ts">
// 主动发起 LLM 对话视图：选择本地 Workspace 后创建 DSH 会话，并发送消息。
// 依赖 Relay 已允许 web 角色写会话；事件文本仅在本地开发明文信封中展示。
import { computed, onMounted, ref } from "vue";
import { sessionState } from "../session";
import {
  acquireLease,
  createSession,
  fetchChatSnapshot,
  listWorkspaces,
  sendMessage,
  startSession,
  type ChatMessage,
  type WorkspaceInfo,
} from "../chat";

type LoadState = "loading" | "ready" | "error" | "no-token";
const state = ref<LoadState>("loading");
const message = ref("");
const workspaces = ref<WorkspaceInfo[]>([]);
const selectedWorkspace = ref("");
const sessionId = ref("");
const sessionStatus = ref("");
// v0.8.4（ADR-015 §3）：只读回合相位（无写入口，仅状态展示）。
const sessionPhase = ref<string | null>(null);
const draft = ref("");
const sending = ref(false);
const chatMessages = ref<ChatMessage[]>([]);
const chatError = ref("");

const hasSession = computed(() => sessionId.value !== "");
const canSend = computed(
  () => hasSession.value && sessionStatus.value === "idle" && draft.value.trim() !== "" && !sending.value,
);

async function loadWorkspaces(): Promise<void> {
  if (!sessionState.token) {
    state.value = "no-token";
    message.value = "请先在首页完成登录。";
    return;
  }
  state.value = "loading";
  message.value = "正在读取本地 Workspace…";
  try {
    workspaces.value = await listWorkspaces();
    if (workspaces.value.length > 0) selectedWorkspace.value = workspaces.value[0].id;
    state.value = "ready";
    message.value = "";
  } catch (err) {
    state.value = "error";
    message.value = `无法读取 Workspace：${err instanceof Error ? err.message : String(err)}`;
  }
}

async function refreshMessages(): Promise<void> {
  if (!hasSession.value) return;
  try {
    const snapshot = await fetchChatSnapshot(sessionId.value);
    sessionStatus.value = snapshot.status;
    sessionPhase.value = snapshot.turnPhase;
    chatMessages.value = snapshot.messages;
    chatError.value = "";
  } catch (err) {
    chatError.value = `读取会话失败：${err instanceof Error ? err.message : String(err)}`;
  }
}

async function waitUntilIdle(timeoutMs = 30_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    await new Promise((resolve) => window.setTimeout(resolve, 500));
    await refreshMessages();
    if (sessionStatus.value === "idle") return;
  }
}

async function newSession(): Promise<void> {
  if (!selectedWorkspace.value) {
    chatError.value = "请先选择 Workspace。";
    return;
  }
  sending.value = true;
  chatError.value = "";
  try {
    const created = await createSession(selectedWorkspace.value, "dsh");
    sessionId.value = created.id;
    const epoch = await acquireLease(sessionId.value);
    await startSession(sessionId.value, epoch, "dsh");
    sessionStatus.value = "starting";
    chatMessages.value = [];
    await waitUntilIdle();
  } catch (err) {
    chatError.value = `新建会话失败：${err instanceof Error ? err.message : String(err)}`;
  } finally {
    sending.value = false;
  }
}

async function send(): Promise<void> {
  const text = draft.value.trim();
  if (!text || !canSend.value) return;
  sending.value = true;
  chatError.value = "";
  try {
    const epoch = await acquireLease(sessionId.value);
    await sendMessage(sessionId.value, epoch, text);
    draft.value = "";
    sessionStatus.value = "running";
    chatMessages.value = [...chatMessages.value, { seq: Date.now(), role: "user", text }];
    const deadline = Date.now() + 180_000;
    while (Date.now() < deadline) {
      await new Promise((resolve) => window.setTimeout(resolve, 800));
      await refreshMessages();
      if (sessionStatus.value === "idle") break;
    }
  } catch (err) {
    chatError.value = `发送失败：${err instanceof Error ? err.message : String(err)}`;
  } finally {
    sending.value = false;
    await refreshMessages();
  }
}

onMounted(loadWorkspaces);
</script>

<template>
  <main class="page page-workflow" aria-labelledby="chat-title">
    <header class="page-intro">
      <p class="eyebrow">Agent Sessions</p>
      <h1 id="chat-title">LLM 对话</h1>
      <p class="intro-copy">通过本地 DSH 桥主动发起会话，当前适合本地开发明文事件模式。</p>
    </header>

    <section class="page-section" aria-labelledby="chat-setup-title">
      <div class="section-heading">
        <div>
          <p class="section-kicker">设置</p>
          <h2 id="chat-setup-title">Workspace 与会话</h2>
        </div>
      </div>
      <p v-if="state === 'no-token'" data-testid="chat-no-token" class="status" role="alert">
        {{ message }}
      </p>
      <p v-else-if="state === 'error'" data-testid="chat-error" class="status status-error" role="alert">
        {{ message }}
      </p>
      <template v-else-if="state === 'ready'">
        <label for="chat-workspace">
          Workspace
          <select id="chat-workspace" v-model="selectedWorkspace" data-testid="chat-workspace">
            <option v-for="ws in workspaces" :key="ws.id" :value="ws.id">
              {{ ws.project_id }} ({{ ws.id }})
            </option>
          </select>
        </label>
        <button
          type="button"
          data-testid="chat-new-session"
          :disabled="sending || !selectedWorkspace"
          @click="newSession"
        >
          新建 DSH 会话
        </button>
        <p v-if="hasSession" data-testid="chat-session-id" class="status">
          会话：{{ sessionId }} · 状态：{{ sessionStatus }}<template v-if="sessionPhase"> · 相位：{{ sessionPhase }}</template>
        </p>
      </template>
    </section>

    <section v-if="hasSession" class="page-section" aria-labelledby="chat-conversation-title">
      <div class="section-heading">
        <div>
          <p class="section-kicker">对话</p>
          <h2 id="chat-conversation-title">消息</h2>
        </div>
        <button type="button" data-testid="chat-refresh" :disabled="sending" @click="refreshMessages">
          刷新
        </button>
      </div>
      <p v-if="chatError" data-testid="chat-error" class="status status-error" role="alert">
        {{ chatError }}
      </p>
      <div v-if="chatMessages.length > 0" data-testid="chat-messages" class="chat-messages">
        <div
          v-for="m in chatMessages"
          :key="m.seq"
          class="chat-message"
          :data-testid="`chat-message-${m.role}`"
        >
          <strong>{{ m.role === "user" ? "你" : m.role === "assistant" ? "助手" : m.role }}</strong>
          <pre>{{ m.text }}</pre>
        </div>
      </div>
      <p v-else data-testid="chat-empty" class="status">
        还没有消息。
      </p>

      <form class="composer" data-testid="chat-form" @submit.prevent="send">
        <textarea
          v-model="draft"
          data-testid="chat-input"
          :disabled="sending || !hasSession"
          rows="3"
          placeholder="输入消息后发送"
        ></textarea>
        <button type="submit" data-testid="chat-send" :disabled="!canSend">
          {{ sending ? "发送中…" : "发送" }}
        </button>
      </form>
    </section>
  </main>
</template>

<style scoped>
.chat-messages {
  display: flex;
  flex-direction: column;
  gap: 0.75rem;
  max-height: 50vh;
  overflow: auto;
  padding: 0.5rem 0;
}
.chat-message {
  border: 1px solid var(--border, #ddd);
  border-radius: 0.5rem;
  padding: 0.5rem 0.75rem;
}
.chat-message pre {
  white-space: pre-wrap;
  margin: 0.25rem 0 0;
}
.composer {
  display: flex;
  gap: 0.5rem;
  align-items: flex-end;
  margin-top: 1rem;
}
.composer textarea {
  flex: 1;
  resize: vertical;
}
</style>