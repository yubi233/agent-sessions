#!/usr/bin/env node
// v0.8.5 图片真实模型 gate（V085-15 / P4，用户已授权，留档=实施记录 24 §4.23）。
// 以真实 dsh-acp-demo 进程（cordis-v085-real-image.yml：attachment-local + image
// 模型目录）直连真实 image-capable 模型（grok-4.6，OpenAI 兼容中转
// api.aabsv.sbs）驱动图片 admission 正向旅程——不启动 mock LLM：
//   1. initialize：promptCapabilities.image 如实为 true（attachment 服务 + image 输入双条件）；
//   2. session/prompt 携带 ACP image block（32x16 纯红 PNG canonical base64，zlib 内联
//      生成）→ 桥 admitAcpPrompt 放行 → 真实模型回包回合 committed；
//   3. 整段回复正则 /红|red/i → 证明模型真实看到了图片内容。
// 口径：real_upstream=true；real_model=true；fixture_data=false；local_test=true；
// credential_source="env"。凭据只经环境变量 AGENT_SESSIONS_V085_REAL_API_KEY 注入，
// 不写进任何 yml/脚本/报告/transcript。报告不落 prompt/回复全文/凭据/完整 session id。

import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { crc32, deflateSync } from "node:zlib";

const ROOT = resolve(new URL("../..", import.meta.url).pathname);
const args = process.argv.slice(2);
const argOf = (flag) => { const i = args.indexOf(flag); return i >= 0 ? args[i + 1] : undefined; };
const dshRoot = resolve(argOf("--dsh-root") ?? "/Users/yubi/code/deepseek-harness");
const configPath = resolve(argOf("--config") ?? "e2e-verify/fixtures/dsh/cordis-v085-real-image.yml");
const outDir = resolve(argOf("--out") ?? "e2e-verify/reports/ADAPTER-DSH");
const keepWorkdir = argOf("--keep-workdir") === "1";

const REAL_BASE_URL = process.env.AGENT_SESSIONS_V085_REAL_BASE_URL ?? "https://api.aabsv.sbs/v1";
const REAL_API_KEY = process.env.AGENT_SESSIONS_V085_REAL_API_KEY ?? "";
const TURN_TIMEOUT_MS = 240_000;

const startedAt = new Date().toISOString();
const report = {
  suite: "adpt-dsh-v085-real-image",
  report_kind: "real_model_gate",
  status: "failed",
  failure_class: null,
  real_browser: false,
  real_model: true,
  real_upstream: true,
  fixture_data: false,
  local_test: true,
  headless: false,
  browser: "n/a",
  model: "grok-4.6 (real, api.aabsv.sbs)",
  provider: "deepseek-harness-acp",
  credential_source: "env",
  command: "node e2e-verify/real/v085-real-image-gate.mjs",
  authorization_ref: "docs/zh/实施记录/24-v0.8.5-工作区显示名与权限契约.md §4.23（用户显式授权）",
  request_ids: [],
  usage: { input_tokens: 0, output_tokens: 0 },
  timing: {},
  artifacts: [],
  checks: {},
  remaining_risk: "",
};

const stamp = startedAt.replace(/[:.]/g, "-");
mkdirSync(outDir, { recursive: true });
const reportPath = join(outDir, `v085-real-image-${stamp}.json`);

function shortHash(value) {
  return createHash("sha256").update(String(value)).digest("hex").slice(0, 12);
}
function redactValue(value) {
  if (typeof value === "string") return value.replace(/(\/Users\/|\/private\/|\/var\/folders\/)[^\s"']+/g, "[PATH REDACTED]");
  return value;
}
// transcript 级脱敏：prompt/回复全文、图片 base64、session id 一律不落盘；路径打码。
function sanitize(value, key) {
  if (typeof value === "string") {
    if (key === "data") return `[BASE64 REDACTED len=${value.length}]`;
    if (key === "text" || key === "prompt") return `[TEXT REDACTED len=${value.length}]`;
    if ((key === "sessionId" || key === "session_id") && value.length > 4) return `[SESSION ID REDACTED sha=${shortHash(value)}]`;
    return redactValue(value);
  }
  if (Array.isArray(value)) return value.map((item) => sanitize(item));
  if (value !== null && typeof value === "object") {
    const out = {};
    for (const [k, v] of Object.entries(value)) out[k] = sanitize(v, k);
    return out;
  }
  return value;
}
function check(name, ok, detail) {
  report.checks[name] = { ok, ...(detail === undefined ? {} : { detail: redactValue(detail) }) };
  console.log(`[v085-real-image] ${ok ? "PASS" : "FAIL"} ${name}`);
}
function fail(kind, message) {
  report.failure_class = kind;
  report.remaining_risk = String(message);
}
function writeReport() {
  writeFileSync(reportPath, JSON.stringify(report, null, 2));
  console.log(`[v085-real-image] report -> ${reportPath}`);
}
async function finalize(code) {
  report.status = Object.values(report.checks).length > 0
    && Object.values(report.checks).every((c) => c.ok === true)
    && code === 0 ? "passed" : report.status;
  writeReport();
  console.log(`[v085-real-image] ${report.status} (exit ${code})`);
  process.exit(code);
}

// ---- 前置校验：凭据缺失即 blocked（exit 2），不启动桥 ------------------------
if (!REAL_API_KEY) {
  report.status = "blocked";
  fail("credential_or_quota_blocker", "未设置 AGENT_SESSIONS_V085_REAL_API_KEY；真实模型 gate 未启动桥、未消耗中转额度。");
  await finalize(2);
}

// ---- 32x16 纯红 PNG（RGB 220,30,30）内联生成：IHDR 8bit RGB + IDAT deflate + IEND
function pngChunk(type, data) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length, 0);
  const typeBuf = Buffer.from(type, "ascii");
  const crcBuf = Buffer.alloc(4);
  crcBuf.writeUInt32BE(crc32(Buffer.concat([typeBuf, data])) >>> 0, 0);
  return Buffer.concat([len, typeBuf, data, crcBuf]);
}
function buildSolidRedPng({ width = 32, height = 16 } = {}) {
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8; // bit depth
  ihdr[9] = 2; // color type: truecolor RGB
  const row = Buffer.alloc(1 + width * 3);
  for (let x = 0; x < width; x++) {
    row[1 + x * 3] = 220;
    row[2 + x * 3] = 30;
    row[3 + x * 3] = 30;
  }
  const raw = Buffer.concat(Array.from({ length: height }, () => row));
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    pngChunk("IHDR", ihdr),
    pngChunk("IDAT", deflateSync(raw)),
    pngChunk("IEND", Buffer.alloc(0)),
  ]);
}
const pngB64 = buildSolidRedPng().toString("base64");

