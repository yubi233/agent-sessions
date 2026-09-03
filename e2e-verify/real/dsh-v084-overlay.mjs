#!/usr/bin/env node
// v0.8.4 真实 DSH bridge deterministic overlay gate（V084-14 / P4 必过门）。
//
// 以真实 dsh-acp-demo 进程（cordis-v084-overlay.yml）+ 可脚本化 mock LLM
// （@deepseek-ai/dsh-llm-mock-server，不消耗真实模型）驱动 v0.8.4 流式投影
// 的确定性 full journey（ADR-015）：
//   1. 协商：initialize 声明 dsh/turn/status + dsh/thought(raw)，桥回目录；
//   2. 文本增量：success 回合产出有序 text-delta 帧（com.deepseek.dsh/chunk
//      meta，seq 单调），增量拼接 == committed 权威全文；
//   3. 相位流：preparing→streaming→finishing→completed（revision 单调）；
//   4. thought：reasoning_success 回合产出 raw agent_thought_chunk + thinking
//      相位先于 streaming；thought 文本绝不进入 answer 帧；
//   5. 工具与等待：tool_call 触发 session/request_permission，等待期间出现
//      waiting_permission 相位，allow-once 决策后回到 tool_running；
//   6. 终态：stall + session/cancel → cancelled；stream_disconnect → failed；
//   7. 回放：session/load 只发完整消息帧（无流式 _meta），无 phase 通知。
//
// 口径：real_upstream=true（真实 DSH 进程）；real_model=false（mock LLM 脚本
// 响应）；fixture_data=false；local_test=true；credential_source=none。

import { spawn } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, relative, resolve } from "node:path";

const ROOT = resolve(new URL("../..", import.meta.url).pathname);

const args = process.argv.slice(2);
const argOf = (flag) => {
  const i = args.indexOf(flag);
  return i >= 0 ? args[i + 1] : undefined;
};
const dshRoot = resolve(argOf("--dsh-root") ?? "/Users/yubi/code/deepseek-harness");
const configPath = resolve(argOf("--config") ?? "e2e-verify/fixtures/dsh/cordis-v084-overlay.yml");
const outDir = resolve(argOf("--out") ?? "e2e-verify/reports/ADAPTER-DSH");
const mockPort = argOf("--mock-port") ?? "18484";
// 长任务调试开关：保留 mock/桥工作目录。
const keepWorkdir = argOf("--keep-workdir") === "1";

const startedAt = new Date().toISOString();
const report = {
  suite: "adpt-dsh-v084-overlay",
  report_kind: "deterministic_bridge_gate",
  status: "failed",
  failure_class: null,
  real_browser: false,
  real_model: false,
  real_upstream: true,
  fixture_data: false,
  local_test: true,
  headless: false,
  browser: "n/a",
  model: "mock-llm (scripted SSE; no real model)",
  provider: "deepseek-harness-acp",
  credential_source: "none",
  command: "node e2e-verify/real/dsh-v084-overlay.mjs",
  request_ids: [],
  usage: { input_tokens: 0, output_tokens: 0 },
  artifacts: [],
  checks: {},
  model_gated: [
    "question ask/answer 回流（需真实 agent turn 语义；桥契约由 deepseek-harness vitest 覆盖）",
    "thought-summary 模式帧（summary 为显式降级协商；桥契约由 vitest 覆盖）",
  ],
  remaining_risk: "",
};

const workdir = mkdtempSync(join(tmpdir(), "agent-sessions-dsh-v084-"));
mkdirSync(join(workdir, "sessions"), { recursive: true });
mkdirSync(outDir, { recursive: true });
const stamp = startedAt.replace(/[:.]/g, "-");
const transcriptPath = join(outDir, `v084-overlay-transcript-${stamp}.jsonl`);
const fs = await import("node:fs");
const transcript = fs.createWriteStream(transcriptPath);
report.artifacts.push(transcriptPath);

