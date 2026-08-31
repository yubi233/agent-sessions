#!/usr/bin/env node
// v0.8 真实 DSH Resume/load/send gate runner。
// 口径：real_model=true、real_upstream=true；凭据只经环境变量或 DSH 本机配置注入。
// 每个模型最多执行 1 次初始请求 + 5 次额外重试；可识别 Zen 额度错误按约定 passed/zen_quota_accepted。
// 未设置 AGENT_SESSIONS_DSH_REAL=1 时直接 blocked，不启动模型请求。
import { spawn } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync, mkdirSync } from "node:fs";
import { join, resolve } from "node:path";
import { tmpdir } from "node:os";
import { classifyDshLiveFailure, dshZenTestModels } from "./dsh-live-result.mjs";

const MAX_RETRIES = 5;
const RETRYABLE_FAILURES = new Set([
  "provider_http_error",
  "provider_timeout",
  "environment_or_startup_failure",
  "model_flakiness",
]);

const args = process.argv.slice(2);
const argOf = (flag) => {
  const index = args.indexOf(flag);
  return index >= 0 ? args[index + 1] : undefined;
};
const dshRoot = process.env.AGENT_SESSIONS_DSH_ROOT ?? "/Users/yubi/code/deepseek-harness";
const bin = process.env.AGENT_SESSIONS_DSH_BIN ?? join(dshRoot, "packages/examples/acp-demo/lib/bin.js");
const configArgument = argOf("--config");
const cfg = process.env.AGENT_SESSIONS_DSH_CONFIG ?? configArgument ?? resolve("cordis.yml");
const configSource = process.env.AGENT_SESSIONS_DSH_CONFIG
  ? "env:AGENT_SESSIONS_DSH_CONFIG"
  : configArgument
    ? "cli:--config"
    : "repository:cordis.yml";
const model = process.env.AGENT_SESSIONS_DSH_MODEL ?? argOf("--model") ?? "deepseek-v4-flash-free";
const provider = process.env.AGENT_SESSIONS_DSH_PROVIDER
  ?? argOf("--provider")
  ?? (dshZenTestModels.has(model) ? "opencode-zen" : "opencode-go");
const outDir = resolve("e2e-verify/reports/ADAPTER-DSH");
mkdirSync(outDir, { recursive: true });
const stamp = new Date().toISOString().replace(/[:.]/g, "-");
const report = {
  suite: "adpt-dsh-v08-resume", report_kind: "full_gate_real_model", status: "blocked",
  failure_class: null, real_browser: false, real_model: true, real_upstream: true,
  fixture_data: false, local_test: false, headless: false, browser: "n/a",
  model, provider,
  credential_source: "env:OPENCODE_GO_API_KEY|dsh-env",
  config_source: configSource,
  command: `node e2e-verify/real/dsh-v08-resume.mjs --model ${model} --provider ${provider} --config <redacted>`,
  max_retries: MAX_RETRIES,
  request_attempts: 0,
  retry_failures: [],
  request_ids: [], usage: { input_tokens: 0, output_tokens: 0 },
  artifacts: [], assistant_text_len: 0, quota_accepted: false, pass_reason: null, remaining_risk: "",
};

function waitForExit(child, timeoutMs = 8_000) {
  if (child.exitCode !== null || child.signalCode !== null) return Promise.resolve();
  return new Promise((resolveExit) => {
    let settled = false;
    const finish = () => {
      if (settled) return;
      settled = true;
      resolveExit();
    };
    child.once("exit", finish);
    child.once("error", finish);
    setTimeout(() => {
      if (settled) return;
      try { child.kill("SIGKILL"); } catch {}
      finish();
    }, timeoutMs);
  });
}

function delay(ms) {
  return new Promise((resolveDelay) => setTimeout(resolveDelay, ms));
}

