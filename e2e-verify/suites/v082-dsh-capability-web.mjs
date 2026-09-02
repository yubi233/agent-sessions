// V082-08（P3 可见验收）：含工具调用的 DSH 会话事件链路 headed Chrome 验收。
// 真实浏览器（headed）完成「登录 → DSH 工作区 → 会话详情」，断言 DSH 会话的
// 工具活动事件（tool.call/tool.result）经 fixture Terminal 上传后完整出现在
// Relay 会话事件时间线（Web 只读架构刻意不渲染密文正文，只显示 event_type 序列；
// 工具载荷的 fixture_payload 形状与 LocalDevEventEncoder 一致，移动端同构渲染
// 由 localdev_encoder 契约测试与 Flutter widget 测试覆盖）。
import { launchHeaded, browserLabel } from "../lib/browser.mjs";

export const v082DshCapabilityWeb = {
  id: "v082-dsh-capability-web",
  title: "V082 Web DSH 工具事件链路 headed 验收",
  planId: "V082",
  async run(ctx) {
    const { relay, web, report, headless = false, fixtureAccount } = ctx;
    const errors = [];
    const notes = [];
    let account;
    let sessionId;
    let workspaceId;
    try {
      account = await fixtureAccount();
      const fixture = await seedDshToolTimeline(relay.base, account);
      sessionId = fixture.sessionId;
      workspaceId = fixture.workspaceId;
    } catch (error) {
      return report({
        suite: "v082-dsh-capability-web",
        planId: "V082",
        status: "failed",
        real_browser: !headless,
        fixture_data: true,
        local_test: true,
        headless: Boolean(headless),
        browser: browserLabel(headless),
        command: "node e2e-verify/run.mjs --suite v082-dsh-capability-web",
        artifacts: [],
        failure_class: "test_harness_defect",
        remaining_risk: "fixture seed failed: " + safeError(error),
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

      await page.click("a[href=\"#/sessions\"]");
      // fixture DSH 会话挂在 origin=dsh 工作区组下：默认 DSH 视图按工作区分组，
      // 展开 fixture 工作区后进入会话详情。
      await page.getByTestId("dsh-workspaces-list").waitFor({ state: "visible" });
      await page.getByTestId("dsh-workspace-expand-" + workspaceId).click();
      await page.getByTestId("session-link-" + sessionId).waitFor({ state: "visible" });
      await page.getByTestId("session-link-" + sessionId).click();
      await page.getByTestId("session-detail-meta").waitFor({ state: "visible" });

      // 事件时间线：fixture 注入的 5 条事件（含工具调用/结果）必须完整可见。
      await page.getByTestId("session-detail-events").waitFor({ state: "visible" });
      const eventText = await page.getByTestId("session-detail-events").innerText();
      notes.push("DSH 会话事件时间线: " + eventText.replace(/\s+/g, " ").slice(0, 200));
      for (const expected of ["user.message", "tool.call", "tool.result", "message.completed", "turn.completed"]) {
        if (!eventText.includes(expected)) {
          errors.push("事件时间线缺少 " + expected + ": " + eventText);
        }
      }
      await page.close();
    } catch (error) {
      errors.push("浏览器旅程异常: " + safeError(error));
    } finally {
      await browser.close();
    }

    return report({
      suite: "v082-dsh-capability-web",
      planId: "V082",
      status: errors.length === 0 ? "passed" : "failed",
      real_browser: !headless,
      real_model: false,
      real_upstream: false,
      fixture_data: true,
      local_test: true,
      headless: Boolean(headless),
      browser: browserLabel(headless),
      command: "node e2e-verify/run.mjs --suite v082-dsh-capability-web",
      test_ids: ["V082-08", "V082-07"],
      artifacts: [],
      failure_class: errors.length ? "selector_or_dom_contract_defect" : null,
      remaining_risk: "基于隔离 Relay 与受控 fixture 事件注入；不读取真实 DSH 根、不调用模型。",
      notes,
      errors,
    });
  },
};

// seedDshToolTimeline 预置含工具时间线的 DSH 会话（owner + fixture Terminal + 命令闭环）。
async function seedDshToolTimeline(relayBase, account) {
  const ownerHeaders = { "Content-Type": "application/json", Authorization: "Bearer " + account.accessToken };
  async function req(path, opts) {
    const method = (opts && opts.method) || "GET";
    const headers = (opts && opts.headers) || ownerHeaders;
    const body = opts && opts.body;
    const response = await fetch(relayBase + path, {
      method,
      headers,
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    });
    if (!response.ok) {
      const text = await response.text();
      throw new Error(method + " " + path + " failed: " + response.status + " " + text.slice(0, 200));
    }
    return response.json();
  }

  // 1) 配对 fixture Terminal 并 hello（bearer；optional 签名窗口放行）。
  const pairing = await req("/v1/pairing/requests", {
    method: "POST",
    body: { role: "terminal", display_name: "v082-fixture-terminal", platform: "test",
      identity_public_key: "v082-fixture-identity", encryption_public_key: "v082-fixture-encryption" },
  });
  const approved = await req("/v1/pairing/requests/" + encodeURIComponent(pairing.id) + "/approve", { method: "POST" });
  const terminalToken = approved.tokens && approved.tokens.access_token;
  if (!terminalToken) throw new Error("fixture terminal token missing");
  const terminalHeaders = { "Content-Type": "application/json", Authorization: "Bearer " + terminalToken };
  const hello = await req("/v1/daemon/hello", {
    method: "POST",
    headers: terminalHeaders,
    body: { protocol_version: 1, daemon_version: "v082-fixture", hostname: "v082-fixture", platform: "test",
      capabilities: ["start", "send", "abort", "kill", "dsh_workspace_sync"] },
  });
  const terminalId = hello.terminal_id;
  if (!terminalId) throw new Error("fixture terminal id missing");

  // 2) sync-dsh 回执造受控 DSH 工作区（与 v081 suite 同路径：hello 声明 dsh_workspace_sync，
  //    owner 提交 sync 命令，fixture Terminal 回执 candidates 生成 origin=dsh workspace）。
  const sync = await req("/v1/workspaces/sync-dsh", { method: "POST", body: { terminal_id: terminalId } });
  await req("/v1/daemon/commands/" + encodeURIComponent(sync.command_id) + "/dsh-workspace-result", {
    method: "POST", headers: terminalHeaders,
    body: { protocol_version: 1, delivery_seq: 1, status: "succeeded",
      candidates: [{ canonical_root: "/fixture/v082/dsh-timeline", display_name: "v082-dsh-timeline" }] },
  });
  const listed = await req("/v1/workspaces");
  const workspace = (listed.workspaces || []).find(function (w) {
    return w.origin === "dsh" && w.display_name === "v082-dsh-timeline";
  });
  if (!workspace) throw new Error("fixture DSH workspace missing");
  const session = await req("/v1/sessions", { method: "POST", body: { workspace_id: workspace.id, provider: "dsh" } });
  const sessionId = session.id;

  // 3) session.start 命令闭环：lease → 提交 → ack received/started → 事件上传 → result。
  const lease = await req("/v1/sessions/" + sessionId + "/lease", { method: "POST" });
  const command = await req("/v1/sessions/" + sessionId + "/commands", {
    method: "POST",
    body: { kind: "session.start", idempotency_key: "v082-timeline-start-" + Date.now(), lease_epoch: lease.lease_epoch,
      target_terminal_id: terminalId,
      ciphertext: { kind: "session.start", session_id: sessionId, workspace_root: "/fixture/v082/dsh-timeline",
        provider: "dsh", ciphertext: { fixture_payload: { provider: "dsh" } } } },
  });
  const commandId = command.id;
  // Relay 投递在提交事务内落表：同一 Terminal 的 delivery_seq 按 MAX+1 单调分配，
  // 本链路 sync-dsh 命令先占 seq=1，session.start 命令必为 seq=2（调试实证；不可写死 1）。
  const startDeliverySeq = 2;
  for (const ackKind of ["received", "started"]) {
    await req("/v1/daemon/commands/" + commandId + "/ack", {
      method: "POST", headers: terminalHeaders,
      body: { protocol_version: 1, delivery_seq: startDeliverySeq, ack_kind: ackKind, error_code: "" },
    });
  }
  // 4) 上传 5 条 local-dev fixture 事件（LocalDevEventEncoder 形状）。
  const events = [
    { id: "evt-v082-user-1", type: "user.message",
      payload: { kind: "user_message", label: "你", text: "请列出工作区文件", copy_text: "请列出工作区文件" } },
    { id: "evt-v082-toolcall-1", type: "tool.call",
      payload: { kind: "tool_activity", label: "bash: ls -la", tool_status: "运行中",
        tool_input: '{"command":"ls -la"}', inspect_target: "tool-v082-1" } },
    { id: "evt-v082-toolresult-1", type: "tool.result",
      payload: { kind: "tool_activity", label: "bash: ls -la", tool_status: "已完成",
        tool_output: "reports/  docs/  cordis.yml", inspect_target: "tool-v082-1" } },
    { id: "evt-v082-msg-1", type: "message.completed",
      payload: { kind: "assistant_message", label: "Assistant", text: "工作区包含 reports 与 docs。", copy_text: "工作区包含 reports 与 docs。" } },
    { id: "evt-v082-turn-1", type: "turn.completed",
      payload: { kind: "assistant_message", label: "Assistant", completed_turn: true } },
  ];
  for (const event of events) {
    const envelope = {
      alg: "local-dev-fixture", key_id: "local-dev", nonce: "local-dev",
      ciphertext: Buffer.from(JSON.stringify({ fixture_payload: event.payload })).toString("base64"),
      aad_hash: "local-dev", payload_version: 1, fixture_payload: event.payload,
    };
    await req("/v1/daemon/events", {
      method: "POST", headers: terminalHeaders,
      body: { protocol_version: 1, event_id: event.id, command_id: commandId, session_id: sessionId,
        event_type: event.type, terminal_status: event.type === "turn.completed" ? "idle" : "", envelope },
    });
  }
  await req("/v1/daemon/commands/" + commandId + "/result", {
    method: "POST", headers: terminalHeaders,
    body: { protocol_version: 1, delivery_seq: startDeliverySeq, status: "succeeded", error_code: "" },
  });
  return { sessionId: sessionId, workspaceId: workspace.id };
}

function safeError(error) {
  return error instanceof Error ? error.message : String(error);
}
