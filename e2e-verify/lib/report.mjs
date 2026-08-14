// 统一报告写入：落在 e2e-verify/reports/<timestamp>/<plan_id>/<name>.json。
// 报告字段对齐自动化测试文档第 8 节与实施计划第 11 节，禁止写入正文/token/密钥。
import { mkdirSync, writeFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");

function timestamp() {
  return new Date().toISOString().replace(/[:.]/g, "-");
}

// 报告会长期归档，因此在落盘前统一移除常见凭据与正文类字段。
// 测试结果只需要状态、计数和脱敏摘要，不能把原始请求或应用内容当作证据保存。
const SENSITIVE_KEYS = /(api.?key|authorization|cookie|password|secret|token|private.?key|access.?key|refresh.?token|prompt|body|content|message|envelope)/i;
const ALLOWED_SENSITIVE_SHAPES = new Set([
  "credential_source",
  "request_ids",
  "usage",
  "input_tokens",
  "output_tokens",
  "target_mobile_content_size",
]);
const MAX_STRING_LENGTH = 2_000;

function sanitizeString(value) {
  const normalized = String(value)
    .replace(/(bearer\s+)[^\s"']+/gi, "$1[REDACTED]")
    .replace(/([?&](?:api[_-]?key|token|password|secret)=)[^&#\s"']+/gi, "$1[REDACTED]")
    .replace(/((?:api[_-]?key|token|password|secret)\s*[:=]\s*)[^\s,}"']+/gi, "$1[REDACTED]");
  return normalized.length > MAX_STRING_LENGTH
    ? `${normalized.slice(0, MAX_STRING_LENGTH)}...[TRUNCATED]`
    : normalized;
}

// sanitizeReport 只保留报告需要的结构化信息，递归处理扩展字段，防止未来场景误写敏感值。
export function sanitizeReport(value, key = "") {
  if (value == null || typeof value === "boolean" || typeof value === "number") return value;
  if (typeof value === "string") {
    return SENSITIVE_KEYS.test(key) && !ALLOWED_SENSITIVE_SHAPES.has(key)
      ? "[REDACTED]"
      : sanitizeString(value);
  }
  if (Array.isArray(value)) return value.map((item) => sanitizeReport(item, key));
  if (typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value).map(([entryKey, entryValue]) => [
        entryKey,
        SENSITIVE_KEYS.test(entryKey) && !ALLOWED_SENSITIVE_SHAPES.has(entryKey)
          ? "[REDACTED]"
          : sanitizeReport(entryValue, entryKey),
      ]),
    );
  }
  return sanitizeString(value);
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
  writeFileSync(file, JSON.stringify(sanitizeReport(body), null, 2) + "\n", "utf-8");
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
  browser = "n/a",
  model = "n/a",
  provider = "n/a",
  credential_source = "none",
  request_ids = [],
  usage = { input_tokens: 0, output_tokens: 0 },
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
    model,
    provider,
    credential_source,
    request_ids,
    usage,
    artifacts,
    failure_class,
    remaining_risk,
  };
}

// reportRoot 返回报告根目录，供清理/归档使用。
export function reportRoot() {
  return join(ROOT, "reports");
}
