#!/usr/bin/env node
// v0.7/P5 全链路演示录屏（V07-10）。
// 录屏不是业务 gate：它必须读取本轮已通过的 gate 报告，并把 fixture、
// headed 浏览器和真实模型口径分别写入 manifest/report，避免演示证据被误读。
import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdir, readFile, stat, writeFile } from "node:fs/promises";
import { join, dirname, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { launchHeaded } from "./lib/browser.mjs";
import { createFixtureAccountFactory } from "./lib/fixture-account.mjs";
import { startRelay } from "./lib/relay.mjs";
import { startWeb } from "./lib/web.mjs";
import { baseReport, writeReport } from "./lib/report.mjs";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const SCREENCAST_ROOT = join(ROOT, "e2e-verify", "screencasts");
export const V07_RECORDING_FPS = 6;
export const V07_RECORDING_QUALITY = 65;
export const V07_RECORDING_PROVIDER = "codex";
export const V07_RECORDING_STEPS = Object.freeze([
  "打开 Web 只读首页",
  "登录只读账号",
  "打开会话列表",
  "进入新建工作区绑定的会话",
  "展示问答回合事件",
  "归档会话并刷新只读视图",
]);

class RecordingError extends Error {
  constructor(message, { failureClass = "test_harness_defect" } = {}) {
    super(message);
    this.name = "V07RecordingError";
    this.failureClass = failureClass;
  }
}

function safeError(error) {
  return String(error instanceof Error ? error.message : error)
    .replace(/(bearer\s+)[^\s"']+/gi, "$1[REDACTED]")
    .replace(/((?:api[_-]?key|token|password|secret)\s*[:=]\s*)[^\s,}"']+/gi, "$1[REDACTED]")
    .replace(/\/(?:Users|private|var|tmp)\/[^\s"']+/g, "[PATH REDACTED]")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 600);
}

function evidenceReference(path) {
  const value = relative(ROOT, path);
  return value && !value.startsWith("..") ? value : "[PATH REDACTED]";
}

function shortHash(value) {
  return `sha256:${createHash("sha256").update(String(value), "utf8").digest("hex").slice(0, 16)}`;
}

function wait(milliseconds) {
  return new Promise((resolveWait) => setTimeout(resolveWait, milliseconds));
}

export function parseRecordingArgs(argv = []) {
  const args = {
    help: false,
    gateReport: process.env.V07_WEB_GATE_REPORT || process.env.V07_GATE_REPORT || "",
    fps: V07_RECORDING_FPS,
    quality: V07_RECORDING_QUALITY,
    fixture: false,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const value = argv[index];
    if (value === "--help" || value === "-h") args.help = true;
    else if (value === "--gate-report") args.gateReport = String(argv[++index] || "").trim();
    else if (value === "--fps") args.fps = Number.parseInt(argv[++index], 10);
    else if (value === "--quality") args.quality = Number.parseInt(argv[++index], 10);
    else if (value === "--fixture") args.fixture = true;
    else if (value === "--headless") {
      throw new RecordingError("v0.7 录屏拒绝 --headless，必须启动可见 Chrome。", {
        failureClass: "test_harness_defect",
      });
    } else {
      throw new RecordingError(`未知参数：${value}`);
    }
  }
  if (!args.help && !args.gateReport) {
    throw new RecordingError("录屏必须通过 --gate-report、V07_WEB_GATE_REPORT 或 V07_GATE_REPORT 提供前置报告。", {
      failureClass: "checkpoint_mismatch",
    });
  }
  if (!args.help && !args.fixture) {
    throw new RecordingError(
      "当前 v0.7 Web 录屏 runner 只实现本地 fixture；必须显式指定 --fixture，真实模型录屏保持 blocked。",
      { failureClass: "checkpoint_mismatch" },
    );
  }
  if (!Number.isInteger(args.fps) || args.fps !== V07_RECORDING_FPS) {
    throw new RecordingError(`v0.7 Web 录屏固定为 ${V07_RECORDING_FPS}fps。`, {
      failureClass: "test_harness_defect",
    });
  }
  if (!Number.isInteger(args.quality) || args.quality !== V07_RECORDING_QUALITY) {
    throw new RecordingError(`v0.7 Web 录屏 JPEG quality 固定为 ${V07_RECORDING_QUALITY}。`, {
      failureClass: "test_harness_defect",
    });
  }
  return args;
}

export function validateGateReport(report, { allowFixture = false } = {}) {
  if (!report || typeof report !== "object") {
    throw new RecordingError("gate 报告不是有效 JSON 对象。", { failureClass: "checkpoint_mismatch" });
  }
  if (report.status !== "passed" || report.headless !== false || report.real_browser !== true) {
    throw new RecordingError("gate 尚未以 headed 模式通过，不能开始录屏。", { failureClass: "checkpoint_mismatch" });
  }
  if (report.real_model !== true && !allowFixture) {
    throw new RecordingError("真实模型 gate 未通过；本地 fixture 录屏必须显式指定 --fixture。", {
      failureClass: "checkpoint_mismatch",
    });
  }
  if (allowFixture && (report.fixture_data !== true || report.local_test !== true)) {
    throw new RecordingError("--fixture 录屏需要 fixture_data=true 且 local_test=true 的 gate。", {
      failureClass: "checkpoint_mismatch",
    });
  }
  return report;
}

async function loadGateReport(path, options) {
  let text;
  try {
    text = await readFile(resolve(path), "utf8");
  } catch {
    throw new RecordingError("找不到 gate 报告。", { failureClass: "checkpoint_mismatch" });
  }
  try {
    return { path: resolve(path), report: validateGateReport(JSON.parse(text), options) };
  } catch (error) {
    if (error instanceof RecordingError) throw error;
    throw new RecordingError("gate 报告无法解析。", { failureClass: "checkpoint_mismatch" });
  }
}

async function requestJson(base, path, { token, method = "GET", body } = {}) {
  const headers = { Accept: "application/json" };
  if (token) headers.Authorization = `Bearer ${token}`;
  if (body !== undefined) headers["Content-Type"] = "application/json";
  let response;
  try {
    response = await fetch(`${base}${path}`, {
      method,
      headers,
      body: body === undefined ? undefined : JSON.stringify(body),
    });
  } catch (error) {
    throw new RecordingError(`${method} ${path} 网络请求失败：${safeError(error)}`, {
      failureClass: "environment_or_startup_failure",
    });
  }
  if (!response.ok) {
    const failureClass = response.status === 401 || response.status === 403
      ? "credential_or_quota_blocker"
      : response.status === 409 || response.status === 422
        ? "product_defect"
        : response.status === 408 || response.status === 429 || response.status >= 500
          ? "provider_timeout"
          : "provider_http_error";
    throw new RecordingError(`${method} ${path} 返回 HTTP ${response.status}`, { failureClass });
  }
  return response.status === 204 ? {} : response.json();
}

// seedFixtureSession 只在本地演示模式创建白名单 workspace/session；owner token
// 仅留在 Node 进程内，浏览器仍通过可见登录页取得自己的只读 token。
async function seedFixtureSession(relayBase, account) {
  const workspace = await requestJson(relayBase, "/v1/workspaces", {
    token: account.accessToken,
    method: "POST",
    body: {
      project_id: "v07-recording-project",
      terminal_id: "",
      canonical_root: "/fixture/v07-recording",
      status: "active",
    },
  });
  const session = await requestJson(relayBase, "/v1/sessions", {
    token: account.accessToken,
    method: "POST",
    // 使用现有只读 Web fixture 已覆盖的 codex provider；这只是 Relay
    // 元数据与 delegation.changed 演示，不代表真实 Codex/Zen 请求。
    body: { workspace_id: workspace.id, provider: V07_RECORDING_PROVIDER },
  });
  if (!workspace.id || !session.id) throw new RecordingError("录屏 fixture 缺少 workspace/session ID");
  return { workspaceId: workspace.id, sessionId: session.id };
}

// appendFixtureTurn 通过现有 delegation 契约制造脱敏事件，模拟问答回合的可见
// 事件增量；它不把回复正文、密钥或原始 envelope 写入报告。
async function appendFixtureTurn(relayBase, account, sessionId, workspaceId) {
  const lease = await requestJson(relayBase, `/v1/sessions/${encodeURIComponent(sessionId)}/lease`, {
    token: account.accessToken,
    method: "POST",
  });
  const envelope = (ciphertext) => ({
    alg: "v1-aes256gcm-hkdfsha256",
    key_id: "fixture-dek",
    nonce: "fixture-nonce",
    ciphertext,
    aad_hash: "fixture-aad",
    payload_version: 1,
  });
  await requestJson(relayBase, `/v1/sessions/${encodeURIComponent(sessionId)}/delegations`, {
    token: account.accessToken,
    method: "POST",
    body: {
      target_workspace_id: workspaceId,
      // delegation 契约只接受已登记的 provider；codex 在本地 fixture
      // 中仅用于展示事件链，不会启动或调用真实模型。
      target_provider: V07_RECORDING_PROVIDER,
      task_envelope: envelope("opaque-v07-question"),
      summary_envelope: envelope("opaque-v07-answer"),
      idempotency_key: `v07-recording-turn-${Date.now()}`,
      lease_epoch: lease.lease_epoch,
    },
  });
}

async function archiveSession(relayBase, account, sessionId) {
  const archived = await requestJson(relayBase, `/v1/sessions/${encodeURIComponent(sessionId)}/archive`, {
    token: account.accessToken,
    method: "POST",
  });
  const archivedList = await requestJson(relayBase, "/v1/sessions?archived=true", { token: account.accessToken });
  const activeList = await requestJson(relayBase, "/v1/sessions", { token: account.accessToken });
  const found = Array.isArray(archivedList.sessions) && archivedList.sessions.some((item) => item.id === sessionId);
  const remainsActive = Array.isArray(activeList.sessions) && activeList.sessions.some((item) => item.id === sessionId);
  if (!found || remainsActive || archived.status !== "idle") {
    throw new RecordingError("录屏 fixture 归档结果未进入 archived 列表", { failureClass: "product_defect" });
  }
  return { status: archived.status, archived: true };
}

function encodeMp4(frameDirectory, outputPath, fps) {
  return new Promise((resolveEncode, rejectEncode) => {
    const child = execFile("ffmpeg", [
      "-framerate", String(fps),
      "-i", join(frameDirectory, "frame-%05d.jpg"),
      "-c:v", "libx264", "-pix_fmt", "yuv420p", "-y", outputPath,
    ], { timeout: 60_000 }, (error) => {
      if (error) rejectEncode(new RecordingError("ffmpeg 未能生成 v0.7 演示 MP4", { failureClass: "environment_or_startup_failure" }));
      else resolveEncode();
    });
    child.on("error", (error) => rejectEncode(new RecordingError(`ffmpeg 启动失败：${safeError(error)}`, { failureClass: "environment_or_startup_failure" })));
  });
}

async function runRecording({ args, gate, timestamp = new Date().toISOString().replace(/[:.]/g, "-") }) {
  const outputDirectory = join(SCREENCAST_ROOT, timestamp, "V07-10");
  const frameDirectory = join(outputDirectory, "frames");
  await mkdir(frameDirectory, { recursive: true });
  let relay;
  let web;
  let browser;
  let page;
  let cdp;
  const frames = [];
  const frameWrites = [];
  let frameIndex = 0;
  let archived = null;
  let context = null;
  let browserStarted = false;
  let fixtureSeeded = false;
  try {
    relay = await startRelay();
    web = await startWeb({ relayBase: relay.base });
    const fixtureAccount = createFixtureAccountFactory(relay.base);
    const account = await fixtureAccount();
    context = await seedFixtureSession(relay.base, account);
    fixtureSeeded = true;
    browser = await launchHeaded({ headless: false });
    browserStarted = true;
    page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
    cdp = await page.context().newCDPSession(page);
    cdp.on("Page.screencastFrame", ({ data, sessionId }) => {
      const path = join(frameDirectory, `frame-${String(frameIndex++).padStart(5, "0")}.jpg`);
      // CDP 回调不能阻塞 ack；把写入 Promise 收集起来，编码前统一等待，避免
      // ffmpeg 在最后几帧仍未落盘时读取到不完整序列。
      frameWrites.push(writeFile(path, Buffer.from(data, "base64")));
      frames.push(path);
      cdp.send("Page.screencastFrameAck", { sessionId }).catch(() => {});
    });
    await cdp.send("Page.startScreencast", {
      format: "jpeg",
      quality: args.quality,
      everyNthFrame: 1,
    });

    // 每个步骤既有可见页面断言，也有必要的后台 fixture 动作；步骤名会进入 manifest。
    await page.goto(web.base, { waitUntil: "domcontentloaded" });
    await page.getByTestId("relay-ready").waitFor({ state: "visible" });
    await wait(700);
    await page.getByTestId("login-email").fill(account.email);
    await page.getByTestId("login-password").fill(account.password);
    await page.getByTestId("login-submit").click();
    await page.getByTestId("auth-ok").waitFor({ state: "visible" });
    await wait(900);
    await page.click('a[href="#/sessions"]');
    await page.getByTestId("sessions-list").waitFor({ state: "visible" });
    await page.getByTestId(`session-link-${context.sessionId}`).waitFor({ state: "visible" });
    await wait(900);
    await page.getByTestId(`session-link-${context.sessionId}`).click();
    await page.getByTestId("session-detail-meta").waitFor({ state: "visible" });
    await page.getByTestId("session-detail-stream-status").filter({ hasText: "已连接" }).waitFor({ state: "visible" });
    await wait(900);
    await appendFixtureTurn(relay.base, account, context.sessionId, context.workspaceId);
    await page.getByTestId("session-detail-events").filter({ hasText: "delegation.changed" }).waitFor({ state: "visible", timeout: 10_000 });
    await wait(1_000);
    archived = await archiveSession(relay.base, account, context.sessionId);
    await page.getByTestId("session-detail-refresh").click();
    await page.getByTestId("session-detail-meta").waitFor({ state: "visible" });
    await wait(1_000);
    // Web 当前只读列表默认隐藏已归档会话；回到列表验证刷新后的可见投影。
    await page.click('a[href="#/sessions"]');
    await page.getByTestId("sessions-list").waitFor({ state: "visible" });
    if (await page.getByTestId(`session-link-${context.sessionId}`).count() !== 0) {
      throw new RecordingError("归档会话仍出现在默认只读列表", { failureClass: "product_defect" });
    }
    await wait(700);
    await cdp.send("Page.stopScreencast");
    // stopScreencast 返回后仍可能有一帧回调排队，给回调一个事件循环再等待全部写入。
    await wait(100);
    await Promise.all(frameWrites);
    if (frames.length === 0) throw new RecordingError("CDP 未采集到 headed 浏览器帧", { failureClass: "environment_or_startup_failure" });
    const frameStats = await Promise.all(frames.map((path) => stat(path)));
    if (frameStats.some((item) => item.size <= 0)) {
      throw new RecordingError("CDP 录屏存在空帧文件", { failureClass: "environment_or_startup_failure" });
    }
    const mp4Path = join(outputDirectory, "v07-demo.mp4");
    await encodeMp4(frameDirectory, mp4Path, args.fps);
    const manifestPath = join(outputDirectory, "manifest.json");
    const manifest = {
      timestamp,
      command: "node e2e-verify/record-v07.mjs --gate-report <passed-report> --fixture",
      gate_report: evidenceReference(gate.path),
      fps: args.fps,
      jpeg_quality: args.quality,
      frame_count: frames.length,
      steps: V07_RECORDING_STEPS,
      backend_assertions: {
        workspace_created: true,
        session_id_hash: shortHash(context.sessionId),
        event_visible: true,
        archived: archived.archived,
        archived_status: archived.status,
        active_list_hidden: true,
      },
      artifacts: [evidenceReference(manifestPath), evidenceReference(mp4Path)],
      validation: {
        real_browser: true,
        headless: false,
        fixture_data: true,
        local_test: true,
        real_model: false,
        real_upstream: false,
      },
      recording: true,
      recording_mode: "fixture",
      provider: V07_RECORDING_PROVIDER,
    };
    await writeFile(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`, "utf8");
    return { status: "passed", failureClass: null, outputDirectory, manifestPath, mp4Path, frameCount: frames.length, timestamp };
  } catch (error) {
    // 主入口据此保留失败时已经发生的 headed/fixture 事实，避免把部分证据误报为未启动。
    error.realBrowser = browserStarted;
    error.fixtureData = fixtureSeeded;
    error.outputDirectory = outputDirectory;
    throw error;
  } finally {
    await page?.close().catch(() => {});
    await browser?.close().catch(() => {});
    await web?.stop().catch(() => {});
    await relay?.stop().catch(() => {});
  }
}

function usage() {
  return [
    "用法：node e2e-verify/record-v07.mjs --gate-report <passed-report> [--fixture]",
    `  --fps ${V07_RECORDING_FPS}               固定 CDP 录屏帧率`,
    `  --quality ${V07_RECORDING_QUALITY}          固定 JPEG quality`,
    "  --fixture              明确声明本地 fixture 演示，不伪称真实模型",
    "  --headless              拒绝；v0.7 录屏必须启动可见 Chrome",
  ].join("\n");
}

async function main() {
  let args;
  let report = null;
  let outcome = null;
  try {
    args = parseRecordingArgs(process.argv.slice(2));
    if (args.help) {
      console.log(usage());
      return;
    }
    const gate = await loadGateReport(args.gateReport, { allowFixture: args.fixture });
    outcome = await runRecording({ args, gate });
    report = {
      timestamp: outcome.timestamp,
      ...baseReport({
      suite: "v07-recording",
      status: outcome.status,
      real_browser: true,
      real_model: false,
      real_upstream: false,
      fixture_data: true,
      local_test: true,
      headless: false,
      browser: "system-chrome",
      provider: "local-relay-fixture",
      command: "node e2e-verify/record-v07.mjs --gate-report <passed-report> --fixture",
      artifacts: [evidenceReference(outcome.manifestPath), evidenceReference(outcome.mp4Path)],
      remaining_risk: "录屏为 headed Chrome + 本地 fixture；不证明 Zen 真实模型、真实上游或 Android。",
      }),
      recording: true,
      recording_mode: "fixture",
    };
  } catch (error) {
    const failureClass = error instanceof RecordingError ? error.failureClass : "test_harness_defect";
    report = {
      ...baseReport({
        suite: "v07-recording",
        status: failureClass === "checkpoint_mismatch" ? "blocked" : "failed",
        real_browser: Boolean(error.realBrowser),
        real_model: false,
        real_upstream: false,
        fixture_data: Boolean(error.fixtureData),
        local_test: true,
        headless: false,
        browser: error.realBrowser ? "system-chrome" : "n/a",
        provider: error.fixtureData ? "local-relay-fixture" : "n/a",
        command: "node e2e-verify/record-v07.mjs --gate-report <passed-report> --fixture",
        artifacts: error.outputDirectory ? [evidenceReference(error.outputDirectory)] : [],
        failure_class: failureClass,
        remaining_risk: safeError(error),
      }),
      recording: true,
      recording_mode: "fixture",
    };
  }
  const file = writeReport({ planId: "V07-RELEASE", name: "V07-10", report });
  console.log(`v07 recording: ${report.status} failure_class=${report.failure_class || "none"}`);
  console.log(`report: ${file}`);
  if (report.status !== "passed") process.exitCode = 1;
}

const invokedPath = process.argv[1] ? resolve(process.argv[1]) : "";
if (invokedPath === fileURLToPath(import.meta.url)) await main();

export { loadGateReport, runRecording };
