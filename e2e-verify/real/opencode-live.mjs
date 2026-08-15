#!/usr/bin/env node
// 经用户授权的 OpenCode 真实模型门禁：只验证受控临时目录中的会话与结构化响应，
// 不把原始 prompt、模型回复、凭据或会话标识写入报告和标准输出。
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { StringDecoder } from "node:string_decoder";

import { baseReport, writeReport } from "../lib/report.mjs";

export const OPENCODE_PROVIDER = "opencode";
export const OPENCODE_LIVE_MODEL = "opencode-go/deepseek-v4-flash";
export const MAX_PROVIDER_RETRIES = 3;
const DEFAULT_TIMEOUT_MS = 10 * 60 * 1000;

export class OpenCodeLiveError extends Error {
  constructor(message, { details = null, failureClass = "test_harness_defect" } = {}) {
    super(message);
    this.details = details;
    this.failureClass = failureClass;
  }
}

function positiveInteger(value, flag) {
  const parsed = Number.parseInt(value, 10);
  if (!Number.isInteger(parsed) || parsed <= 0) {
    throw new OpenCodeLiveError(`${flag} 必须是正整数。`);
  }
  return parsed;
}

function nonNegativeInteger(value, flag) {
  const parsed = Number.parseInt(value, 10);
  if (!Number.isInteger(parsed) || parsed < 0) {
    throw new OpenCodeLiveError(`${flag} 必须是非负整数。`);
  }
  return parsed;
}

// 真实 Provider 调用最多只在连接层可恢复错误时重试；模型输出不符合契约不能靠重试标绿。
export function parseOpenCodeLiveArgs(argv) {
  const args = {
    help: false,
    model: OPENCODE_LIVE_MODEL,
    provider: OPENCODE_PROVIDER,
    retries: MAX_PROVIDER_RETRIES,
    timeoutMs: DEFAULT_TIMEOUT_MS,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const value = argv[index];
    if (value === "--help" || value === "-h") args.help = true;
    else if (value === "--provider") args.provider = argv[++index] || "";
    else if (value === "--model") args.model = argv[++index] || "";
    else if (value === "--retries") {
      args.retries = nonNegativeInteger(argv[++index], "--retries");
    } else if (value === "--timeout-ms") {
      args.timeoutMs = positiveInteger(argv[++index], "--timeout-ms");
    } else if (value === "--headless") {
      throw new OpenCodeLiveError(
        "OpenCode live smoke 不接受 --headless；它不是浏览器验收入口。",
      );
    } else {
      throw new OpenCodeLiveError(`未知参数：${value}`);
    }
  }
  if (!args.help && args.provider !== OPENCODE_PROVIDER) {
    throw new OpenCodeLiveError(
      `当前真实门禁只实现 ${OPENCODE_PROVIDER}，收到 ${args.provider || "空 provider"}。`,
    );
  }
  if (!args.help && !args.model.includes("/")) {
    throw new OpenCodeLiveError("--model 必须使用 provider/model 格式。");
  }
  if (args.retries > MAX_PROVIDER_RETRIES) {
    throw new OpenCodeLiveError(
      `--retries 不能超过 ${MAX_PROVIDER_RETRIES}。`,
    );
  }
  return args;
}

export function openCodeLiveUsage() {
  return [
    "用法：task test:real -- --provider opencode --model opencode-go/deepseek-v4-flash",
    "  --provider opencode    当前唯一实现的真实 Provider",
    `  --model <provider/model> 默认 ${OPENCODE_LIVE_MODEL}`,
    `  --retries <0-${MAX_PROVIDER_RETRIES}> 可恢复 Provider 错误的最大重试次数，默认 ${MAX_PROVIDER_RETRIES}`,
    "  --timeout-ms <ms>      单次调用的超时保护；不限制模型 token",
  ].join("\n");
}

