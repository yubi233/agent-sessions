#!/usr/bin/env node
// v0.8.4 真实模型 gate（V084-15，需用户显式授权：AGENT_SESSIONS_DSH_REAL=1）。
//
// 以真实 DSH 桥（源码 tsx 启动，含 v0.8.4 流式投影）+ 真实模型（DSH cordis.yml
// 生产 Zen 池）逐项验证 ADR-015 的端到端行为：
//   1. new → send：多 chunk 回复（text-delta 帧 `_meta` seq 有序）、增量拼接长度
//      与 committed 权威全文一致、相位流 preparing→streaming→finishing→completed、
//      usage_update 到达；
//   2. tool：bash echo 标记串 → tool_call 帧 + tool_running 相位 + 结果包含标记；
//   3. reasoning：记录 thought 帧观测（模型是否输出 reasoning delta 属模型事实，
//      不做硬门）；
//   4. load → replay 完整消息（无流式 _meta）→ 再 send 新 turn 增量恢复。
//
// 口径：real_model=true、real_upstream=true、fixture_data=false、local_test=false。
// 凭据只经 DSH 侧 .env 注入，本脚本不读取其值。transcript/报告对正文全部脱敏
// （text/rawInput/output 只记录长度），不写 prompt/回复正文/凭据/完整 session 元数据。
// 用法：AGENT_SESSIONS_DSH_REAL=1 node e2e-verify/real/dsh-v084-live.mjs

import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, relative, resolve } from "node:path";
import { classifyDshLiveFailure } from "./dsh-live-result.mjs";

const ROOT = resolve(new URL("../..", import.meta.url).pathname);
if (process.env.AGENT_SESSIONS_DSH_REAL !== "1") {
  console.error("dsh-v084-live blocked: 需要用户显式授权（AGENT_SESSIONS_DSH_REAL=1）");
  process.exit(2);
}

const args = process.argv.slice(2);
const argOf = (flag) => {
  const i = args.indexOf(flag);
  return i >= 0 ? args[i + 1] : undefined;
};
const dshRoot = process.env.AGENT_SESSIONS_DSH_ROOT ?? "/Users/yubi/code/deepseek-harness";
// 生产组合在本仓库根（dsh-happy-init 生成，gitignore）；与 dsh-live-prompt 口径一致。
const configPath = process.env.AGENT_SESSIONS_DSH_CONFIG ?? resolve("cordis.yml");
const model = process.env.AGENT_SESSIONS_DSH_MODEL ?? "nemotron-3-ultra-free";
const provider = process.env.AGENT_SESSIONS_DSH_PROVIDER ?? "opencode-zen";
const outDir = resolve("e2e-verify/reports/ADAPTER-DSH");
mkdirSync(outDir, { recursive: true });

const startedAt = new Date().toISOString();
const stamp = startedAt.replace(/[:.]/g, "-");
const report = {
  suite: "adpt-dsh-v084-live",
  report_kind: "real_model_gate_v084",
  status: "failed",
  failure_class: null,
  real_browser: false,
  real_model: true,
  real_upstream: true,
  fixture_data: false,
  local_test: false,
  headless: false,
  browser: "n/a",
  model,
  provider,
  credential_source: "env:OPENCODE_GO_API_KEY|dsh-env",
  config_source: "dsh:cordis.yml",
  command: "AGENT_SESSIONS_DSH_REAL=1 node e2e-verify/real/dsh-v084-live.mjs",
  request_ids: [],
  usage: { input_tokens: 0, output_tokens: 0 },
  artifacts: [],
  checks: {},
  observations: {},
  remaining_risk: "",
};
const transcriptPath = join(outDir, `v084-live-transcript-${stamp}.jsonl`);
const fs = await import("node:fs");
const transcript = fs.createWriteStream(transcriptPath);
report.artifacts.push(transcriptPath);

let workdir;
try {
  workdir = mkdtempSync(join(tmpdir(), "agent-sessions-dsh-v084-live-"));
} catch (error) {
  report.failure_class = "environment_or_startup_failure";
  report.remaining_risk = String(error);
  await finish();
  process.exit(1);
}

