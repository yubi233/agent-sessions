#!/usr/bin/env node
// 录屏演示入口：用 headed 真实浏览器 + CDP Page.startScreencast 抓帧，
// 合成 mp4 保存到 e2e-verify/screencasts/<timestamp>/。
// 依据 web-iterative-workflow：核心 gate 通过后才录屏；默认 6fps / jpeg q65。
// 用法：node e2e-verify/record.mjs [--fps 6] [--quality 65]
import { spawn } from "node:child_process";
import { createHash, generateKeyPairSync, sign as cryptoSign } from "node:crypto";
import { mkdirSync, writeFileSync, existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { startRelay } from "./lib/relay.mjs";
import { launchHeaded } from "./lib/browser.mjs";
import { startWeb, startAdmin } from "./lib/web.mjs";
import { baseReport, writeReport } from "./lib/report.mjs";

// seedDemoSession 为 p4-web 录屏预置一条只读会话（白名单元数据，无正文）。
// 使用注册响应的 owner 写 token；浏览器仍走可见密码登录。
async function seedDemoSession(relayBase, ownerToken) {
  const headers = {
    "Content-Type": "application/json",
    Authorization: `Bearer ${ownerToken}`,
  };
  const ws = await fetch(`${relayBase}/v1/workspaces`, {
    method: "POST",
    headers,
    body: JSON.stringify({
      project_id: "demo-project",
      terminal_id: "",
      canonical_root: "/demo",
      status: "active",
    }),
  });
  if (!ws.ok) throw new Error(`demo workspace failed: ${ws.status}`);
  const workspace = await ws.json();
  const session = await fetch(`${relayBase}/v1/sessions`, {
    method: "POST",
    headers,
    body: JSON.stringify({ workspace_id: workspace.id, provider: "codex" }),
  });
  if (!session.ok) throw new Error(`demo session failed: ${session.status}`);
}

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const SCREENCAST_DIR = join(dirname(fileURLToPath(import.meta.url)), "screencasts");

// demoScript 描述本次录屏要展示的用户可见流程（步骤 + 停留）。
// 先展示 Relay 就绪，再展示 P1 只读登录与设备列表。
const demoScript = [
  { name: "打开 Relay 状态页", action: async (page, base) => page.goto(base, { waitUntil: "domcontentloaded" }), dwell: 500 },
  { name: "等待 Relay 就绪", action: async (page) => page.getByTestId("relay-ready").waitFor({ state: "visible" }), dwell: 800 },
  { name: "点击重新检查", action: async (page) => page.getByTestId("refresh-health").click(), dwell: 800 },
  { name: "填写只读登录邮箱", action: async (page) => page.getByTestId("login-email").fill("demo@example.dev"), dwell: 400 },
  { name: "填写密码", action: async (page) => page.getByTestId("login-password").fill("demo-pass-123"), dwell: 400 },
  { name: "点击登录并查看只读设备", action: async (page) => {
      await page.getByTestId("login-submit").click();
      await page.getByTestId("auth-ok").waitFor({ state: "visible" });
    }, dwell: 900 },
  { name: "展示只读设备列表", action: async (page) => page.getByTestId("device-list").waitFor({ state: "visible" }), dwell: 900 },
];

function parseArgs(argv) {
  const args = { fps: 6, quality: 65, suite: "p1" };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--fps") args.fps = parseInt(argv[++i], 10);
    else if (argv[i] === "--quality") args.quality = parseInt(argv[++i], 10);
    else if (argv[i] === "--suite") args.suite = argv[++i] || "p1";
  }
  return args;
}

// v0.2/P5：能力矩阵录屏 demo：登录只读 Web 后打开能力矩阵页，
// 展示 opencode 真实探测结果（version/start/resume/abort native）且页面无写入口。
const capabilityMatrixDemoScript = [
  { name: "打开 Web 只读首页", action: async (page, base) => page.goto(base, { waitUntil: "domcontentloaded" }), dwell: 600 },
  { name: "登录演示账号", action: async (page) => {
      await page.getByTestId("login-email").fill("demo@example.dev");
      await page.getByTestId("login-password").fill("demo-pass-123");
      await page.getByTestId("login-submit").click();
      await page.getByTestId("auth-ok").waitFor({ state: "visible" });
    }, dwell: 900 },
  { name: "打开能力矩阵", action: async (page) => {
      await page.getByTestId("capabilities-link").click();
      await page.getByTestId("capability-matrix-view").waitFor({ state: "visible" });
    }, dwell: 1000 },
  { name: "展示 opencode 真实探测结果", action: async (page) => {
      await page.getByTestId("matrix-provider-opencode").waitFor({ state: "visible" });
      await page.getByTestId("matrix-version-opencode").waitFor({ state: "visible" });
    }, dwell: 1400 },
];