// ---- 工作目录与 transcript --------------------------------------------------
const workdir = mkdtempSync(join(tmpdir(), "agent-sessions-dsh-v085-real-image-"));
mkdirSync(join(workdir, "sessions"), { recursive: true });
mkdirSync(join(workdir, "attachments"), { recursive: true });
const transcriptPath = join(outDir, `v085-real-image-transcript-${stamp}.jsonl`);
const fs = await import("node:fs");
const transcript = fs.createWriteStream(transcriptPath);
report.artifacts.push(transcriptPath);

function record(dir, msg) {
  if (typeof msg === "object" && msg !== null) { transcript.write(JSON.stringify({ dir, at: Date.now(), msg: sanitize(msg) }) + "\n"); }
}

const finalizeWithCleanup = async (code) => {
  transcript.end();
  if (!keepWorkdir) { try { rmSync(workdir, { recursive: true, force: true }); } catch {} }
  await finalize(code);
};

// ---- 桥进程 -----------------------------------------------------------------
console.log(`[v085-real-image] starting bridge against ${REAL_BASE_URL}`);
const bridge = spawn(process.execPath, [
  "--import", "tsx", join(dshRoot, "packages/examples/acp-demo/src/bin.ts"),
  "-c", configPath,
], {
  cwd: dshRoot,
  env: {
    PATH: process.env.PATH,
    HOME: process.env.HOME,
    TMPDIR: process.env.TMPDIR,
    DSH_SNAPSHOT_SESSIONS_ROOT: join(workdir, "sessions"),
    AGENT_SESSIONS_DSH_ATTACHMENT_HOME: join(workdir, "attachments"),
    AGENT_SESSIONS_V085_REAL_BASE_URL: REAL_BASE_URL,
    AGENT_SESSIONS_V085_REAL_API_KEY: REAL_API_KEY,
  },
  stdio: ["pipe", "pipe", "pipe"],
});

bridge.stderr.on("data", (d) => { /* 桥诊断只进 transcript（脱敏） */ record("bridge-stderr", { line: String(d) }); });
bridge.stdout.setEncoding("utf8");
let lineBuf = "";
let seq = 0;
const pending = new Map();
const updates = [];
let exitCode = 0;

bridge.stdout.on("data", (chunk) => {
  lineBuf += chunk;
  let idx;
  while ((idx = lineBuf.indexOf("\n")) >= 0) {
    const line = lineBuf.slice(0, idx).trim();
    lineBuf = lineBuf.slice(idx + 1);
    if (!line) continue;
    let msg;
    try { msg = JSON.parse(line); } catch { continue; }
    record("inbound", msg);
    if (msg.method === "session/update" && msg.params?.update) updates.push(msg.params);
    const id = msg.id;
    if (id != null && pending.has(id)) {
      const p = pending.get(id);
      clearTimeout(p.timer);
      pending.delete(id);
      p.resolve(msg);
    }
  }
});

function request(method, params, label, waitMs = 60_000) {
  const id = ++seq;
  report.request_ids.push(id);
  const frame = { jsonrpc: "2.0", id, method, params };
  record("outbound", frame);
  return new Promise((resolvePromise, rejectPromise) => {
    const timer = setTimeout(() => { pending.delete(id); rejectPromise(new Error(`${label} 等待响应超时（${waitMs}ms）`)); }, waitMs);
    pending.set(id, { resolve: resolvePromise, timer });
    bridge.stdin.write(`${JSON.stringify(frame)}\n`);
  });
}

