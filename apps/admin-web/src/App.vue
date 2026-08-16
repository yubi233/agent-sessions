<script setup lang="ts">
// Admin 外壳：运维只读控制台的导航与唯一挂载点。
// 四个分区（概览/终端/会话/审计）全部只读，不注册任何写入口。
import { RouterLink, RouterView } from "vue-router";
import ThemeControl from "./ThemeControl.vue";
</script>

<template>
  <div class="admin-shell">
    <header class="admin-header">
      <div class="admin-frame">
        <div>
          <p class="eyebrow">Agent Sessions</p>
          <p class="admin-title">运维只读控制台</p>
        </div>
        <nav class="admin-nav" aria-label="运维导航">
          <RouterLink to="/">概览</RouterLink>
          <RouterLink to="/terminals">终端</RouterLink>
          <RouterLink to="/sessions">会话</RouterLink>
          <RouterLink to="/audit">审计</RouterLink>
        </nav>
        <ThemeControl />
      </div>
    </header>
    <RouterView />
  </div>
</template>
