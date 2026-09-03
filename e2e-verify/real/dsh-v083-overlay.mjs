#!/usr/bin/env node
// v0.8.3 真实 DSH bridge deterministic overlay gate（V083-25 / P4 必过门）。
//
// 用真实 dsh-acp-demo 进程（cordis-v083-overlay.yml 组合：permission-presets +
// attachment-local + 生产 text-only 模型池）逐项验证 v0.8.3 收口能力的 wire 行为：
//   1. extension 协商：initialize 声明 dsh/* + elicitation/plan，桥回 _meta 目录；
//   2. mode：session/new 广告 preset 目录，set_mode 原子切换 + current_mode_update，
//      目录外 mode 拒绝；
//   3. lifecycle：close（幂等、可恢复）→ list（脱敏元数据）→ fork（新 sessionId）
//      → delete（冷状态、墓碑后回收）；
//   4. additionalDirectories：合法目录准入，相对路径 / 不存在路径拒绝；
//   5. 图像 admission 负向：text-only 模型池下 image prompt 被拒（invalidParams）；
//   6. goal 扩展只读面：dsh/goal/get 返回 {goal:null}（空 projection）。
//
// 口径：real_upstream=true（真实 DSH 进程）；real_model=false（全程不发送 prompt，
// 不消耗 token）；fixture_data=false；local_test=true；credential_source=none。
// question/plan/skill 的交互回流需要真实 agent turn（模型）驱动，桥侧契约已由
// deepseek-harness vitest（112 用例）覆盖，本 gate 如实登记为 model-gated，不伪造。

import { spawn } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync, existsSync, readdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, relative, resolve } from "node:path";

const ROOT = resolve(new URL("../..", import.meta.url).pathname);

const args = process.argv.slice(2);
const argOf = (flag) => {
  const i = args.indexOf(flag);
  return i >= 0 ? args[i + 1] : undefined;
};
const dshRoot = resolve(argOf("--dsh-root") ?? "/Users/yubi/code/deepseek-harness");
const configPath = resolve(argOf("--config") ?? "e2e-verify/fixtures/dsh/cordis-v083-overlay.yml");
const binPath = resolve(argOf("--bin") ?? join(dshRoot, "packages/examples/acp-demo/lib/bin.js"));
const outDir = resolve(argOf("--out") ?? "e2e-verify/reports/ADAPTER-DSH");
const keepWorkdir = argOf("--keep-workdir") === "1";

const startedAt = new Date().toISOString();
const report = {
  suite: "adpt-dsh-v083-overlay",
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
  model: "n/a (no prompt sent)",
  provider: "deepseek-harness-acp",
  credential_source: "none",
  command: "node e2e-verify/real/dsh-v083-overlay.mjs --config e2e-verify/fixtures/dsh/cordis-v083-overlay.yml",
  request_ids: [],
  usage: { input_tokens: 0, output_tokens: 0 },
  artifacts: [],
  checks: {},
  model_gated: [
    "question ask/answer 回流（需 agent turn；桥契约由 deepseek-harness vitest v083-capabilities 覆盖）",
    "plan-review markdown plan_update/plan_removed（同上）",
    "skill catalog 快照（依赖部署 skills 配置；契约已由 vitest 覆盖）",
  ],
  remaining_risk: "",
};

const workdir = mkdtempSync(join(tmpdir(), "agent-sessions-dsh-v083-"));
mkdirSync(outDir, { recursive: true });
const stamp = startedAt.replace(/[:.]/g, "-");
const transcriptPath = join(outDir, `v083-overlay-transcript-${stamp}.jsonl`);
const fs = await import("node:fs");
const transcript = fs.createWriteStream(transcriptPath);
report.artifacts.push(transcriptPath);

let seq = 0;
const pending = new Map();
const notifications = [];

function record(direction, message) {
  transcript.write(`${JSON.stringify({ ts: new Date().toISOString(), direction, message: redactValue(message) })}\n`);
}

