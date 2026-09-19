// V094-27 Web 会话详情只读同步闭环 headed 旅程（计划 §2.6）：
// 真实 Chrome（非 headless）验证「数据同步状态」独立于 SSE 连接状态——
// 增量请求失败时保留最后可信内容并显示「同步失败」，有界重试/恢复后回到
// 「数据已同步」。全程仅 GET/只读，不保留或渲染 envelope。
import { launchHeaded, browserLabel } from "../lib/browser.mjs";

export const v094WebDetailSync = {
  id: "v094-web-detail-sync",
  title: "V094-27 Web 会话详情同步失败/恢复 headed 旅程",
  planId: "V094",
  async run(ctx) {
    const { relay, web, report, headless = false, fixtureAccount } = ctx;
    const errors = [];
    const notes = [];
    let account;
    let sessionId = null;
    try {
      account = await fixtureAccount();
      const created = await createFixtureSession(relay.base, account);
      sessionId = created.sessionId;
      // 预置事件，让首屏时间线有「最后可信内容」。
      await appendFixtureEvents(relay.base, account, sessionId, 1);
    } catch (error) {
      return report({
        suite: "v094-web-detail-sync",
        status: "failed",
        real_browser: !headless,
        fixture_data: true,
        headless,
        browser: browserLabel(headless),
        command: "node e2e-verify/run.mjs --suite v094-web-detail-sync",
        artifacts: [],
        failure_class: "test_harness_defect",
        remaining_risk: `无法预置 fixture 会话：${error instanceof Error ? error.message : String(error)}`,
      });
    }
    let workspaceId = null;
    try {
      // 失效事件经 owner 面的 delegation 提交产生（canonical delegation.changed）。
      workspaceId = await acquireWorkspaceId(relay.base, account, sessionId);
    } catch (error) {
      return report({
        suite: "v094-web-detail-sync",
        status: "failed",
        real_browser: !headless,
        fixture_data: true,
        headless,
        browser: browserLabel(headless),
        command: "node e2e-verify/run.mjs --suite v094-web-detail-sync",
        artifacts: [],
        failure_class: "test_harness_defect",
        remaining_risk: `无法获取 workspace：${error instanceof Error ? error.message : String(error)}`,
      });
    }

    const browser = await launchHeaded({ headless });
    try {
      const page = await browser.newPage({
        viewport: { width: 1280, height: 800 },
      });
      await page.goto(web.base, { waitUntil: "networkidle" });
      await page.getByTestId("relay-ready").waitFor({ state: "visible" });
      await page.getByTestId("login-email").fill(account.email);
      await page.getByTestId("login-password").fill(account.password);
      await page.getByTestId("login-submit").click();
      await page.getByTestId("auth-ok").waitFor({ state: "visible" });

      // 进入会话详情，等待初始加载与同步完成。
      await page.click('a[href="#/sessions"]');
      await page.waitForTimeout(500);
      await page.goto(`${web.base}/#/sessions/${sessionId}`, { waitUntil: "networkidle" });
      await page.getByTestId("session-detail-meta").waitFor({ state: "visible" });
      await page
        .getByTestId("session-detail-sync-status")
        .filter({ hasText: "数据已同步" })
        .waitFor({ state: "visible", timeout: 10_000 });
      const eventsBefore = await page
        .getByTestId("session-detail-events")
        .locator("li")
        .count();

      // 1) 增量请求失败 → 「同步失败 · 保留最近内容」，旧内容不丢。
      let abortedIncremental = 0;
      await page.route(/\/snapshot\?after_seq=[1-9]/, (route) => {
        abortedIncremental += 1;
        return route.abort("failed");
      });
      await appendDelegationEvent(relay.base, account, sessionId, workspaceId, "v094-sync-fail");
      // 账号 SSE 通知触发增量拉取（失败），有界重试期间保持失败态。
      await page
        .getByTestId("session-detail-sync-status")
        .filter({ hasText: "同步失败" })
        .waitFor({ state: "visible", timeout: 15_000 });
      const eventsDuringFailure = await page
        .getByTestId("session-detail-events")
        .locator("li")
        .count();
      if (eventsDuringFailure < eventsBefore) {
        errors.push(
          `增量失败期间事件数减少：${eventsBefore} -> ${eventsDuringFailure}`,
        );
      }

      // 2) 解除故障 → 有界重试把增量补齐，回到「数据已同步」。
      await page.unroute(/\/snapshot\?after_seq=[1-9]/);
      await page
        .getByTestId("session-detail-sync-status")
        .filter({ hasText: "数据已同步" })
        .waitFor({ state: "visible", timeout: 20_000 });
      await page.waitForTimeout(500);
      const eventsAfter = await page
        .getByTestId("session-detail-events")
        .locator("li")
        .count();
      if (eventsAfter <= eventsBefore) {
        errors.push(`恢复后增量未补齐：${eventsBefore} -> ${eventsAfter}`);
      }

      const statusText = await page
        .getByTestId("session-detail-stream-status")
        .textContent();
      notes.push(`恢复后连接状态：${statusText?.trim() ?? "unknown"}`);
      notes.push(`增量拦截次数：${abortedIncremental}`);

      if (errors.length > 0) {
        throw new Error(errors.join("; "));
      }
      return report({
        suite: "v094-web-detail-sync",
        status: "passed",
        real_browser: !headless,
        fixture_data: true,
        headless,
        browser: browserLabel(headless),
        command: "node e2e-verify/run.mjs --suite v094-web-detail-sync",
        artifacts: [],
        notes,
        remaining_risk: "切会话/卸载旧响应隔离由 createDetailSync 单测覆盖（apps/web/tests/v094-detail-sync.test.ts），浏览器旅程未重复驱动",
      });
    } catch (error) {
      // 失败诊断：截图 + 当前同步/连接状态文本（帮助定位 SSE/拦截时序）。
      let diagnostics = "";
      try {
        const page0 = (await browser.contexts()[0]?.pages())?.at(-1);
        if (page0) {
          const syncText = await page0
            .getByTestId("session-detail-sync-status")
            .textContent()
            .catch(() => "n/a");
          const streamText = await page0
            .getByTestId("session-detail-stream-status")
            .textContent()
            .catch(() => "n/a");
          diagnostics = `sync=${syncText?.trim()} stream=${streamText?.trim()}`;
          await page0.screenshot({
            path: "e2e-verify/reports/v094-web-detail-sync-failure.png",
          });
        }
      } catch (_) {
        // 诊断失败不掩盖原始错误。
      }
      return report({
        suite: "v094-web-detail-sync",
        status: "failed",
        real_browser: !headless,
        fixture_data: true,
        headless,
        browser: browserLabel(headless),
        command: "node e2e-verify/run.mjs --suite v094-web-detail-sync",
        artifacts: ["e2e-verify/reports/v094-web-detail-sync-failure.png"],
        failure_class: "product_defect",
        remaining_risk: `${error instanceof Error ? error.message : String(error)} ${diagnostics}`,
      });
    } finally {
      await browser.close();
    }
  },
};

