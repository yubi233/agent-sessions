// V081 headed Chrome fixture：DSH 工作区优先的只读 Web 旅程。
// 预置数据经隔离 Relay + 受控 Daemon 回执生成；浏览器只读取安全投影，不触发写 API。
import { launchHeaded, browserLabel } from "../lib/browser.mjs";

export const v081DshWorkspaceFirst = {
  id: "v081-dsh-workspace-first",
  title: "V081 Web DSH 工作区优先 headed 验收",
  planId: "V081",
  async run(ctx) {
    const { relay, web, report, headless = false, fixtureAccount } = ctx;
    const errors = [];
    const notes = [];
    let account;
    let fixture;
    try {
      account = await fixtureAccount();
      fixture = await createFixtureDshData(relay.base, account);
    } catch (error) {
      return report({
        suite: "v081-dsh-workspace-first",
        planId: "V081",
        status: "failed",
        real_browser: !headless,
        fixture_data: true,
        local_test: true,
        headless: Boolean(headless),
        browser: browserLabel(headless),
        command: "node e2e-verify/run.mjs --suite v081-dsh-workspace-first",
        artifacts: [],
        failure_class: "test_harness_defect",
        remaining_risk: `无法预置 V081 DSH fixture：${safeError(error)}`,
      });
    }

    const browser = await launchHeaded({ headless });
    try {
      const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
      await page.goto(web.base, { waitUntil: "networkidle" });
      await page.getByTestId("relay-ready").waitFor({ state: "visible" });
      await page.getByTestId("login-email").fill(account.email);
      await page.getByTestId("login-password").fill(account.password);
      await page.getByTestId("login-submit").click();
      await page.getByTestId("auth-ok").waitFor({ state: "visible" });

      await page.click('a[href="#/sessions"]');
      await page.getByTestId("dsh-workspaces-list").waitFor({ state: "visible" });
      const labels = await page.locator(".workspace-label").allInnerTexts();
      for (const expected of ["v081-dsh-alpha", "v081-dsh-beta", "v081-dsh-empty"]) {
        if (!labels.includes(expected)) errors.push(`缺少 DSH 工作区 ${expected}`);
      }
      notes.push(`DSH 工作区：${labels.join(", ")}`);

      // 展开箭头与组选中是两个不同目标；空工作区即使没有会话也必须保留。
      await page.getByTestId(`dsh-workspace-expand-${fixture.alphaWorkspaceId}`).click();
      await page.getByTestId(`session-link-${fixture.alphaSessionId}`).waitFor({ state: "visible" });
      await page.getByTestId(`dsh-workspace-select-${fixture.alphaWorkspaceId}`).click();
      await page.getByTestId("dsh-workspace-readonly-detail").filter({ hasText: "v081-dsh-alpha" }).waitFor({ state: "visible" });
      const expanded = await page.getByTestId(`dsh-workspace-expand-${fixture.alphaWorkspaceId}`).getAttribute("aria-expanded");
      if (expanded !== "true") errors.push("组选中后意外收起了已展开工作区");
      await page.getByTestId(`dsh-workspace-expand-${fixture.emptyWorkspaceId}`).click();
      await page.locator(".workspace-empty-session").filter({ hasText: "尚无 DSH 会话" }).waitFor({ state: "visible" });

      await page.getByTestId("dsh-workspace-search").fill("v081-dsh-empty");
      await page.getByTestId(`dsh-workspace-select-${fixture.emptyWorkspaceId}`).waitFor({ state: "visible" });
      await page.getByTestId("dsh-workspace-search").fill("");

      const writeControls = await page
        .locator('textarea, [data-testid*="send"], [data-testid*="composer"], [data-testid*="import"], [data-testid*="sync"], [data-testid*="create"]')
        .count();
      if (writeControls > 0) errors.push(`DSH 工作区视图出现 ${writeControls} 个疑似写控件`);
      else notes.push("DSH 工作区视图保持只读");

      // 普通会话只在显式次级入口显示。
      await page.getByTestId("secondary-sessions-toggle").click();
      await page.getByTestId("secondary-sessions-list").waitFor({ state: "visible" });
      await page.getByTestId(`session-link-${fixture.normalSessionId}`).waitFor({ state: "visible" });

      await page.setViewportSize({ width: 375, height: 720 });
      await page.getByTestId("secondary-sessions-toggle").click();
      await page.getByTestId("dsh-workspaces-list").waitFor({ state: "visible" });
      const overflow = await page.evaluate(() => document.documentElement.scrollWidth > document.documentElement.clientWidth + 1);
      if (overflow) errors.push("375px DSH 工作区视图出现横向溢出");
      else notes.push("375px DSH 工作区视图无横向溢出");
      await page.close();
    } catch (error) {
      errors.push(`浏览器旅程异常：${safeError(error)}`);
    } finally {
      await browser.close();
    }

    return report({
      suite: "v081-dsh-workspace-first",
      planId: "V081",
      status: errors.length === 0 ? "passed" : "failed",
      real_browser: !headless,
      real_model: false,
      real_upstream: false,
      fixture_data: true,
      local_test: true,
      headless: Boolean(headless),
      browser: browserLabel(headless),
      command: "node e2e-verify/run.mjs --suite v081-dsh-workspace-first",
      test_ids: ["V081-03", "V081-04", "V081-08", "V081-10"],
      artifacts: [],
      failure_class: errors.length ? "selector_or_dom_contract_defect" : null,
      remaining_risk: "基于隔离 Relay 与受控 Daemon result fixture；未扫描真实 DSH 根目录、未读取历史正文、未调用模型。",
      notes,
      errors,
    });
  },
};

