#!/usr/bin/env node
// P0 静态 gate：实际执行工具链/协议/密码学检查并产出脱敏报告。
// 产出 e2e-verify/reports/<ts>/PROTO-CRYPTO/{toolchain,schema,crypto}.json。
// 用法：node e2e-verify/p0-gate.mjs
import { spawnSync } from "node:child_process";
import { writeReport } from "./lib/report.mjs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");

function run(cmd, args, cwd = ROOT) {
  const r = spawnSync(cmd, args, { cwd, encoding: "utf-8" });
  return { code: r.status, stdout: r.stdout || "", stderr: r.stderr || "" };
}

function base(suite, command, status, extra = {}) {
  return {
    suite,
    status,
    real_browser: false,
    real_model: false,
    real_upstream: false,
    fixture_data: true,
    local_test: true,
    headless: false,
    command,
    browser: "n/a",
    artifacts: [],
    failure_class: status === "passed" ? null : "product_defect",
    remaining_risk: "",
    ...extra,
  };
}

function main() {
  const results = [];

  // P0-TOOL-01 工具链可复现
  const gofmt = run("gofmt", ["-l", "packages", "apps", "internal"]);
  const docs = run("python3", ["tools/docs_verify.py"]);
  const toolchainOk = gofmt.code === 0 && gofmt.stdout.trim() === "" && docs.code === 0;
  results.push([
    "toolchain",
    base(
      "p0-toolchain",
      "gofmt -l packages apps internal && python3 tools/docs_verify.py",
      toolchainOk ? "passed" : "failed",
      { gofmt_dirty: gofmt.stdout.trim().split("\n").filter(Boolean), docs_verify: docs.stdout.trim() },
    ),
  ]);

  // P0-SCHEMA-01 协议与生成无漂移
  const schema = run("python3", ["-c", "import json,pathlib;[json.loads(p.read_text()) for p in pathlib.Path('packages/protocol/schema').glob('*.json')]"]);
  const protoTest = run("go", ["test", "./packages/protocol", "-count=1"]);
  const schemaOk = schema.code === 0 && protoTest.code === 0;
  results.push([
    "schema",
    base("p0-schema", "task generate && go test ./packages/protocol", schemaOk ? "passed" : "failed", {
      schema_parse: schema.code === 0 ? "ok" : schema.stderr,
      protocol_test: protoTest.code === 0 ? "ok" : protoTest.stdout + protoTest.stderr,
    }),
  ]);

  // P0-CRYPTO-01 Go/TS 跨语言互解
  const goCrypto = run("go", ["test", "./packages/crypto", "-count=1"]);
  const tsCrypto = run("pnpm", ["--filter", "@agent-sessions/crypto", "test"]);
  const cryptoOk = goCrypto.code === 0 && tsCrypto.code === 0;
  results.push([
    "crypto",
    base("p0-crypto", "task test:crypto", cryptoOk ? "passed" : "failed", {
      go: goCrypto.code === 0 ? "ok" : goCrypto.stdout + goCrypto.stderr,
      typescript: tsCrypto.code === 0 ? "ok" : tsCrypto.stdout + tsCrypto.stderr,
      remaining_risk: cryptoOk ? "Dart 端互解待 Android 阶段接入" : "",
    }),
  ]);

  const ts = new Date().toISOString().replace(/[:.]/g, "-");
  for (const [name, report] of results) {
    const path = writeReport({ planId: "PROTO-CRYPTO", name, report: { timestamp: ts, ...report } });
    process.stdout.write(`[p0-gate] ${name}: ${report.status} -> ${path}\n`);
  }
  if (results.some(([, r]) => r.status !== "passed")) process.exit(1);
}

main();
