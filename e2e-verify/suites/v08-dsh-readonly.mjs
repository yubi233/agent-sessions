// V08-11/V08-15：Web 只读 DSH 模式 headed 浏览器验收。
// 真实浏览器走「登录 -> 会话列表 -> DSH 模式 -> 按工作区分组展示 DSH 历史会话」，
// 只读端不显示扫描/导入/发送等写入口。数据来自隔离 Relay fixture。
import { launchHeaded, browserLabel } from "../lib/browser.mjs";

export const v08DshReadonly = {
  id: "v08-dsh-readonly",
  title: "V08 Web 只读 DSH 分组 headed 验收",
  planId: "V08",
  async run(ctx) {
    const { relay, web, report, headless = false, fixtureAccount } = ctx;
    const errors = [];
    const notes = [];
    let account;
    let dshAlphaSessionId;
    let dshBetaSessionId;
    try {
      account = await fixtureAccount();
      const data = await createFixtureDshData(relay.base, account);
      dshAlphaSessionId = data.alphaSessionId;
      dshBetaSessionId = data.betaSessionId;
    } catch (error) {
      return report({
        suite: "v08-dsh-readonly",
        status: "failed",
        real_browser: !headless,
        fixture_data: true,
        headless,
        browser: browserLabel(headless),
        command: "node e2e-verify/run.mjs --suite v08-dsh-readonly",
        artifacts: [],
        failure_class: "test_harness_defect",
        remaining_risk: `无法预置 V08 DSH fixture：${error instanceof Error ? error.message : String(error)}`,
      });
    }

    const browser = await launchHeaded({ headless });
    try {
      const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
      await page.goto(web.base, { waitUntil: "networkidle" });
      await page.getByTestId("relay-ready").waitFor({ state: "visible" });

      // 用户可见只读登录。
      await page.getByTestId("login-email").fill(account.email);
      await page.getByTestId("login-password").fill(account.password);
      await page.getByTestId("login-submit").click();
      await page.getByTestId("auth-ok").waitFor({ state: "visible" });

      // 进入会话列表并切换到 DSH 模式。
      await page.click('a[href="#/sessions"]');
      await page.getByTestId("sessions-list").waitFor({ state: "visible" });
      await page.getByTestId("dsh-mode-toggle").click();
      await page.getByTestId("dsh-sessions-list").waitFor({ state: "visible" });

      // 两个 DSH 工作区分组头可见；普通 codex 会话不进入 DSH 分组。
      const titles = await page.locator('[data-testid="dsh-group-title"]').allInnerTexts();
      notes.push(`DSH 分组标题：${titles.join(", ")}`);
      if (!titles.includes("v08-dsh-alpha") || !titles.includes("v08-dsh-beta")) {
        errors.push(`DSH 分组缺少预期工作区，实际 ${titles.join(", ")}`);
      }
      const bodyText = await page.locator("body").innerText();
      if (bodyText.includes("v08-normal-session")) {
        errors.push("普通 codex 会话不应出现在 DSH 模式分组中");
      }

      // 两个 DSH 会话链接可点击进入详情（详情页只读）。
      await page.getByTestId(`session-link-${dshAlphaSessionId}`).waitFor({ state: "visible" });
      await page.getByTestId(`session-link-${dshBetaSessionId}`).waitFor({ state: "visible" });
      await page.getByTestId(`session-link-${dshAlphaSessionId}`).click();
      await page.getByTestId("session-detail-meta").waitFor({ state: "visible" });
      const writeControls = await page
        .locator('textarea, button[type="submit"], [data-testid*="send"], [data-testid*="composer"], [data-testid*="import"], [data-testid*="sync"]')
        .count();
      if (writeControls > 0) {
        errors.push(`DSH 只读详情出现 ${writeControls} 个疑似写控件`);
      } else {
        notes.push("DSH 详情只读且无写控件");
      }

      // 窄屏下 DSH 列表无横向溢出。
      await page.setViewportSize({ width: 375, height: 720 });
      await page.click('a[href="#/sessions"]');
      await page.getByTestId("sessions-list").waitFor({ state: "visible" });
      await page.getByTestId("dsh-mode-toggle").click();
      await page.getByTestId("dsh-sessions-list").waitFor({ state: "visible" });
      const overflow = await page.evaluate(() => {
        const doc = document.documentElement;
        return doc.scrollWidth > doc.clientWidth + 1;
      });
      if (overflow) {
        errors.push("375px DSH 列表出现横向溢出");
      } else {
        notes.push("375px DSH 列表无横向溢出");
      }
      await page.close();
    } catch (error) {
      errors.push(`浏览器旅程异常：${error instanceof Error ? error.message : String(error)}`);
    } finally {
      await browser.close();
    }

    const status = errors.length === 0 ? "passed" : "failed";
    return report({
      suite: "v08-dsh-readonly",
      planId: "V08",
      status,
      real_browser: !headless,
      real_model: false,
      real_upstream: false,
      fixture_data: true,
      local_test: true,
      headless: Boolean(headless),
      browser: browserLabel(headless),
      command: "node e2e-verify/run.mjs --suite v08-dsh-readonly",
      test_ids: ["V08-11", "V08-15"],
      artifacts: [],
      failure_class: errors.length ? "selector_or_dom_contract_defect" : null,
      remaining_risk:
        "基于隔离 Relay fixture，证明 Web 只读 DSH 分组展示；不触发真实模型、扫描或导入。",
      notes,
      errors,
    });
  },
};

// 通过 fixture owner 写 token 预置两个 DSH Workspace/Session 和一个普通 codex Session。
// 返回实际生成的 opaque session id，供浏览器 data-testid 使用。
async function createFixtureDshData(relayBase, account) {
  const headers = {
    "Content-Type": "application/json",
    Authorization: `Bearer ${account.accessToken}`,
  };
  async function createWorkspace(projectId) {
    const wsResponse = await fetch(`${relayBase}/v1/workspaces`, {
      method: "POST",
      headers,
      body: JSON.stringify({
        project_id: projectId,
        terminal_id: "",
        canonical_root: `/fixture/${projectId}`,
        status: "active",
      }),
    });
    if (!wsResponse.ok) {
      throw new Error(`create fixture workspace ${projectId} failed: ${wsResponse.status}`);
    }
    return (await wsResponse.json()).id;
  }
  async function createSession(workspaceId, provider) {
    const sessionResponse = await fetch(`${relayBase}/v1/sessions`, {
      method: "POST",
      headers,
      body: JSON.stringify({ workspace_id: workspaceId, provider }),
    });
    if (!sessionResponse.ok) {
      throw new Error(`create fixture session failed: ${sessionResponse.status}`);
    }
    return (await sessionResponse.json()).id;
  }

  const wsAlpha = await createWorkspace("v08-dsh-alpha");
  const wsBeta = await createWorkspace("v08-dsh-beta");
  const alphaSessionId = await createSession(wsAlpha, "dsh");
  const betaSessionId = await createSession(wsBeta, "dsh");
  // 额外普通 codex 会话用于断言不会混入 DSH 分组。
  const wsNormal = await createWorkspace("v08-normal-workspace");
  await createSession(wsNormal, "codex");
  return { alphaSessionId, betaSessionId };
}
