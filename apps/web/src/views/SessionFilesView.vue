<script setup lang="ts">
// 工作区文件只读页（降级）：文件内容走 Daemon 加密只读 RPC，Web 尚未接入
// 该 transport，因此明确显示 unavailable，不伪造成功或展示 fixture 数据。
import { useRoute } from "vue-router";

const route = useRoute();
const sessionId = String(route.params.id ?? "");
</script>

<template>
  <main class="page page-workflow" aria-labelledby="files-title">
    <header class="page-intro">
      <p class="eyebrow">Agent Sessions</p>
      <h1 id="files-title">工作区文件</h1>
      <p class="intro-copy">会话 {{ sessionId.slice(0, 8) }} 的只读文件浏览。</p>
    </header>

    <p class="back-link">
      <a :href="`#/sessions/${sessionId}`" data-testid="files-back">← 返回会话详情</a>
    </p>

    <section class="page-section" aria-labelledby="files-unavailable-title">
      <div class="section-heading">
        <div>
          <p class="section-kicker">只读</p>
          <h2 id="files-unavailable-title">文件浏览暂不可用</h2>
        </div>
      </div>
      <p data-testid="files-unavailable" class="status" role="status">
        文件与代码内容由 Daemon 在本机加密读取，Web 只读客户端尚未接入该 transport。
        当前不会展示占位或伪造的文件列表。
      </p>
    </section>
  </main>
</template>