async function runAttempt() {
  const snapshotRoot = mkdtempSync(join(tmpdir(), "dsh-resume-"));
  let ws = null;
  let child = null;
  const stderr = [];
  let assistantTextLength = 0;
  let stopReason = null;
  try {
    child = spawn(process.execPath, [bin, "-c", cfg], {
      cwd: dshRoot,
      env: {
        PATH: process.env.PATH, HOME: process.env.HOME, TMPDIR: process.env.TMPDIR,
        ...(process.env.DEEPSEEK_API_KEY ? { DEEPSEEK_API_KEY: process.env.DEEPSEEK_API_KEY } : {}),
        ...(process.env.OPENCODE_GO_API_KEY ? { OPENCODE_GO_API_KEY: process.env.OPENCODE_GO_API_KEY } : {}),
        DSH_SNAPSHOT_SESSIONS_ROOT: snapshotRoot,
      },
      stdio: ["pipe", "pipe", "pipe"],
    });
    child.on("error", (error) => stderr.push(String(error?.message ?? error)));
    child.stderr.on("data", (data) => stderr.push(data.toString()));
    let buffer = "";
    const pending = new Map();
    const chunks = [];
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk) => {
      buffer += chunk;
      let end;
      while ((end = buffer.indexOf("\n")) >= 0) {
        const line = buffer.slice(0, end).trim();
        buffer = buffer.slice(end + 1);
        if (!line) continue;
        let message;
        try { message = JSON.parse(line); } catch { continue; }
        if (message.id != null && pending.has(message.id)) {
          const resolveRequest = pending.get(message.id);
          pending.delete(message.id);
          resolveRequest(message);
        }
        const update = message.params?.update;
        if (message.method === "session/update" && update?.sessionUpdate === "agent_message_chunk") {
          chunks.push(update.content?.text ?? "");
        }
        if (update?.sessionUpdate === "done" || update?.sessionUpdate === "stop") {
          stopReason = update.reason ?? update.stopReason ?? stopReason;
        }
      }
    });
    let nextRequestID = 1;
    const request = (method, params, timeoutMs = 90_000) => new Promise((resolveRequest, rejectRequest) => {
      const id = nextRequestID++;
      const timer = setTimeout(() => {
        if (!pending.has(id)) return;
        pending.delete(id);
        rejectRequest(new Error(`${method} 超时`));
      }, timeoutMs);
      const settle = (callback) => (message) => {
        clearTimeout(timer);
        callback(message);
      };
      pending.set(id, settle(resolveRequest));
      try {
        child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
      } catch (error) {
        clearTimeout(timer);
        pending.delete(id);
        rejectRequest(error);
      }
    });

    await request("initialize", {
      protocolVersion: 1,
      clientInfo: { name: "agent-sessions-v08-resume", version: "0.0.1" },
      clientCapabilities: {},
    });
    ws = mkdtempSync(join(tmpdir(), "dsh-ws-"));
    const sessionResponse = await request("session/new", { cwd: ws, mcpServers: [] });
    if (!sessionResponse.result?.sessionId) {
      throw new Error(`session/new 未返回 sessionId: ${JSON.stringify(sessionResponse).slice(0, 400)}`);
    }
    const sessionId = sessionResponse.result.sessionId;
    const setModel = await request("session/set_config_option", {
      sessionId, configId: "model", value: model,
    }, 30_000);
    if (setModel.error) {
      throw new Error(`model 切换被拒绝: ${JSON.stringify(setModel.error).slice(0, 400)} | stderr 尾部: ${stderr.join("").slice(-400)}`);
    }
    const loadResponse = await request("session/load", {
      sessionId, cwd: ws, mcpServers: [], additionalDirectories: [],
    }, 60_000);
    if (loadResponse.error) {
      throw new Error(`session/load 被拒绝: ${JSON.stringify(loadResponse.error).slice(0, 400)} | stderr 尾部: ${stderr.join("").slice(-400)}`);
    }
    const promptResponse = await request("session/prompt", {
      sessionId,
      prompt: [{ type: "text", text: "请只回复两个字符：OK" }],
    }, 150_000);
    if (promptResponse.error) {
      throw new Error(`prompt 被拒绝: ${JSON.stringify(promptResponse.error).slice(0, 400)} | stderr 尾部: ${stderr.join("").slice(-400)}`);
    }
    stopReason = stopReason ?? promptResponse.result?.stopReason ?? null;
    const assistantText = chunks.join("");
    assistantTextLength = assistantText.length;
    if (!/OK/i.test(assistantText)) {
      throw new Error(`恢复后回复未包含 OK（len=${assistantText.length}, stopReason=${stopReason}）`);
    }
    return {
      status: "passed",
      failureClass: null,
      passReason: "model_response",
      quotaAccepted: false,
      assistantTextLength: assistantText.length,
      stopReason,
      remainingRisk: `DSH session/load 后 send 往返成立（model=${model}, stopReason=${stopReason ?? "n/a"}, 回复长度=${assistantText.length}）；本 gate 不读取历史正文，不证明完整 UI 回放。`,
    };
  } catch (error) {
    const message = String(error?.message ?? error);
    const result = classifyDshLiveFailure({ model, provider, message, stderr: stderr.join("") });
    return { ...result, assistantTextLength, stopReason };
  } finally {
    if (child) {
      try { child.stdin.end(); } catch {}
      await waitForExit(child);
    }
    if (ws) rmSync(ws, { recursive: true, force: true });
    rmSync(snapshotRoot, { recursive: true, force: true });
  }
}