// transcript 只保留结构与元数据：正文（text/rawInput/output/safeSummary）以
// 长度+哈希前缀代替，session/turn 标识保留（用户自身授权范围），路径脱敏。
function sanitize(value) {
  if (typeof value === "string") {
    return value
      .replaceAll(workdir, "[WORKDIR REDACTED]")
      .replaceAll(dshRoot, "[DSH ROOT REDACTED]")
      .replace(/\/(?:Users|private|var|tmp)\/[^\s"']+/g, "[PATH REDACTED]");
  }
  if (Array.isArray(value)) return value.map(sanitize);
  if (value && typeof value === "object") {
    const out = {};
    for (const [key, child] of Object.entries(value)) {
      if (["content", "rawInput", "raw_input", "output", "output_text", "safeSummary"].includes(key)) {
        const text = typeof child === "string" ? child : JSON.stringify(child);
        out[key] = text === undefined
          ? "<absent>"
          : `<redacted len=${text.length} sha=${createHash("sha256").update(text).digest("hex").slice(0, 8)}>`;
        continue;
      }
      if (key === "text" && typeof child === "string") {
        out[key] = `<redacted len=${child.length} sha=${createHash("sha256").update(child).digest("hex").slice(0, 8)}>`;
        continue;
      }
      out[key] = sanitize(child);
    }
    return out;
  }
  return value;
}

function record(direction, message) {
  transcript.write(`${JSON.stringify({ ts: new Date().toISOString(), direction, message: sanitize(message) })}\n`);
}

const bridge = spawn(process.execPath, [
  "--import", "tsx", join(dshRoot, "packages/examples/acp-demo/src/bin.ts"),
  "-c", configPath,
], {
  cwd: dshRoot, // 桥的 .env 由 dsh-app-boot 按此目录加载；凭据不经过本脚本
  env: {
    PATH: process.env.PATH,
    HOME: process.env.HOME,
    TMPDIR: process.env.TMPDIR,
  },
  stdio: ["pipe", "pipe", "pipe"],
});
const stderrChunks = [];
bridge.stderr.on("data", (d) => stderrChunks.push(d));

let seq = 0;
const pending = new Map();
const updates = [];
const phaseFrames = [];
const permissionRequests = [];
const usageEvents = [];
const requestIds = [];
const turnIds = new Set();

bridge.stdout.setEncoding("utf8");
let lineBuf = "";
bridge.stdout.on("data", (chunk) => {
  lineBuf += chunk;
  let idx;
  while ((idx = lineBuf.indexOf("\n")) >= 0) {
    const line = lineBuf.slice(0, idx).trim();
    lineBuf = lineBuf.slice(idx + 1);
    if (!line) continue;
    let msg;
    try { msg = JSON.parse(line); } catch { record("stderr-ish", { raw: line }); continue; }
    record("inbound", msg);
    if (msg.method === "session/update" && msg.params?.update) {
      updates.push(msg.params);
      const update = msg.params.update;
      if (update.sessionUpdate === "usage_update" && update.usage) {
        usageEvents.push(update.usage);
      }
    } else if (msg.method === "dsh/turn/status") {
      phaseFrames.push(msg.params);
      if (msg.params.turnId !== undefined) turnIds.add(String(msg.params.turnId));
    } else if (msg.method === "session/request_permission") {
      permissionRequests.push(msg);
    }
    const requestId = msg.result?.requestId ?? msg.params?.requestId;
    if (typeof requestId === "string" && requestId.length > 0) requestIds.push(requestId);
    const id = msg.id;
    if (id != null && pending.has(id)) {
      const p = pending.get(id);
      clearTimeout(p.timer);
      pending.delete(id);
      p.resolve(msg);
    }
  }
});

function request(method, params, label, waitMs = 180_000) {
  const id = ++seq;
  const frame = { jsonrpc: "2.0", id, method, params };
  record("outbound", frame);
  return new Promise((resolvePromise, rejectPromise) => {
    const timer = setTimeout(() => {
      pending.delete(id);
      rejectPromise(new Error(`${label} 等待响应超时（${waitMs}ms）`));
    }, waitMs);
    pending.set(id, { resolve: resolvePromise, timer });
    bridge.stdin.write(`${JSON.stringify(frame)}\n`);
  });
}

function notify(method, params) {
  record("outbound", { jsonrpc: "2.0", method, params });
  bridge.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", method, params })}\n`);
}

function respond(id, result) {
  record("outbound", { jsonrpc: "2.0", id, result });
  bridge.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id, result })}\n`);
}

function check(name, ok, detail) {
  report.checks[name] = { ok, ...(detail === undefined ? {} : { detail: sanitize(detail) }) };
  console.log(`[v084-live] ${ok ? "PASS" : "FAIL"} ${name}${detail === undefined ? "" : ` ${JSON.stringify(detail)}`}`);
  if (!ok) throw new Error(`check failed: ${name}`);
}

async function drain(ms) {
  await new Promise((resolveDrain) => setTimeout(resolveDrain, ms));
}

/** 应答权限请求（allow-once，桥广告的唯一 allow 选项）。 */
async function answerPermissions(deadlineMs) {
  const deadline = Date.now() + deadlineMs;
  while (Date.now() < deadline) {
    const pendingPerm = permissionRequests.find((entry) => entry.responded !== true);
    if (pendingPerm !== undefined) {
      pendingPerm.responded = true;
      const optionId = pendingPerm.params?.options?.find((option) => option.kind === "allow_once")?.optionId
        ?? pendingPerm.params?.options?.[0]?.optionId;
      respond(pendingPerm.id, { outcome: { outcome: "selected", optionId } });
      return true;
    }
    await drain(100);
  }
  return false;
}

const CHUNK_META_KEY = "com.deepseek.dsh/chunk";
const THOUGHT_META_KEY = "com.deepseek.dsh/thought";
const deltasOf = (from) => updates.slice(from).filter((entry) => {
  const meta = entry._meta?.[CHUNK_META_KEY];
  return entry.update?.sessionUpdate === "agent_message_chunk" && meta?.kind === "text-delta";
});
const committedOf = (from) => updates.slice(from).filter((entry) => {
  const meta = entry._meta?.[CHUNK_META_KEY];
  return entry.update?.sessionUpdate === "agent_message_chunk" && meta?.kind === "committed";
});
const thoughtsOf = (from) => updates.slice(from).filter((entry) => {
  const meta = entry._meta?.[THOUGHT_META_KEY];
  return entry.update?.sessionUpdate === "agent_thought_chunk" && meta?.kind !== undefined;
});

async function main() {
  // 0) 协商。
  const initResp = await request("initialize", {
    protocolVersion: 1,
    clientInfo: { name: "agent-sessions-v084-live", version: "0.0.1" },
    clientCapabilities: {
      _meta: { "com.deepseek.dsh/extensions": {
        "dsh/turn/status": "1.0",
        "dsh/thought": "1.0",
        "dsh/thought/visibility": "raw",
      } },
    },
  }, "initialize", 60_000);
  const extMeta = initResp.result?.agentCapabilities?._meta?.["com.deepseek.dsh/extensions"] ?? {};
  check("negotiate", extMeta["dsh/turn/status"] === "1.0" && extMeta["dsh/thought"] === "1.0", Object.keys(extMeta));

  const sessionCwd = mkdtempSync(join(workdir, "ws-"));
  const newResp = await request("session/new", { cwd: sessionCwd, mcpServers: [] }, "session/new", 60_000);
  const sessionId = newResp.result?.sessionId;
  check("session_new", typeof sessionId === "string" && sessionId.length > 0);

  // 1) new → send：真实多 chunk 回复。
  let base = { updates: updates.length, phases: phaseFrames.length };
  await request("session/prompt", { sessionId, prompt: [{ type: "text", text: "请用两三句话介绍你擅长处理的任务类型。" }] }, "prompt#1");
  const deltas1 = deltasOf(base.updates);
  const committed1 = committedOf(base.updates);
  const seqs1 = deltas1.map((entry) => entry._meta[CHUNK_META_KEY].seq);
  check("multi_chunk_deltas", deltas1.length >= 2 && seqs1.every((value, index) => index === 0 || value === seqs1[index - 1] + 1), { frames: deltas1.length });
  const deltaText1 = deltas1.map((entry) => entry.update.content.text).join("");
  const committedMatch = committed1.some((entry) => entry.update.content.text === deltaText1);
  check("committed_matches_deltas", committedMatch, {
    deltaChars: deltaText1.length,
    deltaSha: createHash("sha256").update(deltaText1).digest("hex").slice(0, 8),
    committedFrames: committed1.length,
  });
  const phases1 = phaseFrames.slice(base.phases).map((frame) => frame.phase);
  check("phase_stream_complete", phases1.includes("preparing") && phases1.includes("streaming") && phases1.at(-1) === "completed", phases1);
  const revisions = phaseFrames.slice(base.phases).map((frame) => frame.revision);
  check("phase_revision_monotonic", revisions.every((value, index) => index === 0 || value > revisions[index - 1]), revisions);

  // 2) tool：bash echo 标记（模型自主决定是否调用；失败如实降级为观察项）。
  base = { updates: updates.length, phases: phaseFrames.length };
  const answerPromise = answerPermissions(90_000);
  await request("session/prompt", { sessionId, prompt: [{ type: "text", text: "请运行 bash 命令：echo v084-live-check，然后用一句话告诉我输出。" }] }, "prompt#2");
  await answerPromise;
  const toolFrames = updates.slice(base.updates).filter((entry) => entry.update?.sessionUpdate === "tool_call");
  const phases2 = phaseFrames.slice(base.phases).map((frame) => frame.phase);
  report.observations.tool_call_frames = toolFrames.length;
  report.observations.tool_running_phase = phases2.includes("tool_running");
  report.observations.permission_asked = permissionRequests.length > 0;
  const toolResult = updates.slice(base.updates).filter((entry) => entry.update?.sessionUpdate === "tool_call_update");
  const toolOutputText = JSON.stringify(sanitize(toolResult));
  report.observations.tool_result_contains_marker = toolOutputText.includes("v084-live-check");
  check("tool_turn_completed", phases2.at(-1) === "completed", phases2);

  // 3) reasoning：观测模型是否输出 reasoning delta（模型事实，不做硬门）。
  base = { updates: updates.length, phases: phaseFrames.length };
  await request("session/prompt", { sessionId, prompt: [{ type: "text", text: "请先想一想再回答：3、7、12 的下一项是什么？简要说明。" }] }, "prompt#3");
  const thoughts3 = thoughtsOf(base.updates);
  report.observations.thought_frames_reasoning_prompt = thoughts3.length;
  report.observations.thinking_phase_observed = phaseFrames.slice(base.phases).some((frame) => frame.phase === "thinking");

  // 4) load → replay 完整消息 → 再 send 新 turn 增量。
  const beforeReplay = { updates: updates.length, phases: phaseFrames.length };
  await request("session/load", { sessionId, cwd: sessionCwd, mcpServers: [] }, "session/load", 120_000);
  const replayDeltas = deltasOf(beforeReplay.updates);
  const replayCommitted = updates.slice(beforeReplay.updates).filter((entry) =>
    entry.update?.sessionUpdate === "agent_message_chunk" && entry._meta?.[CHUNK_META_KEY] === undefined);
  check("replay_committed_only", replayDeltas.length === 0 && replayCommitted.length >= 1, { deltas: replayDeltas.length, committed: replayCommitted.length });
  check("replay_no_phase_frames", phaseFrames.slice(beforeReplay.phases).length === 0);

  base = { updates: updates.length, phases: phaseFrames.length };
  await request("session/prompt", { sessionId, prompt: [{ type: "text", text: "恢复后的新回合：请只回复“已恢复”三个字。" }] }, "prompt#resume-send");
  const deltasResume = deltasOf(base.updates);
  const phasesResume = phaseFrames.slice(base.phases).map((frame) => frame.phase);
  check("resume_send_new_turn_deltas", deltasResume.length >= 1, { frames: deltasResume.length });
  check("resume_turn_completed", phasesResume.at(-1) === "completed", phasesResume);
  const resumeTurnIds = [...turnIds];
  check("turn_ids_distinct", resumeTurnIds.length >= 3, { count: resumeTurnIds.length });

  for (const usage of usageEvents) {
    report.usage.input_tokens += usage.inputTokens ?? 0;
    report.usage.output_tokens += usage.outputTokens ?? 0;
  }
  report.request_ids = [...new Set(requestIds)].slice(0, 20);
  report.observations.usage_updates = usageEvents.length;
  report.observations.turn_count = resumeTurnIds.length;
  report.status = "passed";
  report.remaining_risk = "";
  console.log(`[v084-live] 全部检查通过 usage=in:${report.usage.input_tokens}/out:${report.usage.output_tokens}`);
}

try {
  await main();
} catch (error) {
  const message = String(error);
  report.failure_class = classifyDshLiveFailure(message, stderrChunks.join("").slice(-2000));
  report.remaining_risk = message.slice(0, 500);
  console.error(`[v084-live] 失败（${report.failure_class}）：${message}`);
} finally {
  await finish();
}

async function finish() {
  try { bridge.stdin.end(); } catch { /* 可能已退出 */ }
  await new Promise((resolveExit) => {
    const timer = setTimeout(() => { try { bridge.kill("SIGKILL"); } catch { /* 已退出 */ } }, 5_000);
    if (bridge.exitCode !== null) { clearTimeout(timer); resolveExit(); return; }
    bridge.once("exit", () => { clearTimeout(timer); resolveExit(); });
  });
  transcript.end();
  const reportPath = join(outDir, `v084-live-report-${stamp}.json`);
  writeFileSync(reportPath, `${JSON.stringify(report, null, 2)}\n`);
  console.log(`[v084-live] 报告：${relative(ROOT, reportPath)} status=${report.status}`);
  try { rmSync(workdir, { recursive: true, force: true }); } catch { /* 尽力清理 */ }
  if (report.status !== "passed") process.exit(1);
}
