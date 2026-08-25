#!/usr/bin/env node
// PERF-04 统一入口：执行固定样本的 Go 根因测试并生成长期脱敏报告。
// 本脚本不启动浏览器、Android 或真实 Provider，不能替代可见客户端性能验收。
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
  "^TestPERF04RelayCommandEventBackpressureBaseline$",
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
const match = output.match(/PERF04_METRICS=(\{[^\n]+\})/);
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
    suite: "perf-04",
    status: passed ? "passed" : "failed",
    real_browser: false,
    real_model: false,
    real_upstream: false,
    fixture_data: true,
    local_test: true,
    headless: false,
    command: command.join(" "),
    failure_class: passed ? null : metrics ? "product_defect" : "test_harness_defect",
    remaining_risk: "仅覆盖本机 SQLite 命令入队、事件持久化和进程内 Hub 背压；长列表/大 diff 可见渲染、真实网络、Provider 与设备性能留在独立 gate。",
  }),
  fixture_revision: "perf-04-v1",
  host: {
    platform: platform(),
    release: release(),
    arch: arch(),
    logical_cpu_count: cpus().length,
  },
  metrics: metrics || { parsed: false, exit_code: result.status },
};
const artifact = writeReport({ planId: "RELIABILITY-RELEASE", name: "perf-04", report });
process.stdout.write(`${output.trim()}\n`);
process.stdout.write(`PERF-04 report: ${artifact}\n`);
if (!passed) process.exit(1);
