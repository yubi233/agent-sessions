#!/usr/bin/env node
// 回归测试统一入口：启动隔离 Relay，按注册表运行 headed 真实浏览器场景，
// 汇总结果写入 e2e-verify/reports/<timestamp>/<plan_id>/。
// 用法：node e2e-verify/run.mjs [--suite <id>] [--headless]
import { startRelay } from "./lib/relay.mjs";
import { startWeb, startAdmin } from "./lib/web.mjs";
import { writeReport, baseReport } from "./lib/report.mjs";
import { createFixtureAccountFactory } from "./lib/fixture-account.mjs";
import { registry } from "./lib/suites.mjs";

function parseArgs(argv) {
  const args = { headless: false, suite: null };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--headless") args.headless = true;
    else if (argv[i] === "--suite") args.suite = argv[++i];
  }
  return args;
}

async function main() {
  const { headless, suite } = parseArgs(process.argv.slice(2));
  const selected = registry.filter((s) => !suite || s.id === suite);
  if (selected.length === 0) {
    console.error(`no suite matched: ${suite}`);
    process.exit(2);
  }

  // 启动隔离 Relay，供所有场景复用。
  const relay = await startRelay({ port: 8787 });
  const web = await startWeb({ relayBase: relay.base });
  const admin = await startAdmin({ port: 15174, relayBase: relay.base });
  const fixtureAccount = createFixtureAccountFactory(relay.base);
  const results = [];

  const report = (payload) => {
    const base = baseReport(payload);
    // 将运行元信息与真实浏览器口径写入报告。
    const full = { ...base, relay_base: relay.base };
    writeReport({ planId: payload.planId || "PROTO-CRYPTO", name: payload.suite, report: full });
    results.push({ id: payload.suite, status: payload.status });
    return full;
  };

  try {
    for (const scene of selected) {
      process.stdout.write(`[run] ${scene.id} (${scene.title})\n`);
      const r = await scene.run({ relay, web, admin, report, headless, fixtureAccount });
      process.stdout.write(`[run] ${scene.id} -> ${r.status}\n`);
    }
  } finally {
    await admin.stop();
    await web.stop();
    await relay.stop();
  }

  const failed = results.filter((r) => r.status !== "passed");
  process.stdout.write(`\n== summary ==\n`);
  for (const r of results) process.stdout.write(`  ${r.id}: ${r.status}\n`);
  if (failed.length > 0) process.exit(1);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
