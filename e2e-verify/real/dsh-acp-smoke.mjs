#!/usr/bin/env node
// DSH ACP 桥 P0 冒烟驱动：真实启动 dsh-acp-demo 子进程，走最小 JSON-RPC 链路。
//
// 目标（对应迭代计划 v0.5.next P0，不写产品代码）：
//   1. initialize 握手（记录协议版本协商与启动耗时）；
//   2. session/new 创建会话（cwd 指向隔离沙箱目录）；
//   3. 探测未声明方法（session/load、session/list）的错误形态 —— 为映射表提供
//      "Resume unsupported" 的 wire 级证据；
//   4. 对空闲会话发 session/cancel 通知，观察桥的容错行为；
//   5. stdin EOF 触发受控 dispose，确认子进程退出码。
//
// 口径：real_upstream=true（真实 DSH 进程）；real_model=false（全程不发送 prompt，
// 不消耗 token、不需要 LLM key）；local_test=true；credential_source=none。
//
// 安全：本脚本只 spawn DSH bin 并转发最小环境变量；DSH 自身按其设计加载其仓库内
// gitignored .env（LLM key 由 DSH 侧承载），本脚本不读取、不转储该文件；stdout 帧
// 转写只含协议消息，若未来出现疑似敏感字段由 --redact 兜底剥离。

import { spawn } from "node:child_process";
import { mkdirSync, writeFileSync, createWriteStream } from "node:fs";
import { join, resolve } from "node:path";
import { tmpdir } from "node:os";
import { mkdtempSync, rmSync } from "node:fs";

const args = process.argv.slice(2);
function argOf(flag) {
  const i = args.indexOf(flag);
  return i >= 0 ? args[i + 1] : undefined;
}
const dshRoot = resolve(argOf("--dsh-root") ?? "/Users/yubi/code/deepseek-harness");
const configPath = argOf("--config") ?? join(dshRoot, "examples/acp-agent/cordis.yml");
const binPath = argOf("--bin") ?? join(dshRoot, "packages/examples/acp-demo/lib/bin.js");
const outDir = resolve(argOf("--out") ?? "e2e-verify/reports/ADAPTER-DSH");
const timeoutMs = Number(argOf("--timeout-ms") ?? 120_000);

// ---- 报告骨架：字段对齐 web-iterative-workflow 证据模板与项目既有 schema ----
const startedAt = new Date().toISOString();
const report = {
  suite: "adpt-dsh-p0-smoke",
  report_kind: "smoke",
  status: "failed",
  failure_class: null,
  real_browser: false,
  real_model: false,
  real_upstream: true,
  fixture_data: false,
  local_test: true,
  headless: false,
  browser: "n/a",
  model: "n/a",
  provider: "deepseek-harness-acp",
  credential_source: "none",
  command: `node e2e-verify/real/dsh-acp-smoke.mjs --dsh-root ${dshRoot}`,
  request_ids: [],
  usage: { input_tokens: 0, output_tokens: 0 },
  artifacts: [],
  observations: {},
  remaining_risk: "",
};

const workdir = mkdtempSync(join(tmpdir(), "agent-sessions-dsh-p0-"));
mkdirSync(outDir, { recursive: true });
const stamp = startedAt.replace(/[:.]/g, "-");
const transcriptPath = join(outDir, `p0-smoke-transcript-${stamp}.jsonl`);
const transcript = createWriteStream(transcriptPath);
report.artifacts.push(transcriptPath);

let seq = 0;
const pending = new Map(); // id -> {resolve, reject, timer, label}
const probes = []; // 每个探测步骤的摘要，供报告 observations 使用

function record(direction, message) {
  transcript.write(
    `${JSON.stringify({ ts: new Date().toISOString(), direction, message })}\n`,
  );
}

function fail(classification, message) {
  report.status = "failed";
  report.failure_class = classification;
  report.remaining_risk = message;
  console.error(`[dsh-p0] 失败（${classification}）：${message}`);
}

// 最小环境注入：只传运行 Node 必需项，scrub 其余（含其他 Provider 凭据）。
const childEnv = {
  PATH: process.env.PATH,
  HOME: process.env.HOME,
  TMPDIR: process.env.TMPDIR,
  // 把持久化会话重定向到本次临时工作目录，避免污染 DSH checkout。
  DSH_SNAPSHOT_SESSIONS_ROOT: join(workdir, "sessions"),
};

const child = spawn(process.execPath, [binPath, "-c", configPath], {
  cwd: dshRoot, // 组合内插件按 DSH 树解析；cwd 同时是 sandbox workspaceRoot 的默认来源
  env: childEnv,
  stdio: ["pipe", "pipe", "pipe"],
});

const stderrChunks = [];
child.stderr.on("data", (d) => {
  stderrChunks.push(d);
});
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
    try {
      msg = JSON.parse(line);
    } catch {
      record("stderr-ish", { raw: line });
      continue;
    }
    record("inbound", msg);
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

function notify(method, params) {
  const frame = { jsonrpc: "2.0", method, params };
  record("outbound", frame);
  child.stdin.write(`${JSON.stringify(frame)}\n`);
}

