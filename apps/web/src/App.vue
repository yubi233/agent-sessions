<script setup lang="ts">
// 应用外壳：包含只读视图与 LLM 对话视图；对话页是 web 主动发起 LLM 会话的写入口。
import { RouterLink, RouterView } from "vue-router";
import ThemeControl from "./components/ThemeControl.vue";
</script>

<template>
  <div class="app-shell">
    <header class="site-header">
      <div class="site-frame">
        <RouterLink to="/" class="brand" aria-label="Agent Sessions 首页">
          <span>Agent Sessions</span>
          <span class="brand-context">本地</span>
        </RouterLink>
        <nav class="site-nav" aria-label="主导航">
          <RouterLink to="/">总览</RouterLink>
          <RouterLink to="/chat">对话</RouterLink>
          <RouterLink to="/sessions">会话</RouterLink>
          <RouterLink to="/terminals">终端</RouterLink>
          <RouterLink to="/capabilities">能力</RouterLink>
        </nav>
        <ThemeControl />
      </div>
    </header>
    <RouterView />
  </div>
</template>
