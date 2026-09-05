#!/usr/bin/env node
// v0.8.7 V087-12：真实 LLM 流式双证据 gate（需用户显式授权：AGENT_SESSIONS_DSH_REAL=1）。
//
// 完整真实栈：本地 Relay + Daemon + 真实 DSH 桥（deepseek-harness，免费池模型）
// + macOS App（localdev 模式经 RELAY_BASE_URL dart-define 接入，打开目标会话页）。
// App 由 LOCAL_DEV_SEND_MESSAGE 注入演示问句后**自己发送**——在途轮询（250ms
// 收紧档）与打字机释放动画只有 App 自己的 sendMessage 才会驱动，API 侧发送
// 不产生可见流式（G6 watch 模式为本轮明确不做项）。
//
// 双证据（与 V087-08/09 同口径）：
//   门禁 1/2 机读判定：App 侧采样（渲染前缀单调性）+ P1 埋点导出
//     （streaming-gate.json，沙箱容器 tmp / system tmp 候选解析），
//     经 run-macos.mjs 的 validateV087StreamingGate 判定；
//   服务端佐证：Relay snapshot 的 message.delta 时间线（条数/首末时刻/累计字符）
//     与 App 采样同回合互证。
// 人审帧：App render-tree PNG 序列（LOCAL_VISUAL_FRAME_*，绕开屏幕录制权限）。
//
// 口径：real_model=true、real_upstream=true、fixture_data=false、local_test=true、
// headless=false。凭据只经 DSH 侧配置/环境加载，本脚本不读取其值；transcript/
// 报告对正文全部脱敏（只记长度与 sha256），不写 prompt/回复正文/凭据。
// 用法：AGENT_SESSIONS_DSH_REAL=1 node e2e-verify/real/v087-real-live.mjs

import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { homedir, tmpdir } from "node:os";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { setTimeout as delay } from "node:timers/promises";

import { validateV087StreamingGate } from "../mobile/run-macos.mjs";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..");
const stamp = new Date().toISOString().replace(/[:.]/g, "-");
const reportDir = join(ROOT, "e2e-verify", "reports", "ADAPTER-DSH");
mkdirSync(reportDir, { recursive: true });

if (process.env.AGENT_SESSIONS_DSH_REAL !== "1") {
  console.error(
    "v087-real-live blocked: 需要用户显式授权真实模型/上游（AGENT_SESSIONS_DSH_REAL=1）",
  );
  process.exit(2);
}

const relayBase = process.env.AGENT_SESSIONS_RELAY_BASE_URL ?? "http://127.0.0.1:8787";
const dshBin =
  process.env.AGENT_SESSIONS_DSH_BIN ??
  "/Users/yubi/code/deepseek-harness/packages/examples/acp-demo/lib/bin.js";
const dshConfig = process.env.AGENT_SESSIONS_DSH_CONFIG ?? join(ROOT, "cordis.yml");
const model = process.env.AGENT_SESSIONS_DSH_MODEL ?? "nemotron-3-ultra-free";
const dshRouteProvider = process.env.AGENT_SESSIONS_DSH_PROVIDER ?? "opencode-zen";
// 演示问句：要求多句长回复，保证足够的 delta 帧数（≥20）供门禁 2 判定。
const sendText =
  process.env.AGENT_SESSIONS_V087_SEND_TEXT ??
  "请用不少于 8 句话介绍当前工作区这个项目是做什么的。";
const telemetryDirName = `v087-real-${stamp}`;
const frameDirName = `v087-frames-${stamp}`;
const turnDeadlineMs = Number(process.env.AGENT_SESSIONS_V087_TURN_DEADLINE_MS ?? 300_000);

