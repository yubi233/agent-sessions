#!/usr/bin/env node
// v0.8.5 图片成功路径 deterministic bridge overlay（V085-05 / P4 必过门）。
// 以真实 dsh-acp-demo 进程（cordis-v085-image.yml：attachment-local + image 模型目录）
// + 可脚本化 mock LLM 驱动图片 admission 正向旅程——不消耗真实模型：
//   1. initialize：promptCapabilities.image 如实为 true（attachment 服务 + image 输入双条件）；
//   2. session/prompt 携带 ACP image block（canonical base64）→ 桥 admitAcpPrompt 放行；
//   3. mock 模型回包 → assistant 消息 committed（图片 prompt 被接受并完成回合）。
// 口径：real_upstream=true（真实 DSH 进程）；real_model=false（mock LLM）；fixture_data=false；
// local_test=true；credential_source=none。

import { spawn } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, relative, resolve } from "node:path";

const ROOT = resolve(new URL("../..", import.meta.url).pathname);
const args = process.argv.slice(2);
const argOf = (flag) => { const i = args.indexOf(flag); return i >= 0 ? args[i + 1] : undefined; };
const dshRoot = resolve(argOf("--dsh-root") ?? "/Users/yubi/code/deepseek-harness");
const configPath = resolve(argOf("--config") ?? "e2e-verify/fixtures/dsh/cordis-v085-image.yml");
const outDir = resolve(argOf("--out") ?? "e2e-verify/reports/ADAPTER-DSH");
const mockPort = argOf("--mock-port") ?? "18585";
const keepWorkdir = argOf("--keep-workdir") === "1";

const startedAt = new Date().toISOString();
const report = {
  suite: "adpt-dsh-v085-image",
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
  command: "node e2e-verify/real/dsh-v085-image-overlay.mjs",
  request_ids: [],
  usage: { input_tokens: 0, output_tokens: 0 },
  artifacts: [],
  checks: {},
  remaining_risk: "",
};

const workdir = mkdtempSync(join(tmpdir(), "agent-sessions-dsh-v085-image-"));
mkdirSync(join(workdir, "sessions"), { recursive: true });
mkdirSync(join(workdir, "attachments"), { recursive: true });
mkdirSync(outDir, { recursive: true });
const stamp = startedAt.replace(/[:.]/g, "-");
const transcriptPath = join(outDir, `v085-image-overlay-transcript-${stamp}.jsonl`);
const fs = await import("node:fs");
const transcript = fs.createWriteStream(transcriptPath);
report.artifacts.push(transcriptPath);

