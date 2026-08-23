#!/usr/bin/env node
// DSH transport gate runner（v0.5.next P4）。
// 口径：真实启动 dsh-acp-demo 桥做生命周期验证（real_upstream=true）；
// 真实模型 prompt 需用户单独授权后由 Go live gate 扩展执行——本 runner 只在
// AGENT_SESSIONS_DSH_LIVE=1 下驱动既有 TestLiveBridgeLifecycle 契约，
// 并如实输出报告；缺 bin/缺配置时 blocked（credential_or_quota_blocker 同类口径：
// environment/凭据类 blocker），绝不伪造 passed。
//
// 用法：node e2e-verify/real/dsh-transport.mjs [--dsh-root <path>]

import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";

const args = process.argv.slice(2);
const dshRoot = resolve(
  args[args.indexOf("--dsh-root") + 1] ??
    process.env.AGENT_SESSIONS_DSH_ROOT ??
    "/Users/yubi/code/deepseek-harness",
);
const repoRoot = resolve(import.meta.dirname, "../..");
const binPath =
  process.env.AGENT_SESSIONS_DSH_BIN ??
  join(dshRoot, "packages/examples/acp-demo/lib/bin.js");
const startedAt = new Date().toISOString();
const stamp = startedAt.replace(/[:.]/g, "-");
const outDir = resolve(repoRoot, "e2e-verify/reports/ADAPTER-DSH");
mkdirSync(outDir, { recursive: true });

// 报告骨架：字段对齐项目证据模板与 SKILL §0 口径。
const report = {
  suite: "adpt-dsh-transport",
  report_kind: "transport_gate",
  status: "failed",
  failure_class: null,
  real_browser: false,
  // 真实模型请求未包含在本 runner 内：授权后的 live prompt 扩展另行执行并覆盖此字段。
  real_model: false,
  real_upstream: true,
  fixture_data: false,
  local_test: true,
  headless: false,
  browser: "n/a",
  model: process.env.AGENT_SESSIONS_DSH_MODEL ?? "bridge-config",
  provider: "deepseek-harness-acp",
  credential_source: "none",
  command: "node e2e-verify/real/dsh-transport.mjs",
  request_ids: [],
  usage: { input_tokens: 0, output_tokens: 0 },
  artifacts: [],
  live_summary_present: false,
  failure_class_note: "",
  remaining_risk: "",
};

function finalize(extra = {}) {
  Object.assign(report, extra);
  const path = join(outDir, `p4-dsh-transport-${stamp}.json`);
  writeFileSync(path, `${JSON.stringify(report, null, 2)}\n`);
  report.artifacts.push(path);
  console.log(`[dsh-transport] status=${report.status} -> ${path}`);
  process.exitCode = report.status === "passed" ? 0 : 1;
}

// 前置检查：bin 与 cordis 配置必须存在，否则 fail-closed 为 blocked。
if (!existsSync(binPath)) {
  finalize({
    status: "blocked",
    failure_class: "environment_or_startup_failure",
    remaining_risk: `桥二进制不存在：${binPath}；provider 在 Daemon 侧同样会 fail-closed。如需启用请设置 AGENT_SESSIONS_DSH_BIN/AGENT_SESSIONS_DSH_CONFIG。`,
  });
} else if (process.env.AGENT_SESSIONS_DSH_REAL_MODEL !== "1") {
  // 未授权真实模型：按 SKILL 规则先交付可安全执行的本地范围，blocked 记录待办。
  finalize({
    status: "blocked",
    failure_class: "credential_or_quota_blocker",
    remaining_risk:
      "真实模型 prompt 需用户显式授权（设 AGENT_SESSIONS_DSH_REAL_MODEL=1 并确保 DSH 侧 LLM key 可用）。本报告只证明桥生命周期，不证明模型往返。",
  });
} else {
  // 授权路径：运行真实桥生命周期契约（握手/new/abort/dispose），后续可扩展真实 prompt。
  const res = spawnSync(
    "go",
    ["test", "./internal/adapter/dsh/", "-run", "TestLiveBridgeLifecycle", "-count=1", "-v"],
    { cwd: repoRoot, env: { ...process.env, AGENT_SESSIONS_DSH_LIVE: "1" }, encoding: "utf8", timeout: 300_000 },
  );
  const out = `${res.stdout ?? ""}${res.stderr ?? ""}`;
  report.live_summary_present = /LIVE_SUMMARY/.test(out) && res.status === 0;
  if (res.status === 0 && report.live_summary_present) {
    finalize({
      status: "passed",
      remaining_risk:
        "本 gate 证明真实桥生命周期（握手/建会话/取消/受控退出）；prompt 往返与 usage 投影需在扩展用例中消耗真实 token 后才能声明 real_model=true。",
    });
  } else {
    finalize({
      status: "failed",
      failure_class: res.status === 0 ? "model_contract_failure" : "test_harness_defect",
      failure_class_note: `exit=${res.status}`,
      remaining_risk: "LIVE_SUMMARY 缺失或用例失败；详见 go test 输出。",
    });
  }
}
