#!/usr/bin/env node
// v0.7/P4 headed Web 只读验收（V07-08）。
// 真实浏览器、Vite Web 和隔离 Relay 均由本脚本创建；默认拒绝 headless，
// 避免把无界面快速回归误标为用户可见验收。数据仍是本地 fixture，不能冒充真实模型。
import { baseReport, writeReport } from "../lib/report.mjs";
import { createFixtureAccountFactory } from "../lib/fixture-account.mjs";
import { startRelay } from "../lib/relay.mjs";
import { startWeb } from "../lib/web.mjs";
import { p4WebReadonly } from "./p4-web-readonly.mjs";

function parseArgs(argv) {
  const args = { headless: false };
  for (const value of argv) {
    if (value === "--headless") args.headless = true;
    else if (value === "--help" || value === "-h") args.help = true;
    else throw new Error(`未知参数：${value}`);
  }
  if (String(process.env.HEADLESS || "").toLowerCase() === "true") args.headless = true;
  return args;
}

export async function runV07HeadedReadonly({ headless = false, write = writeReport } = {}) {
  if (headless) {
    const report = baseReport({
      suite: "v07-headed-readonly",
      status: "failed",
      real_browser: false,
      real_model: false,
      real_upstream: false,
      fixture_data: true,
      local_test: true,
      headless: true,
      browser: "chromium-headless",
      model: "n/a",
      provider: "n/a",
      command: "node e2e-verify/suites/v07-headed-readonly.mjs",
      failure_class: "test_harness_defect",
      remaining_risk: "V07-08 要求 headed 浏览器；拒绝 headless 执行。",
    });
    const file = write({ planId: "V07-RELEASE", name: "V07-08", report });
    return { exitCode: 1, file, report };
  }

  let relay;
  let web;
  let written;
  try {
    relay = await startRelay();
    web = await startWeb({ relayBase: relay.base });
    const report = (payload) => {
      const full = baseReport({
        suite: "v07-headed-readonly",
        status: payload.status,
        real_browser: true,
        real_model: false,
        real_upstream: false,
        fixture_data: true,
        local_test: true,
        headless: false,
        browser: payload.browser || "system-chrome",
        model: "n/a",
        provider: "local-relay-fixture",
        command: "node e2e-verify/suites/v07-headed-readonly.mjs",
        failure_class: payload.failure_class || null,
        remaining_risk: payload.remaining_risk || "",
        artifacts: payload.artifacts || [],
      });
      const extras = Object.fromEntries(Object.entries(payload).filter(([key]) => !(key in full)));
      written = write({ planId: "V07-RELEASE", name: "V07-08", report: { ...full, ...extras } });
      return { ...full, ...extras };
    };
    const result = await p4WebReadonly.run({
      relay,
      web,
      report,
      headless: false,
      fixtureAccount: createFixtureAccountFactory(relay.base),
    });
    const reportResult = written ? result : report(result);
    return { exitCode: reportResult.status === "passed" ? 0 : 1, file: written, report: reportResult };
  } catch (error) {
    const report = baseReport({
      suite: "v07-headed-readonly",
      status: "failed",
      real_browser: false,
      real_model: false,
      real_upstream: false,
      fixture_data: true,
      local_test: true,
      headless: false,
      browser: "system-chrome",
      model: "n/a",
      provider: "local-relay-fixture",
      command: "node e2e-verify/suites/v07-headed-readonly.mjs",
      failure_class: "environment_or_startup_failure",
      remaining_risk: "headed Web 进程或浏览器启动失败，需检查本机窗口权限与依赖。",
      artifacts: [],
    });
    const file = write({ planId: "V07-RELEASE", name: "V07-08", report: {
      ...report,
      error_summary: String(error instanceof Error ? error.message : error).slice(0, 400),
    } });
    return { exitCode: 1, file, report };
  } finally {
    await web?.stop().catch(() => {});
    await relay?.stop().catch(() => {});
  }
}

async function main() {
  try {
    const args = parseArgs(process.argv.slice(2));
    if (args.help) {
      console.log("用法：HEADLESS=false node e2e-verify/suites/v07-headed-readonly.mjs");
      return;
    }
    const result = await runV07HeadedReadonly(args);
    console.log(`v07 headed readonly: ${result.report.status} failure_class=${result.report.failure_class || "none"}`);
    console.log(`report: ${result.file}`);
    process.exitCode = result.exitCode;
  } catch (error) {
    console.error(`v07 headed readonly: ${error instanceof Error ? error.message : String(error)}`);
    process.exitCode = 1;
  }
}

if (import.meta.url === `file://${process.argv[1]}`) await main();
