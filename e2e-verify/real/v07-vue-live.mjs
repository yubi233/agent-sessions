#!/usr/bin/env node
// v0.7 真实会话收口驱动（V07-VUE-LIVE）：
//   隔离真实拓扑（opencode serve + Relay + Daemon）→ Flutter macOS App 以真实 owner
//   连接真实 Relay 并自动打开目标会话 → Zen 免费模型在演示工作区真实创建 Vue 单页应用
//   → 本机启动静态服务并验证可达 → 按 flutter-smoke-recording 规则对可见 App 窗口
//   做严格 5fps 候选采集（≥300 帧）并筛选 100 连续帧编码 MP4。
// 报告/manifest 只落盘脱敏摘要：模型、事件类型、长度、哈希、计数；不含 prompt、
// 回复正文、token 或凭据。Zen key 只由 opencode 本机认证配置读取。
import { execFile, spawn } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { baseReport, writeReport } from "../lib/report.mjs";
import { reservePort, startOpenCodeServe } from "../lib/opencode.mjs";
import { startRelay } from "../lib/relay.mjs";
import {
  V07HarnessError,
  buildDaemon,
  chooseZenModel,
  classifyHarnessError,
  discoverLocalZenFreeModels,
  discoverOfficialZenFreeModels,
  opaqueSessionEnvelope,
  requestJson,
  shortHash,
  startDaemon,
  waitCommand,
  waitForTerminal,
  waitForTurn,
} from "./v07-harness.mjs";
import {
  createMacosWindowObserver,
  macosDebugAppBundle,
  terminateMacosAppProcessesForBundle,
} from "../mobile/macos.mjs";
import {
  materializeStrictWindowEvidenceFrames,
  selectStrictWindowEvidenceFrames,
  WINDOW_EVIDENCE_FPS,
  WINDOW_EVIDENCE_FRAME_INTERVAL_MS,
  WINDOW_EVIDENCE_MAX_START_DRIFT_MS,
} from "../mobile/macos-screenshot.mjs";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..");
const MOBILE_ROOT = join(ROOT, "apps", "mobile");
const PLAN_ID = "V07-RELEASE";
const SUITE = "v07-vue-live";
const COMMAND = "node e2e-verify/real/v07-vue-live.mjs";
const DEFAULT_GOAL =
  "请在当前目录创建一个简单的 Vue 单页应用：只需要一个 index.html 文件，" +
  "通过 CDN（jsdelivr 或 unpkg）引入 Vue 3，页面实现一个简单的计数器（一个按钮，点击数字加一）。" +
  "只创建这个文件，不要启动开发服务器。";
const FLUTTER_BUILD_TIMEOUT_MS = 900_000;
const TURN_TIMEOUT_MS = 300_000;
const WINDOW_WAIT_TIMEOUT_MS = 90_000;

function parseArgs(argv) {
  const args = { help: false, frames: 600, spaPort: 8123, model: "", goal: DEFAULT_GOAL };
  for (let index = 0; index < argv.length; index += 1) {
    const value = argv[index];
    if (value === "--help" || value === "-h") args.help = true;
    else if (value === "--frames") args.frames = Number.parseInt(argv[++index], 10);
    else if (value === "--spa-port") args.spaPort = Number.parseInt(argv[++index], 10);
    else if (value === "--model") args.model = argv[++index] || "";
    else if (value === "--goal") args.goal = argv[++index] || DEFAULT_GOAL;
    else throw new V07HarnessError(`未知参数：${value}`, { failureClass: "test_harness_defect" });
  }
  if (!Number.isInteger(args.frames) || args.frames < 300) {
    throw new V07HarnessError("--frames 至少 300（严格 5fps 候选下限）。", { failureClass: "test_harness_defect" });
  }
  if (!Number.isInteger(args.spaPort) || args.spaPort <= 0 || args.spaPort > 65535) {
    throw new V07HarnessError("--spa-port 不合法。", { failureClass: "test_harness_defect" });
  }
  return args;
}