if (process.env.AGENT_SESSIONS_DSH_REAL !== "1") {
  report.status = "blocked";
  report.failure_class = "credential_or_quota_blocker";
  report.remaining_risk = "未设置 AGENT_SESSIONS_DSH_REAL=1；未启动模型请求，无法验证真实 DSH Resume/load/send。";
  const reportPath = join(outDir, `p4-dsh-v08-resume-${stamp}.json`);
  writeFileSync(reportPath, JSON.stringify(report, null, 2) + "\n");
  console.log(`[dsh-v08-resume] status=blocked -> ${reportPath}`);
  process.exit(2);
}

let finalResult = null;
for (let attempt = 1; attempt <= MAX_RETRIES + 1; attempt += 1) {
  report.request_attempts = attempt;
  const result = await runAttempt();
  finalResult = result;
  if (result.status === "passed" || !RETRYABLE_FAILURES.has(result.failureClass) || attempt > MAX_RETRIES) {
    break;
  }
  report.retry_failures.push({
    attempt,
    failure_class: result.failureClass,
    diagnostic_code: result.diagnosticCode ?? null,
  });
  await delay(Math.min(2_000, 250 * attempt));
}

if (finalResult) {
  report.status = finalResult.status;
  report.failure_class = finalResult.failureClass;
  report.pass_reason = finalResult.passReason;
  report.diagnostic_code = finalResult.diagnosticCode ?? null;
  report.quota_accepted = finalResult.quotaAccepted;
  report.remaining_risk = finalResult.remainingRisk;
  report.assistant_text_len = finalResult.assistantTextLength ?? 0;
  report.usage_note = "ACP wire 未回传 token 计数，usage 保持 0 并如实注明";
  if (finalResult.status !== "passed") {
    console.error(`[dsh-v08-resume] ${finalResult.status}:`, finalResult.passReason ?? finalResult.failureClass);
  }
}

const reportPath = join(outDir, `p4-dsh-v08-resume-${stamp}.json`);
writeFileSync(reportPath, JSON.stringify(report, null, 2) + "\n");
console.log(`[dsh-v08-resume] status=${report.status} attempts=${report.request_attempts} -> ${reportPath}`);
process.exitCode = report.status === "passed" ? 0 : report.status === "blocked" ? 2 : 1;