async function createFixtureSession(relayBase, account) {
  const headers = {
    "Content-Type": "application/json",
    Authorization: `Bearer ${account.accessToken}`,
  };
  const wsResponse = await fetch(`${relayBase}/v1/workspaces`, {
    method: "POST",
    headers,
    body: JSON.stringify({
      project_id: "v094-web-sync",
      terminal_id: "",
      canonical_root: "/fixture/v094-web-sync",
      status: "active",
    }),
  });
  if (!wsResponse.ok) {
    throw new Error(`create fixture workspace failed: ${wsResponse.status}`);
  }
  const workspace = await wsResponse.json();
  const sessionResponse = await fetch(`${relayBase}/v1/sessions`, {
    method: "POST",
    headers,
    body: JSON.stringify({ workspace_id: workspace.id, provider: "codex" }),
  });
  if (!sessionResponse.ok) {
    throw new Error(`create fixture session failed: ${sessionResponse.status}`);
  }
  const session = await sessionResponse.json();
  return { sessionId: session.id, workspaceId: workspace.id };
}

// 首屏事件：预置一条 delegation（canonical delegation.changed 进 snapshot）。
async function appendFixtureEvents(relayBase, account, sessionId, count) {
  const workspaceId = await acquireWorkspaceId(relayBase, account, sessionId);
  for (let i = 0; i < count; i += 1) {
    await appendDelegationEvent(
      relayBase,
      account,
      sessionId,
      workspaceId,
      `v094-sync-seed-${i}`,
    );
  }
}

// 经 snapshot 读取 workspace_id（createFixtureSession 已返回但 helper 边界保持独立）。
async function acquireWorkspaceId(relayBase, account, sessionId) {
  const response = await fetch(
    `${relayBase}/v1/sessions/${sessionId}/snapshot?after_seq=0`,
    { headers: { Authorization: `Bearer ${account.accessToken}` } },
  );
  if (!response.ok) {
    throw new Error(`snapshot for workspace failed: ${response.status}`);
  }
  const snapshot = await response.json();
  const workspaceId = snapshot?.session?.workspace_id;
  if (!workspaceId) throw new Error("snapshot missing workspace_id");
  return workspaceId;
}

// 以 owner 面 delegation 提交产生 canonical delegation.changed 事件
// （幂等键唯一，重试安全）；token 不进入浏览器或报告。
async function appendDelegationEvent(
  relayBase,
  account,
  sessionId,
  workspaceId,
  idempotencyKey,
) {
  const headers = {
    "Content-Type": "application/json",
    Authorization: `Bearer ${account.accessToken}`,
  };
  const leaseResponse = await fetch(
    `${relayBase}/v1/sessions/${sessionId}/lease`,
    { method: "POST", headers },
  );
  if (!leaseResponse.ok) {
    throw new Error(`acquire fixture lease failed: ${leaseResponse.status}`);
  }
  const lease = await leaseResponse.json();
  const envelope = (ciphertext) => ({
    alg: "v1-aes256gcm-hkdfsha256",
    key_id: "fixture-dek",
    nonce: "fixture-nonce",
    ciphertext,
    aad_hash: "fixture-aad",
    payload_version: 1,
  });
  const response = await fetch(
    `${relayBase}/v1/sessions/${sessionId}/delegations`,
    {
      method: "POST",
      headers,
      body: JSON.stringify({
        target_workspace_id: workspaceId,
        target_provider: "codex",
        task_envelope: envelope(`opaque-task-${idempotencyKey}`),
        summary_envelope: envelope(`opaque-summary-${idempotencyKey}`),
        idempotency_key: idempotencyKey,
        lease_epoch: lease.lease_epoch,
      }),
    },
  );
  if (!response.ok) {
    throw new Error(`append delegation event failed: ${response.status}`);
  }
}
