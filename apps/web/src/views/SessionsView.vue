<script setup lang="ts">
// DSH 工作区优先的只读视图：只消费 Relay 安全投影，不提供或调用同步、导入、建会话、恢复、发送 API。
import { computed, onMounted, ref } from "vue";
import { readOnlyGet, sessionState, type SessionMeta } from "../session";

type ListState = "loading" | "ready" | "error";
type WorkspaceMeta = {
  id: string;
  project_id: string;
  terminal_id?: string;
  origin?: "managed" | "dsh";
  display_name?: string;
};

const state = ref<ListState>("loading");
const message = ref("");
const sessions = ref<SessionMeta[]>([]);
const workspaces = ref<WorkspaceMeta[]>([]);
const showSecondarySessions = ref(false);
const expandedWorkspaceIds = ref(new Set<string>());
const selectedWorkspaceId = ref<string | null>(null);
const workspaceQuery = ref("");

async function load(): Promise<void> {
  state.value = "loading";
  message.value = "正在读取 DSH 工作区…";
  try {
    const [sessionData, workspaceData] = await Promise.all([
      readOnlyGet<{ sessions?: SessionMeta[] }>("/v1/sessions"),
      readOnlyGet<{ workspaces?: WorkspaceMeta[] }>("/v1/workspaces"),
    ]);
    sessions.value = sessionData.sessions ?? [];
    workspaces.value = workspaceData.workspaces ?? [];
    state.value = "ready";
    message.value = "";
  } catch {
    state.value = "error";
    message.value = "无法读取工作区列表，请检查 Relay 或重新登录。";
  }
}

const dshGroups = computed(() =>
  workspaces.value
    .filter((workspace) => workspace.origin === "dsh")
    .map((workspace) => ({
      workspace,
      label: workspace.display_name?.trim() || "未命名 DSH 工作区",
      items: sessions.value.filter(
        (session) =>
          session.workspace_id === workspace.id && session.provider === "dsh",
      ),
    }))
    .sort((left, right) => left.label.localeCompare(right.label, "zh-CN")),
);

const filteredDshGroups = computed(() => {
  const query = workspaceQuery.value.trim().toLocaleLowerCase("zh-CN");
  if (query.length === 0) return dshGroups.value;
  return dshGroups.value.filter((group) =>
    group.label.toLocaleLowerCase("zh-CN").includes(query),
  );
});

const secondarySessions = computed(() =>
  sessions.value.filter((session) => session.provider !== "dsh"),
);

const selectedWorkspace = computed(
  () =>
    filteredDshGroups.value.find(
      (group) => group.workspace.id === selectedWorkspaceId.value,
    ) ?? null,
);

function isExpanded(workspaceId: string): boolean {
  return expandedWorkspaceIds.value.has(workspaceId);
}

function toggleWorkspace(workspaceId: string): void {
  const next = new Set(expandedWorkspaceIds.value);
  if (next.has(workspaceId)) next.delete(workspaceId);
  else next.add(workspaceId);
  expandedWorkspaceIds.value = next;
}

