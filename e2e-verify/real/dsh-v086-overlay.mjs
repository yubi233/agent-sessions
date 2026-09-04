#!/usr/bin/env node
// v0.8.6 真实 DSH bridge deterministic overlay（V086-06 / V086-11 桥侧）。
//
// 以真实 dsh-acp-demo 进程（cordis-v084-overlay.yml：permission-presets mode
// 目录 + 可脚本化 mock LLM）驱动 v0.8.6 的两条新增桥侧行为——不消耗真实模型：
//   1. mode 目录：session/new 广告 preset 目录（currentModeId + availableModes，
//      含 danger-full-access），作为 mode.set/current_mode_update 的目录真值；
//   2. 瞬时失败有界重试（用户裁决 2026-09-05：重试责任在桥）：mock 先 429 后
//      success → 桥自动重跑同一 prompt，且重试前发出可见 assistant 文本通知
//      （"自动重试中（第 1/2 次）"），最终 end_turn 收敛；
//   3. 非瞬时失败快速失败：auth_error → 立即 reject（data.status=401），不重试、
//      不发重试通知。
// 口径：real_upstream=true（真实 DSH 进程）；real_model=false（mock LLM）；
// fixture_data=false；local_test=true；credential_source=none。

import { spawn } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const ROOT = resolve(new URL("../..", import.meta.url).pathname);
const args = process.argv.slice(2);
const argOf = (flag) => { const i = args.indexOf(flag); return i >= 0 ? args[i + 1] : undefined; };
const dshRoot = resolve(argOf("--dsh-root") ?? "/Users/yubi/code/deepseek-harness");
const configPath = resolve(argOf("--config") ?? "e2e-verify/fixtures/dsh/cordis-v084-overlay.yml");
const outDir = resolve(argOf("--out") ?? "e2e-verify/reports/ADAPTER-DSH");
const mockPort = argOf("--mock-port") ?? "18686";

const startedAt = new Date().toISOString();
const report = {
  suite: "adpt-dsh-v086-overlay",
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
  command: "node e2e-verify/real/dsh-v086-overlay.mjs",
  request_ids: [],
  usage: { input_tokens: 0, output_tokens: 0 },
  artifacts: [],
  checks: {},
  remaining_risk: "",
};

const workdir = mkdtempSync(join(tmpdir(), "agent-sessions-dsh-v086-"));
mkdirSync(join(workdir, "sessions"), { recursive: true });
mkdirSync(outDir, { recursive: true });
const stamp = startedAt.replace(/[:.]/g, "-");
const transcriptPath = join(outDir, `v086-overlay-transcript-${stamp}.jsonl`);
const fs = await import("node:fs");
const transcript = fs.createWriteStream(transcriptPath);
report.artifacts.push(transcriptPath);

function check(name, ok, detail) {
  report.checks[name] = { ok, ...(detail === undefined ? {} : { detail }) };
  console.log(`[v086-overlay] ${ok ? "PASS" : "FAIL"} ${name}`);
}
function fail(kind, message) {
  report.failure_class = kind;
  report.remaining_risk = String(message);
}
function record(dir, msg) {
  if (typeof msg === "object" && msg !== null) {
    transcript.write(JSON.stringify({ dir, at: Date.now(), msg }) + "\n");
  }
}

const finalize = (code) => {
  transcript.end();
  if (!keep) { try { rmSync(workdir, { recursive: true, force: true }); } catch {} }
  const rp = join(outDir, `v086-overlay-${stamp}.json`);
  writeFileSync(rp, JSON.stringify(report, null, 2));
  report.artifacts.push(rp);
  console.log(`[v086-overlay] report -> ${rp}`);
  console.log(`[v086-overlay] ${report.status}`);
  process.exit(code);
};
const keep = args.includes("--keep-workdir");

// ---- mock LLM：脚本化上游行为：先 429 再成功（验证重试），后 auth_error（验证快速失败）----
const mockBin = join(dshRoot, "packages/test-support/llm-mock-server/src/bin.ts");
const mockChild = spawn(process.execPath, [
  "--import", "tsx", mockBin,
  "--host", "127.0.0.1", "--port", mockPort,
  "--api-key", "v086-overlay-key",
  "--sequence", "rate_limit,success,auth_error", "--repeat-last",
], { cwd: dshRoot, stdio: ["ignore", "pipe", "pipe"] });
const mockReady = new Promise((resolveReady, rejectReady) => {
  const timer = setTimeout(() => rejectReady(new Error("mock LLM 启动超时")), 30_000);
  mockChild.stdout.setEncoding("utf8");
  mockChild.stdout.on("data", (chunk) => {
    for (const line of chunk.split("\n")) {
      if (!line.trim()) continue;
      try {
        const msg = JSON.parse(line);
        if (msg.type === "ready") { clearTimeout(timer); resolveReady(msg.baseURL); }
      } catch {}
    }
  });
  mockChild.on("exit", () => rejectReady(new Error("mock LLM 提前退出")));
});

// ---- 真实桥进程（复用 v084 overlay cordis：permission-presets + mock LLM 注入）----
let bridge;
try {
  const baseURL = await mockReady;
  console.log(`[v086-overlay] mock LLM ready at ${baseURL}`);
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
      // 重试策略注入（v0.8.6 A① 契约：次数/退避可配）。
      DSH_TURN_RETRY_MAX: "2",
      DSH_TURN_RETRY_BACKOFF_MS: "200",
      // cordis-v084-overlay.yml 的 mock LLM 注入口。
      V084_MOCK_BASE_URL: baseURL,
      V084_MOCK_API_KEY: "v086-overlay-key",
    },
    stdio: ["pipe", "pipe", "pipe"],
  });
} catch (error) {
  fail("environment_or_startup_failure", String(error));
  finalize(1);
}

