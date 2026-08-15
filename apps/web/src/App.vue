<script setup lang="ts">
// 应用外壳：只读 Web 客户端唯一挂载点，子页面全部为只读视图。
import { RouterLink, RouterView } from "vue-router";
import ThemeControl from "./components/ThemeControl.vue";
</script>

<template>
  <div class="app-shell">
    <header class="site-header">
      <div class="site-frame">
        <RouterLink to="/" class="brand" aria-label="Agent Sessions 首页">
          <span>Agent Sessions</span>
          <span class="brand-context">只读</span>
        </RouterLink>
        <nav class="site-nav" aria-label="主导航">
          <RouterLink to="/">总览</RouterLink>
          <RouterLink to="/capabilities">能力</RouterLink>
        </nav>
        <ThemeControl />
      </div>
    </header>
    <RouterView />
  </div>
</template>
