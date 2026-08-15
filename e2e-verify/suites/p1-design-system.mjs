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
        adminDark.resolved === "dark" &&
        adminDark.preference === "dark" &&
        adminDark.activeTestId === "theme-select" &&
        adminDarkReloaded.resolved === "dark" &&
        adminDarkReloaded.preference === "dark" &&
        adminDarkReloaded.selected === "dark" &&
        adminLight.resolved === "light" &&
        adminLight.preference === "light" &&
        adminLight.noHorizontalOverflow;

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
        failure_class: passed ? null : "product_defect",
        remaining_risk: passed
          ? "仅覆盖隔离 Relay fixture；不证明 P4 的真实会话、机器、文件或 Git 路由。"
          : "主题、键盘焦点或窄屏布局未满足 P1 设计系统契约。",
      });
    } catch {
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
        failure_class: "environment_or_startup_failure",
        remaining_risk: "P1 headed 浏览器或隔离 Relay fixture 未能完成启动，未生成用户可见验收结果。",
      });
    } finally {
      await browser?.close();
    }
  },
};
