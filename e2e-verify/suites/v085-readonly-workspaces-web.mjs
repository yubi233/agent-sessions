// V085-10/14（Web 只读可见面）：dsh 工作区显示名与只读投影 headed Chrome 验收。
// 真实浏览器（headed）完成「登录 → DSH 工作区列表」：seed 两个受控 DSH 工作区
// （display_name 安全投影），断言列表显示真实 display_name 且不出现 canonical root；
// 展开工作区进入会话详情，只读投影只显示状态/事件类型，不渲染密文正文。
// workspace_name 的移动端副标题/空状态显示由 Flutter widget/gate 覆盖。
import { launchHeaded, browserLabel } from "../lib/browser.mjs";
import { waitForDeliverySeq } from "../lib/delivery.mjs";

export const v085ReadonlyWorkspacesWeb = {
  id: "v085-readonly-workspaces-web",
  title: "V085 Web 工作区显示名与只读投影 headed 验收",
  planId: "V085",
  async run(ctx) {
    const { relay, web, report, headless = false, fixtureAccount } = ctx;
    const errors = [];
    const notes = [];
    let account;
    let workspaceIds = [];
    let sessionIds = [];
    try {
      account = await fixtureAccount();
      const seeded = await seedWorkspaces(relay.base, account);
      workspaceIds = seeded.workspaceIds;
      sessionIds = seeded.sessionIds;
    } catch (error) {
      return report({
        suite: "v085-readonly-workspaces-web",
        planId: "V085",
        status: "failed",
        real_browser: !headless,
        fixture_data: true,
        local_test: true,
        headless: Boolean(headless),
        browser: browserLabel(headless),
        command: "node e2e-verify/run.mjs --suite v085-readonly-workspaces-web",
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

      // 工作区列表：两个 display_name 都必须以安全标签可见；canonical root 绝不出现。
      await page.click('a[href="#/sessions"]');
      await page.getByTestId("dsh-workspaces-list").waitFor({ state: "visible" });
      for (const name of ["money-tracker", "novel-draft"]) {
        const visible = await page.getByText(name, { exact: false }).count();
        if (visible === 0) {
          errors.push("工作区列表缺少显示名 " + name);
        }
      }
      const listText = await page.getByTestId("dsh-workspaces-list").innerText();
      if (/\/fixture\//.test(listText) || listText.includes("canonical_root")) {
        errors.push("工作区列表泄漏 canonical root: " + listText);
      }
      notes.push("工作区列表: " + listText.replace(/\s+/g, " ").slice(0, 260));

      // 展开第一个工作区并进入其会话：详情只读投影（状态 + 事件类型），不渲染密文正文。
      for (let i = 0; i < workspaceIds.length && i < 2; i++) {
        await page.getByTestId("dsh-workspace-expand-" + workspaceIds[i]).click();
      }
      await page.getByTestId("session-link-" + sessionIds[0]).waitFor({ state: "visible" });
      await page.getByTestId("session-link-" + sessionIds[0]).click();
      await page.getByTestId("session-detail-meta").waitFor({ state: "visible" });
      const metaText = await page.getByTestId("session-detail-meta").innerText();
      const eventText = await page.getByTestId("session-detail-events").innerText();
      notes.push("会话详情: " + metaText.replace(/\s+/g, " ").slice(0, 120));
      for (const expected of ["user.message", "message.completed"]) {
        if (!eventText.includes(expected)) {
          errors.push("事件时间线缺少 " + expected + ": " + eventText);
        }
      }
      // 只读投影绝不泄漏会话正文（fixture 密文 payload 只含脱敏 display 字段）。
      if (eventText.includes("秘密正文") || metaText.includes("/fixture/")) {
        errors.push("只读投影泄漏正文或路径: " + eventText + " " + metaText);
      }
      await page.close();
    } catch (error) {
      errors.push("浏览器旅程异常: " + safeError(error));
    } finally {
      await browser.close();
    }

    return report({
      suite: "v085-readonly-workspaces-web",
      planId: "V085",
      status: errors.length === 0 ? "passed" : "failed",
      real_browser: !headless,
      real_model: false,
      real_upstream: false,
      fixture_data: true,
      local_test: true,
      headless: Boolean(headless),
      browser: browserLabel(headless),
      command: "node e2e-verify/run.mjs --suite v085-readonly-workspaces-web",
      test_ids: ["V085-10", "V085-14"],
      artifacts: [],
      failure_class: errors.length ? "selector_or_dom_contract_defect" : null,
      remaining_risk:
        "Web 只读端不渲染 workspace_name/usage/preset（属移动端显示）；本套件只验证工作区显示名安全投影、会话只读不越界与 capability 展示不越权。基于隔离 Relay 与受控 fixture，不读真实 DSH 根、不调用模型。",
      notes,
      errors,
    });
  },
};

// seedWorkspaces 预置两个受控 DSH 工作区（display_name 安全投影）与各一个会话。
async function seedWorkspaces(relayBase, account) {
  const ownerHeaders = {
    "Content-Type": "application/json",
    Authorization: "Bearer " + account.accessToken,
  };
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

  // 1) 配对 fixture Terminal 并 hello。
  const pairing = await req("/v1/pairing/requests", {
    method: "POST",
    body: {
      role: "terminal", display_name: "v085-ro-terminal", platform: "test",
      identity_public_key: "v085-ro-identity", encryption_public_key: "v085-ro-encryption",
    },
  });
  const approved = await req("/v1/pairing/requests/" + encodeURIComponent(pairing.id) + "/approve", { method: "POST" });
  const terminalToken = approved.tokens && approved.tokens.access_token;
  if (!terminalToken) throw new Error("fixture terminal token missing");
  const terminalHeaders = { "Content-Type": "application/json", Authorization: "Bearer " + terminalToken };
  const hello = await req("/v1/daemon/hello", {
    method: "POST",
    headers: terminalHeaders,
    body: {
      protocol_version: 1, daemon_version: "v085-ro", hostname: "v085-ro", platform: "test",
      capabilities: ["start", "send", "abort", "kill", "dsh_workspace_sync"],
    },
  });
  const terminalId = hello.terminal_id;

  // 2) sync-dsh 回执造两个受控 DSH 工作区（均登记 origin=dsh）。
  const sync = await req("/v1/workspaces/sync-dsh", { method: "POST", body: { terminal_id: terminalId } });
  // 回执前先确认命令确实已投递给本 Terminal 并拿到真实 delivery_seq：
  // 硬编码 seq 在共享 Relay 上会因其它命令/重试使投递序号漂移而失败
  // （2026-09-16 整套运行偶发：回执被拒导致工作区为空，诊断为"expected 2"）。
  const syncDeliverySeq = await waitForDeliverySeq(relayBase, terminalHeaders, sync.command_id);
  await req("/v1/daemon/commands/" + encodeURIComponent(sync.command_id) + "/dsh-workspace-result", {
    method: "POST", headers: terminalHeaders,
    body: {
      protocol_version: 1, delivery_seq: syncDeliverySeq, status: "succeeded",
      candidates: [
        { canonical_root: "/fixture/v085/money-tracker", display_name: "money-tracker" },
        { canonical_root: "/fixture/v085/novel-draft", display_name: "novel-draft" },
      ],
    },
  });
  const listed = await req("/v1/workspaces");
  // fixture owner 是**跨套件共享**的单租户账号（见 lib/fixture-account.mjs），
  // 因此账号下会累积其它套件建立的 DSH 工作区。这里只断言本套件刚刚创建的两个
  // 工作区存在（按 display_name 精确匹配），不账号级计数——计数会让本套件在
  // 整套运行时必然失败（2026-09-16 实测：got 7）。
  const dshWorkspaces = (listed.workspaces || []).filter((w) => w.origin === "dsh");
  const workspaces = [
    dshWorkspaces.find((w) => w.display_name === "money-tracker"),
    dshWorkspaces.find((w) => w.display_name === "novel-draft"),
  ].filter(Boolean);
  if (workspaces.length !== 2) {
    throw new Error(
      "本套件期望的 2 个 dsh 工作区缺失, got " + workspaces.length +
      " (dsh total=" + dshWorkspaces.length + ", sync delivery_seq=" + syncDeliverySeq + ")",
    );
  }
  const workspaceIds = workspaces.map((w) => w.id);
  const sessionIds = [];

  // 3) 每个工作区建会话并跑 start + 用户/助手事件闭环（只读详情展示需要）。
  for (let i = 0; i < workspaces.length; i++) {
    const workspace = workspaces[i];
    const session = await req("/v1/sessions", {
      method: "POST",
      body: { workspace_id: workspace.id, provider: "dsh" },
    });
    const sessionId = session.id;
    sessionIds.push(sessionId);
    const lease = await req("/v1/sessions/" + sessionId + "/lease", { method: "POST" });
    const command = await req("/v1/sessions/" + sessionId + "/commands", {
      method: "POST",
      body: {
        kind: "session.start", idempotency_key: "v085-ro-start-" + sessionId + "-" + Date.now(),
        lease_epoch: lease.lease_epoch, target_terminal_id: terminalId,
        ciphertext: {
          kind: "session.start", session_id: sessionId,
          workspace_root: "/fixture/v085/" + workspace.display_name,
          provider: "dsh", ciphertext: { fixture_payload: { provider: "dsh" } },
        },
      },
    });
    // Terminal 范围的 delivery_seq 全局连续：sync-dsh 占 seq=1，各会话 start 依次递增。
    const deliverySeq = 2 + i;
    for (const ackKind of ["received", "started"]) {
      await req("/v1/daemon/commands/" + command.id + "/ack", {
        method: "POST", headers: terminalHeaders,
        body: { protocol_version: 1, delivery_seq: deliverySeq, ack_kind: ackKind, error_code: "" },
      });
    }
    const events = [
      { id: "evt-ro-user-" + i, type: "user.message", payload: { kind: "user_message", label: "你", text: "你好", copy_text: "你好" } },
      { id: "evt-ro-msg-" + i, type: "message.completed", payload: { kind: "assistant_message", label: "Assistant", text: "收到。", copy_text: "收到。" } },
    ];
    for (const event of events) {
      const envelope = {
        alg: "local-dev-fixture", key_id: "local-dev", nonce: "local-dev",
        ciphertext: Buffer.from(JSON.stringify({ fixture_payload: event.payload })).toString("base64"),
        aad_hash: "local-dev", payload_version: 1, fixture_payload: event.payload,
      };
      await req("/v1/daemon/events", {
        method: "POST", headers: terminalHeaders,
        body: {
          protocol_version: 1, event_id: event.id, command_id: command.id, session_id: sessionId,
          event_type: event.type, envelope,
        },
      });
    }
  }
  return { workspaceIds, sessionIds };
}

function safeError(error) {
  return String((error && error.message) || error);
}
