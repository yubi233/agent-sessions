import { computed, onBeforeUnmount, onMounted, ref, watch } from "vue";

export type ThemePreference = "system" | "light" | "dark";
type ResolvedTheme = Exclude<ThemePreference, "system">;

const storageKey = "agent-sessions.web.appearance.v1";

export function normalizeThemePreference(
  value: string | null,
): ThemePreference {
  return value === "light" || value === "dark" || value === "system"
    ? value
    : "system";
}

function systemTheme(): ResolvedTheme {
  return typeof window !== "undefined" &&
    typeof window.matchMedia === "function" &&
    window.matchMedia("(prefers-color-scheme: dark)").matches
    ? "dark"
    : "light";
}

export function resolvedTheme(preference: ThemePreference): ResolvedTheme {
  return preference === "system" ? systemTheme() : preference;
}

export function readThemePreference(): ThemePreference {
  if (typeof window === "undefined") return "system";
  try {
    return normalizeThemePreference(window.localStorage.getItem(storageKey));
  } catch {
    return "system";
  }
}

export function applyThemePreference(preference: ThemePreference): void {
  if (typeof document === "undefined") return;
  const resolved = resolvedTheme(preference);
  document.documentElement.dataset.theme = resolved;
  document.documentElement.dataset.themePreference = preference;
  document.documentElement.style.colorScheme = resolved;
}

function persistThemePreference(preference: ThemePreference): void {
  try {
    window.localStorage.setItem(storageKey, preference);
  } catch {
    // 隐私模式或受限存储不影响当前页面的主题切换。
  }
}

/// 外观偏好只写浏览器本地存储，不包含登录 token、会话或 Relay 数据。
export function useThemePreference() {
  const preference = ref<ThemePreference>(readThemePreference());
  const resolved = computed(() => resolvedTheme(preference.value));
  let mediaQuery: MediaQueryList | null = null;

  const followSystem = () => {
    if (preference.value === "system") applyThemePreference("system");
  };

  onMounted(() => {
    applyThemePreference(preference.value);
    if (
      typeof window !== "undefined" &&
      typeof window.matchMedia === "function"
    ) {
      mediaQuery = window.matchMedia("(prefers-color-scheme: dark)");
      mediaQuery.addEventListener("change", followSystem);
    }
  });

  onBeforeUnmount(() =>
    mediaQuery?.removeEventListener("change", followSystem),
  );

  watch(preference, (value) => {
    persistThemePreference(value);
    applyThemePreference(value);
  });

  return {
    preference,
    resolved,
    setPreference: (value: ThemePreference) => {
      preference.value = value;
    },
  };
}

export function clearThemePreferenceForTest(): void {
  try {
    window.localStorage.removeItem(storageKey);
  } catch {
    // 测试环境可能不提供 localStorage。
  }
  document.documentElement.removeAttribute("data-theme");
  document.documentElement.removeAttribute("data-theme-preference");
  document.documentElement.style.removeProperty("color-scheme");
}
