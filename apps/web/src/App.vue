<script setup lang="ts">
// 应用外壳：只读 Web 客户端唯一挂载点，子页面全部为只读视图。
import { RouterView } from "vue-router";
</script>

<template>
  <RouterView />
</template>
