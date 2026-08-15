import { onBeforeUnmount, onMounted, ref, watch } from "vue";

export type ThemePreference = "system" | "light" | "dark";
type ResolvedTheme = Exclude<ThemePreference, "system">;

const storageKey = "agent-sessions.admin.appearance.v1";

export function normalizeThemePreference(
  value: string | null,
): ThemePreference {
  return value === "light" || value === "dark" || value === "system"
    ? value
    : "system";
}

function resolve(preference: ThemePreference): ResolvedTheme {
  if (preference !== "system") return preference;
  return typeof window !== "undefined" &&
    typeof window.matchMedia === "function" &&
    window.matchMedia("(prefers-color-scheme: dark)").matches
    ? "dark"
    : "light";
}

function read(): ThemePreference {
  if (typeof window === "undefined") return "system";
  try {
    return normalizeThemePreference(window.localStorage.getItem(storageKey));
  } catch {
    return "system";
  }
}

function apply(preference: ThemePreference): void {
  if (typeof document === "undefined") return;
  const theme = resolve(preference);
  document.documentElement.dataset.theme = theme;
  document.documentElement.dataset.themePreference = preference;
  document.documentElement.style.colorScheme = theme;
}

/// 管理台只保存本机外观选择；登录 token 和运维数据绝不进入此存储。
export function useThemePreference() {
  const preference = ref<ThemePreference>(read());
  let mediaQuery: MediaQueryList | null = null;
  const followSystem = () => {
    if (preference.value === "system") apply("system");
  };

  onMounted(() => {
    apply(preference.value);
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
    try {
      window.localStorage.setItem(storageKey, value);
    } catch {
      // 受限存储只影响下次启动，不影响当前可访问性设置。
    }
    apply(value);
  });

  return {
    preference,
    setPreference: (value: ThemePreference) => {
      preference.value = value;
    },
  };
}

export function clearThemePreferenceForTest(): void {
  try {
    window.localStorage.removeItem(storageKey);
  } catch {
    // jsdom 或隐私模式可能不提供可写存储。
  }
  document.documentElement.removeAttribute("data-theme");
  document.documentElement.removeAttribute("data-theme-preference");
  document.documentElement.style.removeProperty("color-scheme");
}