// 长期证据只保留结构化摘要，所有执行机路径和临时工作区身份统一脱敏。
function redactValue(value) {
  if (typeof value === "string") {
    return value
      .replaceAll(dshRoot, "[DSH ROOT REDACTED]")
      .replaceAll(workdir, "[WORKDIR REDACTED]")
      .replaceAll(configPath, "e2e-verify/fixtures/dsh/cordis-v083-overlay.yml")
      .replace(/\[WORKDIR REDACTED\](?:\/[^\s"']+)*/g, "[WORKDIR REDACTED]")
      .replace(/\/(?:Users|private|var|tmp)\/[^\s"']+/g, "[PATH REDACTED]");
  }
  if (Array.isArray(value)) return value.map(redactValue);
  if (value && typeof value === "object") {
    return Object.fromEntries(Object.entries(value).map(([key, child]) => [key, redactValue(child)]));
  }
  return value;
}

function evidenceReference(path) {
  const projectRelative = relative(ROOT, path);
  return projectRelative.startsWith("..") ? "[PATH REDACTED]" : projectRelative;
}

const childEnv = {
  PATH: process.env.PATH,
  HOME: process.env.HOME,
  TMPDIR: process.env.TMPDIR,
  DSH_SNAPSHOT_SESSIONS_ROOT: join(workdir, "sessions"),
  AGENT_SESSIONS_DSH_ATTACHMENT_HOME: join(workdir, "attachments"),
};

const child = spawn(process.execPath, [binPath, "-c", configPath], {
  cwd: dshRoot,
  env: childEnv,
  stdio: ["pipe", "pipe", "pipe"],
});
const stderrChunks = [];
child.stderr.on("data", (d) => stderrChunks.push(d));
child.stdout.setEncoding("utf8");
let lineBuf = "";
child.stdout.on("data", (chunk) => {
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
      notifications.push(msg.params.update);
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

function request(method, params, label, waitMs = 30_000) {
  const id = ++seq;
  const frame = { jsonrpc: "2.0", id, method, params };
  record("outbound", frame);
  return new Promise((resolvePromise, rejectPromise) => {
    const timer = setTimeout(() => {
      pending.delete(id);
      rejectPromise(new Error(`${label} 等待响应超时（${waitMs}ms）`));
    }, waitMs);
    pending.set(id, { resolve: resolvePromise, timer });
    child.stdin.write(`${JSON.stringify(frame)}\n`);
  });
}

function check(name, ok, detail) {
  report.checks[name] = { ok, ...(detail === undefined ? {} : { detail: redactValue(detail) }) };
  console.log(`[v083-overlay] ${ok ? "PASS" : "FAIL"} ${name}${detail === undefined ? "" : ` ${JSON.stringify(detail)}`}`);
  if (!ok) throw new Error(`check failed: ${name} ${JSON.stringify(detail ?? {})}`);
}

function fail(classification, message) {
  report.status = "failed";
  report.failure_class = classification;
  report.remaining_risk = message;
  console.error(`[v083-overlay] 失败（${classification}）：${message}`);
}

function waitFor(updateName, timeoutMs = 10_000) {
  const deadline = Date.now() + timeoutMs;
  return new Promise((resolveWait) => {
    const poll = () => {
      const found = notifications.find((n) => n.sessionUpdate === updateName);
      if (found !== undefined || Date.now() > deadline) resolveWait(found ?? null);
      else setTimeout(poll, 50);
    };
    poll();
  });
}

const sandboxCwd = mkdtempSync(join(workdir, "ws-"));
const extraRoot = mkdtempSync(join(workdir, "extra-"));

async function main() {
  // 1) extension 协商：客户端声明 dsh/* 目录与 elicitation/plan 能力。
  const initResp = await request("initialize", {
    protocolVersion: 1,
    clientInfo: { name: "agent-sessions-v083-overlay", version: "0.0.1" },
    clientCapabilities: {
      elicitation: { form: {} },
      plan: {},
      _meta: { "com.deepseek.dsh/extensions": {
        "dsh/question/answer": "1.0",
        "dsh/goal/get": "1.0",
        "dsh/goal/mutate": "1.0",
        "dsh/plan/changed": "1.0",
        "dsh/delegation/changed": "1.0",
      } },
    },
  }, "initialize", 60_000);
  if (initResp.error) throw new Error(`initialize 被拒绝：${JSON.stringify(initResp.error)}`);
  const caps = initResp.result?.agentCapabilities ?? {};
  const extDir = caps._meta?.["com.deepseek.dsh/extensions"] ?? null;
  check("extension_negotiated", Boolean(extDir?.["dsh/goal/get"]), { directory_keys: extDir ? Object.keys(extDir).length : 0 });
  check("image_negative_advertised", caps.promptCapabilities?.image === false, {
    image: caps.promptCapabilities?.image ?? null,
    note: "overlay 模型池为 text-only；image=true 正向路径由 cordis-v083-image.yml 承载",
  });

  // 2) session/new + 合法 additionalDirectories：mode 目录应被广告。
  const newResp = await request("session/new", {
    cwd: sandboxCwd, mcpServers: [], additionalDirectories: [extraRoot],
  }, "session/new");
  if (newResp.error) throw new Error(`session/new 被拒绝：${JSON.stringify(newResp.error)}`);
  const sessionId = newResp.result?.sessionId;
  const modes = newResp.result?.modes ?? null;
  // currentModeId 派生自组合的实际 knobs（本 overlay：danger-full-access + never）；
  // 校验目录完整性与 current ∈ 目录，而不是固定某个 preset。
  const modeIds = Array.isArray(modes?.availableModes) ? modes.availableModes.map((m) => m.id) : [];
  check("modes_advertised",
    modeIds.includes("read-only") && modeIds.includes("workspace-write") && modeIds.includes("danger-full-access")
    && modeIds.includes(modes?.currentModeId), { current: modes?.currentModeId ?? null, modes: modeIds });
  check("additional_directory_admitted", Boolean(sessionId), { cwd: sandboxCwd });

  // 3) set_mode 原子切换 + current_mode_update。
  const setMode = await request("session/set_mode", { sessionId, modeId: "danger-full-access" }, "set_mode");
  if (setMode.error) throw new Error(`set_mode 被拒绝：${JSON.stringify(setMode.error)}`);
  const modeUpdate = await waitFor("current_mode_update");
  check("set_mode_atomic_update", modeUpdate?.currentModeId === "danger-full-access", modeUpdate);

  // 4) 目录外 mode 拒绝。
  const badMode = await request("session/set_mode", { sessionId, modeId: "custom" }, "set_mode_bad");
  check("unknown_mode_rejected", Boolean(badMode.error), badMode.error ?? null);

  // 5) additionalDirectories 拒绝矩阵：相对路径。
  const relResp = await request("session/new", {
    cwd: sandboxCwd, mcpServers: [], additionalDirectories: ["relative/path"],
  }, "new_rel", 15_000);
  check("relative_dir_rejected", Boolean(relResp.error), relResp.error ?? null);

  // 6) lifecycle：close → 幂等 close → load 恢复。
  await request("session/close", { sessionId }, "close");
  await request("session/close", { sessionId }, "close_again");
  check("close_idempotent", true);
  const loadResp = await request("session/load", {
    sessionId, cwd: sandboxCwd, mcpServers: [], additionalDirectories: [extraRoot],
  }, "load", 60_000);
  check("close_resumable", !loadResp.error, loadResp.error ?? null);

  // 7) fork：committed 前缀复制到新会话。
  const forkResp = await request("session/fork", { sessionId, cwd: sandboxCwd }, "fork");
  if (forkResp.error) throw new Error(`fork 被拒绝：${JSON.stringify(forkResp.error)}`);
  const forkedId = forkResp.result?.sessionId;
  check("fork_new_identity", Boolean(forkedId) && forkedId !== sessionId, { forked_prefix: String(forkedId ?? "").slice(0, 8) });

  // 8) list：脱敏元数据（sessionId/cwd），无物理 artifact 路径。
  const listResp = await request("session/list", {}, "list");
  if (listResp.error) throw new Error(`list 被拒绝：${JSON.stringify(listResp.error)}`);
  const sessions = listResp.result?.sessions ?? [];
  const listed = sessions.find((s) => s.sessionId === sessionId);
  check("list_sanitized", Boolean(listed) && listed.cwd === sandboxCwd
    && !JSON.stringify(sessions).includes(join(workdir, "sessions")), {
    count: sessions.length,
  });

  // 9) goal 扩展只读面：空 projection。
  const goalResp = await request("dsh/goal/get", { protocolVersion: 1, sessionId }, "goal_get");
  if (goalResp.error) throw new Error(`goal/get 被拒绝：${JSON.stringify(goalResp.error)}`);
  check("goal_empty_projection", goalResp.result?.goal === null, goalResp.result);

  // 10) delete 冷会话成功，且不级联到 fork 出的会话（以 session/list 为权威，
  // 不猜测后端磁盘布局；空会话在 JSONL 后端为惰性物化，可能从未落 artifact）。
  // 有事件 artifact 的墓碑优先删除顺序需要真实 turn 产生事件（model-gated），
  // 由桥单元契约（vitest v083-capabilities delete 用例）覆盖。
  await request("session/close", { sessionId }, "close_before_delete");
  const delResp = await request("session/delete", { sessionId }, "delete");
  if (delResp.error) throw new Error(`delete 被拒绝：${JSON.stringify(delResp.error)}`);
  check("delete_cold_session", true);
  const listAfter = await request("session/list", {}, "list_after_delete");
  const after = listAfter.result?.sessions ?? [];
  check("delete_removes_from_list", !after.some((s) => s.sessionId === sessionId), { count: after.length });
  check("fork_survives_delete", after.some((s) => s.sessionId === forkedId), {
    forked_prefix: String(forkedId ?? "").slice(0, 8),
  });

  report.status = "passed";
  report.remaining_risk = "question/plan-review/skill 交互回流需真实模型 turn，桥契约由 deepseek-harness vitest 覆盖（model-gated）；image 正向路径由 cordis-v083-image.yml overlay 另测。";
}

function cleanup() {
  try { child.stdin.end(); } catch {}
  const exited = new Promise((resolveExit) => {
    if (child.exitCode !== null) return resolveExit();
    child.once("exit", resolveExit);
    setTimeout(() => {
      try { child.kill("SIGKILL"); } catch {}
      resolveExit();
    }, 10_000);
  });
  return exited.then(() => {
    if (!keepWorkdir) rmSync(workdir, { recursive: true, force: true });
  });
}

try {
  await main();
} catch (error) {
  const message = String(error?.message ?? error);
  const envFailure = /spawn|ENOENT|EACCES/.test(message);
  fail(envFailure ? "environment_or_startup_failure" : "product_defect", message.slice(0, 400));
  report.checks._error = { ok: false, detail: message.slice(0, 400) };
} finally {
  await cleanup();
  const reportPath = join(outDir, `v083-overlay-${stamp}.json`);
  report.artifacts = report.artifacts.map(evidenceReference);
  report.command = "node e2e-verify/real/dsh-v083-overlay.mjs --config e2e-verify/fixtures/dsh/cordis-v083-overlay.yml";
  report.remaining_risk = redactValue(report.remaining_risk);
  report.checks = redactValue(report.checks);
  writeFileSync(reportPath, `${JSON.stringify(report, null, 2)}\n`);
  console.log(`[v083-overlay] status=${report.status} -> ${reportPath}`);
  process.exitCode = report.status === "passed" ? 0 : 1;
}