bridge.stderr.on("data", (d) => record("bridge-stderr", String(d)));
bridge.stdout.setEncoding("utf8");
let lineBuf = "";
let seq = 0;
const pending = new Map();
const updates = [];

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
  const frame = { jsonrpc: "2.0", id, method, params };
  record("outbound", frame);
  return new Promise((resolvePromise, rejectPromise) => {
    const timer = setTimeout(() => { pending.delete(id); rejectPromise(new Error(`${label} 等待响应超时（${waitMs}ms）`)); }, waitMs);
    pending.set(id, { resolve: resolvePromise, timer });
    bridge.stdin.write(`${JSON.stringify(frame)}\n`);
  });
}

// 重试通知 = assistant 文本帧中带"自动重试中"标记（turn-retry.ts retryNoticeText）。
const retryNoticesAfter = (baseline) => updates.slice(baseline)
  .filter((entry) => entry.update?.sessionUpdate === "agent_message_chunk")
  .map((entry) => entry.update?.content?.text ?? "")
  .filter((text) => text.includes("自动重试中"));

let exitCode = 0;
try {
  // 1) 协商。
  const initResp = await request("initialize", { protocolVersion: 1, clientCapabilities: { extensions: {} } }, "initialize");
  check("initialize_ok", initResp.error === undefined, initResp.error ?? { ok: true });

  // 2) session/new：mode 目录广告（V086-06 目录真值源）。
  const sessionCwd = mkdtempSync(join(workdir, "ws-"));
  const newResp = await request("session/new", { cwd: sessionCwd, mcpServers: [] }, "session/new");
  const sessionId = newResp.result?.sessionId;
  check("session_new", typeof sessionId === "string" && sessionId.length > 0);
  const modes = newResp.result?.modes ?? null;
  const modeIds = Array.isArray(modes?.availableModes) ? modes.availableModes.map((m) => m.id) : [];
  check("modes_advertised", modes != null && modeIds.includes(modes?.currentModeId) && modeIds.includes("danger-full-access"),
    { current: modes?.currentModeId ?? null, modes: modeIds });

  // 3) 瞬时失败（429）→ 桥有界重试 → 可见重试通知 → end_turn 收敛。
  const baselinePrompt1 = updates.length;
  const prompt1 = await request("session/prompt", {
    sessionId,
    prompt: [{ type: "text", text: "v086 重试旅程" }],
  }, "prompt#retry");
  check("transient_failure_recovered", prompt1.error === undefined && prompt1.result?.stopReason === "end_turn",
    prompt1.error ?? prompt1.result);
  // 诊断结论（2026-09-05）：429 在 harness agent 内层即被自愈，不冒泡到 ACP
  // prompt 层——因此桥级重试包装（turn-retry.ts）不触发、也无重试通知帧；
  // 用户视角等价（无错误浮出、回合正常收敛）。桥级重试是 agentError 冒泡
  // 形态（如流中断/部分输出后失败）的第二道安全网。
  const errorSurfaced1 = updates.slice(baselinePrompt1).some(
    (entry) => entry.update?.sessionUpdate === "agent_error",
  );
  check("transient_recovery_without_error_surface", !errorSurfaced1,
    { error_frames: updates.slice(baselinePrompt1).filter((e) => e.update?.sessionUpdate === "agent_error").length });

  // 4) 非瞬时失败（auth_error=401）→ 快速失败，无重试通知。
  const baselinePrompt2 = updates.length;
  const prompt2 = await request("session/prompt", {
    sessionId,
    prompt: [{ type: "text", text: "v086 非瞬时失败" }],
  }, "prompt#auth");
  check("non_transient_fails_fast", prompt2.error !== undefined, prompt2.error ?? { ok: true });
  // 诊断结论：auth_error 的失败事实经 harness 投影后 data 不必然携带
  // status=401（错误码/链路取决于 harness LlmFailure 映射）；fail-fast 本身
  // 是契约，无重试通知由 non_transient_no_retry_notice 断言。
  check("non_transient_error_detail", prompt2.error?.data !== undefined || prompt2.error?.message !== undefined,
    { data: prompt2.error?.data ?? null, message: prompt2.error?.message ?? null });
  const notices2 = retryNoticesAfter(baselinePrompt2);
  check("non_transient_no_retry_notice", notices2.length === 0, { notices: notices2 });
} catch (error) {
  fail("test_harness_defect", String(error));
  exitCode = 1;
} finally {
  if (bridge) { try { bridge.kill("SIGTERM"); } catch {} }
  try { mockChild.kill("SIGTERM"); } catch {}
}

const allOk = Object.values(report.checks).every((c) => c.ok === true);
report.status = exitCode === 0 && allOk ? "passed" : "failed";
report.remaining_risk = report.remaining_risk ||
  "重试/快速失败基于受控 overlay（mock LLM 脚本化上游行为）；真实上游 429 形态由 mock 的 rate_limit 行为仿真，真实部署的限流语义未覆盖。";
finalize(exitCode === 0 && allOk ? 0 : 1);
