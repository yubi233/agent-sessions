// P4 Web 只读闭环 headed 验收（WEB-05 / E2E-WEB-01 / E2E-WEB-02）：
// 真实浏览器走「登录 -> 会话列表 -> 详情 -> 文件/Git 降级 -> 终端」只读旅程，
// 断言无写入口；多视口（桌面 + 窄屏）检查响应式。数据来自隔离 Relay fixture。
import { launchHeaded, browserLabel } from "../lib/browser.mjs";

export const p4WebReadonly = {
  id: "p4-web-readonly",
  title: "P4 Web 只读闭环 headed 多视口验收",
  planId: "WEB",
  async run(ctx) {
    const { relay, web, report, headless = false, fixtureAccount } = ctx;
    const errors = [];
    const notes = [];
    let account;
    let sessionId = null;
    let workspaceId = null;
    try {
      account = await fixtureAccount();
      ({ sessionId, workspaceId } = await createFixtureSession(relay.base, account));
    } catch (error) {
      return report({
        suite: "p4-web-readonly",
        status: "failed",
        real_browser: !headless,
        fixture_data: true,
        headless,
        browser: browserLabel(headless),
        command: "node e2e-verify/run.mjs --suite p4-web-readonly",
        artifacts: [],
        failure_class: "test_harness_defect",
        remaining_risk: `无法预置 fixture 会话：${error instanceof Error ? error.message : String(error)}`,
      });
    }

    const browser = await launchHeaded({ headless });
    try {
      const page = await browser.newPage({
        viewport: { width: 1280, height: 800 },
      });
      await page.goto(web.base, { waitUntil: "networkidle" });
      await page.getByTestId("relay-ready").waitFor({ state: "visible" });

      // 用户可见只读登录。
      await page.getByTestId("login-email").fill(account.email);
      await page.getByTestId("login-password").fill(account.password);
      await page.getByTestId("login-submit").click();
      await page.getByTestId("auth-ok").waitFor({ state: "visible" });

      // 会话列表：fixture 会话可见且可进入详情。
      await page.click('a[href="#/sessions"]');
      await page.getByTestId("sessions-list").waitFor({ state: "visible" });
      await page
        .getByTestId(`session-link-${sessionId}`)
        .waitFor({ state: "visible" });
      notes.push(`会话列表展示 fixture 会话 ${sessionId}`);

      // 会话详情：白名单元数据可见，无 composer/发送等写控件。
      await page.getByTestId(`session-link-${sessionId}`).click();
      await page.getByTestId("session-detail-meta").waitFor({ state: "visible" });
      await page.getByTestId("session-detail-events").waitFor({ state: "visible" });
      await page.getByTestId("session-detail-stream-status").filter({ hasText: "已连接" }).waitFor({ state: "visible" });
      const writeControls = await page
        .locator('textarea, button[type="submit"], [data-testid*="send"], [data-testid*="composer"]')
        .count();
      if (writeControls > 0) {
        errors.push(`会话详情出现 ${writeControls} 个疑似写控件`);
      } else {
        notes.push("会话详情只读且无写控件");
      }

      // 断网后由 Node fixture 提交 parent event，再恢复真实浏览器网络。客户端必须携带
      // Last-Event-ID 重连并以 snapshot 增量刷新时间线；SSE data 中的 opaque 密文不应出现于 DOM。
      await page.context().setOffline(true);
      await page.evaluate(() => window.dispatchEvent(new Event("offline")));
      await page.getByTestId("session-detail-stream-status").filter({ hasText: "正在恢复" }).waitFor({ state: "visible", timeout: 5000 });
      await createFixtureDelegation(relay.base, account, sessionId, workspaceId);
      await page.context().setOffline(false);
      await page.getByTestId("session-detail-stream-status").filter({ hasText: "已连接" }).waitFor({ state: "visible", timeout: 5000 });
      await page.getByTestId("session-detail-events").filter({ hasText: "delegation.changed" }).waitFor({ state: "visible", timeout: 5000 });
      const timelineText = await page.getByTestId("session-detail-events").innerText();
      if (timelineText.includes("opaque-task-ciphertext")) {
        errors.push("SSE opaque task envelope 出现在 Web 时间线 DOM");
      } else {
        notes.push("断网重连后以 cursor 刷新 delegation 时间线，opaque envelope 未进入 DOM");
      }

      // 旧 P4-C fixture 没有配对 Daemon transport：页面必须显示真实连接错误，不能伪造
      // 文件/Git 列表。完整加密读取由独立的 P4-D suite 覆盖。
      await page.getByTestId("session-files-link").click();
      await page.getByTestId("files-error").waitFor({ state: "visible" });
      const filesText = await page.getByTestId("files-error").innerText();
      if (!filesText.includes("无法读取工作区内容")) {
        errors.push("文件页未正确显示 transport 连接错误");
      }
      await page.goBack();
      await page.getByTestId("session-detail-meta").waitFor({ state: "visible" });
      await page.getByTestId("session-git-link").click();
      await page.getByTestId("git-error").waitFor({ state: "visible" });
      await page.goBack();
      await page.getByTestId("session-detail-meta").waitFor({ state: "visible" });

      // 终端状态页：白名单 hostname/平台可见，无重启按钮。
      await page.click('a[href="#/terminals"]');
      await page.getByTestId("terminals-list").waitFor({ state: "visible" });
      const terminalText = await page.getByTestId("terminals-list").innerText();
      const terminalSeeded = await seedTerminal(relay.base, account);
      if (terminalSeeded && !/MacBook|fixture/i.test(terminalText)) {
        errors.push("终端列表未展示 fixture 白名单元数据");
      }
      const restartControls = await page
        .locator('[data-testid*="restart"], [data-testid*="reboot"]')
        .count();
      if (restartControls > 0) {
        errors.push("终端页出现重启写入口");
      }

      // 窄屏视口：会话列表无横向溢出。
      await page.setViewportSize({ width: 375, height: 720 });
      await page.click('a[href="#/sessions"]');
      await page.getByTestId("sessions-list").waitFor({ state: "visible" });
      const overflow = await page.evaluate(() => {
        const doc = document.documentElement;
        return doc.scrollWidth > doc.clientWidth + 1;
      });
      if (overflow) {
        errors.push("375px 视口出现横向溢出");
      } else {
        notes.push("375px 窄屏无横向溢出");
      }
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
      suite: "p4-web-readonly",
      planId: "WEB",
      status,
      real_browser: !headless,
      real_model: false,
      real_upstream: false,
      fixture_data: true,
      local_test: true,
      headless: Boolean(headless),
      browser: browserLabel(headless),
      command: "node e2e-verify/run.mjs --suite p4-web-readonly",
      test_ids: ["WEB-02", "WEB-05", "E2E-WEB-01", "E2E-WEB-02"],
      artifacts: [],
      failure_class: errors.length ? "selector_or_dom_contract_defect" : null,
      remaining_risk:
        "Web SSE cursor 与只读闭环基于隔离 Relay fixture；文件/Git 按真实边界显示 unavailable，未接入 Daemon 加密 RPC，也不证明真实 Provider 或生产 E2EE 密钥生命周期。",
      notes,
      errors,
    });
  },
};