function safeError(error) {
  return String(error instanceof Error ? error.message : error).replace(/\s+/g, " ").slice(0, 400);
}

function projectRelative(path) {
  const value = relative(ROOT, path);
  return value.length > 0 && !value.startsWith("..") ? value : "[PATH REDACTED]";
}

function execFileResult(file, args, options = {}) {
  return new Promise((resolveResult) => {
    execFile(file, args, options, (error, stdout, stderr) => {
      resolveResult({
        code: typeof error?.code === "number" ? error.code : error ? null : 0,
        stdout: String(stdout || ""),
        stderr: String(stderr || ""),
        error,
      });
    });
  });
}

// opencode serve 的演示配置：只放行 Zen 相关 provider，并对 edit/bash/webfetch 显式放行，
// 避免无头 serve 在权限询问上挂起。配置只存在于本轮临时目录，不触碰用户全局配置。
function writeDemoOpencodeConfig(configDir) {
  mkdirSync(configDir, { recursive: true });
  writeFileSync(join(configDir, "opencode.json"), `${JSON.stringify({
    $schema: "https://opencode.ai/config.json",
    enabled_providers: ["openai", "opencode", "opencode-go"],
    permission: { edit: "allow", bash: "allow", webfetch: "allow" },
  }, null, 2)}\n`);
}

async function buildFlutterApp(relayBase) {
  const result = await execFileResult(
    "flutter",
    ["build", "macos", "--debug", "--no-pub", `--dart-define=RELAY_BASE_URL=${relayBase}`],
    { cwd: MOBILE_ROOT, timeout: FLUTTER_BUILD_TIMEOUT_MS, maxBuffer: 32_000_000 },
  );
  if (result.code !== 0) {
    throw new V07HarnessError("Flutter macOS debug 构建失败", {
      failureClass: "environment_or_startup_failure",
      details: { exit_code: result.code, stderr_tail: result.stderr.slice(-1_000) },
    });
  }
  const appPath = macosDebugAppBundle(MOBILE_ROOT);
  if (!existsSync(appPath)) {
    throw new V07HarnessError("Flutter 构建产物缺失", { failureClass: "environment_or_startup_failure" });
  }
  return appPath;
}

async function waitForAppWindow(observer) {
  const deadline = Date.now() + WINDOW_WAIT_TIMEOUT_MS;
  let lastCount = 0;
  while (Date.now() < deadline) {
    const observation = await observer.observe();
    lastCount = observation.count;
    const window = observation.windows
      .filter((item) => item.width >= 300 && item.height >= 500)
      .sort((a, b) => b.width * b.height - a.width * a.height)[0];
    if (window) return window;
    await new Promise((resolveDelay) => setTimeout(resolveDelay, 500));
  }
  throw new V07HarnessError("未在期限内观测到 Flutter App 可见窗口", {
    failureClass: "environment_or_startup_failure",
    details: { last_window_count: lastCount },
  });
}

function encodeMp4({ frameDirectory, outputPath, fps }) {
  return new Promise((resolveEncode, rejectEncode) => {
    const child = execFile(
      "ffmpeg",
      ["-framerate", String(fps), "-i", join(frameDirectory, "frame-%04d.png"), "-c:v", "libx264", "-pix_fmt", "yuv420p", "-y", outputPath],
      { timeout: 120_000, maxBuffer: 4_000_000 },
      (error) => {
        if (error || !existsSync(outputPath) || statSync(outputPath).size <= 0) {
          rejectEncode(new V07HarnessError("ffmpeg 未能生成会话录屏 MP4", { failureClass: "environment_or_startup_failure" }));
          return;
        }
        resolveEncode(outputPath);
      },
    );
    child.on("error", (error) => rejectEncode(new V07HarnessError(`ffmpeg 启动失败：${safeError(error)}`, { failureClass: "environment_or_startup_failure" })));
  });
}

