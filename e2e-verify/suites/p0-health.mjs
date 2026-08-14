// P0 健康检查回归：用 headed 真实浏览器加载 Vue 状态页并操作重试按钮。
// 覆盖测试 ID：P0-TOOL-01（工具链可复现）、P0-DEPLOY-01（本地部署健康）。
import { launchHeaded, browserLabel } from "../lib/browser.mjs";

export const p0Health = {
  id: "p0-health",
  title: "P0 Relay 健康检查 headed 回归",
  planId: "PROTO-CRYPTO",
  async run(ctx) {
    const { web, report, headless = false } = ctx;
    const browser = await launchHeaded({ headless });
    const label = browserLabel(headless);
    try {
      const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
      await page.goto(web.base, { waitUntil: "networkidle" });
      // 页面必须展示由 Relay /readyz 驱动的用户可见成功状态。
      await page.getByTestId("relay-ready").waitFor({ state: "visible" });
      // 重新检查会再次发起请求，成功状态不能因交互退化。
      await page.getByTestId("refresh-health").click();
      const passed = await page.getByTestId("relay-ready").isVisible();
      return report({
        suite: "p0-health",
        status: passed ? "passed" : "failed",
        real_browser: !headless,
        headless,
        browser: label,
        command: `node e2e-verify/run.mjs --suite p0-health`,
        artifacts: [],
        failure_class: passed ? null : "product_defect",
        remaining_risk: passed
          ? ""
          : "Vue Relay 状态页未显示 ready 状态",
      });
    } finally {
      await browser.close();
    }
  },
};