function selectWorkspace(workspaceId: string): void {
  selectedWorkspaceId.value = workspaceId;
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
      <h1 id="sessions-title">DSH 工作区</h1>
      <p class="intro-copy">只读查看已同步的工作区和会话元数据。</p>
    </header>

    <section class="page-section" aria-labelledby="workspace-list-title">
      <div class="section-heading">
        <div>
          <p class="section-kicker">只读</p>
          <h2 id="workspace-list-title">
            {{ showSecondarySessions ? "普通会话" : "工作区" }}
          </h2>
        </div>
        <div class="section-toolbar">
          <label v-if="!showSecondarySessions" class="workspace-search">
            <span class="sr-only">搜索工作区</span>
            <input
              v-model="workspaceQuery"
              type="search"
              data-testid="dsh-workspace-search"
              placeholder="搜索工作区"
              autocomplete="off"
            />
          </label>
          <button
            type="button"
            data-testid="sessions-refresh"
            :disabled="state === 'loading'"
            @click="load"
          >
            刷新
          </button>
          <button
            type="button"
            class="secondary-action"
            data-testid="secondary-sessions-toggle"
            :disabled="state !== 'ready'"
            @click="showSecondarySessions = !showSecondarySessions"
          >
            {{ showSecondarySessions ? "DSH 工作区" : "普通会话" }}
          </button>
        </div>
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

      <ul
        v-else-if="showSecondarySessions"
        data-testid="secondary-sessions-list"
        class="readonly-list"
      >
        <li
          v-if="secondarySessions.length === 0"
          data-testid="secondary-sessions-empty"
          class="status"
        >
          暂无普通会话。
        </li>
        <li
          v-for="item in secondarySessions"
          :key="item.id"
          class="readonly-item"
        >
          <a :href="`#/sessions/${item.id}`" :data-testid="`session-link-${item.id}`">
            <span class="item-title">会话 {{ item.id.slice(0, 8) }}</span>
            <span class="item-sub">{{ item.provider }} · {{ item.status }}</span>
            <span class="item-sub">事件序号 {{ item.last_seq }}</span>
          </a>
        </li>
      </ul>

      <div v-else data-testid="dsh-workspaces-list" class="workspace-browser">
        <p
          v-if="dshGroups.length === 0"
          data-testid="dsh-workspaces-empty"
          class="status"
        >
          尚无 DSH 工作区。
        </p>
        <p
          v-else-if="filteredDshGroups.length === 0"
          data-testid="dsh-workspaces-search-empty"
          class="status"
        >
          没有匹配的工作区。
        </p>
        <section
          v-for="group in filteredDshGroups"
          :key="group.workspace.id"
          class="dsh-group"
          :data-testid="`dsh-workspace-${group.workspace.id}`"
        >
          <div class="workspace-group-row">
            <button
              type="button"
              class="workspace-expand"
              :data-testid="`dsh-workspace-expand-${group.workspace.id}`"
              :aria-label="`${isExpanded(group.workspace.id) ? '收起' : '展开'} ${group.label}`"
              :aria-expanded="isExpanded(group.workspace.id)"
              @click="toggleWorkspace(group.workspace.id)"
            >
              {{ isExpanded(group.workspace.id) ? "⌄" : "›" }}
            </button>
            <button
              type="button"
              class="workspace-select"
              :class="{ selected: selectedWorkspaceId === group.workspace.id }"
              :data-testid="`dsh-workspace-select-${group.workspace.id}`"
              :aria-pressed="selectedWorkspaceId === group.workspace.id"
              @click="selectWorkspace(group.workspace.id)"
            >
              <span class="workspace-label">{{ group.label }}</span>
              <span class="workspace-meta">
                {{ group.items.length === 0 ? "尚无 DSH 会话" : `${group.items.length} 个 DSH 会话` }}
              </span>
            </button>
          </div>
          <ul v-if="isExpanded(group.workspace.id)" class="readonly-list workspace-session-list">
            <li v-if="group.items.length === 0" class="workspace-empty-session">
              尚无 DSH 会话
            </li>
            <li v-for="item in group.items" :key="item.id" class="readonly-item">
              <a :href="`#/sessions/${item.id}`" :data-testid="`session-link-${item.id}`">
                <span class="item-title">会话 {{ item.id.slice(0, 8) }}</span>
                <span class="item-sub">{{ item.status }} · 事件序号 {{ item.last_seq }}</span>
              </a>
            </li>
          </ul>
        </section>

        <aside
          v-if="selectedWorkspace"
          data-testid="dsh-workspace-readonly-detail"
          class="workspace-readonly-detail"
        >
          <p class="section-kicker">已选工作区</p>
          <h3>{{ selectedWorkspace.label }}</h3>
          <p class="status">
            {{ selectedWorkspace.items.length === 0 ? "尚无 DSH 会话" : `${selectedWorkspace.items.length} 个 DSH 会话` }}
          </p>
        </aside>
      </div>
    </section>
  </main>
</template>