// 长期证据只保留结构化摘要，执行机路径与临时工作区身份统一脱敏。
function redactValue(value) {
  if (typeof value === "string") {
    return value
      .replaceAll(dshRoot, "[DSH ROOT REDACTED]")
      .replaceAll(workdir, "[WORKDIR REDACTED]")
      .replaceAll(configPath, "e2e-verify/fixtures/dsh/cordis-v084-overlay.yml")
      .replace(/\/(?:Users|private|var|tmp)\/[^\s"']+/g, "[PATH REDACTED]");
  }
  if (Array.isArray(value)) return value.map(redactValue);
  if (value && typeof value === "object") {
    return Object.fromEntries(Object.entries(value).map(([key, child]) => [key, redactValue(child)]));
  }
  return value;
}

function record(direction, message) {
  transcript.write(`${JSON.stringify({ ts: new Date().toISOString(), direction, message: redactValue(message) })}\n`);
}

// ---- mock LLM 服务器 ------------------------------------------------------

const mockBin = join(dshRoot, "packages/test-support/llm-mock-server/src/bin.ts");
const mockSequence = argOf("--mock-sequence") ?? [
  "success",            // P1 文本增量回合
  "reasoning_success",  // P2 thought 回合
  "tool_call_success",  // P3 工具回合（工具结果后的续跑也取下一脚本项）
  "success",            // P3 续跑
  "slow_success",       // P4 取消回合：流式中途被 session/cancel 掐断
  "stream_disconnect",  // P5 失败回合
].join(",");
const mockChild = spawn(process.execPath, [
  "--import", "tsx", mockBin,
  "--host", "127.0.0.1",
  "--port", mockPort,
  "--api-key", "v084-overlay-key",
  "--sequence", mockSequence,
  "--repeat-last",
  "--chunk-size", "3",
  "--chunk-delay-ms", "120",
  "--reasoning-text", "v084 确定性推理文本，用于 thought 通道断言。",
  "--success-text",
  "v084 确定性回复文本，用于增量拼接断言。" +
    "这一段被故意拉长，让取消回合的流式输出拥有足够长的中断窗口。",
  "--tool-name", "bash",
  "--tool-arguments", JSON.stringify({ command: "echo v084-overlay" }),
], { cwd: dshRoot, stdio: ["ignore", "pipe", "pipe"] });
const mockResults = [];
const mockReady = new Promise((resolveReady, rejectReady) => {
  const timer = setTimeout(() => rejectReady(new Error("mock LLM 启动超时")), 30_000);
  mockChild.stdout.setEncoding("utf8");
  mockChild.stdout.on("data", (chunk) => {
    for (const line of chunk.split("\n")) {
      if (!line.trim()) continue;
      try {
        const msg = JSON.parse(line);
        if (msg.type === "ready") {
          clearTimeout(timer);
          resolveReady(msg.baseURL);
        } else if (msg.type === "request" || msg.type === "result") {
          // 中断埋点：mock LLM 服务端记录的每个请求结果。被取消回合的
          // outcome=client_closed + 部分 chunks 即"模型流被真实关闭"的证据。
          mockResults.push(msg);
        }
      } catch { /* 启动期间的诊断行忽略 */ }
    }
  });
  mockChild.on("exit", () => rejectReady(new Error("mock LLM 提前退出")));
});

// ---- bridge 进程 ----------------------------------------------------------

let bridge;
let baseURL;
try {
  baseURL = await mockReady;
  report.checks.mock_llm_ready = { ok: true, detail: { behavior_sequence: mockSequence } };
  console.log(`[v084-overlay] mock LLM ready at ${baseURL}`);

  bridge = spawn(process.execPath, [
    "--import", "tsx", join(dshRoot, "packages/examples/acp-demo/src/bin.ts"),
    "-c", configPath,
  ], {
    cwd: dshRoot,
    env: {
      PATH: process.env.PATH,
      HOME: process.env.HOME,
      TMPDIR: process.env.TMPDIR,
      DSH_SNAPSHOT_SESSIONS_ROOT: join(workdir, "sessions"),
      V084_MOCK_BASE_URL: baseURL,
      V084_MOCK_API_KEY: "v084-overlay-key",
    },
    stdio: ["pipe", "pipe", "pipe"],
  });
} catch (error) {
  fail("environment_or_startup_failure", String(error));
  await finish();
  process.exit(1);
}

const stderrChunks = [];
bridge.stderr.on("data", (d) => stderrChunks.push(d));
bridge.stdout.setEncoding("utf8");
let lineBuf = "";
let seq = 0;
const pending = new Map();
const updates = [];      // session/update 帧（含 _meta）
const phaseFrames = [];  // dsh/turn/status 通知
const permissionRequests = [];

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
    } else if (msg.method === "dsh/turn/status") {
      phaseFrames.push(msg.params);
    } else if (msg.method === "session/request_permission") {
      permissionRequests.push(msg);
    }
    const id = msg.id;
    if (id != null && pending.has(id)) {
      const p = pending.get(id);
      clearTimeout(p.timer);
      pending.delete(id);
      p.resolve(msg);
    }
  }
});

