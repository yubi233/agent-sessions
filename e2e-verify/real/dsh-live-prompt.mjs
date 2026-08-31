// 真实模型 prompt 往返冒烟（经 DSH ACP 桥）。
// 口径：real_model=true（消耗真实 token）、real_upstream=true；凭据只经
// DEEPSEEK_API_KEY / OPENCODE_GO_API_KEY 环境变量或 DSH 侧自身 .env 注入，本脚本不读取其值。
// 用法：node e2e-verify/real/dsh-live-prompt.mjs --model mimo-v2.5-free --config cordis.yml
import { spawn } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync, mkdirSync } from "node:fs";
import { join, resolve } from "node:path";
import { tmpdir } from "node:os";
import { classifyDshLiveFailure, dshZenTestModels } from "./dsh-live-result.mjs";

const args = process.argv.slice(2);
const argOf = (flag) => {
  const i = args.indexOf(flag);
  return i >= 0 ? args[i + 1] : undefined;
};
const dshRoot = process.env.AGENT_SESSIONS_DSH_ROOT ?? "/Users/yubi/code/deepseek-harness";
const bin = process.env.AGENT_SESSIONS_DSH_BIN ?? join(dshRoot, "packages/examples/acp-demo/lib/bin.js");
const configArgument = argOf("--config");
const cfg = process.env.AGENT_SESSIONS_DSH_CONFIG ?? configArgument ?? resolve("cordis.yml");
const configSource = process.env.AGENT_SESSIONS_DSH_CONFIG ? "env:AGENT_SESSIONS_DSH_CONFIG" : configArgument ? "cli:--config" : "repository:cordis.yml";
const model = process.env.AGENT_SESSIONS_DSH_MODEL ?? argOf("--model") ?? "mimo-v2.5-free";
const provider = process.env.AGENT_SESSIONS_DSH_PROVIDER ?? argOf("--provider") ?? (dshZenTestModels.has(model) ? "opencode-zen" : "opencode-go");
const outDir = resolve("e2e-verify/reports/ADAPTER-DSH");
mkdirSync(outDir, { recursive: true });
const stamp = new Date().toISOString().replace(/[:.]/g, "-");
const report = {
  suite: "adpt-dsh-live-prompt", report_kind: "smoke_real_model", status: "failed",
  failure_class: null, real_browser: false, real_model: true, real_upstream: true,
  fixture_data: false, local_test: false, headless: false, browser: "n/a",
  model, provider,
  credential_source: "env:OPENCODE_GO_API_KEY|dsh-env",
  config_source: configSource,
  command: `node e2e-verify/real/dsh-live-prompt.mjs --model ${model} --provider ${provider} --config <redacted>`,
  request_ids: [], usage: { input_tokens: 0, output_tokens: 0 },
  artifacts: [], assistant_text_len: 0, quota_accepted: false, pass_reason: null, remaining_risk: "",
};
const snapshotRoot = mkdtempSync(join(tmpdir(), "dsh-prompt-"));
const child = spawn(process.execPath, [bin, "-c", cfg], {
  cwd: dshRoot,
  env: {
    PATH: process.env.PATH, HOME: process.env.HOME, TMPDIR: process.env.TMPDIR,
    ...(process.env.DEEPSEEK_API_KEY ? { DEEPSEEK_API_KEY: process.env.DEEPSEEK_API_KEY } : {}),
    ...(process.env.OPENCODE_GO_API_KEY ? { OPENCODE_GO_API_KEY: process.env.OPENCODE_GO_API_KEY } : {}),
    DSH_SNAPSHOT_SESSIONS_ROOT: snapshotRoot,
  },
  stdio: ["pipe", "pipe", "pipe"],
});
const stderr = [];
child.stderr.on("data", (d) => stderr.push(d));
let buf = "", pending = new Map(), chunks = [], stopReason = null;
child.stdout.setEncoding("utf8");
child.stdout.on("data", (c) => {
  buf += c; let i;
  while ((i = buf.indexOf("\n")) >= 0) {
    const line = buf.slice(0, i).trim(); buf = buf.slice(i + 1);
    if (!line) continue;
    let m; try { m = JSON.parse(line); } catch { continue; }
    if (m.id != null && pending.has(m.id)) { const p = pending.get(m.id); pending.delete(m.id); p(m); }
    const u = m.params?.update;
    if (m.method === "session/update" && u?.sessionUpdate === "agent_message_chunk")
      chunks.push(u.content?.text ?? "");
    if (u?.sessionUpdate === "done" || u?.sessionUpdate === "stop")
      stopReason = u.reason ?? u.stopReason ?? stopReason;
  }
});
const req = (method, params, ms = 90_000) => new Promise((res, rej) => {
  const id = Date.now() % 1e6 + Math.floor(Math.random() * 999);
  pending.set(id, res);
  setTimeout(() => { if (pending.has(id)) { pending.delete(id); rej(new Error(method + " 超时")); } }, ms);
  child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
});
let ws = null;
try {
  await req("initialize", { protocolVersion: 1, clientInfo: { name: "agent-sessions-live-prompt", version: "0.0.1" }, clientCapabilities: {} });
  ws = mkdtempSync(join(tmpdir(), "dsh-ws-"));
  const n = await req("session/new", { cwd: ws, mcpServers: [] });
  const sessionId = n.result.sessionId;
  if (!n.result?.sessionId) throw new Error(`session/new 未返回 sessionId: ${JSON.stringify(n)}`);
  const setModel = await req("session/set_config_option", { sessionId, configId: "model", value: model }, 30_000);
  if (setModel.error) throw new Error(`model 切换被拒绝: ${JSON.stringify(setModel.error).slice(0,400)} | stderr尾部: ${stderr.join("").slice(-400)}`);
  const p = await req("session/prompt", { sessionId, prompt: [{ type: "text", text: "请只回复两个字符：OK" }] }, 150_000);
  if (p.error) throw new Error(`prompt 被拒绝: ${JSON.stringify(p.error).slice(0,400)} | stderr尾部: ${stderr.join("").slice(-400)}`);
  stopReason = stopReason ?? p.result?.stopReason ?? null;
  const text = chunks.join("");
  report.assistant_text_len = text.length;
  report.usage_note = "ACP wire 未回传 token 计数，usage 保持 0 并如实注明";
  if (/OK/i.test(text)) {
    report.status = "passed"; report.failure_class = null; report.pass_reason = "model_response";
    report.remaining_risk = `真实模型往返成立（model=${model}, stopReason=${stopReason ?? "n/a"}, 回复长度=${text.length}）；单次冒烟不构成模型能力 full gate。`;
  } else throw new Error(`回复未包含 OK（len=${text.length}, stopReason=${stopReason}）`);
} catch (e) {
  const msg = String(e?.message ?? e);
  const result = classifyDshLiveFailure({ model, provider, message: msg, stderr: stderr.join("") });
  report.status = result.status;
  report.failure_class = result.failureClass;
  report.pass_reason = result.passReason;
  report.quota_accepted = result.quotaAccepted;
  report.remaining_risk = result.remainingRisk;
  console.error(`[dsh-live-prompt] ${result.status}:`, result.passReason ?? result.failureClass);
} finally {
  try { child.stdin.end(); } catch {}
  setTimeout(() => { try { child.kill("SIGKILL"); } catch {} }, 8000);
  child.on("exit", () => {
    const path = join(outDir, `p4-dsh-live-prompt-${stamp}.json`);
    writeFileSync(path, JSON.stringify(report, null, 2) + "\n");
    if (ws) rmSync(ws, { recursive: true, force: true });
    rmSync(snapshotRoot, { recursive: true, force: true });
    console.log(`[dsh-live-prompt] status=${report.status} -> ${path}`);
    process.exitCode = report.status === "passed" ? 0 : 1;
  });
}
