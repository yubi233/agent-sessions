<script setup lang="ts">
// Git Diff 只读页（降级）：与文件页相同，依赖 Daemon 加密只读 RPC，
// Web 尚未接入时明确显示 unavailable。
import { useRoute } from "vue-router";

const route = useRoute();
const sessionId = String(route.params.id ?? "");
</script>

<template>
  <main class="page page-workflow" aria-labelledby="git-title">
    <header class="page-intro">
      <p class="eyebrow">Agent Sessions</p>
      <h1 id="git-title">Git Diff</h1>
      <p class="intro-copy">会话 {{ sessionId.slice(0, 8) }} 的只读变更视图。</p>
    </header>

    <p class="back-link">
      <a :href="`#/sessions/${sessionId}`" data-testid="git-back">← 返回会话详情</a>
    </p>

    <section class="page-section" aria-labelledby="git-unavailable-title">
      <div class="section-heading">
        <div>
          <p class="section-kicker">只读</p>
          <h2 id="git-unavailable-title">Git Diff 暂不可用</h2>
        </div>
      </div>
      <p data-testid="git-unavailable" class="status" role="status">
        Diff 内容由 Daemon 在本机加密读取，Web 只读客户端尚未接入该 transport。
        当前不会展示占位或伪造的 diff。
      </p>
    </section>
  </main>
</template>
