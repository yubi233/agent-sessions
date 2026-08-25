// P1 headed 验收：真实可见 Chrome 验证 Web/Admin 的主题、窄屏和键盘焦点。
// 覆盖测试 ID：WEB-06、ADMIN-06；Relay 与账户均为隔离 fixture，不宣称真实上游。
import { mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { launchHeaded, browserLabel } from "../lib/browser.mjs";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");

function screenshotDirectory() {
  const stamp = new Date().toISOString().replace(/[:.]/g, "-");
  const directory = join(ROOT, "e2e-verify", "screenshots", stamp, "P1");
  mkdirSync(directory, { recursive: true });
  return directory;
}

async function login(page, account) {
  await page.getByTestId("login-email").fill(account.email);
  await page.getByTestId("login-password").fill(account.password);
  await page.getByTestId("login-submit").click();
  await page.getByTestId("auth-ok").waitFor({ state: "visible" });
}

async function selectTheme(page, value) {
  await page.getByTestId("theme-select").selectOption(value);
  await page.waitForFunction(
    (expected) => document.documentElement.dataset.theme === expected,
    value,
  );
  return page.evaluate(() => ({
    resolved: document.documentElement.dataset.theme,
    preference: document.documentElement.dataset.themePreference,
    activeTestId: document.activeElement?.getAttribute("data-testid"),
    noHorizontalOverflow: document.documentElement.scrollWidth <= window.innerWidth,
  }));
}

async function reloadAndReadTheme(page) {
  await page.reload({ waitUntil: "networkidle" });
  await page.getByTestId("relay-ready").waitFor({ state: "visible" });
  return page.evaluate(() => ({
    resolved: document.documentElement.dataset.theme,
    preference: document.documentElement.dataset.themePreference,
    selected: document.querySelector('[data-testid="theme-select"]')?.value,
  }));
}

// verifyAccessibilityModes 在真实 Chrome 中启用 reduced motion，并用 2x CSS zoom
// 对应 200% 浏览器缩放的布局压力。只检查稳定的可观察结果，不读取实现 token。
async function verifyAccessibilityModes(page) {
  await page.emulateMedia({ reducedMotion: "reduce" });
  await page.setViewportSize({ width: 640, height: 760 });
  return page.evaluate(() => {
    const durationMs = (raw) =>
      raw
        .split(",")
        .map((part) => part.trim())
        .map((part) =>
          part.endsWith("ms")
            ? Number.parseFloat(part)
            : Number.parseFloat(part) * 1000,
        )
        .reduce((maximum, value) => Math.max(maximum, value || 0), 0);
    const interactive = [...document.querySelectorAll("button, select, a")];
    const reducedMotionApplied = interactive.every((element) => {
      const style = getComputedStyle(element);
      return (
        durationMs(style.transitionDuration) <= 1 &&
        durationMs(style.animationDuration) <= 1
      );
    });
    document.documentElement.style.zoom = "2";
    const themeControl = document.querySelector('[data-testid="theme-select"]');
    const rect = themeControl?.getBoundingClientRect();
    const result = {
      reducedMotionQuery: matchMedia("(prefers-reduced-motion: reduce)").matches,
      reducedMotionApplied,
      noHorizontalOverflow:
        document.documentElement.scrollWidth <= window.innerWidth + 1,
      themeControlVisible:
        Boolean(rect) &&
        rect.width > 0 &&
        rect.height > 0 &&
        rect.left >= 0 &&
        rect.right <= window.innerWidth + 1,
    };
    document.documentElement.style.zoom = "";
    return result;
  });
}

export const p1DesignSystem = {
  id: "p1-design-system",
  title: "P1 Web/Admin 主题与无障碍 headed 回归",
  planId: "V04-UI",
  async run(ctx) {
    const { web, admin, report, headless = false, fixtureAccount } = ctx;
    const label = browserLabel(headless);
    let browser;
    const artifacts = [];
    try {
      const account = await fixtureAccount();
      browser = await launchHeaded({ headless });

      const webPage = await browser.newPage({ viewport: { width: 1280, height: 800 } });
      await webPage.goto(web.base, { waitUntil: "networkidle" });
      await webPage.getByTestId("relay-ready").waitFor({ state: "visible" });
      await login(webPage, account);
      await webPage.getByTestId("capability-list").waitFor({ state: "visible" });
      await webPage.getByTestId("theme-select").focus();
      const webDark = await selectTheme(webPage, "dark");
      const directory = screenshotDirectory();
      const webDesktopScreenshot = join(directory, "web-desktop-dark.png");
      await webPage.screenshot({ path: webDesktopScreenshot, fullPage: true });
      artifacts.push(webDesktopScreenshot);
      const webDarkReloaded = await reloadAndReadTheme(webPage);
      await login(webPage, account);
      await webPage.getByTestId("capabilities-link").click();
      await webPage.getByTestId("capability-matrix").waitFor({ state: "visible" });
      await webPage.setViewportSize({ width: 375, height: 760 });
      const webLight = await selectTheme(webPage, "light");
      const webNarrowScreenshot = join(directory, "web-narrow-light.png");
      await webPage.screenshot({ path: webNarrowScreenshot, fullPage: true });
      artifacts.push(webNarrowScreenshot);
      const webAccessibility = await verifyAccessibilityModes(webPage);

      const adminPage = await browser.newPage({ viewport: { width: 1280, height: 800 } });
      await adminPage.goto(admin.base, { waitUntil: "networkidle" });
      await adminPage.getByTestId("relay-ready").waitFor({ state: "visible" });
      await login(adminPage, account);
      await adminPage.getByTestId("device-list").waitFor({ state: "visible" });
      await adminPage.getByTestId("theme-select").focus();
      const adminDark = await selectTheme(adminPage, "dark");
      const adminDesktopScreenshot = join(directory, "admin-desktop-dark.png");
      await adminPage.screenshot({ path: adminDesktopScreenshot, fullPage: true });
      artifacts.push(adminDesktopScreenshot);
      const adminDarkReloaded = await reloadAndReadTheme(adminPage);
      await login(adminPage, account);
      await adminPage.setViewportSize({ width: 375, height: 760 });
      const adminLight = await selectTheme(adminPage, "light");
      const adminNarrowScreenshot = join(directory, "admin-narrow-light.png");
      await adminPage.screenshot({ path: adminNarrowScreenshot, fullPage: true });
      artifacts.push(adminNarrowScreenshot);
      const adminAccessibility = await verifyAccessibilityModes(adminPage);

      const passed =
        webDark.resolved === "dark" &&
        webDark.preference === "dark" &&
        webDark.activeTestId === "theme-select" &&
        webDarkReloaded.resolved === "dark" &&
        webDarkReloaded.preference === "dark" &&
        webDarkReloaded.selected === "dark" &&
        webLight.resolved === "light" &&
        webLight.preference === "light" &&
        webLight.noHorizontalOverflow &&
        webAccessibility.reducedMotionQuery &&
        webAccessibility.reducedMotionApplied &&
        webAccessibility.noHorizontalOverflow &&
        webAccessibility.themeControlVisible &&
        adminDark.resolved === "dark" &&
        adminDark.preference === "dark" &&
        adminDark.activeTestId === "theme-select" &&
        adminDarkReloaded.resolved === "dark" &&
        adminDarkReloaded.preference === "dark" &&
        adminDarkReloaded.selected === "dark" &&
        adminLight.resolved === "light" &&
        adminLight.preference === "light" &&
        adminLight.noHorizontalOverflow &&
        adminAccessibility.reducedMotionQuery &&
        adminAccessibility.reducedMotionApplied &&
        adminAccessibility.noHorizontalOverflow &&
        adminAccessibility.themeControlVisible;

      return report({
        suite: "p1-design-system",
        planId: "V04-UI",
        status: passed ? "passed" : "failed",
        real_browser: !headless,
        real_model: false,
        real_upstream: false,
        fixture_data: true,
        local_test: true,
        headless,
        browser: label,
        command: "node e2e-verify/run.mjs --suite p1-design-system",
        artifacts,
        accessibility: {
          zoom_percent: 200,
          web: webAccessibility,
          admin: adminAccessibility,
        },
        failure_class: passed ? null : "product_defect",
        remaining_risk: passed
          ? "隔离 Relay fixture 已覆盖 200% zoom 与 reduced motion；不证明 P4 的真实会话、机器、文件或 Git 路由。"
          : "主题、键盘焦点、200% zoom、reduced motion 或窄屏布局未满足 P1 设计系统契约。",
      });
    } catch (error) {
      const detail = error instanceof Error ? error.message : String(error);
      return report({
        suite: "p1-design-system",
        planId: "V04-UI",
        status: "failed",
        real_browser: !headless,
        real_model: false,
        real_upstream: false,
        fixture_data: true,
        local_test: true,
        headless,
        browser: label,
        command: "node e2e-verify/run.mjs --suite p1-design-system",
        artifacts,
        failure_class: "test_harness_defect",
        remaining_risk: `P1 headed 流程异常：${detail}`,
      });
    } finally {
      await browser?.close();
    }
  },
};
