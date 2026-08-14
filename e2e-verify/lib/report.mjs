// 统一报告写入：落在 e2e-verify/reports/<timestamp>/<plan_id>/<name>.json。
// 报告字段对齐自动化测试文档第 8 节与实施计划第 11 节，禁止写入正文/token/密钥。
import { mkdirSync, writeFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");

function timestamp() {
  return new Date().toISOString().replace(/[:.]/g, "-");
}

// writeReport 写入一条脱敏报告并返回其磁盘路径。
export function writeReport({ planId, name, report }) {
  const ts = report.timestamp || timestamp();
  const dir = join(ROOT, "reports", ts, planId);
  mkdirSync(dir, { recursive: true });
  const file = join(dir, `${name}.json`);
  const body = {
    timestamp: ts,
    plan_id: planId,
    ...report,
  };
  writeFileSync(file, JSON.stringify(body, null, 2) + "\n", "utf-8");
  return file;
}

// baseReport 构造一条满足最小字段集合的脱敏报告骨架。
export function baseReport({
  suite,
  status,
  real_browser,
  real_model = false,
  real_upstream = false,
  fixture_data = false,
  local_test = true,
  headless = false,
  command,
  browser,
  artifacts = [],
  failure_class = null,
  remaining_risk = "",
}) {
  return {
    suite,
    status,
    real_browser,
    real_model,
    real_upstream,
    fixture_data,
    local_test,
    headless,
    command,
    browser,
    artifacts,
    failure_class,
    remaining_risk,
  };
}

// reportRoot 返回报告根目录，供清理/归档使用。
export function reportRoot() {
  return join(ROOT, "reports");
}
