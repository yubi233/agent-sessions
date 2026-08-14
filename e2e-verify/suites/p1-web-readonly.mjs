// P1 只读登录 headed 回归：在真实可见浏览器中打开 Web，登录后展示只读设备列表。
// 覆盖测试 ID：WEB-01（Web 只读入口）的 P1 基线 + AUTH/PAIR 的浏览器端验证。
import { launchHeaded, browserLabel } from "../lib/browser.mjs";

export const p1WebReadonly = {
  id: "p1-web-readonly",
  title: "P1 Web 只读登录 headed 回归",
  planId: "RELAY-REALTIME",
  async run(ctx) {
    const { web, report, headless = false, fixtureAccount } = ctx;
    let account;
    try {
      account = await fixtureAccount();
    } catch {
      return report({
        suite: "p1-web-readonly",
        status: "failed",
        real_browser: !headless,
        headless,
        browser: browserLabel(headless),
        command: `node e2e-verify/run.mjs --suite p1-web-readonly`,
        artifacts: [],
        failure_class: "test_harness_defect",
        remaining_risk: "无法预置单租户 fixture owner，headed 登录流程无法执行",
      });
    }

    const browser = await launchHeaded({ headless });
    const label = browserLabel(headless);
    try {
      const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
      await page.goto(web.base, { waitUntil: "networkidle" });
      await page.getByTestId("relay-ready").waitFor({ state: "visible" });

      // 用户可见登录流程。
      await page.getByTestId("login-email").fill(account.email);
      await page.getByTestId("login-password").fill(account.password);
      await page.getByTestId("login-submit").click();
      await page.getByTestId("auth-ok").waitFor({ state: "visible" });

      // 只读设备列表应展示 bootstrap owner。
      await page.getByTestId("device-list").waitFor({ state: "visible" });
      const items = await page.getByTestId("device-item").count();
      // P4 WEB-01：能力矩阵亦只读展示。
      await page.getByTestId("capability-list").waitFor({ state: "visible" });
      const caps = await page.getByTestId("capability-item").count();
      const passed = items >= 1 && caps >= 4;

      return report({
        suite: "p1-web-readonly",
        status: passed ? "passed" : "failed",
        real_browser: !headless,
        headless,
        browser: label,
        command: `node e2e-verify/run.mjs --suite p1-web-readonly`,
        artifacts: [],
        failure_class: passed ? null : "product_defect",
        remaining_risk: passed ? "" : "Web 登录或只读设备列表未按预期渲染",
      });
    } finally {
      await browser.close();
    }
  },
};