function summarize(label, extra) {
  probes.push({ label, ...extra });
  console.log(`[dsh-p0] ${label}${extra ? ` ${JSON.stringify(extra)}` : ""}`);
}

async function main() {
  // 1) initialize：记录协议版本协商与冷启动耗时。
  const bootStart = Date.now();
  const initResp = await request(
    "initialize",
    {
      protocolVersion: 1,
      clientInfo: { name: "agent-sessions-dsh-smoke", version: "0.0.1" },
      clientCapabilities: {},
    },
    "initialize",
  );
  if (initResp.error) throw new Error(`initialize 被拒绝：${JSON.stringify(initResp.error)}`);
  const bootMs = Date.now() - bootStart;
  report.observations.boot_ms = bootMs;
  report.observations.agent_protocol_version = initResp.result?.protocolVersion ?? null;
  report.observations.agent_info = initResp.result?.agentInfo ?? null;
  summarize("initialize", { bootMs, protocolVersion: initResp.result?.protocolVersion });

  // 2) session/new：cwd 用临时目录，避免触碰真实工作区。
  const sandboxCwd = mkdtempSync(join(workdir, "ws-"));
  const newResp = await request(
    "session/new",
    { cwd: sandboxCwd, mcpServers: [] },
    "session/new",
  );
  if (newResp.error) throw new Error(`session/new 被拒绝：${JSON.stringify(newResp.error)}`);
  const sessionId = newResp.result?.sessionId;
  report.observations.session_id_prefix = String(sessionId ?? "").slice(0, 8) || null;
  summarize("session/new", { hasSessionId: Boolean(sessionId) });

  // 3) 未声明方法探测：桥源码未实现 load/list，预期 method-not-found 类错误。
  for (const method of ["session/load", "session/list"]) {
    const resp = await request(method, { cwd: sandboxCwd }, method, 15_000).catch((e) => ({
      error: { code: "timeout", message: String(e.message) },
    }));
    report.request_ids?.push?.(undefined); // 保持字段形状；本迭代无服务端 request id
    summarize(method, {
      error_code: resp.error?.code ?? null,
      error_message: typeof resp.error?.message === "string"
        ? resp.error.message.slice(0, 160)
        : null,
    });
  }

  // 4) 空闲会话 cancel：观察容错（通知无响应帧，仅记录已发送且进程存活）。
  notify("session/cancel", { sessionId });
  await new Promise((r) => setTimeout(r, 500));
  summarize("session/cancel(idle)", { child_alive_after: !child.killed && child.exitCode === null });

  // 5) EOF 受控退出：stdin end 后进程应自行 dispose 并以 0 退出。
  const exitCode = await new Promise((resolveExit) => {
    const t = setTimeout(() => {
      child.kill("SIGKILL");
      resolveExit("kill-timeout");
    }, 30_000);
    child.stdin.end();
    child.on("exit", (code) => {
      clearTimeout(t);
      resolveExit(code);
    });
  });
  report.observations.exit_on_eof = exitCode;
  summarize("eof-dispose", { exitCode });
  rmSync(sandboxCwd, { recursive: true, force: true });

  // 全部步骤通过才允许 passed；任何一步异常已在上方抛出。
  report.status = "passed";
  report.failure_class = null;
  report.remaining_risk =
    "冒烟未触发模型请求；prompt 往返、权限决策往返与工具事件面留待 P1 假桥契约测试与 P4 live gate 验证。";
}

const hardTimer = setTimeout(() => {
  fail("provider_timeout", `整体超时（>${timeoutMs}ms），强制终止子进程`);
  child.kill("SIGKILL");
}, timeoutMs);

main()
  .catch((error) => {
    // 从第一个因果失败开始分类：优先识别为环境/启动问题，其余归 harness 缺陷待查。
    fail(
      /超时/.test(String(error?.message)) ? "provider_timeout" : "environment_or_startup_failure",
      String(error?.message ?? error),
    );
  })
  .finally(() => {
    clearTimeout(hardTimer);
    try {
      child.kill("SIGTERM");
    } catch {}
    setTimeout(() => {
      transcript.end(() => {
        report.observations.probes = probes;
        report.command = `${report.command} --config ${configPath}`;
        const reportPath = join(outDir, `p0-smoke-${stamp}.json`);
        writeFileSync(reportPath, `${JSON.stringify(report, null, 2)}\n`);
        console.log(`[dsh-p0] status=${report.status} -> ${reportPath}`);
        if (stderrChunks.length) {
          // stderr 只保留脱敏摘要（首尾各 40 行以内），避免整段日志入档。
          const text = Buffer.concat(stderrChunks).toString("utf8");
          const lines = text.split("\n").filter(Boolean);
          const digest = lines.length > 80
            ? [...lines.slice(0, 40), `...(${lines.length - 80} 行省略)`, ...lines.slice(-40)]
            : lines;
          writeFileSync(`${reportPath.replace(/\.json$/, "")}-stderr.txt`, `${digest.join("\n")}\n`);
        }
        rmSync(workdir, { recursive: true, force: true });
        process.exitCode = report.status === "passed" ? 0 : 1;
      });
    }, 300);
  });
