<script setup lang="ts">
import { normalizeThemePreference, useThemePreference } from "../theme";

const { preference, setPreference } = useThemePreference();

function updateTheme(event: Event): void {
  const target = event.target;
  if (!(target instanceof HTMLSelectElement)) return;
  setPreference(normalizeThemePreference(target.value));
}
</script>

<template>
  <label class="theme-control">
    <span class="theme-control-label">外观</span>
    <select
      :value="preference"
      data-testid="theme-select"
      aria-label="外观"
      @change="updateTheme"
    >
      <option value="system">跟随系统</option>
      <option value="light">浅色</option>
      <option value="dark">深色</option>
    </select>
  </label>
</template>