function stripAnsi(value) {
  return String(value).replace(/\x1B\[[0-?]*[ -/]*[@-~]/g, "");
}

function safeSummary(value) {
  return stripAnsi(value)
    .replace(/(bearer\s+)[^\s"']+/gi, "$1[REDACTED]")
    .replace(/([?&](?:api[_-]?key|token|password|secret)=)[^&#\s"']+/gi, "$1[REDACTED]")
    .replace(/((?:api[_-]?key|token|password|secret)\s*[:=]\s*)[^\s,}"']+/gi, "$1[REDACTED]")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 600);
}

function hash(value) {
  return createHash("sha256").update(value).digest("hex");
}

// 子进程只接收运行 OpenCode 所需的路径与语言环境，不把不相关 shell 凭据继承给测试进程。
function safeOpenCodeEnvironment() {
  const names = [
    "HOME",
    "LANG",
    "LC_ALL",
    "PATH",
    "TMPDIR",
    "XDG_CACHE_HOME",
    "XDG_CONFIG_HOME",
    "XDG_DATA_HOME",
  ];
  return Object.fromEntries(
    names
      .filter((name) => typeof process.env[name] === "string")
      .map((name) => [name, process.env[name]]),
  );
}

function commandResult(file, args, { cwd, timeoutMs }) {
  return new Promise((resolveResult) => {
    let timedOut = false;
    let spawnFailure = null;
    let stdout = "";
    let stderr = "";
    const child = spawn(file, args, {
      cwd,
      env: safeOpenCodeEnvironment(),
      stdio: ["ignore", "pipe", "pipe"],
    });
    const timer = setTimeout(() => {
      timedOut = true;
      child.kill("SIGTERM");
    }, timeoutMs);
    child.stdout.on("data", (chunk) => {
      stdout += String(chunk);
    });
    child.stderr.on("data", (chunk) => {
      stderr += String(chunk);
    });
    child.once("error", (error) => {
      spawnFailure = error;
    });
    child.once("close", (code, signal) => {
      clearTimeout(timer);
      resolveResult({
        code,
        signal,
        spawnFailure,
        stderr,
        stdout,
        timedOut,
      });
    });
  });
}

async function discoverModel(model, timeoutMs) {
  const result = await commandResult("opencode", ["models"], {
    cwd: process.cwd(),
    timeoutMs,
  });
  if (result.spawnFailure != null) {
    throw new OpenCodeLiveError("无法启动本机 opencode CLI。", {
      failureClass: "environment_or_startup_failure",
    });
  }
  if (result.timedOut || result.code !== 0) {
    throw new OpenCodeLiveError("opencode models 未能完成模型发现。", {
      failureClass: "environment_or_startup_failure",
    });
  }
  const listed = stripAnsi(result.stdout)
    .split(/\r?\n/)
    .map((line) => line.trim())
    .includes(model);
  if (!listed) {
    throw new OpenCodeLiveError(`OpenCode 未声明目标模型：${model}。`, {
      failureClass: "credential_or_quota_blocker",
    });
  }
  return {
    inventory_sha256: hash(stripAnsi(result.stdout)),
    model_discovered: true,
  };
}

function directAssistantRole(value) {
  if (value == null || typeof value !== "object") return false;
  const candidates = [
    value.role,
    value.info?.role,
    value.message?.role,
    value.part?.role,
  ];
  return candidates.some((role) => String(role).toLowerCase() === "assistant");
}

function collectSchema(value, output, depth = 0) {
  if (value == null || depth > 8) return;
  if (Array.isArray(value)) {
    for (const item of value) collectSchema(item, output, depth + 1);
    return;
  }
  if (typeof value !== "object") return;
  for (const [key, item] of Object.entries(value)) {
    output.keys.add(key);
    if (key === "type" && typeof item === "string") output.types.add(item);
    collectSchema(item, output, depth + 1);
  }
}

function collectUsage(value, usage, depth = 0) {
  if (value == null || depth > 8) return;
  if (Array.isArray(value)) {
    for (const item of value) collectUsage(item, usage, depth + 1);
    return;
  }
  if (typeof value !== "object") return;
  for (const [key, item] of Object.entries(value)) {
    const normalized = key.toLowerCase().replace(/[^a-z]/g, "");
    if (typeof item === "number" && Number.isFinite(item)) {
      if (normalized === "inputtokens" || normalized === "input") {
        usage.inputTokens = Math.max(usage.inputTokens, item);
        usage.observed = true;
      }
      if (normalized === "outputtokens" || normalized === "output") {
        usage.outputTokens = Math.max(usage.outputTokens, item);
        usage.observed = true;
      }
    }
    collectUsage(item, usage, depth + 1);
  }
}

function collectRequestIdentifiers(value, identifiers, depth = 0) {
  if (value == null || depth > 8) return;
  if (Array.isArray(value)) {
    for (const item of value) collectRequestIdentifiers(item, identifiers, depth + 1);
    return;
  }
  if (typeof value !== "object") return;
  for (const [key, item] of Object.entries(value)) {
    if (
      typeof item === "string" &&
      /^(request|session)[_-]?id$/i.test(key) &&
      item.length > 0
    ) {
      identifiers.add(`sha256:${hash(item).slice(0, 16)}`);
    }
    collectRequestIdentifiers(item, identifiers, depth + 1);
  }
}

function collectAssistantText(value, output, inAssistant = false, depth = 0) {
  if (value == null || depth > 8) return;
  if (Array.isArray(value)) {
    for (const item of value) {
      collectAssistantText(item, output, inAssistant, depth + 1);
    }
    return;
  }
  if (typeof value !== "object") return;
  // OpenCode 1.17 的 JSON CLI 将最终回复拆为顶层 text event，
  // 不重复 role 字段；该 event 不是用户 prompt 回显，故可作为受控模型文本读取。
  const assistant =
    inAssistant ||
    directAssistantRole(value) ||
    String(value.type || "").toLowerCase() === "text";
  for (const [key, item] of Object.entries(value)) {
    if (
      assistant &&
      typeof item === "string" &&
      /^(text|content|delta)$/i.test(key)
    ) {
      output.fragments.push(item);
      output.assistantTextObserved = true;
      continue;
    }
    collectAssistantText(item, output, assistant, depth + 1);
  }
}

// OpenCode 的 JSON event 格式会随版本演进，因此记录事件类型/字段集合而非原始回复，
// 并只从带 assistant role 的事件提取契约文本，避免把用户 prompt 当作模型回答。
export function observeJsonEvents(stdout) {
  const decoder = new StringDecoder("utf8");
  const output = {
    assistantTextObserved: false,
    fragments: [],
    identifiers: new Set(),
    keys: new Set(),
    parsedLines: 0,
    totalLines: 0,
    types: new Set(),
    usage: { inputTokens: 0, observed: false, outputTokens: 0 },
  };
  let remainder = "";
  const consume = (line) => {
    const trimmed = line.trim();
    if (trimmed.length === 0) return;
    output.totalLines += 1;
    try {
      const event = JSON.parse(trimmed);
      output.parsedLines += 1;
      collectSchema(event, output);
      collectUsage(event, output.usage);
      collectRequestIdentifiers(event, output.identifiers);
      collectAssistantText(event, output);
    } catch {
      // 非 JSON 行只是 CLI 的本地进度信息；不作为模型响应或报告正文保存。
    }
  };
  const append = (chunk) => {
    remainder += decoder.write(chunk);
    let newline = remainder.indexOf("\n");
    while (newline >= 0) {
      consume(remainder.slice(0, newline));
      remainder = remainder.slice(newline + 1);
      newline = remainder.indexOf("\n");
    }
  };
  append(stdout);
  remainder += decoder.end();
  consume(remainder);
  return {
    assistant_text: output.fragments.join(""),
    assistant_text_observed: output.assistantTextObserved,
    event_keys: [...output.keys].sort(),
    event_types: [...output.types].sort(),
    parsed_lines: output.parsedLines,
    request_ids: [...output.identifiers].sort(),
    total_lines: output.totalLines,
    usage: output.usage,
  };
}

function parseJsonResponse(text) {
  const normalized = String(text)
    .trim()
    .replace(/^```(?:json)?\s*/i, "")
    .replace(/\s*```$/i, "")
    .trim();
  if (!normalized.startsWith("{") || !normalized.endsWith("}")) {
    throw new OpenCodeLiveError("模型没有返回单个 JSON 对象。", {
      failureClass: "model_contract_failure",
    });
  }
  try {
    return JSON.parse(normalized);
  } catch {
    throw new OpenCodeLiveError("模型返回的 JSON 无法解析。", {
      failureClass: "model_contract_failure",
    });
  }
}

export function validateArithmeticResponse(text) {
  const response = parseJsonResponse(text);
  if (response.sum !== 42) {
    throw new OpenCodeLiveError("模型未满足最小算术响应契约。", {
      failureClass: "model_contract_failure",
    });
  }
  return { arithmetic_verified: true };
}

export function validateComparisonResponse(text) {
  const response = parseJsonResponse(text);
  const allowed = new Set(["provider_transport", "voice", "social"]);
  if (!allowed.has(response.highest_priority_gap)) {
    throw new OpenCodeLiveError("模型未返回可识别的功能差距优先级。", {
      failureClass: "model_contract_failure",
    });
  }
  return { highest_priority_gap: response.highest_priority_gap };
}

const LIVE_CASES = Object.freeze([
  {
    id: "ADPT-OPENCODE-04",
    prompt: [
      "You are in an isolated empty directory.",
      "Do not call tools and do not modify files.",
      "Return only one JSON object with one numeric field named sum.",
      "The value must be the result of thirty-seven plus five.",
    ].join("\n"),
    validate: validateArithmeticResponse,
  },
  {
    id: "HAPPY-OPENCODE-01",
    prompt: [
      "Compare these mobile remote-coding product facts.",
      "Happy: remote Claude/Codex sessions, message and tool timeline, permission/questions, attachments, files/diff, resume/fork/archive, realtime voice, inbox/friends.",
      "Agent Sessions: encrypted Android session control, message and tool timeline, permission/questions, attachments, Git diff, lifecycle recovery, but its OpenCode adapter Start and Resume currently return unsupported; voice and social are intentionally absent.",
      "Which gap should be addressed first to make live OpenCode mobile control real?",
      "Return only one JSON object with highest_priority_gap set to exactly one of provider_transport, voice, social.",
      "Do not call tools and do not modify files.",
    ].join("\n"),
    validate: validateComparisonResponse,
  },
]);

function classifyProviderFailure(result) {
  if (result.timedOut) return "provider_timeout";
  if (result.spawnFailure != null) return "environment_or_startup_failure";
  const diagnostic = `${result.stderr}\n${result.stdout}`.toLowerCase();
  if (/401|403|unauthori[sz]ed|credential|api key|quota|insufficient/.test(diagnostic)) {
    return "credential_or_quota_blocker";
  }
  if (/timeout|timed out|econnreset|econnrefused|eai_again|429|rate limit|\b5\d\d\b/.test(diagnostic)) {
    return "provider_timeout";
  }
  return "provider_http_error";
}

export function isRecoverableProviderFailure(failureClass) {
  return failureClass === "provider_timeout" || failureClass === "provider_http_error";
}

async function runLiveCase({
  liveCase,
  metrics,
  model,
  retries,
  timeoutMs,
  workspace,
}) {
  const attempts = [];
  for (let attempt = 0; attempt <= retries; attempt += 1) {
    metrics.requestAttempts += 1;
    const result = await commandResult(
      "opencode",
      [
        "run",
        "--pure",
        "--dir",
        workspace,
        "--model",
        model,
        "--format",
        "json",
        liveCase.prompt,
      ],
      { cwd: workspace, timeoutMs },
    );
    const stdoutSha256 = hash(result.stdout);
    const stderrSha256 = hash(result.stderr);
    if (!result.timedOut && result.spawnFailure == null && result.code === 0) {
      const observed = observeJsonEvents(result.stdout);
      if (!observed.assistant_text_observed) {
        throw new OpenCodeLiveError("OpenCode JSON 流没有可识别的 assistant 响应事件。", {
          details: {
            event_keys: observed.event_keys,
            event_types: observed.event_types,
            parsed_event_lines: observed.parsed_lines,
            total_output_lines: observed.total_lines,
          },
          failureClass: "model_contract_failure",
        });
      }
      const validated = liveCase.validate(observed.assistant_text);
      return {
        attempts: attempt + 1,
        event_keys: observed.event_keys,
        event_types: observed.event_types,
        id: liveCase.id,
        parsed_event_lines: observed.parsed_lines,
        request_ids: observed.request_ids,
        response_sha256: hash(observed.assistant_text),
        result: validated,
        stdout_sha256: stdoutSha256,
        total_output_lines: observed.total_lines,
        usage: observed.usage,
      };
    }
    const failureClass = classifyProviderFailure(result);
    attempts.push({
      attempt: attempt + 1,
      exit_code: result.code,
      failure_class: failureClass,
      stderr_sha256: stderrSha256,
      stdout_sha256: stdoutSha256,
      timed_out: result.timedOut,
    });
    if (!isRecoverableProviderFailure(failureClass) || attempt === retries) {
      throw new OpenCodeLiveError(
        `OpenCode ${liveCase.id} 未完成；已归档脱敏诊断哈希。`,
        { failureClass },
      );
    }
  }
  throw new OpenCodeLiveError("OpenCode 重试循环意外结束。");
}

function aggregateUsage(cases) {
  return cases.reduce(
    (usage, liveCase) => ({
      input_tokens: usage.input_tokens + (liveCase.usage.observed ? liveCase.usage.inputTokens : 0),
      output_tokens: usage.output_tokens + (liveCase.usage.observed ? liveCase.usage.outputTokens : 0),
    }),
    { input_tokens: 0, output_tokens: 0 },
  );
}

async function main() {
  let args;
  let workspace = null;
  let status = "failed";
  let failureClass = "test_harness_defect";
  let remainingRisk = "";
  let diagnostic = null;
  const completedCases = [];
  const metrics = { requestAttempts: 0 };
  let discovery = null;
  const startedAt = Date.now();

  try {
    args = parseOpenCodeLiveArgs(process.argv.slice(2));
    if (args.help) {
      process.stdout.write(`${openCodeLiveUsage()}\n`);
      return;
    }
    process.stdout.write(`[opencode-live] 发现模型 ${args.model}\n`);
    discovery = await discoverModel(args.model, args.timeoutMs);
    workspace = await mkdtemp(join(tmpdir(), "agent-sessions-opencode-live-"));
    for (const liveCase of LIVE_CASES) {
      process.stdout.write(
        `[opencode-live] ${liveCase.id}：真实调用，最多 ${args.retries} 次重试\n`,
      );
      completedCases.push(
        await runLiveCase({
          liveCase,
          metrics,
          model: args.model,
          retries: args.retries,
          timeoutMs: args.timeoutMs,
          workspace,
        }),
      );
    }
    status = "passed";
    failureClass = null;
    remainingRisk =
      "该 gate 证明本机 OpenCode Go 模型与 CLI 的真实请求，但当前 Agent Sessions OpenCode Adapter 尚未把 Start/Resume/事件流接入该传输，不能据此宣称移动端已控制真实 OpenCode 会话。";
  } catch (error) {
    failureClass =
      error instanceof OpenCodeLiveError
        ? error.failureClass
        : "test_harness_defect";
    remainingRisk = safeSummary(error instanceof Error ? error.message : error);
    diagnostic = error instanceof OpenCodeLiveError ? error.details : null;
  } finally {
    if (workspace != null) {
      await rm(workspace, { force: true, recursive: true });
    }
    if (args?.help) return;
    const usage = aggregateUsage(completedCases);
    const report = baseReport({
      artifacts: [],
      browser: "n/a",
      command: "task test:real -- --provider opencode --model opencode-go/deepseek-v4-flash",
      credential_source: "opencode-auth:OpenCode Go",
      failure_class: failureClass,
      fixture_data: false,
      headless: false,
      local_test: true,
      model: args?.model || OPENCODE_LIVE_MODEL,
      provider: "OpenCode Go",
      real_browser: false,
      real_model: metrics.requestAttempts > 0,
      real_upstream: metrics.requestAttempts > 0,
      remaining_risk: remainingRisk,
      request_ids: completedCases.flatMap((liveCase) => liveCase.request_ids),
      status,
      suite: "adapter-opencode-live",
      usage,
    });
    const reportPath = writeReport({
      planId: "ADAPTER-OPENCODE",
      name: "04-live-smoke",
      report: {
        ...report,
        completed_cases: completedCases.map((liveCase) => ({
          attempts: liveCase.attempts,
          event_keys: liveCase.event_keys,
          event_types: liveCase.event_types,
          id: liveCase.id,
          parsed_event_lines: liveCase.parsed_event_lines,
          response_sha256: liveCase.response_sha256,
          result: liveCase.result,
          stdout_sha256: liveCase.stdout_sha256,
          total_output_lines: liveCase.total_output_lines,
          usage_observed: liveCase.usage.observed,
        })),
        duration_ms: Date.now() - startedAt,
        diagnostic,
        model_discovery: discovery,
        request_attempts: metrics.requestAttempts,
        retry_policy: {
          max_retries: args?.retries ?? MAX_PROVIDER_RETRIES,
          retries_only_for: ["provider_timeout", "provider_http_error"],
        },
      },
    });
    process.stdout.write(`[opencode-live] ${status}：${reportPath}\n`);
    if (status !== "passed") process.exitCode = 1;
  }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch((error) => {
    process.stderr.write(`[opencode-live] ${safeSummary(error)}\n`);
    process.exit(1);
  });
}