// captureCandidateSeries 按严格 200ms 节拍管线化发起窗口截图：串行等待会让
// screencapture 的固定 ~200ms 成本累积漂移；本机实测单次调用即接近预算。
// 图像抓取发生在 screencapture 进程启动时，按时发起即保证 5fps 内容节拍；
// 每帧记录真实发起/完成时刻，最终裁决仍交给严格校验器。
async function captureCandidateSeries({ windowId, outputDirectory, frameCount, scenarioId }) {
  mkdirSync(outputDirectory, { recursive: true });
  const startedAt = Date.now();
  const completions = [];
  const frames = [];
  for (let index = 0; index < frameCount; index += 1) {
    const targetElapsedMs = index * WINDOW_EVIDENCE_FRAME_INTERVAL_MS;
    const remainingMs = targetElapsedMs - (Date.now() - startedAt);
    if (remainingMs > 0) await new Promise((resolveDelay) => setTimeout(resolveDelay, remainingMs));
    const captureStartedOffsetMs = Date.now() - startedAt;
    const outputPath = join(outputDirectory, `frame-${String(index + 1).padStart(4, "0")}.png`);
    const frame = {
      scenarioId,
      frameIndex: index + 1,
      scheduledOffsetMs: targetElapsedMs,
      captureStartedOffsetMs,
      capturedOffsetMs: captureStartedOffsetMs,
      // 与 captureMacosWindowScreenshot 产物同形的 path 键，materialize 复制依赖它。
      path: outputPath,
      captureFailed: false,
    };
    frames.push(frame);
    completions.push(new Promise((resolveFrame) => {
      execFile(
        "screencapture",
        ["-x", "-l", String(windowId), "-t", "png", outputPath],
        { timeout: 15_000, windowsHide: true },
        (error) => {
          frame.capturedOffsetMs = Math.max(Date.now() - startedAt, captureStartedOffsetMs);
          frame.captureFailed = Boolean(error);
          resolveFrame();
        },
      );
    }));
  }
  await Promise.all(completions);
  const failed = frames.filter((frame) => frame.captureFailed);
  if (failed.length > 0) {
    throw new V07HarnessError(`macOS screencapture 未能保存窗口截图（${failed.length} 帧失败）。请检查 Screen Recording 权限。`, {
      failureClass: "environment_or_startup_failure",
    });
  }
  return frames;
}

// pickStrictPacedWindow 返回候选序列中最长的连续子窗口：窗口首帧 lag 为窗口最小值
// （每帧 drift ≥ 0）且 max-min ≤ 100ms（每帧 drift ≤ 上限）。这是对真实会话现场
// 采集的如实筛选：只选择实测满足 5fps 连续节拍的帧，不放宽也不伪造。
// 返回帧按窗口起点重定基，满足 selectStrictWindowEvidenceFrames 的输入契约。
function pickStrictPacedWindow(frames, minimumWindow = 300) {
  const lag = frames.map((frame) => frame.captureStartedOffsetMs - frame.scheduledOffsetMs);
  let bestStart = -1;
  let bestLength = 0;
  for (let start = 0; start + minimumWindow <= frames.length; start += 1) {
    const base = lag[start];
    let runningMax = base;
    let length = 0;
    for (let end = start; end < frames.length; end += 1) {
      const value = lag[end];
      // 校验对重定基后的每帧要求 0 ≤ drift ≤ 上限，即 base ≤ lag ≤ base + 上限。
      if (value < base || value - base > WINDOW_EVIDENCE_MAX_START_DRIFT_MS) break;
      if (value > runningMax) runningMax = value;
      length = end - start + 1;
    }
    if (length > bestLength) {
      bestLength = length;
      bestStart = start;
    }
  }
  if (bestLength < minimumWindow) {
    return null;
  }
  const baseScheduledOffsetMs = frames[bestStart].scheduledOffsetMs;
  const baseLag = lag[bestStart];
  return frames.slice(bestStart, bestStart + bestLength).map((frame, index) => ({
    ...frame,
    frameIndex: index + 1,
    scheduledOffsetMs: index * WINDOW_EVIDENCE_FRAME_INTERVAL_MS,
    captureStartedOffsetMs: frame.captureStartedOffsetMs - baseScheduledOffsetMs - baseLag,
    capturedOffsetMs: frame.capturedOffsetMs - baseScheduledOffsetMs - baseLag,
  }));
}