function redactValue(value) {
  if (typeof value === "string") return value.replace(/(\/Users\/|\/private\/)[^\s"']+/g, "[PATH REDACTED]");
  return value;
}
function check(name, ok, detail) {
  report.checks[name] = { ok, ...(detail === undefined ? {} : { detail: redactValue(detail) }) };
  console.log(`[v085-image] ${ok ? "PASS" : "FAIL"} ${name}`);
}
function fail(kind, message) {
  report.failure_class = kind;
  report.remaining_risk = String(message);
}
function record(dir, msg) {
  if (typeof msg === "object" && msg !== null) { transcript.write(JSON.stringify({ dir, at: Date.now(), msg }) + "\n"); }
}

const finalize = async (code) => {
  transcript.end();
  if (!keepWorkdir) { try { rmSync(workdir, { recursive: true, force: true }); } catch {} }
  const rp = join(outDir, `v085-image-overlay-${stamp}.json`);
  writeFileSync(rp, JSON.stringify(report, null, 2));
  report.artifacts.push(rp);
  console.log(`[v085-image] report -> ${rp}`);
  console.log(`[v085-image] ${report.status}`);
  process.exit(code);
};

// ---- mock LLM 服务器 ------------------------------------------------------
const mockBin = join(dshRoot, "packages/test-support/llm-mock-server/src/bin.ts");
const mockChild = spawn(process.execPath, [
  "--import", "tsx", mockBin,
  "--host", "127.0.0.1", "--port", mockPort,
  "--api-key", "v085-overlay-key",
  "--sequence", "success", "--repeat-last",
  "--success-text", "v085 图片回合的确定性回复文本。",
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

// ---- bridge 进程 ----------------------------------------------------------
let bridge;
let baseURL;
try {
  baseURL = await mockReady;
  console.log(`[v085-image] mock LLM ready at ${baseURL}`);
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
      V085_MOCK_BASE_URL: baseURL,
      V085_MOCK_API_KEY: "v085-overlay-key",
      AGENT_SESSIONS_DSH_ATTACHMENT_HOME: join(workdir, "attachments"),
    },
    stdio: ["pipe", "pipe", "pipe"],
  });
} catch (error) {
  fail("environment_or_startup_failure", String(error));
  await finalize(1);
}

bridge.stderr.on("data", (d) => { /* 桥诊断只进 transcript */ record("bridge-stderr", String(d)); });
bridge.stdout.setEncoding("utf8");
let lineBuf = "";
let seq = 0;
const pending = new Map();
const updates = [];
let capabilities = null;

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

function request(method, params, label, waitMs = 45_000) {
  const id = ++seq;
  const frame = { jsonrpc: "2.0", id, method, params };
  record("outbound", frame);
  return new Promise((resolvePromise, rejectPromise) => {
    const timer = setTimeout(() => { pending.delete(id); rejectPromise(new Error(`${label} 等待响应超时（${waitMs}ms）`)); }, waitMs);
    pending.set(id, { resolve: resolvePromise, timer });
    bridge.stdin.write(`${JSON.stringify(frame)}\n`);
  });
}

let exitCode = 0;
try {
  // 1) 协商：image 能力如实（attachment 服务 + image 模型目录双条件）。
  const initResp = await request("initialize", { protocolVersion: 1, clientCapabilities: { extensions: {} } }, "initialize");
  capabilities = initResp.result?.agentCapabilities ?? {};
  const caps = capabilities.promptCapabilities ?? capabilities ?? {};
  check("promptCapabilities_image_true", caps.image === true, { image: caps.image, full: capabilities });
  check("initialize_ok", initResp.error === undefined, initResp.error ?? { ok: true });

  // 2) 图片回合：ACP image block（1x1 PNG canonical base64）+ 文本。
  const sessionCwd = mkdtempSync(join(workdir, "ws-"));
  const newResp = await request("session/new", { cwd: sessionCwd, mcpServers: [] }, "session/new");
  const sessionId = newResp.result?.sessionId;
  check("session_new", typeof sessionId === "string" && sessionId.length > 0);
  // 1x1 透明 PNG 的 canonical base64。
  const pngB64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==";
  const baseline = updates.length;
  const promptResp = await request("session/prompt", {
    sessionId,
    prompt: [
      { type: "text", text: "这张图是什么？" },
      { type: "image", mimeType: "image/png", data: pngB64 },
    ],
  }, "prompt#image");
  check("image_prompt_accepted", promptResp.error === undefined, promptResp.error ?? promptResp.result);

  // 3) 模型回包：assistant 消息 committed（图片 prompt 走通整轮）。
  const deadline = Date.now() + 30_000;
  let committedText = "";
  while (Date.now() < deadline) {
    const texts = updates.slice(baseline)
      .filter((entry) => entry.update?.sessionUpdate === "agent_message_chunk")
      .map((entry) => entry.update?.content?.text ?? "");
    committedText = texts.join("");
    const finished = updates.slice(baseline).some((entry) => entry.update?.sessionUpdate === "assistant_message" || entry.update?.sessionUpdate === "turn_completed");
    if (finished && committedText.length > 0) break;
    await new Promise((resolveWait) => setTimeout(resolveWait, 200));
  }
  check("image_turn_committed", committedText.length > 0, { chars: committedText.length });
} catch (error) {
  fail("test_harness_defect", String(error));
  exitCode = 1;
} finally {
  if (bridge) { try { bridge.kill("SIGTERM"); } catch {} }
  try { mockChild.kill("SIGTERM"); } catch {}
}

const allOk = Object.values(report.checks).every((c) => c.ok === true);
report.status = exitCode === 0 && allOk ? "passed" : "failed";
report.remaining_risk = report.remaining_risk || "图片成功路径基于受控 overlay（attachment-local + image 模型目录 + mock LLM）；text-only 拒绝矩阵由生产组合（cordis.yml）V083 负向与桥 vitest 覆盖；真实 image-capable 模型部署未授权。";
console.log(`[v085-image] checks ${Object.values(report.checks).filter((c) => c.ok).length}/${Object.values(report.checks).length}`);
await finalize(report.status === "passed" ? 0 : 1);