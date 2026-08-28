#!/usr/bin/env node
// v0.7/P3 Zen 免费模型真实 smoke（测试 ID：V07-05）。
// 入口只允许在显式授权后启动真实服务；报告使用统一 sanitizer，永不落盘
// prompt、回复正文、凭据、完整会话 ID 或本机工作区路径。
import { baseReport, writeReport } from "../lib/report.mjs";
import {
  V07HarnessError,
  classifyHarnessError,
  runZenSessionSmoke,
} from "./v07-harness.mjs";

const PLAN_ID = "V07-RELEASE";
const SUITE = "v07-zen-smoke";
const COMMAND = "node e2e-verify/real/v07-zen-smoke.mjs";

function usage() {
  return [
    "用法：AGENT_SESSIONS_ZEN_REAL=1 node e2e-verify/real/v07-zen-smoke.mjs [选项]",
    "  --model <provider/id>  只在动态发现目录包含该模型时使用",
    "  --timeout-ms <ms>     单轮真实回合超时，默认 180000",
    "  --keep                保留 harness 临时目录（仅诊断）",
  ].join("\n");
}

function positiveInteger(value, flag) {
  const parsed = Number.parseInt(value, 10);
  if (!Number.isInteger(parsed) || parsed <= 0) {
    throw new V07HarnessError(`${flag} 必须是正整数。`, { failureClass: "test_harness_defect" });
  }
  return parsed;
}

export function parseZenSmokeArgs(argv) {
  const args = { help: false, keep: false, model: "", timeoutMs: 180_000 };
  for (let index = 0; index < argv.length; index += 1) {
    const value = argv[index];
    if (value === "--help" || value === "-h") args.help = true;
    else if (value === "--keep") args.keep = true;
    else if (value === "--model") args.model = argv[++index] || "";
    else if (value === "--timeout-ms") args.timeoutMs = positiveInteger(argv[++index], "--timeout-ms");
    else throw new V07HarnessError(`未知参数：${value}`, { failureClass: "test_harness_defect" });
  }
  return args;
}

function initialReport(args) {
  return baseReport({
    suite: SUITE,
    status: "in_progress",
    real_browser: false,
    real_model: false,
    real_upstream: false,
    fixture_data: false,
    local_test: false,
    headless: false,
    command: `${COMMAND}${args.model ? ` --model ${args.model}` : ""}`,
    browser: "n/a",
    model: args.model || "dynamic-free-model",
    provider: "opencode",
    // Zen key 只由 OpenCode 本机认证配置读取，Node/Relay/Daemon 不接触 key。
    credential_source: "opencode-local-auth",
  });
}

function printOutcome(file, report) {
  // 标准输出只报告状态、分类、模型摘要和报告路径；不输出 harness 错误正文。
  const model = typeof report.model === "string" ? report.model : "dynamic-free-model";
  console.log(`v07 Zen smoke: ${report.status} model=${model} failure_class=${report.failure_class || "none"}`);
  console.log(`report: ${file}`);
}

export async function runZenSmoke(args = parseZenSmokeArgs([]), {
  run = runZenSessionSmoke,
  write = writeReport,
  zenEnabled = process.env.AGENT_SESSIONS_ZEN_REAL === "1",
} = {}) {
  const report = initialReport(args);
  if (!zenEnabled) {
    // 没有显式授权时绝不启动 OpenCode/Relay，也不消耗真实模型额度。
    report.status = "blocked";
    report.failure_class = "credential_or_quota_blocker";
    report.remaining_risk = "未设置 AGENT_SESSIONS_ZEN_REAL=1；真实 Zen smoke 未执行。";
    const file = write({ planId: PLAN_ID, name: "V07-05", report });
    return { exitCode: 2, file, report };
  }

  try {
    const result = await run({
      model: args.model,
      timeoutMs: args.timeoutMs,
      keepArtifacts: args.keep,
    });
    Object.assign(report, result.report || {});
    report.status = "passed";
    report.real_model = true;
    report.real_upstream = true;
    report.fixture_data = false;
    report.local_test = false;
    report.failure_class = null;
    report.remaining_risk = "单会话单轮 smoke 通过；多会话、多模型随机问答由 V07-06 full gate 验证。";
    const file = write({ planId: PLAN_ID, name: "V07-05", report });
    return { exitCode: 0, file, report };
  } catch (error) {
    const outcome = classifyHarnessError(error);
    if (error?.report && typeof error.report === "object") Object.assign(report, error.report);
    report.status = outcome.status;
    report.failure_class = outcome.failure_class;
    report.remaining_risk = outcome.remaining_risk;
    // 只有 harness 已经产生请求尝试时，才把 real_model/upstream 标成 true；
    // 凭证/目录阻塞停在本地发现阶段，必须保持 false。
    const attempts = Number(report.request_attempts) || 0;
    report.real_model = attempts > 0;
    report.real_upstream = attempts > 0;
    report.fixture_data = false;
    report.local_test = false;
    const file = write({ planId: PLAN_ID, name: "V07-05", report });
    return { exitCode: 1, file, report };
  }
}

async function main() {
  let args;
  try {
    args = parseZenSmokeArgs(process.argv.slice(2));
    if (args.help) {
      console.log(usage());
      return;
    }
    const outcome = await runZenSmoke(args);
    printOutcome(outcome.file, outcome.report);
    process.exitCode = outcome.exitCode;
  } catch (error) {
    // 参数/runner 基础设施错误也写一条结构化报告，避免只留下不可审计 stderr。
    const report = initialReport(args || { model: "" });
    const classified = classifyHarnessError(error);
    report.status = classified.status;
    report.failure_class = classified.failure_class;
    report.remaining_risk = classified.remaining_risk;
    const file = writeReport({ planId: PLAN_ID, name: "V07-05", report });
    printOutcome(file, report);
    process.exitCode = 1;
  }
}

if (import.meta.url === `file://${process.argv[1]}`) await main();