async function wakeDisplay() {
  // caffeinate -d 只能阻止睡眠，不能唤醒已睡着的显示器；-u 发送用户活动信号唤醒。
  await execFileResult("caffeinate", ["-u", "-t", "3"], { timeout: 10_000 });
  await new Promise((resolveDelay) => setTimeout(resolveDelay, 2_000));
}

async function probeWindowCapture(windowId, probePath) {
  const result = await execFileResult(
    "screencapture",
    ["-x", "-l", String(windowId), "-t", "png", probePath],
    { timeout: 15_000 },
  );
  return result.code === 0 && existsSync(probePath);
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    console.log("用法：AGENT_SESSIONS_ZEN_REAL=1 node e2e-verify/real/v07-vue-live.mjs [--frames 600] [--spa-port 8123] [--model provider/id]");
    return;
  }
  if (process.env.AGENT_SESSIONS_ZEN_REAL !== "1") {
    console.error("v07-vue-live blocked: set AGENT_SESSIONS_ZEN_REAL=1 after confirming Zen Free model scope");
    process.exitCode = 2;
    return;
  }

  const timestamp = new Date().toISOString().replace(/[:.]/g, "-");
  const report = baseReport({
    suite: SUITE,
    status: "in_progress",
    real_browser: false,
    real_model: false,
    real_upstream: false,
    fixture_data: false,
    local_test: false,
    headless: false,
    command: COMMAND,
    browser: "flutter-macos-app",
    model: args.model || "dynamic-free-model",
    provider: "opencode",
    credential_source: "opencode-local-auth",
  });
  report.request_attempts = 0;
  report.command_kinds = [];
  report.topology = "flutter-macos-app -> relay -> daemon -> adapter -> opencode-serve(workspace-cwd) -> zen-free-model";

  const demoRoot = join(ROOT, "testbox", "v07-vue-live");
  const workspaceDir = join(demoRoot, "vue-spa-demo");
  const configDir = join(demoRoot, ".opencode-config");
  const artifactsDir = join(ROOT, "e2e-verify", "screenshots", `v07-vue-live-${timestamp}`);
  const candidatesDir = join(artifactsDir, "candidates");
  const evidenceDir = join(artifactsDir, "evidence");
  const stateDir = mkdtempSync(join(tmpdir(), "v07-vue-live-state-"));

  let opencode = null;
  let relay = null;
  let daemon = null;
  let appPath = null;
  let capturePromise = null;
  const startedAt = Date.now();
  const windowObserver = await createMacosWindowObserver();
  // 采集期间保持显示器唤醒；-w 绑定本进程，驱动退出即断言释放。
  const caffeinate = spawn("caffeinate", ["-d", "-w", String(process.pid)], { stdio: "ignore" });
  caffeinate.unref();
  const cleanupStack = async () => {
    if (capturePromise) await capturePromise.then(() => true, () => false).catch(() => false);
    await daemon?.stop().catch(() => {});
    await relay?.stop().catch(() => {});
    await opencode?.stop().catch(() => {});
    if (appPath) {
      try { await terminateMacosAppProcessesForBundle({ appPath }); } catch { /* 已退出时忽略 */ }
    }
    caffeinate.kill("SIGTERM");
    windowObserver.dispose();
  };

  try {
    mkdirSync(workspaceDir, { recursive: true });
    // daemon 对已存在目录要求其已是 Git 根（防悄悄改写用户目录），预创建后立即初始化。
    const gitInit = await execFileResult("git", ["init", "--quiet"], { cwd: workspaceDir });
    if (gitInit.code !== 0) {
      throw new V07HarnessError("演示工作区 git init 失败", { failureClass: "environment_or_startup_failure" });
    }
    writeDemoOpencodeConfig(configDir);
    mkdirSync(candidatesDir, { recursive: true });

    const officialCatalog = await discoverOfficialZenFreeModels();
    report.official_catalog = { count: officialCatalog.count, sha256: officialCatalog.catalog_sha256 };

    opencode = await startOpenCodeServe({ cwd: workspaceDir, configDir });
    report.auth_mode = opencode.auth_mode;
    const localCatalog = await discoverLocalZenFreeModels({
      base: opencode.base,
      username: opencode.username,
      password: process.env.OPENCODE_SERVER_PASSWORD || "",
      official: officialCatalog,
    });
    report.local_catalog = { count: localCatalog.count, sha256: localCatalog.local_catalog_sha256 };
    const model = chooseZenModel(localCatalog.options, args.model);
    report.model = model;

    relay = await startRelay({
      env: {
        AGENT_SESSIONS_OPENCODE_URL: opencode.base,
        AGENT_SESSIONS_TERMINAL_SIGNATURE_MODE: "optional",
      },
    });

    // Flutter owner bootstrap：与 restart.sh 同一真实 Relay HTTP 流程，响应原样注入 App。
    const bootstrap = await requestJson(relay.base, "/v1/auth/device-bootstrap", {
      method: "POST",
      body: {
        display_name: "v07 Vue Live Owner",
        platform: "local",
        identity_public_key: `v07-vue-live-identity-${shortHash(String(Date.now())).slice(7, 23)}`,
        encryption_public_key: "v07-vue-live-encryption",
      },
    });
    if (!bootstrap?.tokens?.access_token || !bootstrap?.device?.id) {
      throw new V07HarnessError("owner device-bootstrap 响应不完整", { failureClass: "test_harness_defect" });
    }
    const ownerToken = bootstrap.tokens.access_token;

    const pairingRequest = await requestJson(relay.base, "/v1/pairing/requests", {
      token: ownerToken,
      method: "POST",
      body: {
        role: "terminal",
        display_name: "v07-vue-live-terminal",
        platform: "darwin",
        identity_public_key: `v07-vue-live-terminal-${shortHash(String(Date.now())).slice(7, 23)}`,
        encryption_public_key: "v07-vue-live-terminal-encryption",
      },
    });
    const approved = await requestJson(
      relay.base,
      `/v1/pairing/requests/${encodeURIComponent(pairingRequest.id)}/approve`,
      { token: ownerToken, method: "POST" },
    );
    if (!approved?.tokens?.access_token) {
      throw new V07HarnessError("terminal pairing approval 响应不完整", { failureClass: "test_harness_defect" });
    }

    const binary = await buildDaemon(stateDir);
    daemon = await startDaemon(binary, {
      relayBase: relay.base,
      terminal: { deviceId: approved.id, token: approved.tokens.access_token },
      opencodeBase: opencode.base,
      model,
      workspaceRoot: demoRoot,
      stateDir,
    });
    const terminalView = await waitForTerminal(relay.base, ownerToken, approved.id);
    // session.start 与 session.send 必须使用 /v1/terminals 行 id（与 workspace 绑定一致）。
    const terminalRowId = terminalView.id;

    const workspaceCreated = await requestJson(relay.base, "/v1/workspaces/create-with-folder", {
      token: ownerToken,
      method: "POST",
      body: { name: "vue-spa-demo" },
    });
    report.command_kinds.push("workspace.create");
    const workspaceCommand = workspaceCreated.command_id
      ? await waitCommand(relay.base, ownerToken, workspaceCreated.command_id)
      : workspaceCreated;
    if (String(workspaceCommand.status || workspaceCreated.status) !== "succeeded") {
      throw new V07HarnessError("workspace.create 未成功收口", { failureClass: "product_defect" });
    }
    const workspaceId = workspaceCreated.workspace_id || workspaceCommand.workspace_id;
    report.workspace_id_hash = shortHash(workspaceId);

    const session = await requestJson(relay.base, "/v1/sessions", {
      token: ownerToken,
      method: "POST",
      body: { workspace_id: workspaceId, provider: "opencode" },
    });
    if (!session.id) throw new V07HarnessError("创建会话响应缺少 id", { failureClass: "test_harness_defect" });
    report.session_id_hash = shortHash(session.id);

    const lease = await requestJson(relay.base, `/v1/sessions/${encodeURIComponent(session.id)}/lease`, { token: ownerToken, method: "POST" });
    const leaseEpoch = Number(lease.lease_epoch);
    const startCommand = await requestJson(relay.base, `/v1/sessions/${encodeURIComponent(session.id)}/commands`, {
      token: ownerToken,
      method: "POST",
      body: {
        kind: "session.start",
        idempotency_key: `v07-vue-start-${Date.now()}`,
        lease_epoch: leaseEpoch,
        target_terminal_id: terminalRowId,
        ciphertext: opaqueSessionEnvelope({ kind: "session.start", sessionId: session.id, provider: "opencode", model }),
      },
    });
    report.command_kinds.push("session.start");
    const startResult = await waitCommand(relay.base, ownerToken, startCommand.id);
    if (startResult.status !== "succeeded") {
      throw new V07HarnessError("session.start 未成功", { failureClass: "product_defect" });
    }

    console.log("[v07-vue-live] building Flutter macOS app (debug)...");
    await wakeDisplay();
    appPath = await buildFlutterApp(relay.base);
    await terminateMacosAppProcessesForBundle({ appPath });
    console.log("[v07-vue-live] launching app on real relay...");
    const openResult = await execFileResult("/usr/bin/open", [
      "-n",
      "--env", `LOCAL_DEV_OWNER_BOOTSTRAP_B64=${Buffer.from(JSON.stringify(bootstrap)).toString("base64")}`,
      "--env", `LOCAL_DEV_TARGET_SESSION_ID=${session.id}`,
      appPath,
    ]);
    if (openResult.code !== 0) {
      throw new V07HarnessError("open 启动 Flutter App 失败", {
        failureClass: "environment_or_startup_failure",
        details: { stderr_tail: openResult.stderr.slice(-500) },
      });
    }
    const appWindow = await waitForAppWindow(windowObserver);
    report.app_window = { width: appWindow.width, height: appWindow.height };
    // 显示器睡眠时窗口列表仍可枚举，但 screencapture 无法成像；探针通过后再开严格采集。
    let captureWindowId = appWindow.id;
    let captureReady = false;
    for (let attempt = 1; attempt <= 5 && !captureReady; attempt += 1) {
      captureReady = await probeWindowCapture(captureWindowId, join(stateDir, `capture-probe-${attempt}.png`));
      if (!captureReady) {
        console.log(`[v07-vue-live] capture probe ${attempt} failed; waking display and re-observing`);
        await wakeDisplay();
        const reobserved = await waitForAppWindow(windowObserver).catch(() => null);
        if (reobserved) {
          captureWindowId = reobserved.id;
          report.app_window = { width: reobserved.width, height: reobserved.height };
        }
      }
    }
    if (!captureReady) {
      throw new V07HarnessError("窗口探针截图持续失败：显示器状态或 Screen Recording 权限不可用", {
        failureClass: "environment_or_startup_failure",
      });
    }
    console.log(`[v07-vue-live] app window ${report.app_window.width}x${report.app_window.height}; starting capture + real turn`);

    capturePromise = captureCandidateSeries({
      windowId: captureWindowId,
      outputDirectory: candidatesDir,
      frameCount: args.frames,
      scenarioId: "V07-VUE-LIVE-01",
    });
    // 立即挂接拒绝处理器：失败经由 try/catch 收口报告，不允许未处理拒绝直接杀死进程。
    capturePromise.catch(() => {});

    const sendCommand = await requestJson(relay.base, `/v1/sessions/${encodeURIComponent(session.id)}/commands`, {
      token: ownerToken,
      method: "POST",
      body: {
        kind: "session.send",
        idempotency_key: `v07-vue-send-${Date.now()}`,
        lease_epoch: leaseEpoch,
        target_terminal_id: terminalRowId,
        ciphertext: opaqueSessionEnvelope({
          kind: "session.send",
          sessionId: session.id,
          provider: "opencode",
          model,
          message: args.goal,
        }),
      },
    });
    report.command_kinds.push("session.send");
    report.request_attempts += 1;
    const sendResult = await waitCommand(relay.base, ownerToken, sendCommand.id, 30_000);
    if (sendResult.status !== "succeeded") {
      throw new V07HarnessError("session.send 未成功", { failureClass: "product_defect" });
    }

    const turn = await waitForTurn(relay.base, ownerToken, session.id, { timeoutMs: TURN_TIMEOUT_MS });
    report.event_types = turn.summary.eventTypes;
    report.assistant_text_length = turn.summary.assistantTextLength;
    report.assistant_text_sha256 = turn.summary.assistantTextHash;
    report.session_status = turn.summary.sessionStatus;

    const controls = await requestJson(relay.base, `/v1/sessions/${encodeURIComponent(session.id)}/controls`, { token: ownerToken, timeoutMs: 10_000 });
    report.usage = {
      input_tokens: Number(controls?.usage?.input_tokens) || 0,
      output_tokens: Number(controls?.usage?.output_tokens) || 0,
    };
    if (!report.usage.input_tokens || !report.usage.output_tokens) {
      throw new V07HarnessError("真实回合未产生正数 usage 投影", { failureClass: "model_contract_failure" });
    }

    const indexPath = join(workspaceDir, "index.html");
    if (!existsSync(indexPath)) {
      throw new V07HarnessError("真实回合未产出 index.html", { failureClass: "model_contract_failure" });
    }
    const indexContent = readFileSync(indexPath, "utf8");
    report.vue_app = {
      file: "index.html",
      bytes: statSync(indexPath).size,
      sha256_short: shortHash(indexContent),
      has_vue_cdn: /unpkg\.com\/vue|jsdelivr/.test(indexContent.toLowerCase()) || /vue(\.js|@3|3\.[0-9])/.test(indexContent.toLowerCase()),
      has_counter: /count|计数/.test(indexContent.toLowerCase()),
    };
    if (!report.vue_app.has_vue_cdn) {
      throw new V07HarnessError("index.html 未检测到 Vue CDN 引入", { failureClass: "model_contract_failure" });
    }

    console.log(`[v07-vue-live] SPA created; serving on http://127.0.0.1:${args.spaPort}`);
    const server = spawn(
      "python3",
      ["-m", "http.server", String(args.spaPort), "--bind", "127.0.0.1", "--directory", workspaceDir],
      { detached: true, stdio: "ignore" },
    );
    server.unref();
    await new Promise((resolveDelay) => setTimeout(resolveDelay, 1_500));
    const served = await fetch(`http://127.0.0.1:${args.spaPort}/index.html`);
    report.vue_app.served_http_status = served.status;
    const servedBody = await served.text();
    report.vue_app.served_sha256_short = shortHash(servedBody);
    if (served.status !== 200 || !servedBody) {
      throw new V07HarnessError(`静态服务返回 HTTP ${served.status}`, { failureClass: "environment_or_startup_failure" });
    }

    const liveFrames = await capturePromise;
    report.recording = {
      fps: WINDOW_EVIDENCE_FPS,
      capture_mode: "screencapture-window",
      crop: "none",
      candidate_frame_count: liveFrames.length,
      strict_5fps: true,
      screen_recording_required: true,
    };
    // 真实回合现场的采集可能因末段渲染出现个别慢帧；只接受实测连续节拍 ≥300 帧的窗口。
    let pacedFrames = pickStrictPacedWindow(liveFrames);
    let capturedDuringLiveTurn = pacedFrames != null;
    if (pacedFrames == null) {
      // 现场窗口节拍不达标时，等回合结束、窗口稳定后重采一段（与 gate 静态场景同口径）。
      console.log("[v07-vue-live] live capture pacing insufficient; recapturing stable session view");
      const stableFrames = await captureCandidateSeries({
        windowId: captureWindowId,
        outputDirectory: join(candidatesDir, "..", "candidates-stable"),
        frameCount: 300,
        scenarioId: "V07-VUE-LIVE-01-STABLE",
      });
      pacedFrames = pickStrictPacedWindow(stableFrames);
    }
    if (pacedFrames == null) {
      throw new V07HarnessError("现场与稳定窗口采集均无 ≥300 帧的严格 5fps 连续节拍窗口", {
        failureClass: "environment_or_startup_failure",
      });
    }
    report.recording.candidate_paced_frame_count = pacedFrames.length;
    report.recording.captured_during_live_turn = capturedDuringLiveTurn;
    const selected = selectStrictWindowEvidenceFrames({ frames: pacedFrames });
    const evidence = materializeStrictWindowEvidenceFrames({ frames: selected, outputDirectory: evidenceDir });
    const mp4Path = join(artifactsDir, "v07-vue-live.mp4");
    await encodeMp4({ frameDirectory: evidenceDir, outputPath: mp4Path, fps: WINDOW_EVIDENCE_FPS });
    report.recording.selected_frame_count = evidence.length;
    report.recording.mp4 = projectRelative(mp4Path);
    report.artifacts = [
      projectRelative(evidenceDir),
      projectRelative(mp4Path),
      projectRelative(join(artifactsDir, "manifest.json")),
    ];
    writeFileSync(join(artifactsDir, "manifest.json"), `${JSON.stringify({
      timestamp,
      suite: SUITE,
      scenario_id: "V07-VUE-LIVE-01",
      capture_mode: "screencapture-window",
      crop: "none",
      frame_rate_fps: WINDOW_EVIDENCE_FPS,
      candidate_frame_count: pacedFrames.length,
      live_turn_candidate_frame_count: liveFrames.length,
      captured_during_live_turn: capturedDuringLiveTurn,
      selected_frame_count: evidence.length,
      strict_frame_rate: true,
      permission_caveat: "需要终端 Screen Recording 权限；App 窗口为真实 Flutter macOS 会话视图。",
      session_view: "真实 Relay 会话：owner 由 device-bootstrap 注入，App 自动打开目标会话并实时渲染真实模型回合。",
    }, null, 2)}\n`);

    report.status = "passed";
    report.failure_class = null;
    report.real_model = true;
    report.real_upstream = true;
    report.remaining_risk = "单会话单任务真实收口：模型产出文件并通过静态服务验证；多轮/多模型覆盖由 V07-06 full gate 承担。";
    report.duration_ms = Date.now() - startedAt;
    const file = writeReport({ planId: PLAN_ID, name: "V07-VUE-LIVE", report });
    console.log(`v07 vue live: passed model=${model} served=http://127.0.0.1:${args.spaPort}`);
    console.log(`report: ${file}`);
    await cleanupStack();
  } catch (error) {
    const classified = classifyHarnessError(error);
    report.status = classified.status;
    report.failure_class = classified.failure_class;
    report.remaining_risk = classified.remaining_risk;
    report.real_model = report.request_attempts > 0;
    report.real_upstream = report.real_model;
    try {
      const file = writeReport({ planId: PLAN_ID, name: "V07-VUE-LIVE", report });
      console.error(`v07 vue live: ${report.status} failure_class=${report.failure_class}`);
      console.error(`report: ${file}`);
    } catch (writeError) {
      console.error(`v07 vue live: ${report.status}; report 写盘失败：${safeError(writeError)}`);
    }
    await cleanupStack();
    process.exitCode = 1;
  }
}

await main();