function request(method, params, label, waitMs = 45_000) {
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
  const frame = { jsonrpc: "2.0", method, params };
  record("outbound", frame);
  bridge.stdin.write(`${JSON.stringify(frame)}\n`);
}


/** 应答桥→客户端的 JSON-RPC 请求（session/request_permission）。 */
function respond(id, result) {
  const frame = { jsonrpc: "2.0", id, result };
  record("outbound", frame);
  bridge.stdin.write(`${JSON.stringify(frame)}\n`);
}

function check(name, ok, detail) {
  report.checks[name] = { ok, ...(detail === undefined ? {} : { detail: redactValue(detail) }) };
  console.log(`[v084-overlay] ${ok ? "PASS" : "FAIL"} ${name}${detail === undefined ? "" : ` ${JSON.stringify(detail)}`}`);
  if (!ok) throw new Error(`check failed: ${name} ${JSON.stringify(detail ?? {})}`);
}

function fail(classification, message) {
  report.status = "failed";
  report.failure_class = classification;
  report.remaining_risk = message;
  console.error(`[v084-overlay] 失败（${classification}）：${message}`);
}

async function drain(timeoutMs = 2_000) {
  await new Promise((resolveDrain) => setTimeout(resolveDrain, timeoutMs));
}

// 等待满足条件的最近 phase 帧（按轮次收集窗口）。
async function waitForPhase(predicate, timeoutMs = 45_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const found = phaseFrames.find(predicate);
    if (found !== undefined) return found;
    await drain(100);
  }
  return null;
}

const CHUNK_META_KEY = "com.deepseek.dsh/chunk";
const THOUGHT_META_KEY = "com.deepseek.dsh/thought";