const report = {
  suite: "v087-real-live-typewriter-streaming",
  plan_id: "V087-12",
  report_kind: "real_model_streaming_dual_evidence",
  status: "failed",
  failure_class: null,
  executed_at: new Date().toISOString(),
  real_browser: true,
  real_model: true,
  real_upstream: true,
  fixture_data: false,
  local_test: true,
  headless: false,
  browser: "macOS Flutter visible window (localdev render-tree frames)",
  model,
  provider: "dsh",
  dsh_route_provider: dshRouteProvider,
  credential_source: "dsh-local-config-or-env-redacted",
  command: "AGENT_SESSIONS_DSH_REAL=1 node e2e-verify/real/v087-real-live.mjs",
  request_ids: [],
  usage: { input_tokens: null, output_tokens: null },
  artifacts: [],
  relay: {},
  app: {},
  streaming_gate: null,
  verification: [],
  remaining_risk: "",
};

function evidence(path) {
  const rel = relative(ROOT, path);
  return rel && !rel.startsWith("..") ? rel : "[PATH REDACTED]";
}
function sha256(text) {
  return createHash("sha256").update(String(text)).digest("hex");
}
function sanitizeError(value) {
  return String(value?.message ?? value)
    .replace(/(bearer\s+)[^\s"']+/gi, "$1[REDACTED]")
    .replace(/([?&](?:token|password|secret)=)[^&#\s"']+/gi, "$1[REDACTED]")
    .replace(/(access_token|refresh_token|api[_-]?key|authorization)(["'=: ]+)[^\s"'}]+/gi, "$1$2[REDACTED]")
    .replace(/\/(?:Users|private|var|tmp)\/[^\s"']+/g, "[PATH REDACTED]")
    .slice(0, 800);
}
function run(cmd, args, { timeout = 600_000 } = {}) {
  const result = spawnSync(cmd, args, {
    cwd: ROOT,
    encoding: "utf8",
    timeout,
    env: baseEnv,
  });
  if (result.status !== 0) {
    throw new Error(
      `${cmd} ${args.join(" ")} 退出码 ${result.status}：${sanitizeError(result.stderr ?? result.stdout)}`,
    );
  }
  return result;
}
function http(method, path, body, token) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 30_000);
  const promise = fetch(`${relayBase}${path}`, {
    method,
    headers: {
      "content-type": "application/json",
      ...(token ? { authorization: `Bearer ${token}` } : {}),
    },
    body: body == null ? undefined : JSON.stringify(body),
    signal: controller.signal,
  }).then(async (response) => {
    clearTimeout(timer);
    const text = await response.text();
    if (!response.ok) {
      throw new Error(`HTTP ${response.status} ${method} ${path}: ${text.slice(0, 300)}`);
    }
    return text ? JSON.parse(text) : {};
  }).catch((error) => {
    clearTimeout(timer);
    throw error;
  });
  return promise;
}
function unwrap(payload) {
  const inner = payload?.ciphertext ?? payload;
  return inner?.fixture_payload ?? inner ?? payload;
}

// 证据文件候选路径：flutter-run 调试 App 可能落在沙箱容器 tmp 或系统 tmp
// （与 dsh-cache-flutter-live 的帧目录候选解析同一模型）。
function telemetryCandidatePaths() {
  const container = join(
    homedir(),
    "Library",
    "Containers",
    "com.agentsessions.agentSessionsMobile",
    "Data",
    "tmp",
    telemetryDirName,
    "streaming-gate.json",
  );
  return [container, join(tmpdir(), telemetryDirName, "streaming-gate.json")];
}
function readTelemetryEvidence() {
  for (const candidate of telemetryCandidatePaths()) {
    if (existsSync(candidate)) {
      return { path: candidate, payload: JSON.parse(readFileSync(candidate, "utf8")) };
    }
  }
  return null;
}

const baseEnv = {
  ...process.env,
  AGENT_SESSIONS_RELAY_ADDR: relayBase.replace(/^https?:\/\//, ""),
  AGENT_SESSIONS_DSH_BIN: dshBin,
  AGENT_SESSIONS_DSH_CONFIG: dshConfig,
  AGENT_SESSIONS_DSH_REAL_MODEL: "1",
  AGENT_SESSIONS_DSH_PROVIDER: dshRouteProvider,
  LOCAL_VISUAL_FRAME_DIRECTORY: frameDirName,
  // 500 帧 × 400ms = 200s：覆盖 localdev 冷启动认证（~50s）+ 真实模型思考期
  // （首字延迟可到 70s+）+ assistant 正文打字机阶段（人审证据的拍摄目标）。
  LOCAL_VISUAL_FRAME_COUNT: "500",
  LOCAL_VISUAL_FRAME_INTERVAL_MS: "400",
  LOCAL_VISUAL_TELEMETRY_DIRECTORY: telemetryDirName,
  LOCAL_DEV_SEND_MESSAGE: sendText,
};

try {
  if (!existsSync(dshBin)) throw new Error(`DSH bin not found: ${dshBin}`);
  if (!existsSync(dshConfig)) throw new Error(`DSH config not found: ${dshConfig}`);
  rmSync(join(tmpdir(), telemetryDirName), { force: true, recursive: true });
  rmSync(join(homedir(), "Library", "Containers", "com.agentsessions.agentSessionsMobile", "Data", "tmp", telemetryDirName), {
    force: true,
    recursive: true,
  });

  // 1) 启动真实栈（Relay + Daemon + DSH 桥进程由 daemon 托管），不启动 App。
  console.log("[v087-real] 启动真实栈（restart --no-flutter）");
  run("./restart.sh", ["restart", "--no-opencode", "--no-web", "--no-admin", "--no-flutter"], { timeout: 300_000 });

  // 2) 经 Relay API 同步 DSH 工作区（v0.8.1 起 DSH 会话必须建在 origin=dsh 的
  //    工作区：home 终端在线 + start 能力；同步命令驱动 daemon 扫描授权根），
  //    然后在 dsh 工作区内创建会话（不 lease、不 start：App 发送时自动受理）。
  const tokenPath = join(ROOT, ".task", "restart", "local-owner-token");
  const token = readFileSync(tokenPath, "utf8").trim();
  console.log("[v087-real] 同步 DSH 工作区（workspace.sync_dsh）");
  const syncStarted = unwrap(
    await http("POST", "/v1/workspaces/sync-dsh", {}, token),
  );
  const syncCommandId = syncStarted.command_id ?? syncStarted.commandId ?? syncStarted.id;
  if (!syncCommandId) throw new Error(`sync-dsh 未返回 command id: ${JSON.stringify(syncStarted).slice(0, 200)}`);
  let syncState = null;
  const syncDeadline = Date.now() + 120_000;
  while (Date.now() < syncDeadline) {
    await delay(2000);
    syncState = unwrap(
      await http("GET", `/v1/workspaces/sync-dsh/${syncCommandId}`, null, token),
    );
    if (syncState.status === "succeeded" || syncState.status === "failed") break;
  }
  if (syncState?.status !== "succeeded") {
    throw new Error(`DSH 工作区同步未成功：${JSON.stringify(syncState).slice(0, 300)}`);
  }
  const workspaces = unwrap(await http("GET", "/v1/workspaces", null, token)).workspaces ?? [];
  const dshWorkspaces = workspaces.filter((item) => item.origin === "dsh");
  if (dshWorkspaces.length === 0) {
    throw new Error(`授权根内未发现 dsh 工作区（全部 ${workspaces.length} 个均非 dsh origin）`);
  }
  // 优先 agent-sessions 仓库自身（历史真实会话所在），否则取第一个 dsh 工作区。
  const workspace =
    dshWorkspaces.find((item) => item.display_name === "agent-sessions" || item.project_id === "agent-sessions") ??
    dshWorkspaces[0];
  const created = unwrap(
    await http("POST", "/v1/sessions", { workspace_id: workspace.id, provider: "dsh" }, token),
  );
  const sessionId = created.id;
  if (!sessionId) throw new Error("Relay session creation returned no id");
  report.relay.session_id = sessionId;
  report.relay.workspace_id = workspace.id;
  report.relay.workspace_display_name = workspace.display_name ?? null;
  console.log(`[v087-real] dsh 会话已创建 ${sessionId}（workspace=${workspace.display_name ?? workspace.id}）`);

  // 2b) lease + session.start（dsh-cache-flutter-live 同路径）：新会话若不先
  //     start，daemon 无本机实例，App 的发送会命中 local_state_missing（App 的
  //     可运行检查只对 stopped 会话自动启动）。App 发送时按跨设备接管语义
  //     重新取得 lease（epoch+1），不与此处冲突。
  const lease = unwrap(await http("POST", `/v1/sessions/${sessionId}/lease`, {}, token));
  const leaseEpoch = lease.lease_epoch ?? lease.epoch;
  if (!Number.isInteger(leaseEpoch) || leaseEpoch <= 0) {
    throw new Error(`Invalid lease_epoch: ${JSON.stringify(lease).slice(0, 200)}`);
  }
  await http("POST", `/v1/sessions/${sessionId}/commands`, {
    kind: "session.start",
    idempotency_key: `v087-real-start-${stamp}`,
    lease_epoch: leaseEpoch,
    ciphertext: {
      session_id: sessionId,
      ciphertext: { fixture_payload: { session_id: sessionId, provider: "dsh", model } },
    },
  }, token);
  // 等 daemon 实例就绪（会话离开 stopped 且 start 命令出终态）。
  const startDeadline = Date.now() + 120_000;
  let startReady = false;
  while (Date.now() < startDeadline) {
    await delay(2000);
    const snap = unwrap(await http("GET", `/v1/sessions/${sessionId}/snapshot?after_seq=0`, null, token));
    const status = snap.session?.status ?? "";
    if (status && status !== "stopped" && status !== "starting") {
      startReady = true;
      break;
    }
  }
  if (!startReady) throw new Error("session.start 在时限内未就绪（daemon 实例未拉起）");
  console.log("[v087-real] daemon 实例已就绪");

  // 3) 只启动 macOS App（--no-daemon：保留带存活 bridge 实例的 daemon——
  //    daemon 重启会丢失本机会话实例，App 的发送会命中 local_state_missing）。
  //    relay 保留在启动集合里（幂等跳过已运行实例），确保 owner bootstrap
  //    dart-define 重新下发——App 需要它完成自动认证后才能打开会话并发送。
  console.log("[v087-real] 启动 macOS App（localdev，目标会话 + 自动发送；daemon 不重启）");
  run("./restart.sh", [
    "start",
    "--no-daemon",
    "--no-opencode",
    "--no-web",
    "--no-admin",
    "--flutter-target-session", sessionId,
  ], { timeout: 600_000 });

  // 4) 轮询 Relay snapshot：等 App 的 user.message → 统计 message.delta 时间线 →
  //    等 completed_turn。delta 事件时间戳是服务端佐证面（与 App 采样同回合互证）。
  const startedAt = Date.now();
  let sawUserMessage = false;
  let completedAt = null;
  let deltaCount = 0;
  let firstDeltaAt = null;
  let lastDeltaAt = null;
  let cumulativeChars = 0;
  let finalChars = null;
  while (Date.now() - startedAt < turnDeadlineMs) {
    await delay(1000);
    let snap;
    try {
      snap = unwrap(await http("GET", `/v1/sessions/${sessionId}/snapshot?after_seq=0`, null, token));
    } catch {
      continue;
    }
    const events = Array.isArray(snap.events) ? snap.events : [];
    deltaCount = 0;
    firstDeltaAt = null;
    lastDeltaAt = null;
    cumulativeChars = 0;
    finalChars = null;
    let hasUser = false;
    let completed = false;
    for (const event of events) {
      const envelope = event.envelope ?? {};
      const payload = envelope.fixture_payload ?? {};
      if (payload.kind === "user_message") hasUser = true;
      if (event.event_type === "message.delta" || event.event_type === "message.thought_delta") {
        deltaCount += 1;
        const at = payload.created_at ?? event.created_at ?? null;
        if (event.event_type === "message.delta") {
          firstDeltaAt ??= at;
          lastDeltaAt = at;
          const text = typeof payload.text === "string" ? payload.text : "";
          cumulativeChars = Math.max(cumulativeChars, text.length);
        }
      }
      if (event.event_type === "message.completed" && payload.kind === "assistant_message") {
        finalChars = typeof payload.text === "string" ? payload.text.length : null;
      }
      if (event.event_type === "turn.completed" || payload.completed_turn === true) completed = true;
    }
    sawUserMessage = sawUserMessage || hasUser;
    if (hasUser && deltaCount > 0 && deltaCount !== report.relay.delta_events) {
      report.relay.delta_events = deltaCount;
    }
    if (sawUserMessage && !completedAt && firstDeltaAt) {
      console.log(`[v087-real] 流式中：delta=${deltaCount} 累计字符=${cumulativeChars}`);
    }
    if (sawUserMessage && completed) {
      completedAt = new Date().toISOString();
      report.relay.delta_events = deltaCount;
      report.relay.first_delta_at = firstDeltaAt;
      report.relay.last_delta_at = lastDeltaAt;
      report.relay.cumulative_chars = cumulativeChars;
      report.relay.final_chars = finalChars;
      console.log(`[v087-real] 回合终态：delta=${deltaCount} final=${finalChars}`);
      break;
    }
  }
  if (!sawUserMessage) {
    throw new Error("App 未在时限内发送消息（未观察到 user_message）");
  }
  if (completedAt == null) {
    throw new Error(`回合在 ${turnDeadlineMs}ms 内未到达终态（delta=${deltaCount}）`);
  }

  // 5) 等待释放动画追平与证据落盘，读取 streaming-gate.json 并按 V087-08/09
  //    同口径机读判定。
  await delay(8_000);
  const telemetryEvidence = readTelemetryEvidence();
  if (telemetryEvidence == null) {
    throw new Error("App 未产出 streaming-gate.json（候选路径均缺失）");
  }
  writeFileSync(
    join(reportDir, `v087-real-streaming-gate-${stamp}.json`),
    `${JSON.stringify(telemetryEvidence.payload, null, 2)}\n`,
  );
  report.artifacts.push(evidence(join(reportDir, `v087-real-streaming-gate-${stamp}.json`)));
  const gate = validateV087StreamingGate({ payload: telemetryEvidence.payload });
  report.streaming_gate = {
    ...gate,
    evidence_path: evidence(telemetryEvidence.path),
  };
  if (!gate.passed) {
    throw new Error(`流式门禁未通过：${gate.failures.join("；")}`);
  }

  // 6) 人审帧目录（render-tree PNG 序列）。
  const frameCandidates = [
    join(tmpdir(), frameDirName),
    join(homedir(), "Library", "Containers", "com.agentsessions.agentSessionsMobile", "Data", "tmp", frameDirName),
  ];
  const frameDir = frameCandidates.find((candidate) => existsSync(candidate)) ?? null;
  const frameCount = frameDir == null
    ? 0
    : readdirSync(frameDir).filter((name) => name.endsWith(".png")).length;
  report.app = {
    target_session_id: sessionId,
    render_tree_frames: frameCount,
    frame_directory: frameDir == null ? null : evidence(frameDir),
    send_text_sha256: sha256(sendText),
  };

  report.verification.push(
    "真实 DSH 桥 + 免费池模型回合：Relay snapshot 观察到 message.delta 逐步到达且 turn.completed 收敛。",
  );
  report.verification.push(
    "App 侧同回合采样 + P1 埋点经 validateV087StreamingGate 判定通过（与 V087-08/09 同口径）。",
  );
  report.status = "passed";
  report.remaining_risk =
    "真实免费池回合结果确定性问题（模型侧波动）属 provider 事实；人审帧为 render-tree 序列（绕开屏幕录制权限），非窗口截图。";
} catch (error) {
  report.remaining_risk = sanitizeError(error);
  report.failure_class = /credential|api key|quota|unauthorized/i.test(String(error?.message ?? error))
    ? "credential_or_quota_blocker"
    : /timeout|时限|未在/i.test(String(error?.message ?? error))
      ? "provider_timeout"
      : "verification_failure";
  if (report.failure_class === "credential_or_quota_blocker") report.status = "blocked";
  console.error("[v087-real] failed:", report.remaining_risk);
}

const reportPath = join(reportDir, `v087-real-live-${stamp}.json`);
writeFileSync(reportPath, `${JSON.stringify(report, null, 2)}\n`);
console.log(`[v087-real] status=${report.status} -> ${reportPath}`);
if (report.status !== "passed") process.exitCode = 1;
