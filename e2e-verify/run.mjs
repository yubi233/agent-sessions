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
    // 场景自定义字段（如 opencode_observed 探测快照）原样透传，不作为敏感正文处理；
    // 字段由 report.mjs 的 sanitizeReport 统一脱敏后再落盘。
    const extras = Object.fromEntries(
      Object.entries(payload).filter(([key]) => !(key in base) && key !== "planId"),
    );
    // 将运行元信息与真实浏览器口径写入报告。
    // relay_base 优先采用场景自带的专用 Relay（如接真实 opencode serve 的实例），
    // 未提供时回退到共享 Relay，保证报告不误标本轮实际验证的服务地址。
    const full = { ...base, ...extras, relay_base: payload.relay_base || relay.base };
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
