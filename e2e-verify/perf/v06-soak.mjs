#!/usr/bin/env node
// v0.6 P3 受限 soak 诊断统一入口：执行固定并发样本的 Go 根因测试并生成长期脱敏报告。
// 本脚本不启动浏览器、Android 或真实 Provider；它只证明单租户本地 SQLite 架构在
// 受限并发下的正确性（无 5xx、无 outbox 失败行、积压可解释），不是生产性能验收。
import { spawnSync } from "node:child_process";
import { arch, cpus, platform, release } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { baseReport, writeReport } from "../lib/report.mjs";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const command = [
  "go",
  "test",
  "./internal/relay",
  "-run",
  "^TestV06SoakSQLiteConcurrencyAndOutboxBacklog$",
  "-count=1",
  "-v",
];

const result = spawnSync(command[0], command.slice(1), {
  cwd: ROOT,
  encoding: "utf8",
  env: {
    PATH: process.env.PATH || "",
    HOME: process.env.HOME || "",
    TMPDIR: process.env.TMPDIR || "",
    GOCACHE: process.env.GOCACHE || "",
    GOPATH: process.env.GOPATH || "",
    GIN_MODE: "release",
  },
});
const output = `${result.stdout || ""}\n${result.stderr || ""}`;
const match = output.match(/V06_SOAK_METRICS=(\{[^\n]+\})/);
let metrics = null;
if (match) {
  try {
    metrics = JSON.parse(match[1]);
  } catch {
    metrics = null;
  }
}
const passed = result.status === 0 && metrics !== null;
const report = {
  ...baseReport({
    suite: "v06-soak",
    status: passed ? "passed" : result.status === 0 ? "incomplete" : "failed",
    real_browser: false,
    real_model: false,
    real_upstream: false,
    fixture_data: true,
    local_test: true,
    headless: false,
    command: command.join(" "),
    failure_class: passed ? null : metrics ? "product_defect" : "environment_or_startup_failure",
    remaining_risk:
      "受限并发诊断：6 worker × 12 命令 × 每命令 2 密文事件。只证明无 5xx、outbox 不丢行不失败与延迟分位观测；" +
      "不代表生产负载、多实例扩展能力或真实 Provider 性能。SQLite busy/锁等待以错误计数间接体现。",
  }),
  fixture_revision: "v06-soak-v1",
  host: {
    platform: platform(),
    release: release(),
    arch: arch(),
    cpu_count: cpus().length,
  },
  metrics,
};
const path = writeReport({ planId: "RELIABILITY-RELEASE", name: "v06-soak", report });
console.log(`v06-soak ${report.status}; report: ${path}`);
if (!passed) {
  process.exitCode = 1;
}