// P4 Web 只读闭环录屏：登录 -> 会话列表 -> 详情 -> 文件/Git 降级 -> 终端。
const p4WebReadOnlyDemoScript = [
  { name: "打开 Web 只读首页", action: async (page, base) => page.goto(base, { waitUntil: "domcontentloaded" }), dwell: 600 },
  { name: "登录只读账号", action: async (page) => {
      await page.getByTestId("login-email").fill("demo@example.dev");
      await page.getByTestId("login-password").fill("demo-pass-123");
      await page.getByTestId("login-submit").click();
      await page.getByTestId("auth-ok").waitFor({ state: "visible" });
    }, dwell: 900 },
  { name: "打开会话列表", action: async (page) => {
      await page.click('a[href="#/sessions"]');
      await page.getByTestId("sessions-list").waitFor({ state: "visible" });
    }, dwell: 900 },
  { name: "进入会话详情", action: async (page) => {
      const link = page.locator('[data-testid^="session-link-"]').first();
      await link.click();
      await page.getByTestId("session-detail-meta").waitFor({ state: "visible" });
    }, dwell: 1000 },
  { name: "文件页 unavailable 降级", action: async (page) => {
      await page.getByTestId("session-files-link").click();
      await page.getByTestId("files-error").waitFor({ state: "visible" });
    }, dwell: 900 },
  { name: "Git Diff unavailable 降级", action: async (page) => {
      await page.goBack();
      await page.getByTestId("session-detail-meta").waitFor({ state: "visible" });
      await page.getByTestId("session-git-link").click();
      await page.getByTestId("git-error").waitFor({ state: "visible" });
    }, dwell: 900 },
  { name: "终端状态", action: async (page) => {
      await page.goBack();
      await page.getByTestId("session-detail-meta").waitFor({ state: "visible" });
      await page.click('a[href="#/terminals"]');
      await page.getByTestId("terminals-list").waitFor({ state: "visible" });
    }, dwell: 1000 },
];

// v0.6 录屏回归清单（P4 发布门）：先定义后执行。
// 展示 signed Terminal 闭环与 Web 只读面的实时联动：
// 1) 打开 Web 只读首页并登录
// 2) 会话列表可见（fixture 会话初始 pending）
// 3) 进入会话详情，SSE 就绪
// 4) [后台] challenge -> signed hello（auth_modes 双轨）
// 5) [后台] owner 提交命令，Terminal 收到投递
// 6) [后台] signed ack started + 密文事件上传（opaque envelope）
// 7) 页面实时反映事件序号增长
// 8) [后台] signed result 收口命令为 succeeded
// 9) 页面展示会话终态与终端在线状态
const v06SignedLoopDemoScript = [
  { name: "打开 Web 只读首页", action: async (page, base) => page.goto(base, { waitUntil: "domcontentloaded" }), dwell: 600 },
  { name: "登录只读账号", action: async (page) => {
      await page.getByTestId("login-email").fill("demo@example.dev");
      await page.getByTestId("login-password").fill("demo-pass-123");
      await page.getByTestId("login-submit").click();
      await page.getByTestId("auth-ok").waitFor({ state: "visible" });
    }, dwell: 900 },
  { name: "打开会话列表", action: async (page) => {
      await page.click('a[href="#/sessions"]');
      await page.getByTestId("sessions-list").waitFor({ state: "visible" });
    }, dwell: 900 },
  { name: "进入会话详情（SSE 就绪）", action: async (page) => {
      const link = page.locator('[data-testid^="session-link-"]').first();
      await link.click();
      await page.getByTestId("session-detail-meta").waitFor({ state: "visible" });
    }, dwell: 1000 },
];