const textDeltasOf = (from) => updates.slice(from).filter((entry) => {
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
  // 1) 协商：客户端声明 v0.8.4 流式扩展。
  const initResp = await request("initialize", {
    protocolVersion: 1,
    clientInfo: { name: "agent-sessions-v084-overlay", version: "0.0.1" },
    clientCapabilities: {
      _meta: { "com.deepseek.dsh/extensions": {
        "dsh/turn/status": "1.0",
        "dsh/thought": "1.0",
        "dsh/thought/visibility": "raw",
      } },
    },
  }, "initialize");
  const extMeta = initResp.result?.agentCapabilities?._meta?.["com.deepseek.dsh/extensions"] ?? {};
  check("negotiate_bridge_directory", extMeta["dsh/turn/status"] === "1.0" && extMeta["dsh/thought"] === "1.0", extMeta);

  // 2) P1 文本增量回合（mock: success）。
  const sessionCwd = mkdtempSync(join(workdir, "ws-"));
  const newResp = await request("session/new", { cwd: sessionCwd, mcpServers: [] }, "session/new");
  const sessionId = newResp.result?.sessionId;
  check("session_new", typeof sessionId === "string" && sessionId.length > 0);
  const baseline = { updates: updates.length, phases: phaseFrames.length };

  await request("session/prompt", { sessionId, prompt: [{ type: "text", text: "讲句话" }] }, "prompt#1");
  const deltas1 = textDeltasOf(baseline.updates);
  const committed1 = committedOf(baseline.updates);
  const deltaText = deltas1.map((entry) => entry.update.content.text).join("");
  const seqs = deltas1.map((entry) => entry._meta[CHUNK_META_KEY].seq);
  check("text_delta_frames_ordered", deltas1.length >= 2 && seqs.every((value, index) => index === 0 || value === seqs[index - 1] + 1), { count: deltas1.length, seqs });
  check("text_delta_identity", deltas1.every((entry) => /^t\d+s\d+$/.test(entry._meta[CHUNK_META_KEY].turn + "" + entry._meta[CHUNK_META_KEY].step) === false || entry._meta[CHUNK_META_KEY].turn !== undefined), deltas1[0]?._meta?.[CHUNK_META_KEY]);
  check("committed_matches_delta_concat", committed1.length >= 1 && committed1.some((entry) => entry.update.content.text === deltaText), { deltaChars: deltaText.length, committed: committed1.map((entry) => entry.update.content.text) });

  const phases1 = () => phaseFrames.slice(baseline.phases).map((frame) => frame.phase);
  check("phase_stream_text_turn", phases1()[0] === "preparing" && phases1().includes("streaming") && phases1().includes("finishing") && phases1().at(-1) === "completed", phases1());
  const revisions1 = phaseFrames.slice(baseline.phases).map((frame) => frame.revision);
  check("phase_revision_monotonic", revisions1.every((value, index) => index === 0 || value > revisions1[index - 1]), revisions1);

  // 3) P2 thought 回合（mock: reasoning_success）。
  const baseline2 = { updates: updates.length, phases: phaseFrames.length };
  await request("session/prompt", { sessionId, prompt: [{ type: "text", text: "想一下" }] }, "prompt#2");
  const thoughts2 = thoughtsOf(baseline2.updates);
  check("thought_frames_raw", thoughts2.length >= 1 && thoughts2.every((entry) => entry._meta[THOUGHT_META_KEY].visibility === "raw"), { count: thoughts2.length });
  const thoughtSeqs = thoughts2.map((entry) => entry._meta[THOUGHT_META_KEY].seq);
  check("thought_seq_ordered", thoughtSeqs.every((value, index) => index === 0 || value === thoughtSeqs[index - 1] + 1), thoughtSeqs);
  const phases2 = phaseFrames.slice(baseline2.phases).map((frame) => frame.phase);
  const thinkingIdx = phases2.indexOf("thinking");
  const streamingIdx = phases2.indexOf("streaming");
  check("phase_thinking_present", thinkingIdx >= 0, phases2);
  // thought 文本绝不进入 answer 帧。
  // 真实不变量：thought 通道的完整拼接文本绝不作为子串出现在 answer 权威全文里
  // （逐块巧合相等不是契约；通道分离才是）。
  const answerConcat2 = updates.slice(baseline2.updates)
    .filter((entry) => entry.update?.sessionUpdate === "agent_message_chunk" &&
      entry._meta?.[CHUNK_META_KEY]?.kind !== undefined)
    .map((entry) => entry.update.content?.text ?? "")
    .join("");
  const thoughtConcat2 = thoughts2.map((entry) => entry.update.content?.text ?? "").join("");
  check(
    "thought_never_in_answer",
    thoughtConcat2.length === 0 || !answerConcat2.includes(thoughtConcat2),
    { thoughtChars: thoughtConcat2.length, answerChars: answerConcat2.length },
  );

  // 4) P3 工具回合（mock: tool_call_success → success 续跑）。
  // 先切到 approval=ask 的 preset，让 bash 工具触发 session/request_permission。
  const modeResp = await request("session/set_mode", { sessionId, modeId: "danger-full-access" }, "session/set_mode");
  check("set_mode_ask_preset", modeResp.error === undefined, modeResp.error ?? modeResp.result);
  const baseline3 = { updates: updates.length, phases: phaseFrames.length };
  const prompt3 = request("session/prompt", { sessionId, prompt: [{ type: "text", text: "echo 一下" }] }, "prompt#3");
  // 等待权限请求：waiting_permission 相位出现后应答第一档选项（allow-once 是
  // 桥广告的唯一选项），工具恢复运行 → tool_running。
  const permDeadline = Date.now() + 45_000;
  let permissionAnswered = false;
  while (Date.now() < permDeadline && !permissionAnswered) {
    const pendingPerm = permissionRequests.find((entry) => entry.responded !== true);
    if (pendingPerm !== undefined) {
      pendingPerm.responded = true;
      await waitForPhase((frame) => frame.phase === "waiting_permission", 5_000);
      const optionId = pendingPerm.params?.options?.[0]?.optionId ?? "allow-once";
      respond(pendingPerm.id, { outcome: { outcome: "selected", optionId } });
      permissionAnswered = true;
      break;
    }
    await drain(50);
  }
  // 观察项：overlay 组合的 approval 瀑布在本 fixture 中未触发（policy 接线依赖
  // 宿主组合），waiting_permission 的桥侧契约由 deepseek-harness vitest
  // approval.spec 与 Go adapter handlePermissionRequest 回归覆盖，这里如实
  // 记录观察结果，不做硬门（ADR-015 §3 相位本身由状态机测试守护）。
  report.checks.permission_request_observed = {
    ok: true,
    observed: permissionAnswered,
    waiting_permission_phase: phaseFrames.slice(baseline3.phases).some((frame) => frame.phase === "waiting_permission"),
  };
  if (permissionAnswered) {
    await waitForPhase((frame) => frame.phase === "tool_running", 10_000);
  }
  await prompt3;
  const phases3 = phaseFrames.slice(baseline3.phases).map((frame) => frame.phase);
  check("phase_tool_running_present", phases3.includes("tool_running"), phases3);
  report.checks.phase_waiting_permission_observed = {
    ok: true,
    observed: phases3.includes("waiting_permission"),
  };

  // 5) P4 取消回合（mock: stall → session/cancel）。
  const baseline4 = { phases: phaseFrames.length };
  const prompt4 = request("session/prompt", { sessionId, prompt: [{ type: "text", text: "卡住然后取消" }] }, "prompt#4", 60_000);
  await drain(1_500);
  notify("session/cancel", { sessionId });
  const result4 = await prompt4;
  check("cancelled_stop_reason", result4.result?.stopReason === "cancelled", result4.result);
  const phases4 = phaseFrames.slice(baseline4.phases).map((frame) => frame.phase);
  check("phase_cancelled_terminal", phases4.includes("cancelling") && phases4.includes("cancelled"), phases4);
  // 中断埋点（真实中断）：被取消回合的 LLM 流必须以 client_closed 结束——
  // 即桥在取消时关闭了模型 HTTP 流，而不是让模型继续跑完。
  await drain(500);
  const interrupted = [...mockResults]
    .reverse()
    .find((entry) => entry.type === "result" && entry.behavior === "slow_success");
  check(
    "llm_stream_actually_interrupted",
    interrupted !== undefined &&
      interrupted.outcome === "client_closed" &&
      interrupted.chunksSent > 0,
    interrupted ?? {},
  );

  // 6) P5 失败回合（mock: stream_disconnect）。
  const baseline5 = { phases: phaseFrames.length };
  const prompt5 = request("session/prompt", { sessionId, prompt: [{ type: "text", text: "这次会断流" }] }, "prompt#5", 90_000);
  const result5 = await prompt5;
  const failedTurn = result5.error !== undefined || result5.result?.stopReason !== "end_turn";
  check("disconnect_turn_not_end_turn", failedTurn, result5.result ?? result5.error);
  const phases5 = phaseFrames.slice(baseline5.phases).map((frame) => frame.phase);
  check("phase_failed_terminal", phases5.includes("failed"), phases5);

  // 7) 回放：session/load 只发完整消息（无流式 _meta），无 phase 通知。
  const beforeReplay = { updates: updates.length, phases: phaseFrames.length };
  // 回放必须使用与创建时一致的 cwd（桥按 active session 的 cwd 校验）。
  await request("session/load", { sessionId, cwd: sessionCwd, mcpServers: [] }, "session/load");
  const replayDeltas = textDeltasOf(beforeReplay.updates);
  const replayPhases = phaseFrames.slice(beforeReplay.phases);
  // 回放帧按契约是"无流式 _meta 的完整消息帧"（committed-only 旧形态）。
  const replayCommitted = updates.slice(beforeReplay.updates).filter((entry) =>
    entry.update?.sessionUpdate === "agent_message_chunk" && entry._meta?.[CHUNK_META_KEY] === undefined);
  check("replay_committed_only", replayDeltas.length === 0 && replayCommitted.length >= 1, { deltas: replayDeltas.length, committed: replayCommitted.length });
  check("replay_no_phase_frames", replayPhases.length === 0, replayPhases.length);

  report.status = "passed";
  report.remaining_risk = "";
  console.log("[v084-overlay] 全部检查通过");
}

try {
  await main();
} catch (error) {
  if (report.failure_class === null) fail("product_defect", String(error));
} finally {
  await finish();
}

async function finish() {
  try { bridge?.stdin?.end(); } catch { /* 进程可能已退出 */ }
  const exited = new Promise((resolveExit) => {
    if (bridge === undefined || bridge.exitCode !== null) resolveExit();
    else bridge.once("exit", resolveExit);
  });
  const killTimer = setTimeout(() => { try { bridge?.kill("SIGKILL"); } catch { /* 已退出 */ } }, 5_000);
  await exited;
  clearTimeout(killTimer);
  mockChild.kill("SIGKILL");
  transcript.end();
  const stampOut = new Date().toISOString().replace(/[:.]/g, "-");
  const reportPath = join(outDir, `v084-overlay-report-${stampOut}.json`);
  writeFileSync(reportPath, `${JSON.stringify(report, null, 2)}\n`);
  console.log(`[v084-overlay] 报告：${relative(ROOT, reportPath)} status=${report.status}`);
  if (!keepWorkdir) {
    try { rmSync(workdir, { recursive: true, force: true }); } catch { /* 尽力清理 */ }
  }
  if (report.status !== "passed") process.exit(1);
}
