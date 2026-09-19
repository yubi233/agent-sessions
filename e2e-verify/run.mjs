#!/usr/bin/env node
// 默认 headed、无自动重试；--suite 可重复指定，最终全量门与定向诊断共用同一隔离方式。
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { buildRelay } from "./lib/relay.mjs";
import { writeReport, baseReport } from "./lib/report.mjs";
import { openSuiteEnvironment } from "./lib/suite-environment.mjs";
import { runSuites } from "./lib/runner.mjs";
import { registry } from "./lib/suites.mjs";

function parseArgs(argv) {
  const args = { headless: false, suites: [], retryLimit: 0 };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--headless") args.headless = true;
    else if (argv[i] === "--suite" && argv[i + 1]) args.suites.push(argv[++i]);
    else if (argv[i] === "--retry-environment-once") args.retryLimit = 1;
    else throw new Error(`未知或缺值参数：${argv[i]}`);
  }
  return args;
}

async function main() {
  const { headless, suites, retryLimit } = parseArgs(process.argv.slice(2));
  for (const id of suites) {
    if (!registry.some((suite) => suite.id === id)) throw new Error(`no suite matched: ${id}`);
  }
  const selected = registry.filter((suite) => suites.length === 0 || suites.includes(suite.id));
  const runId = new Date().toISOString().replace(/[:.]/g, "-");
  const revision = execFileSync("git", ["rev-parse", "HEAD"], { encoding: "utf8" }).trim();
  const diff = execFileSync("git", ["diff", "HEAD", "--", "apps", "internal", "packages", "e2e-verify", "Taskfile.yml"]);
  const source = { revision, dirty: diff.length > 0, diff_sha256: createHash("sha256").update(diff).digest("hex") };
  const started = Date.now();
  const build = await buildRelay();
  let summary;
  try {
    summary = await runSuites({
      suites: selected,
      headless,
      retryLimit,
      openEnvironment: (suite) => openSuiteEnvironment(suite, build.path),
      log: (text) => process.stdout.write(`${text}\n`),
      saveAttempt(payload) {
        const { planId, service_logs, ...rest } = payload;
        const path = writeReport({
          planId: planId || "E2E",
          name: `${payload.suite}-attempt-${payload.attempt}`,
          report: { ...baseReport(rest), ...rest, timestamp: runId, run_id: runId, source },
        });
        payload.report_path = path;
        if (service_logs) {
          // 日志也经过统一脱敏；不直接转储裸 stdout，避免报告旁路泄漏凭据。
          writeReport({ planId: planId || "E2E", name: `${payload.suite}-attempt-${payload.attempt}-services`, report: { timestamp: runId, run_id: runId, service_logs } });
          delete payload.service_logs;
        }
      },
    });
  } finally {
    build.stop();
  }
  const reportPath = writeReport({
    planId: "E2E",
    name: "summary",
    report: {
      timestamp: runId, run_id: runId, source,
      command: `node e2e-verify/run.mjs ${process.argv.slice(2).join(" ")}`.trim(),
      headless, local_test: true, real_model: false,
      retry_limit: retryLimit, duration_ms: Date.now() - started,
      ...summary,
    },
  });
  process.stdout.write(`\n== summary ==\n`);
  for (const result of summary.results) process.stdout.write(`  ${result.id}: ${result.status}${result.flaky ? " (retried/flaky)" : ""}\n`);
  process.stdout.write(`report: ${reportPath}\n`);
  process.exitCode = summary.status === "passed" ? 0 : 1;
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
