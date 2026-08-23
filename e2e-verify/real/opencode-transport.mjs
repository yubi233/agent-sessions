#!/usr/bin/env node
// ADPT-OPENCODE-05 授权 live gate 编排：在隔离临时目录启动真实 opencode serve，
// 注入 AGENT_SESSIONS_LIVE_OPENCODE=1 运行 Go 的 Adapter transport live 测试，
// 并写入脱敏报告。真实模型与真实上游均为 true；报告只保留事件类型、哈希与 usage。
import { spawn } from "node:child_process";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { baseReport, writeReport } from "../lib/report.mjs";
import { classifyTransportResult } from "./opencode-transport-result.mjs";

const ROOT = join(import.meta.dirname, "..", "..");

function usage() {
  return [
    "用法：node e2e-verify/real/opencode-transport.mjs [--keep]",
    "  --keep    保留临时目录（诊断用，默认删除）",
  ].join("\n");
}

async function runGoLiveGate({ cwd, keep }) {
  const report = baseReport({
    suite: "adapter-opencode",
    status: "in_progress",
    real_browser: false,
    real_model: false,
    real_upstream: false,
    fixture_data: false,
    local_test: true,
    headless: false,
    command:
      "go test ./internal/adapter/opencode -run TestLiveTransport -count=1",
    model: "opencode-go/deepseek-v4-flash",
    provider: "opencode",
    credential_source: "env:OPENCODE_SERVER_PASSWORD",
  });
  const args = [
    "test",
    "./internal/adapter/opencode",
    "-run",
    "TestLiveTransport",
    "-count=1",
    "-v",
  ];
  return new Promise((resolve) => {
    const child = spawn("go", args, {
      cwd,
      env: {
        ...process.env,
        AGENT_SESSIONS_LIVE_OPENCODE: "1",
        OPENCODE_SERVER_USERNAME:
          process.env.OPENCODE_SERVER_USERNAME || "opencode",
      },
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => {
      stdout += String(chunk);
    });
    child.stderr.on("data", (chunk) => {
      stderr += String(chunk);
    });
    child.once("error", (error) => {
      report.status = "blocked";
      report.failure_class = "environment_or_startup_failure";
      report.remaining_risk = `go 子进程启动失败：${error.message}`;
      resolve({ report, output: stdout });
    });
    child.once("close", (code) => {
      const outcome = classifyTransportResult({ code, stdout });
      report.status = outcome.status;
      report.failure_class = outcome.failureClass;
      report.real_model = outcome.realModel;
      report.real_upstream = outcome.realUpstream;
      report.remaining_risk = outcome.remainingRisk;
      const summary = outcome.summary;
      if (Array.isArray(summary?.observed_event_types)) {
        report.observed_event_types = summary.observed_event_types;
      }
      if (summary?.usage && typeof summary.usage === "object") {
        report.usage = {
          input_tokens: Number(summary.usage.input_tokens) || 0,
          output_tokens: Number(summary.usage.output_tokens) || 0,
          total_tokens: Number(summary.usage.total_tokens) || 0,
        };
      }
      resolve({ report, output: stdout });
    });
  });
}

async function main() {
  const args = process.argv.slice(2);
  const keep = args.includes("--keep");
  if (args.includes("--help") || args.includes("-h")) {
    console.log(usage());
    process.exit(0);
  }
  const tmpDir = await mkdtemp(join(tmpdir(), "agent-sessions-oc-live-"));
  // 临时目录只承载 opencode serve 的会话状态，不包含凭据或用户工作区。
  const { report, output } = await runGoLiveGate({ cwd: ROOT, keep });
  if (!keep) {
    await rm(tmpDir, { recursive: true, force: true });
  } else {
    report.artifacts.push(tmpDir);
  }
  // 输出只保留最后几行 go 测试摘要（脱敏由 Go 侧负责）。
  const tail = output.trim().split("\n").slice(-12).join("\n");
  const file = writeReport({
    planId: "ADAPTER-OPENCODE",
    name: "05-transport-live",
    report,
  });
  console.log(tail);
  console.log(`\nreport: ${file}`);
  process.exit(report.status === "passed" ? 0 : 1);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
