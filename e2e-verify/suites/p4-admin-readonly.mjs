// P4 Admin 运维只读 headed 回归：验证脱敏元数据只读展示、四分区导航、
// 审计分页与无配对/撤销/写入口。
// 覆盖测试 ID：ADMIN-01、ADMIN-02、ADMIN-03、ADMIN-04、ADMIN-05、E2E-ADMIN-01/02。
import { launchHeaded, browserLabel } from "../lib/browser.mjs";

export const p4AdminReadonly = {
  id: "p4-admin-readonly",
  title: "P4 Admin 运维只读 headed 回归",
  planId: "ADMIN",
  async run(ctx) {
    const { relay, admin, report, headless = false, fixtureAccount } = ctx;
    const label = browserLabel(headless);
    const errors = [];
    const notes = [];

    let account;
    try {
      account = await fixtureAccount();
    } catch {
      return report({
        suite: "p4-admin-readonly", status: "failed",
        real_browser: !headless, headless, browser: label,
        fixture_data: true,
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

      // 概览：脱敏设备列表应展示 owner。
      await page.getByTestId("device-list").waitFor({ state: "visible" });
      const items = await page.getByTestId("device-item").count();
      if (items < 1) errors.push("概览设备列表为空");
      else notes.push(`概览展示 ${items} 台设备`);

      // ADMIN-05：概览无配对/撤销写入口。
      const writeEntry =
        (await page.getByTestId("approve-pairing").count()) > 0 ||
        (await page.getByTestId("revoke-device").count()) > 0;
      if (writeEntry) errors.push("Admin 出现配对/撤销写入口");

      // ADMIN-03：终端分区。
      await page.click('a[href="#/terminals"]');
      await page.getByTestId("terminals-list").waitFor({ state: "visible" });
      const restartEntry = await page
        .locator('[data-testid*="restart"], [data-testid*="reboot"]')
        .count();
      if (restartEntry > 0) errors.push("Admin 终端页出现重启写入口");
      notes.push("终端分区只读展示");

      // ADMIN-01/02：会话分区。
      await page.click('a[href="#/sessions"]');
      await page.getByTestId("sessions-list").waitFor({ state: "visible" });
      const sessionText = await page.getByTestId("sessions-list").innerText();
      if (/Bearer|token|password|secret/i.test(sessionText)) {
        errors.push("会话分区泄漏敏感字段");
      }
      notes.push("会话分区白名单展示");

      // ADMIN-04：审计分区与分页。
      await page.click('a[href="#/audit"]');
      await page.getByTestId("audit-list").waitFor({ state: "visible" });
      const auditText = await page.getByTestId("audit-list").innerText();
      if (/Bearer|token|password|\/Users\//i.test(auditText)) {
        errors.push("审计分区泄漏敏感字段");
      }
      const paginationVisible =
        (await page.getByTestId("audit-pagination").count()) > 0;
      if (!paginationVisible) errors.push("审计分页控件缺失");
      notes.push("审计分区与分页可见");

      // E2E-ADMIN-02：窄屏无横向溢出。
      await page.setViewportSize({ width: 375, height: 720 });
      const overflow = await page.evaluate(() => {
        const doc = document.documentElement;
        return doc.scrollWidth > doc.clientWidth + 1;
      });
      if (overflow) errors.push("Admin 375px 视口出现横向溢出");
      else notes.push("375px 窄屏无横向溢出");

      await page.close();
    } catch (error) {
      errors.push(
        `浏览器旅程异常：${error instanceof Error ? error.message : String(error)}`,
      );
    } finally {
      await browser.close();
    }

    const status = errors.length === 0 ? "passed" : "failed";
    return report({
      suite: "p4-admin-readonly", status,
      planId: "ADMIN",
      real_browser: !headless, headless, browser: label,
      fixture_data: true,
      command: `node e2e-verify/run.mjs --suite p4-admin-readonly`,
      test_ids: ["ADMIN-01", "ADMIN-02", "ADMIN-03", "ADMIN-04", "ADMIN-05", "E2E-ADMIN-01", "E2E-ADMIN-02"],
      artifacts: [],
      failure_class: errors.length ? "selector_or_dom_contract_defect" : null,
      remaining_risk: errors.length
        ? errors.join("；")
        : "Admin 四分区基于隔离 Relay fixture；审计数据来自账号级白名单，生产部署与真实告警未覆盖。",
      notes,
      errors,
    });
  },
};