try {
  // 1) 协商：image 能力如实（attachment 服务 + image 模型目录双条件）。
  const initResp = await request("initialize", { protocolVersion: 1, clientCapabilities: { extensions: {} } }, "initialize");
  const capabilities = initResp.result?.agentCapabilities ?? {};
  const caps = capabilities.promptCapabilities ?? capabilities ?? {};
  check("initialize_ok", initResp.error === undefined, initResp.error ?? { ok: true });
  check("promptCapabilities_image_true", caps.image === true, { image: caps.image, full: capabilities });

  // 2) 图片回合：真实模型目录 + attachment 服务下 prompt 文本 + 32x16 纯红 PNG。
  const sessionCwd = mkdtempSync(join(workdir, "ws-"));
  const newResp = await request("session/new", { cwd: sessionCwd, mcpServers: [] }, "session/new");
  const sessionId = newResp.result?.sessionId;
  check("session_new", typeof sessionId === "string" && sessionId.length > 0);

  const baseline = updates.length;
  const promptSentAt = Date.now();
  const promptResp = await request("session/prompt", {
    sessionId,
    prompt: [
      { type: "text", text: "这张图片的主色是什么？只回答颜色中文名。" },
      { type: "image", mimeType: "image/png", data: pngB64 },
    ],
  }, "prompt#real-image", TURN_TIMEOUT_MS);
  check("image_prompt_accepted", promptResp.error === undefined, promptResp.error ?? promptResp.result);

  // 3) 回合 committed：等 agent_message_chunk 累积稳定 + assistant_message/turn_completed；
  //    prompt 响应本身在回合收口时返回（ACP stopReason）。
  const settleDeadline = Date.now() + 20_000;
  let lastLen = -1;
  let stableTicks = 0;
  const collectText = () => updates.slice(baseline)
    .filter((entry) => entry.update?.sessionUpdate === "agent_message_chunk")
    .map((entry) => entry.update?.content?.text ?? "")
    .join("");
  const finishedSeen = () => updates.slice(baseline).some((entry) =>
    entry.update?.sessionUpdate === "assistant_message" || entry.update?.sessionUpdate === "turn_completed");
  while (Date.now() < settleDeadline && stableTicks < 5) {
    const len = collectText().length;
    if (len > 0 && len === lastLen) stableTicks += 1;
    else { stableTicks = 0; lastLen = len; }
    if (finishedSeen() && len > 0) break;
    await new Promise((resolveWait) => setTimeout(resolveWait, 200));
  }
  const committedText = collectText();
  const turnElapsedSeconds = Number(((Date.now() - promptSentAt) / 1000).toFixed(2));
  report.timing.turn_elapsed_seconds = turnElapsedSeconds;
  check("image_turn_committed", promptResp.error === undefined && committedText.length > 0, {
    chars: committedText.length,
    stop_reason: promptResp.result?.stopReason ?? null,
  });

  // 4) 真实性断言：整段回复匹配 /红|red/i（reasoning 前缀一并纳入匹配范围）。
  const colorMatched = /红|red/i.test(committedText);
  check("real_model_saw_image_content", colorMatched, {
    matched: colorMatched,
    reply_chars: committedText.length,
    reply_sha256: committedText.length ? shortHash(committedText) : null,
  });

  // 5) usage/timing 投影：桥 usage_update（真实模型 token 用量 + usage timing _meta）。
  const usageEntry = updates.slice(baseline).find((entry) => entry.update?.sessionUpdate === "usage_update");
  if (usageEntry) {
    const u = usageEntry.update;
    report.usage = {
      input_tokens: Number(u.usage?.inputTokens) || 0,
      output_tokens: Number(u.usage?.outputTokens) || 0,
    };
    report.timing.context_used = u.used ?? null;
    report.timing.context_window = u.size ?? null;
    const timingMeta = usageEntry._meta?.["com.deepseek.dsh/usage-timing"];
    if (timingMeta !== undefined) report.timing.bridge_usage_timing = timingMeta;
  }
} catch (error) {
  fail("test_harness_defect", String(error));
  exitCode = 1;
} finally {
  try { bridge.kill("SIGTERM"); } catch {}
}

report.remaining_risk = report.remaining_risk
  || "单回合真实模型 smoke：图片真实发送 + usage/turn timing 真实值已验；grok-4.6 输出带 reasoning（中转 usage 计 reasoning_tokens，桥 usage_update 只投影 input/outputTokens）；依赖中转 api.aabsv.sbs 额度与可用性；非流式缺省路径与多轮对话未在本 gate 覆盖。";
const allOk = Object.values(report.checks).length > 0 && Object.values(report.checks).every((c) => c.ok === true);
console.log(`[v085-real-image] checks ${Object.values(report.checks).filter((c) => c.ok).length}/${Object.values(report.checks).length}`);
await finalizeWithCleanup(exitCode === 0 && allOk ? 0 : 1);
