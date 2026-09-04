// V085-14（P3 可见验收·中止侧）：中止后会话状态与轨迹时间的 Web 只读投影 headed Chrome 验收。
// 真实浏览器（headed）完成「登录 → DSH 工作区 → 会话详情」，断言 fixture Terminal
// 上传的 session.aborted（含 created_at_unix_ms）经 Relay 投影后，Web 会话详情
// 时间线出现 session.aborted 事件类型、会话状态收敛为 stopped（Relay 不解密 payload
// 即可用 terminal_status 投影）。Web 只读架构不渲染密文正文与 HH:mm:ss——移动端
// 的“已中止 · 时间”渲染由 Flutter widget 测试与可见 macOS gate 覆盖（V085-20..23）。
import { launchHeaded, browserLabel } from "../lib/browser.mjs";

export const v085AbortTrajectoryWeb = {
  id: "v085-abort-trajectory-web",
  title: "V085 Web 中止轨迹 stopped 投影 headed 验收",
  planId: "V085",
  async run(ctx) {
    const { relay, web, report, headless = false, fixtureAccount } = ctx;
    const errors = [];
    const notes = [];
    let account;
    let sessionId;
    let workspaceId;
    try {
      account = await fixtureAccount();
      const fixture = await seedAbortTrajectory(relay.base, account);
      sessionId = fixture.sessionId;
      workspaceId = fixture.workspaceId;
    } catch (error) {
      return report({
        suite: "v085-abort-trajectory-web",
        planId: "V085",
        status: "failed",
        real_browser: !headless,
        fixture_data: true,
        local_test: true,
        headless: Boolean(headless),
        browser: browserLabel(headless),
        command: "node e2e-verify/run.mjs --suite v085-abort-trajectory-web",
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

      await page.click('a[href="#/sessions"]');
      await page.getByTestId("dsh-workspaces-list").waitFor({ state: "visible" });
      await page.getByTestId("dsh-workspace-expand-" + workspaceId).click();
      await page.getByTestId("session-link-" + sessionId).waitFor({ state: "visible" });
      await page.getByTestId("session-link-" + sessionId).click();
      await page.getByTestId("session-detail-meta").waitFor({ state: "visible" });

      // 时间线：中止回合的 event_type 序列必须完整可见（session.aborted 为新增类型）。
      await page.getByTestId("session-detail-events").waitFor({ state: "visible" });
      const eventText = await page.getByTestId("session-detail-events").innerText();
      notes.push("中止会话事件时间线: " + eventText.replace(/\s+/g, " ").slice(0, 240));
      for (const expected of ["user.message", "message.completed", "session.aborted", "turn.completed"]) {
        if (!eventText.includes(expected)) {
          errors.push("事件时间线缺少 " + expected + ": " + eventText);
        }
      }
      // 会话状态必须收敛为 stopped（session.aborted 的 terminal_status 投影）。
      const metaText = await page.getByTestId("session-detail-meta").innerText();
      notes.push("会话详情 meta: " + metaText.replace(/\s+/g, " ").slice(0, 160));
      if (!/stopped/.test(metaText)) {
        errors.push("会话详情未显示 stopped 状态: " + metaText);
      }
      await page.close();
    } catch (error) {
      errors.push("浏览器旅程异常: " + safeError(error));
    } finally {
      await browser.close();
    }

    return report({
      suite: "v085-abort-trajectory-web",
      planId: "V085",
      status: errors.length === 0 ? "passed" : "failed",
      real_browser: !headless,
      real_model: false,
      real_upstream: false,
      fixture_data: true,
      local_test: true,
      headless: Boolean(headless),
      browser: browserLabel(headless),
      command: "node e2e-verify/run.mjs --suite v085-abort-trajectory-web",
      test_ids: ["V085-14"],
      artifacts: [],
      failure_class: errors.length ? "selector_or_dom_contract_defect" : null,
      remaining_risk: "Web 只读不渲染 HH:mm:ss；时间显示由 Flutter widget/gate 覆盖。基于隔离 Relay 与受控 fixture，不读真实 DSH 根、不调用模型。",
      notes,
      errors,
    });
  },
};

// seedAbortTrajectory 预置中止回合的 DSH 会话：owner + fixture Terminal + 命令闭环，
// 事件顺序冻结为 user.message → message.completed → session.aborted(stopped) → turn.completed。
async function seedAbortTrajectory(relayBase, account) {
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
    body: { role: "terminal", display_name: "v085-fixture-terminal", platform: "test",
      identity_public_key: "v085-fixture-identity", encryption_public_key: "v085-fixture-encryption" },
  });
  const approved = await req("/v1/pairing/requests/" + encodeURIComponent(pairing.id) + "/approve", { method: "POST" });
  const terminalToken = approved.tokens && approved.tokens.access_token;
  if (!terminalToken) throw new Error("fixture terminal token missing");
  const terminalHeaders = { "Content-Type": "application/json", Authorization: "Bearer " + terminalToken };
  const hello = await req("/v1/daemon/hello", {
    method: "POST",
    headers: terminalHeaders,
    body: { protocol_version: 1, daemon_version: "v085-fixture", hostname: "v085-fixture", platform: "test",
      capabilities: ["start", "send", "abort", "kill", "dsh_workspace_sync"] },
  });
  const terminalId = hello.terminal_id;
  if (!terminalId) throw new Error("fixture terminal id missing");

  // 2) sync-dsh 回执造受控 DSH 工作区。
  const sync = await req("/v1/workspaces/sync-dsh", { method: "POST", body: { terminal_id: terminalId } });
  await req("/v1/daemon/commands/" + encodeURIComponent(sync.command_id) + "/dsh-workspace-result", {
    method: "POST", headers: terminalHeaders,
    body: { protocol_version: 1, delivery_seq: 1, status: "succeeded",
      candidates: [{ canonical_root: "/fixture/v085/abort-trajectory", display_name: "v085-abort-trajectory" }] },
  });
  const listed = await req("/v1/workspaces");
  const workspace = (listed.workspaces || []).find(function (w) {
    return w.origin === "dsh" && w.display_name === "v085-abort-trajectory";
  });
  if (!workspace) throw new Error("fixture DSH workspace missing");
  const session = await req("/v1/sessions", { method: "POST", body: { workspace_id: workspace.id, provider: "dsh" } });
  const sessionId = session.id;

  // 3) session.start 命令闭环（sync-dsh 占 seq=1，start 必为 seq=2）。
  const lease = await req("/v1/sessions/" + sessionId + "/lease", { method: "POST" });
  const command = await req("/v1/sessions/" + sessionId + "/commands", {
    method: "POST",
    body: { kind: "session.start", idempotency_key: "v085-abort-start-" + Date.now(), lease_epoch: lease.lease_epoch,
      target_terminal_id: terminalId,
      ciphertext: { kind: "session.start", session_id: sessionId, workspace_root: "/fixture/v085/abort-trajectory",
        provider: "dsh", ciphertext: { fixture_payload: { provider: "dsh" } } } },
  });
  const commandId = command.id;
  const startDeliverySeq = 2;
  for (const ackKind of ["received", "started"]) {
    await req("/v1/daemon/commands/" + commandId + "/ack", {
      method: "POST", headers: terminalHeaders,
      body: { protocol_version: 1, delivery_seq: startDeliverySeq, ack_kind: ackKind, error_code: "" },
    });
  }
  // 4) 上传中止回合事件：user.message → message.completed → session.aborted(stopped) → turn.completed。
  const createdAtMs = Date.now() - 60000;
  const events = [
    { id: "evt-v085-user-1", type: "user.message", terminal: "",
      payload: { kind: "user_message", label: "你", text: "你好", copy_text: "你好" } },
    { id: "evt-v085-msg-1", type: "message.completed", terminal: "",
      payload: { kind: "assistant_message", label: "Assistant", text: "正在处理你的回合…", copy_text: "正在处理你的回合…" } },
    { id: "evt-v085-aborted-1", type: "session.aborted", terminal: "stopped",
      payload: { kind: "system_notice", label: "已中止", text: "Android 控制端已中止当前回合。" } },
    // Provider 收到 cancel 后的 cancelled 终态必须以 stopped 收口，不能把
    // session.aborted 已投影的 stopped 状态打回 idle。
    { id: "evt-v085-turn-1", type: "turn.completed", terminal: "stopped",
      payload: { kind: "assistant_message", label: "Assistant", completed_turn: true } },
  ];
  for (const event of events) {
    const envelope = {
      alg: "local-dev-fixture", key_id: "local-dev", nonce: "local-dev",
      ciphertext: Buffer.from(JSON.stringify({ fixture_payload: event.payload })).toString("base64"),
      aad_hash: "local-dev", payload_version: 1, fixture_payload: event.payload,
    };
    const body = { protocol_version: 1, event_id: event.id, command_id: commandId, session_id: sessionId,
      event_type: event.type, envelope };
    if (event.terminal) body.terminal_status = event.terminal;
    body.created_at_unix_ms = createdAtMs;
    await req("/v1/daemon/events", { method: "POST", headers: terminalHeaders, body });
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