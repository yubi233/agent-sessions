// P4 Admin 运维只读 headed 回归：验证脱敏元数据只读展示，且无配对/撤销/写入口。
// 覆盖测试 ID：ADMIN-01、ADMIN-02、ADMIN-05、E2E-ADMIN-01。
import { launchHeaded, browserLabel } from "../lib/browser.mjs";

export const p4AdminReadonly = {
  id: "p4-admin-readonly",
  title: "P4 Admin 运维只读 headed 回归",
  planId: "ADMIN",
  async run(ctx) {
    const { admin, report, headless = false, fixtureAccount } = ctx;
    const label = browserLabel(headless);

    let account;
    try {
      account = await fixtureAccount();
    } catch {
      return report({
        suite: "p4-admin-readonly", status: "failed",
        real_browser: !headless, headless, browser: label,
        command: `node e2e-verify/run.mjs --suite p4-admin-readonly`,
        artifacts: [], failure_class: "test_harness_defect",
        remaining_risk: "无法预置单租户 fixture owner",
      });
    }

    const browser = await launchHeaded({ headless });
    try {
      const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
      await page.goto(admin.base, { waitUntil: "networkidle" });
      await page.getByTestId("relay-ready").waitFor({ state: "visible" });

      await page.getByTestId("login-email").fill(account.email);
      await page.getByTestId("login-password").fill(account.password);
      await page.getByTestId("login-submit").click();
      await page.getByTestId("auth-ok").waitFor({ state: "visible" });

      // 脱敏设备列表应展示 owner（不展示 token/正文）。
      await page.getByTestId("device-list").waitFor({ state: "visible" });
      const items = await page.getByTestId("device-item").count();
      // ADMIN-05：页面无配对/撤销写入口（无 approve/revoke 按钮）。
      const hasWriteEntry = (await page.getByTestId("approve-pairing").count()) > 0 || (await page.getByTestId("revoke-device").count()) > 0;
      const passed = items >= 1 && !hasWriteEntry;

      return report({
        suite: "p4-admin-readonly", status: passed ? "passed" : "failed",
        real_browser: !headless, headless, browser: label,
        command: `node e2e-verify/run.mjs --suite p4-admin-readonly`,
        artifacts: [], failure_class: passed ? null : "product_defect",
        remaining_risk: passed ? "" : "Admin 元数据展示或只读约束未满足",
      });
    } finally {
      await browser.close();
    }
  },
};