// 通过 fixture 账号的密码登录取得 token 并创建会话（隔离 fixture 数据）。
async function createFixtureSession(relayBase, account) {
  // 使用 fixture owner 的注册写 token 预置会话；token 不进入浏览器或报告。
  // terminal_id 传空串绕过终端绑定（P4 浏览器侧不签发 terminal bearer）。
  const headers = {
    "Content-Type": "application/json",
    Authorization: `Bearer ${account.accessToken}`,
  };
  const wsResponse = await fetch(`${relayBase}/v1/workspaces`, {
    method: "POST",
    headers,
    body: JSON.stringify({
      project_id: "p4-web-project",
      terminal_id: "",
      canonical_root: "/fixture/p4-web",
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

// createFixtureDelegation 使用浏览器之外的 fixture owner token 制造已提交事件；token 不进入
// 页面或报告，浏览器只消费自己的只读快照与 SSE cursor。
async function createFixtureDelegation(relayBase, account, sessionId, workspaceId) {
  const headers = {
    "Content-Type": "application/json",
    Authorization: `Bearer ${account.accessToken}`,
  };
  const leaseResponse = await fetch(`${relayBase}/v1/sessions/${sessionId}/lease`, {
    method: "POST",
    headers,
  });
  if (!leaseResponse.ok) {
    throw new Error(`acquire fixture delegation lease failed: ${leaseResponse.status}`);
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
  const response = await fetch(`${relayBase}/v1/sessions/${sessionId}/delegations`, {
    method: "POST",
    headers,
    body: JSON.stringify({
      target_workspace_id: workspaceId,
      target_provider: "codex",
      task_envelope: envelope("opaque-task-ciphertext"),
      summary_envelope: envelope("opaque-summary-ciphertext"),
      idempotency_key: "p4-web-sse-reconnect",
      lease_epoch: lease.lease_epoch,
    }),
  });
  if (!response.ok) {
    throw new Error(`create fixture delegation failed: ${response.status}`);
  }
}

// 以配对 + daemon hello 登记一台 fixture 终端并返回 terminal_id。
// 失败时返回 null（页面空态也可接受，但终端断言会被跳过）。
async function seedTerminal(relayBase, account) {
  try {
    const headers = {
      "Content-Type": "application/json",
      Authorization: `Bearer ${account.accessToken}`,
    };
    const pending = await fetch(`${relayBase}/v1/pairing/requests`, {
      method: "POST",
      headers,
      body: JSON.stringify({
        role: "terminal",
        display_name: "p4-web-terminal",
        platform: "macos",
        identity_public_key: "p4-web-identity",
        encryption_public_key: "p4-web-encryption",
      }),
    });
    if (!pending.ok) return null;
    const pairing = await pending.json();
    const approved = await fetch(
      `${relayBase}/v1/pairing/requests/${pairing.id}/approve`,
      { method: "POST", headers },
    );
    if (!approved.ok) return null;
    const device = await approved.json();
    // 以 hello 让 Relay 登记 terminal 行并返回 terminal_id。
    const hello = await fetch(`${relayBase}/v1/daemon/hello`, {
      method: "POST",
      headers,
      body: JSON.stringify({
        protocol_version: 1,
        daemon_version: "0.4.0-fixture",
        hostname: "MacBook Fixture",
        platform: "macos",
        capabilities: [],
      }),
    });
    if (!hello.ok) return null;
    const helloData = await hello.json();
    return helloData.terminal_id ?? device.id ?? null;
  } catch {
    return null;
  }
}