// P4 Admin 四分区录屏：登录 -> 概览 -> 终端 -> 会话 -> 审计。
const p4AdminDemoScript = [
  { name: "打开 Admin 概览", action: async (page, base) => page.goto(base, { waitUntil: "domcontentloaded" }), dwell: 600 },
  { name: "管理员登录", action: async (page) => {
      await page.getByTestId("login-email").fill("demo@example.dev");
      await page.getByTestId("login-password").fill("demo-pass-123");
      await page.getByTestId("login-submit").click();
      await page.getByTestId("auth-ok").waitFor({ state: "visible" });
    }, dwell: 900 },
  { name: "概览脱敏摘要", action: async (page) => page.getByTestId("device-list").waitFor({ state: "visible" }), dwell: 900 },
  { name: "终端分区", action: async (page) => {
      await page.click('a[href="#/terminals"]');
      await page.getByTestId("terminals-list").waitFor({ state: "visible" });
    }, dwell: 900 },
  { name: "会话分区", action: async (page) => {
      await page.click('a[href="#/sessions"]');
      await page.getByTestId("sessions-list").waitFor({ state: "visible" });
    }, dwell: 900 },
  { name: "审计分区", action: async (page) => {
      await page.click('a[href="#/audit"]');
      await page.getByTestId("audit-list").waitFor({ state: "visible" });
    }, dwell: 1000 },
];

// ---------------------------------------------------------------------------
// v0.6 signed-loop 录屏（P4 发布门）：先定义回归内容，再执行录屏。
// Node 侧签名实现与 internal/authz 冻结契约逐字段对齐（ADR-012）：
//   canonical = protocol_version|device_id|method|path|timestamp_ms|nonce|sha256(body)|key_id
//   body hash = 删除顶层 signature 成员后、顶层键字典序、紧凑 UTF-8 JSON 的 sha256 hex。
// 私钥只在内存中，不进入 manifest、报告或日志。
// ---------------------------------------------------------------------------

// signedBodyHash 复刻 Go terminalSignedBody：顶层键排序 + 紧凑序列化后取 sha256。
// 嵌套对象保持 JS 插入序（Go 端对 RawMessage 只做紧凑化不改内部顺序），两端字节一致。
function signedBodyHash(payload) {
  const members = Object.keys(payload)
    .sort()
    .map((key) => `${JSON.stringify(key)}:${JSON.stringify(payload[key])}`);
  const canonical = `{${members.join(",")}}`;
  return createHash("sha256").update(canonical, "utf8").digest("hex");
}

// signTerminalV06 对 POST path 构造 TerminalSignature；nonce 由调用方提供
// （hello 必须用一次性 challenge）。Ed25519 签名为 base64 raw std（无 padding）。
function signTerminalV06({ privateKey, deviceId, keyId }, path, payload, nonce) {
  const timestampMS = Date.now();
  const bodyHash = signedBodyHash(payload);
  const canonical = ["1", deviceId, "POST", path, String(timestampMS), nonce, bodyHash, keyId].join("|");
  const signature = cryptoSign(null, Buffer.from(canonical, "utf8"), privateKey).toString("base64").replace(/=+$/, "");
  return { protocol_version: 1, key_id: keyId, timestamp_ms: timestampMS, nonce, body_hash: bodyHash, signature };
}