async function createFixtureDshData(relayBase, account) {
  const ownerHeaders = {
    "Content-Type": "application/json",
    Authorization: `Bearer ${account.accessToken}`,
  };
  const pairing = await requestJSON(relayBase, "/v1/pairing/requests", {
    method: "POST",
    headers: ownerHeaders,
    body: {
      role: "terminal",
      display_name: "v081-web-fixture-terminal",
      platform: "test",
      identity_public_key: "v081-fixture-identity",
      encryption_public_key: "v081-fixture-encryption",
    },
  });
  const approved = await requestJSON(relayBase, `/v1/pairing/requests/${encodeURIComponent(pairing.id)}/approve`, {
    method: "POST",
    headers: ownerHeaders,
  });
  const terminalToken = approved.tokens?.access_token;
  if (typeof terminalToken !== "string" || terminalToken.length === 0) {
    throw new Error("fixture terminal token missing");
  }
  const hello = await requestJSON(relayBase, "/v1/daemon/hello", {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${terminalToken}` },
    body: {
      protocol_version: 1,
      daemon_version: "v081-fixture",
      hostname: "v081-fixture",
      platform: "test",
      capabilities: ["dsh_workspace_sync", "dsh_session_import", "start"],
    },
  });
  const terminalId = hello.terminal_id;
  if (typeof terminalId !== "string" || terminalId.length === 0) {
    throw new Error("fixture terminal id missing");
  }
  const sync = await requestJSON(relayBase, "/v1/workspaces/sync-dsh", {
    method: "POST",
    headers: ownerHeaders,
    body: { terminal_id: terminalId },
  });
  await requestJSON(relayBase, `/v1/daemon/commands/${encodeURIComponent(sync.command_id)}/dsh-workspace-result`, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${terminalToken}` },
    body: {
      protocol_version: 1,
      delivery_seq: 1,
      status: "succeeded",
      candidates: [
        { canonical_root: "/fixture/v081/dsh-alpha", display_name: "v081-dsh-alpha" },
        { canonical_root: "/fixture/v081/dsh-beta", display_name: "v081-dsh-beta" },
        { canonical_root: "/fixture/v081/dsh-empty", display_name: "v081-dsh-empty" },
      ],
    },
  });
  const listed = await requestJSON(relayBase, "/v1/workspaces", { headers: ownerHeaders });
  const dshByName = new Map(
    (listed.workspaces ?? [])
      .filter((workspace) => workspace.origin === "dsh")
      .map((workspace) => [workspace.display_name, workspace.id]),
  );
  const alphaWorkspaceId = dshByName.get("v081-dsh-alpha");
  const betaWorkspaceId = dshByName.get("v081-dsh-beta");
  const emptyWorkspaceId = dshByName.get("v081-dsh-empty");
  if (!alphaWorkspaceId || !betaWorkspaceId || !emptyWorkspaceId) {
    throw new Error("fixture DSH workspaces missing");
  }
  const alphaSession = await createSession(relayBase, ownerHeaders, alphaWorkspaceId, "dsh");
  await createSession(relayBase, ownerHeaders, betaWorkspaceId, "dsh");
  const normalWorkspace = await requestJSON(relayBase, "/v1/workspaces", {
    method: "POST",
    headers: ownerHeaders,
    body: {
      project_id: "v081-normal",
      terminal_id: terminalId,
      canonical_root: "/fixture/v081/normal",
      status: "active",
    },
  });
  const normalSession = await createSession(relayBase, ownerHeaders, normalWorkspace.id, "codex");
  return {
    alphaWorkspaceId,
    emptyWorkspaceId,
    alphaSessionId: alphaSession.id,
    normalSessionId: normalSession.id,
  };
}

async function createSession(relayBase, headers, workspaceId, provider) {
  return requestJSON(relayBase, "/v1/sessions", {
    method: "POST",
    headers,
    body: { workspace_id: workspaceId, provider },
  });
}

async function requestJSON(base, path, { method = "GET", headers = {}, body } = {}) {
  const response = await fetch(`${base}${path}`, {
    method,
    headers,
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
  if (!response.ok) throw new Error(`${method} ${path} failed: ${response.status}`);
  return response.json();
}

function safeError(error) {
  return error instanceof Error ? error.message : String(error);
}