// postSignedV06 发送携带 v0.6 签名的 Terminal POST；非 2xx 直接抛错让录屏失败可见。
async function postSignedV06(env, path, payload, nonce) {
  const signature = signTerminalV06(env, path, payload, nonce);
  const response = await fetch(`${env.relayBase}${path}`, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${env.terminalToken}` },
    body: JSON.stringify({ ...payload, signature }),
  });
  if (!response.ok) {
    throw new Error(`signed ${path} failed: ${response.status} ${await response.text()}`);
  }
  return response.json();
}

// v06Challenge 获取绑定当前 Terminal 的一次性 hello challenge。
async function v06Challenge(relayBase, token) {
  const response = await fetch(`${relayBase}/v1/daemon/challenge`, {
    headers: { Authorization: `Bearer ${token}` },
  });
  if (!response.ok) throw new Error(`challenge failed: ${response.status}`);
  const body = await response.json();
  return body.challenge;
}

// seedV06SignedLoop 在录制开始前准备完整 fixture：
// Ed25519 身份密钥配对 → owner 批准 → signed hello（双轨 auth_modes 断言）
// → 绑定 workspace/session。返回后续后台步骤需要的上下文。
async function seedV06SignedLoop(relayBase, ownerToken) {
  const headers = { "Content-Type": "application/json", Authorization: `Bearer ${ownerToken}` };
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  const spki = publicKey.export({ type: "spki", format: "der" });
  const identityPublicKey = spki.subarray(spki.length - 32).toString("base64url");

  const pending = await fetch(`${relayBase}/v1/pairing/requests`, {
    method: "POST",
    headers,
    body: JSON.stringify({
      role: "terminal", display_name: "v06-recording-terminal", platform: "darwin",
      identity_public_key: identityPublicKey, encryption_public_key: "ekk-v06-recording",
    }),
  });
  if (!pending.ok) throw new Error(`pairing request failed: ${pending.status} ${await pending.text()}`);
  const pairing = await pending.json();
  const approved = await fetch(`${relayBase}/v1/pairing/requests/${pairing.id}/approve`, { method: "POST", headers });
  if (!approved.ok) throw new Error(`pairing approve failed: ${approved.status}`);
  const device = await approved.json();
  const env = {
    relayBase,
    ownerToken,
    terminalToken: device.tokens.access_token,
    deviceId: device.id,
    keyId: device.id,
    privateKey,
  };

  // signed hello：nonce 必须是预签发的一次性 challenge；optional 窗口声明双轨。
  const challenge = await v06Challenge(relayBase, env.terminalToken);
  const hello = await postSignedV06(env, "/v1/daemon/hello", {
    protocol_version: 1, daemon_version: "v06-recording", hostname: "recording", platform: "darwin",
    capabilities: ["start"],
  }, challenge);
  if (!Array.isArray(hello.auth_modes) || !hello.auth_modes.includes("signature_v1") || !hello.auth_modes.includes("bearer")) {
    throw new Error(`signed hello must advertise dual auth modes: ${JSON.stringify(hello.auth_modes)}`);
  }
  env.terminalId = hello.terminal_id;

  // 绑定会话：workspace.terminal_id 使用 hello 返回的 Terminal ID。
  const ws = await fetch(`${relayBase}/v1/workspaces`, {
    method: "POST", headers,
    body: JSON.stringify({
      project_id: "v06-recording-project", terminal_id: env.terminalId,
      canonical_root: "/demo/v06-recording", status: "active",
    }),
  });
  if (!ws.ok) throw new Error(`recording workspace failed: ${ws.status}`);
  const workspace = await ws.json();
  const session = await fetch(`${relayBase}/v1/sessions`, {
    method: "POST", headers,
    body: JSON.stringify({ workspace_id: workspace.id, provider: "fixture" }),
  });
  if (!session.ok) throw new Error(`recording session failed: ${session.status}`);
  env.sessionId = (await session.json()).id;
  return env;
}

// createV06DemoScript 把后台 signed 闭环步骤插入浏览器可见流程之间；
// 每个后台步骤失败都会让整次录屏以异常结束，不允许静默降级为纯浏览录像。
function createV06DemoScript(env) {
  const ownerHeaders = { "Content-Type": "application/json", Authorization: `Bearer ${env.ownerToken}` };
  let commandId = "";
  return [
    { name: "打开 Web 只读首页", action: async (page, base) => page.goto(base, { waitUntil: "domcontentloaded" }), dwell: 600 },
    { name: "登录只读账号", action: async (page) => {
        await page.getByTestId("login-email").fill("demo@example.dev");
        await page.getByTestId("login-password").fill("demo-pass-123");
        await page.getByTestId("login-submit").click();
        await page.getByTestId("auth-ok").waitFor({ state: "visible" });
      }, dwell: 900 },
    { name: "打开会话列表", action: async (page) => {
        await page.click('a[href="#/sessions"]');
        await page.getByTestId("sessions-list").waitFor({ state: "visible" });
      }, dwell: 900 },
    { name: "进入会话详情（SSE 就绪）", action: async (page) => {
        await page.getByTestId(`session-link-${env.sessionId}`).click();
        await page.getByTestId("session-detail-meta").waitFor({ state: "visible" });
      }, dwell: 1000 },
    { name: "[后台] challenge -> signed hello（双轨 auth_modes 已在 seed 阶段断言）", action: async () => {
        const challenge = await v06Challenge(env.relayBase, env.terminalToken);
        await postSignedV06(env, "/v1/daemon/hello", {
          protocol_version: 1, daemon_version: "v06-recording-step4", hostname: "recording", platform: "darwin",
          capabilities: ["start"],
        }, challenge);
      }, dwell: 600 },
    { name: "[后台] owner 获取 lease 并提交命令", action: async () => {
        const lease = await fetch(`${env.relayBase}/v1/sessions/${env.sessionId}/lease`, { method: "POST", headers: ownerHeaders });
        if (!lease.ok) throw new Error(`lease failed: ${lease.status}`);
        const epoch = (await lease.json()).lease_epoch;
        const command = await fetch(`${env.relayBase}/v1/sessions/${env.sessionId}/commands`, {
          method: "POST", headers: ownerHeaders,
          body: JSON.stringify({
            kind: "session.start", idempotency_key: "v06-recording-1", lease_epoch: epoch,
            target_terminal_id: env.terminalId,
            ciphertext: {
              kind: "session.start", session_id: env.sessionId,
              ciphertext: { demo: true },
            },
          }),
        });
        if (!command.ok) throw new Error(`command submit failed: ${command.status} ${await command.text()}`);
        commandId = (await command.json()).id;
      }, dwell: 800 },
    { name: "[后台] signed ack started + 密文事件上传", action: async () => {
        await postSignedV06(env, `/v1/daemon/commands/${commandId}/ack`, {
          protocol_version: 1, delivery_seq: 1, ack_kind: "received", error_code: "",
        }, `rec-ack-received-${Date.now()}`);
        await postSignedV06(env, `/v1/daemon/commands/${commandId}/ack`, {
          protocol_version: 1, delivery_seq: 1, ack_kind: "started", error_code: "",
        }, `rec-ack-started-${Date.now()}`);
        await postSignedV06(env, "/v1/daemon/events", {
          protocol_version: 1, event_id: "evt-v06-recording-1", command_id: commandId,
          session_id: env.sessionId, event_type: "turn.started",
          envelope: {
            alg: "fixture-aead", key_id: "fixture-key", nonce: "fixture-nonce",
            ciphertext: "v06-recording-opaque", aad_hash: "fixture-aad", payload_version: 1,
          },
        }, `rec-event-${Date.now()}`);
      }, dwell: 600 },
    { name: "页面实时反映事件序号增长", action: async (page) => {
        await page.getByTestId("session-detail-events").getByText("turn.started").waitFor({ state: "visible", timeout: 10_000 });
      }, dwell: 1200 },
    { name: "[后台] signed result 收口命令为 succeeded", action: async () => {
        const receipt = await postSignedV06(env, `/v1/daemon/commands/${commandId}/result`, {
          protocol_version: 1, delivery_seq: 1, status: "succeeded", error_code: "",
        }, `rec-result-${Date.now()}`);
        if (receipt.status !== "succeeded") throw new Error(`result receipt mismatch: ${receipt.status}`);
      }, dwell: 800 },
    { name: "页面展示会话终态与终端在线状态", action: async (page) => {
        await page.getByTestId("session-detail-refresh").click();
        await page.getByTestId("session-detail-meta").waitFor({ state: "visible" });
        await page.getByTestId("session-files-link").waitFor({ state: "visible" });
        await page.click('a[href="#/terminals"]');
        await page.getByTestId("terminals-list").waitFor({ state: "visible" });
      }, dwell: 1200 },
  ];
}

async function main() {
  const { fps, quality, suite } = parseArgs(process.argv.slice(2));
  // 先登记回归内容：suite=v4-web 录 Web 只读闭环，suite=p4-admin 录 Admin 四分区，
  // suite=p5 录能力矩阵，suite=v06 录 signed Terminal 闭环与只读 Web 联动，
  // 其余保留既有 P1 只读 demo。
  const activeDemo = suite === "p5"
    ? capabilityMatrixDemoScript
    : suite === "p4-web"
      ? p4WebReadOnlyDemoScript
      : suite === "p4-admin"
        ? p4AdminDemoScript
        : demoScript;
  const ts = new Date().toISOString().replace(/[:.]/g, "-");
  const outDir = join(SCREENCAST_DIR, ts);
  const frameDir = join(outDir, "frames");
  mkdirSync(frameDir, { recursive: true });

  // 录屏也必须使用隔离动态端口，不能碰用户已有 Relay 数据库。
  const relay = await startRelay();
  const app = suite === "p4-admin" ? await startAdmin({ relayBase: relay.base }) : await startWeb({ relayBase: relay.base });
  const browser = await launchHeaded({ headless: false });
  const frames = [];

  try {
    // 预置录屏演示账号（bootstrap owner），保证登录流程可重复演示。
    // 注册响应携带 owner 写 token（仅用于预置会话，不进入录屏或报告）。
    const reg = await fetch(`${relay.base}/v1/auth/register`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ email: "demo@example.dev", password: "demo-pass-123" }),
    });
    if (!reg.ok) {
      throw new Error(`seed demo account failed: ${reg.status} ${await reg.text()}`);
    }
    const demoOwner = await reg.json();
    // p4-web 录屏需要一条 fixture 会话供列表/详情展示。
    if (suite === "p4-web") {
      await seedDemoSession(relay.base, demoOwner.access_token);
    }
    // v0.6 录屏：先完成配对 + signed hello + 绑定会话（回归内容已在脚本清单中定义）。
    let v06Env;
    if (suite === "v06") {
      v06Env = await seedV06SignedLoop(relay.base, demoOwner.access_token);
    }

    const page = await browser.newPage();
    const cdp = await page.context().newCDPSession(page);

    await cdp.send("Page.startScreencast", {
      format: "jpeg",
      quality,
      everyNthFrame: 1,
    });

    let seq = 0;
    cdp.on("Page.screencastFrame", ({ data, sessionId }) => {
      const file = join(frameDir, `frame-${String(seq++).padStart(5, "0")}.jpg`);
      writeFileSync(file, Buffer.from(data, "base64"));
      frames.push(file);
      cdp.send("Page.screencastFrameAck", { sessionId }).catch(() => {});
    });

    // 逐步骤执行用户可见流程，每个状态保留停留时间以便录屏审阅。
    for (const step of v06Env ? createV06DemoScript(v06Env) : activeDemo) {
      await step.action(page, app.base);
      await new Promise((r) => setTimeout(r, step.dwell));
    }

    await cdp.send("Page.stopScreencast");

    const manifest = {
      timestamp: ts,
      fps,
      quality,
      suite,
      steps: (v06Env ? createV06DemoScript(v06Env) : activeDemo).map((s) => s.name),
      frame_count: frames.length,
      relay_base: relay.base,
      web_base: app.base,
    };
    writeFileSync(join(outDir, "manifest.json"), JSON.stringify(manifest, null, 2) + "\n");

    // 用 ffmpeg 合成 mp4；缺少 ffmpeg 时仅保留帧与 manifest。
    const mp4 = join(outDir, "demo.mp4");
    if (existsSync("/opt/homebrew/bin/ffmpeg") || existsSync("/usr/local/bin/ffmpeg")) {
      await synthMp4(frameDir, mp4, fps);
      manifest.mp4 = mp4;
      writeFileSync(join(outDir, "manifest.json"), JSON.stringify(manifest, null, 2) + "\n");
    } else {
      process.stdout.write("[record] ffmpeg 不可用，仅保留帧与 manifest\n");
    }

    process.stdout.write(`[record] 完成：${outDir}（${frames.length} 帧）\n`);
    writeReport({
      planId: suite === "v06" ? "RELIABILITY-RELEASE" : "PROTO-CRYPTO",
      name: suite === "v06" ? "v06-signed-loop-recording" : "p0-web-relay-recording",
      report: baseReport({
        suite: suite === "p5"
          ? "p5-opencode-capabilities-recording"
          : suite === "v06"
            ? "v06-signed-loop-recording"
            : "p0-web-relay-recording",
        status: "passed",
        real_browser: true,
        fixture_data: true,
        local_test: true,
        headless: false,
        browser: "system-chrome",
        command: `node e2e-verify/record.mjs --suite ${suite}`,
        artifacts: [join(outDir, "manifest.json"), mp4],
        remaining_risk: suite === "p5"
          ? "录屏展示能力矩阵真实探测结果；探测失败路径由 p5-opencode-capabilities headed 回归覆盖。"
          : suite === "v06"
            ? "录屏覆盖 challenge→signed hello→命令投递→signed ack/result/event 与只读 Web 实时联动；nonce 重放、撤销等 fail-closed 分支由 task test:e2e:relay 契约回归覆盖。"
            : "录屏复用已通过的 P0 Web 状态回归；不覆盖 P1 账户和会话功能。",
      }),
    });
  } finally {
    await browser.close();
    await app.stop();
    await relay.stop();
  }
}

function synthMp4(dir, out, fps) {
  return new Promise((resolve, reject) => {
    const child = spawn(
      "ffmpeg",
      [
        "-framerate",
        String(fps),
        "-i",
        join(dir, "frame-%05d.jpg"),
        "-c:v",
        "libx264",
        "-pix_fmt",
        "yuv420p",
        "-y",
        out,
      ],
      { stdio: "inherit" },
    );
    child.on("error", reject);
    child.on("exit", (code) => (code === 0 ? resolve() : reject(new Error(`ffmpeg exited ${code}`))));
  });
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
