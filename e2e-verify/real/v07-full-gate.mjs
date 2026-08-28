#!/usr/bin/env node
// v0.7/P4 Zen 免费模型随机问答 full gate（V07-06/V07-07/V07-11）。
// 本脚本只在显式 AGENT_SESSIONS_ZEN_REAL=1 后启动真实 OpenCode/Relay/Daemon；
// 题目和回复只存在于进程内，checkpoint/报告只保留可审计的摘要与 case ID。
import { mkdtemp, mkdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, dirname, relative } from "node:path";
import { fileURLToPath } from "node:url";

import { baseReport, writeReport } from "../lib/report.mjs";
import { startOpenCodeServe } from "../lib/opencode.mjs";
import { startRelay } from "../lib/relay.mjs";
import {
  V07HarnessError,
  buildDaemon,
  classifyHarnessError,
  discoverLocalZenFreeModels,
  discoverOfficialZenFreeModels,
  chooseZenModel,
  opaqueSessionEnvelope,
  pairTerminal,
  registerOwner,
  requestJson,
  shortHash,
  snapshotSummary,
  startDaemon,
  waitCommand,
  waitForTerminal,
  waitForTurn,
} from "./v07-harness.mjs";
import {
  GENERATOR_VERSION,
  PROMPT_ORACLE_VERSION,
  checkResponseOracle,
  generateQuestions,
  hasSensitiveQuestionContent,
  questionPoolSummary,
} from "./qa_generator.mjs";
import {
  CHECKPOINT_VERSION,
  buildCheckpointIdentity,
  checkpointMismatchReason,
  prepareCheckpoint,
  writeCheckpoint,
} from "./v07-checkpoint.mjs";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
export const FULL_GATE_VERSION = "v07-full-gate-1";
export const DEFAULT_SEED = "20260829";
export const DEFAULT_CASE_COUNT = 12;
export const DEFAULT_SESSION_COUNT = 3;
export const DEFAULT_MAX_RETRIES = 2;
export const RETRYABLE_FAILURES = Object.freeze(new Set([
  "provider_http_error",
  "provider_timeout",
  "environment_or_startup_failure",
]));

function safeInteger(value, fallback, { min = 1, max = Number.MAX_SAFE_INTEGER } = {}) {
  const parsed = Number.parseInt(String(value ?? ""), 10);
  if (!Number.isInteger(parsed) || parsed < min || parsed > max) return fallback;
  return parsed;
}

export function parseFullGateArgs(argv = []) {
  const args = {
    help: false,
    seed: DEFAULT_SEED,
    count: DEFAULT_CASE_COUNT,
    sessions: DEFAULT_SESSION_COUNT,
    maxRetries: DEFAULT_MAX_RETRIES,
    timeoutMs: 180_000,
    checkpoint: process.env.V07_FULL_GATE_CHECKPOINT || join(ROOT, "e2e-verify/checkpoints/v07-full-gate.json"),
    model: "",
    keep: false,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const value = argv[index];
    if (value === "--help" || value === "-h") args.help = true;
    else if (value === "--seed") args.seed = String(argv[++index] || "").trim() || DEFAULT_SEED;
    else if (value === "--count") args.count = safeInteger(argv[++index], DEFAULT_CASE_COUNT, { min: 10, max: 32 });
    else if (value === "--sessions") args.sessions = safeInteger(argv[++index], DEFAULT_SESSION_COUNT, { min: 3, max: 8 });
    else if (value === "--max-retries") args.maxRetries = safeInteger(argv[++index], DEFAULT_MAX_RETRIES, { min: 0, max: 2 });
    else if (value === "--timeout-ms") args.timeoutMs = safeInteger(argv[++index], 180_000, { min: 1_000, max: 900_000 });
    else if (value === "--checkpoint") args.checkpoint = String(argv[++index] || "").trim();
    else if (value === "--model") args.model = String(argv[++index] || "").trim();
    else if (value === "--keep") args.keep = true;
    else throw new V07HarnessError(`未知参数：${value}`, { failureClass: "test_harness_defect" });
  }
  if (!args.checkpoint) throw new V07HarnessError("--checkpoint 不能为空", { failureClass: "test_harness_defect" });
  return args;
}

function usage() {
  return [
    "用法：AGENT_SESSIONS_ZEN_REAL=1 node e2e-verify/real/v07-full-gate.mjs [选项]",
    "  --seed <value>       固定题目抽样 seed，默认 20260829",
    "  --count <10..32>     问题数量，默认 12",
    "  --sessions <3..8>    会话数量，默认 3",
    "  --max-retries <0..2> 单题最大重试次数，默认 2",
    "  --checkpoint <path>  checkpoint 路径",
    "  --model <provider/id> 首选动态目录中的模型",
    "  --keep               保留本轮临时目录（仅故障诊断）",
  ].join("\n");
}

// buildAssignments 以轮询方式把题目分配到会话和动态模型，确保至少使用两个模型。
// assignments 只包含 ID/槽位/模型，可直接进入 behavior hash，不含 question 文本。
export function buildAssignments(questions, modelOptions, sessionCount = DEFAULT_SESSION_COUNT) {
  const models = [...new Set((modelOptions ?? []).map((model) => String(model).trim()).filter(Boolean))].sort();
  if (models.length < 2) {
    throw new V07HarnessError("full gate 至少需要两个动态 Zen 免费模型", { failureClass: "credential_or_quota_blocker" });
  }
  if (!Number.isInteger(sessionCount) || sessionCount < 3) {
    throw new V07HarnessError("full gate 至少需要三个会话", { failureClass: "test_harness_defect" });
  }
  return (questions ?? []).map((question, index) => ({
    case_id: String(question.id),
    session_slot: index % sessionCount,
    // 同一个 session 的 Adapter model 在 session.start 时固定，因此模型按
    // session 槽位分配，避免后续 case 的报告模型与实际 provider 路由不一致。
    model: models[(index % sessionCount) % models.length],
  }));
}

function assignmentsForSession(assignments, slot) {
  return assignments.filter((assignment) => assignment.session_slot === slot);
}

function usageCounts(controls) {
  return {
    input_tokens: Math.max(0, Number(controls?.usage?.input_tokens) || 0),
    output_tokens: Math.max(0, Number(controls?.usage?.output_tokens) || 0),
  };
}

async function readControls(relayBase, ownerToken, sessionId) {
  return requestJson(relayBase, `/v1/sessions/${encodeURIComponent(sessionId)}/controls`, {
    token: ownerToken,
    timeoutMs: 10_000,
  });
}

async function readSnapshot(relayBase, ownerToken, sessionId, afterSeq = 0) {
  return requestJson(relayBase, `/v1/sessions/${encodeURIComponent(sessionId)}/snapshot?after_seq=${Math.max(0, afterSeq)}`, {
    token: ownerToken,
    timeoutMs: 15_000,
  });
}

async function waitForUsageDelta(relayBase, ownerToken, sessionId, before, timeoutMs = 30_000) {
  const deadline = Date.now() + timeoutMs;
  let latest = before;
  while (Date.now() < deadline) {
    latest = usageCounts(await readControls(relayBase, ownerToken, sessionId));
    if (latest.input_tokens > before.input_tokens && latest.output_tokens > before.output_tokens) {
      return { usage: latest, delta: {
        input_tokens: latest.input_tokens - before.input_tokens,
        output_tokens: latest.output_tokens - before.output_tokens,
      } };
    }
    await new Promise((resolve) => setTimeout(resolve, 500));
  }
  throw new V07HarnessError("full gate 回合没有产生正数 usage 增量", {
    failureClass: "model_contract_failure",
    details: { input_tokens: latest.input_tokens, output_tokens: latest.output_tokens },
  });
}

async function createWorkspace(relayBase, ownerToken, folderName, commandKinds) {
  const created = await requestJson(relayBase, "/v1/workspaces/create-with-folder", {
    token: ownerToken,
    method: "POST",
    body: { name: folderName },
  });
  commandKinds.push("workspace.create");
  const command = created.command_id
    ? await waitCommand(relayBase, ownerToken, created.command_id)
    : created;
  if (String(command.status || created.status) !== "succeeded") {
    throw new V07HarnessError("workspace.create 未成功收口", {
      failureClass: "product_defect",
      details: { status: String(command.status || created.status || "unknown") },
    });
  }
  const workspaceId = created.workspace_id || command.workspace_id;
  if (!workspaceId) throw new V07HarnessError("workspace.create 响应缺少 workspace_id", { failureClass: "test_harness_defect" });
  return workspaceId;
}

async function createSession(relayBase, ownerToken, workspaceId) {
  const session = await requestJson(relayBase, "/v1/sessions", {
    token: ownerToken,
    method: "POST",
    body: { workspace_id: workspaceId, provider: "opencode" },
  });
  if (!session.id) throw new V07HarnessError("创建会话响应缺少 id", { failureClass: "test_harness_defect" });
  return session.id;
}

async function startSession({ relayBase, ownerToken, terminalId, sessionId, model, commandKinds }) {
  const lease = await requestJson(relayBase, `/v1/sessions/${encodeURIComponent(sessionId)}/lease`, {
    token: ownerToken,
    method: "POST",
  });
  const leaseEpoch = Number(lease.lease_epoch);
  if (!Number.isInteger(leaseEpoch) || leaseEpoch <= 0) {
    throw new V07HarnessError("session lease 不合法", { failureClass: "product_defect" });
  }
  const command = await requestJson(relayBase, `/v1/sessions/${encodeURIComponent(sessionId)}/commands`, {
    token: ownerToken,
    method: "POST",
    body: {
      kind: "session.start",
      idempotency_key: `v07-full-start-${sessionId}-${Date.now()}`,
      lease_epoch: leaseEpoch,
      target_terminal_id: terminalId,
      ciphertext: opaqueSessionEnvelope({ kind: "session.start", sessionId, provider: "opencode", model }),
    },
  });
  commandKinds.push("session.start");
  const result = await waitCommand(relayBase, ownerToken, command.id);
  if (result.status !== "succeeded") {
    throw new V07HarnessError("session.start 未成功", {
      failureClass: "provider_http_error",
      details: { status: String(result.status || "unknown") },
    });
  }
  return leaseEpoch;
}

async function runQuestion({ relayBase, ownerToken, terminalId, sessionId, leaseEpoch, model, question, timeoutMs, commandKinds }) {
  const beforeSnapshot = snapshotSummary(await readSnapshot(relayBase, ownerToken, sessionId));
  const beforeUsage = usageCounts(await readControls(relayBase, ownerToken, sessionId));
  const command = await requestJson(relayBase, `/v1/sessions/${encodeURIComponent(sessionId)}/commands`, {
    token: ownerToken,
    method: "POST",
    body: {
      kind: "session.send",
      idempotency_key: `v07-full-send-${question.id}-${Date.now()}`,
      lease_epoch: leaseEpoch,
      target_terminal_id: terminalId,
      ciphertext: opaqueSessionEnvelope({
        kind: "session.send",
        sessionId,
        provider: "opencode",
        model,
        message: question.question,
      }),
    },
  });
  commandKinds.push("session.send");
  const result = await waitCommand(relayBase, ownerToken, command.id, timeoutMs);
  if (result.status !== "succeeded") {
    throw new V07HarnessError("session.send 未成功", {
      failureClass: "provider_http_error",
      details: { status: String(result.status || "unknown") },
    });
  }
  const turn = await waitForTurn(relayBase, ownerToken, sessionId, {
    timeoutMs,
    afterSeq: beforeSnapshot.lastSeq,
  });
  const texts = turn.summary.assistantTexts;
  const response = texts.length > beforeSnapshot.assistantTexts.length
    ? texts[texts.length - 1]
    : texts.at(-1) || "";
  const oracle = checkResponseOracle(question, response);
  if (!oracle.ok) {
    throw new V07HarnessError(`模型回复未满足弱 oracle：${oracle.reason}`, {
      failureClass: "model_contract_failure",
      details: { oracle: oracle.reason },
    });
  }
  const usage = await waitForUsageDelta(relayBase, ownerToken, sessionId, beforeUsage, Math.min(timeoutMs, 60_000));
  return {
    responseLength: response.length,
    responseHash: response.length ? shortHash(response) : null,
    eventTypes: turn.summary.eventTypes,
    sessionStatus: turn.summary.sessionStatus,
    lastSeq: turn.summary.lastSeq,
    usage: usage.delta,
  };
}

function reportFailure(error, attempts = 0) {
  const classified = classifyHarnessError(error);
  return {
    failure_class: classified.failure_class,
    attempts,
  };
}

async function runWithRetries(task, maxRetries) {
  const failures = [];
  let attempts = 0;
  while (attempts <= maxRetries) {
    attempts += 1;
    try {
      const result = await task(attempts);
      return { result, attempts, failures };
    } catch (error) {
      const classified = classifyHarnessError(error);
      failures.push({ failure_class: classified.failure_class, attempts });
      if (!RETRYABLE_FAILURES.has(classified.failure_class) || attempts > maxRetries) {
        throw Object.assign(error, { attempts, retryFailures: failures });
      }
      // 有上限的退避，避免真实模型限流时并发放大；不对 model_contract_failure 自动重试。
      await new Promise((resolve) => setTimeout(resolve, Math.min(2_000, 250 * attempts)));
    }
  }
  throw new V07HarnessError("full gate 重试循环异常结束", { failureClass: "test_harness_defect" });
}

// prepareTopology 逐步启动真实拓扑；任一环节失败都要回收已经启动的句柄。
// 调用方只有在函数成功后才拿到完整 topology，因此清理必须在这里完成，
// 不能依赖外层 finally 观察到一个尚未赋值的局部变量。
async function prepareTopology(model, rootTemp) {
  const daemonState = join(rootTemp, "daemon-state");
  const workspaceRoot = join(rootTemp, "workspace-root");
  const binaryDir = join(rootTemp, "bin");
  await mkdir(daemonState, { recursive: true });
  await mkdir(workspaceRoot, { recursive: true });
  await mkdir(binaryDir, { recursive: true });
  let opencode = null;
  let relay = null;
  let daemon = null;
  try {
    opencode = await startOpenCodeServe();
    relay = await startRelay({
      env: {
        AGENT_SESSIONS_OPENCODE_URL: opencode.base,
        AGENT_SESSIONS_TERMINAL_SIGNATURE_MODE: "optional",
      },
    });
    const owner = await registerOwner(relay.base);
    const terminal = await pairTerminal(relay.base, owner.accessToken);
    const daemonBinary = await buildDaemon(binaryDir);
    daemon = await startDaemon(daemonBinary, {
      relayBase: relay.base,
      terminal,
      opencodeBase: opencode.base,
      model,
      workspaceRoot,
      stateDir: daemonState,
    });
    await waitForTerminal(relay.base, owner.accessToken, terminal.deviceId);
    return { opencode, relay, owner, terminal, daemon, workspaceRoot };
  } catch (error) {
    // 逆序关闭，确保 Daemon 不再向 Relay 发请求后再释放 Relay/OpenCode。
    await daemon?.stop().catch(() => {});
    await relay?.stop().catch(() => {});
    await opencode?.stop().catch(() => {});
    throw error;
  }
}

async function stopTopology(topology) {
  if (!topology) return;
  await topology.daemon?.stop().catch(() => {});
  await topology.relay?.stop().catch(() => {});
  await topology.opencode?.stop().catch(() => {});
}

function initialReport(args) {
  return baseReport({
    suite: "v07-full-gate",
    status: "in_progress",
    real_browser: false,
    real_model: false,
    real_upstream: false,
    fixture_data: false,
    local_test: false,
    headless: false,
    browser: "n/a",
    model: args.model || "dynamic-free-models",
    provider: "opencode",
    credential_source: "opencode-local-auth",
    command: `node e2e-verify/real/v07-full-gate.mjs --seed ${args.seed} --count ${args.count} --sessions ${args.sessions}`,
  });
}

// runZenFullGate 执行完整多会话、多模型 gate；默认执行 12 题，满足计划中的最低门槛。
export async function runZenFullGate(args = parseFullGateArgs([]), {
  zenEnabled = process.env.AGENT_SESSIONS_ZEN_REAL === "1",
  write = writeReport,
} = {}) {
  const report = initialReport(args);
  report.suite_version = FULL_GATE_VERSION;
  report.checkpoint_version = CHECKPOINT_VERSION;
  report.seed = args.seed;
  report.question_count = args.count;
  report.session_count = args.sessions;
  report.max_retries = args.maxRetries;
  report.question_pool = questionPoolSummary();
  report.request_attempts = 0;
  report.completed_case_count = 0;
  report.case_results = [];
  report.failure_classes = {};
  report.checkpoint_path = args.checkpoint;
  if (!zenEnabled) {
    report.status = "blocked";
    report.failure_class = "credential_or_quota_blocker";
    report.remaining_risk = "未设置 AGENT_SESSIONS_ZEN_REAL=1；full gate 未启动真实拓扑。";
    const file = write({ planId: "V07-RELEASE", name: "V07-06", report });
    return { exitCode: 2, file, report };
  }

  const questions = generateQuestions({ seed: args.seed, count: args.count });
  if (questions.some((question) => hasSensitiveQuestionContent(question.question))) {
    report.status = "failed";
    report.failure_class = "test_harness_defect";
    report.remaining_risk = "题目池敏感词守卫失败，未启动真实拓扑。";
    const file = write({ planId: "V07-RELEASE", name: "V07-06", report });
    return { exitCode: 1, file, report };
  }

  const rootTemp = await mkdtemp(join(tmpdir(), "agent-sessions-v07-full-"));
  let topology = null;
  let officialCatalog = null;
  let localCatalog = null;
  try {
    officialCatalog = await discoverOfficialZenFreeModels();
    report.official_catalog = {
      count: officialCatalog.count,
      sha256: officialCatalog.catalog_sha256,
      source: officialCatalog.source,
    };
    topology = { opencode: await startOpenCodeServe() };
    report.auth_mode = topology.opencode.auth_mode;
    localCatalog = await discoverLocalZenFreeModels({
      base: topology.opencode.base,
      username: topology.opencode.username,
      password: process.env.OPENCODE_SERVER_PASSWORD || "",
      official: officialCatalog,
    });
    report.local_catalog = {
      count: localCatalog.count,
      sha256: localCatalog.local_catalog_sha256,
      endpoints: localCatalog.endpoints_tried,
    };
    if (localCatalog.options.length < 2) {
      throw new V07HarnessError("本机动态目录少于两个 Zen 免费模型", { failureClass: "credential_or_quota_blocker" });
    }
    const selectedModel = chooseZenModel(localCatalog.options, args.model);
    // 显式首选模型作为第一个 session 的模型，其余 session 继续覆盖其它动态条目。
    const orderedModels = [selectedModel, ...localCatalog.options.filter((model) => model !== selectedModel)];
    const assignments = buildAssignments(questions, orderedModels, args.sessions);
    report.models = [...new Set(assignments.map((assignment) => assignment.model))].sort();
    if (report.models.length < 2) {
      throw new V07HarnessError("模型分配未覆盖两个动态 Zen 免费模型", { failureClass: "credential_or_quota_blocker" });
    }
    report.assignment_count = assignments.length;
    const identity = buildCheckpointIdentity({
      suiteVersion: FULL_GATE_VERSION,
      seed: args.seed,
      questionCount: questions.length,
      generatorVersion: GENERATOR_VERSION,
      oracleVersion: PROMPT_ORACLE_VERSION,
      modelCatalogSha256: localCatalog.local_catalog_sha256,
      modelOptions: localCatalog.options,
      assignments,
    });
    Object.assign(report, {
      behavior_hash: identity.behavior_hash,
      generator_version: GENERATOR_VERSION,
      oracle_version: PROMPT_ORACLE_VERSION,
      model_catalog_sha256: localCatalog.local_catalog_sha256,
    });
    const checkpoint = await prepareCheckpoint(args.checkpoint, identity);
    report.checkpoint_action = checkpoint.action;
    if (checkpoint.mismatch) {
      report.checkpoint_failure_class = checkpointMismatchReason(checkpoint);
      report.checkpoint_mismatch = checkpointMismatchReason(checkpoint);
      report.checkpoint_stale_path = checkpoint.stalePath;
    }
    const validCaseIds = new Set(questions.map((question) => question.id));
    const completed = new Set((checkpoint.checkpoint?.completed_case_ids ?? []).filter((id) => validCaseIds.has(id)));
    report.resumed_case_count = completed.size;
    if (completed.size === questions.length) {
      report.status = "passed";
      report.real_model = true;
      report.real_upstream = true;
      report.remaining_risk = "本次使用一致 checkpoint 恢复，所有 case 已有既有真实 gate 证据；未重复消耗模型额度。";
      const file = write({ planId: "V07-RELEASE", name: "V07-06", report });
      return { exitCode: 0, file, report };
    }

    // 目录发现完成后才启动共享拓扑，确保没有 Zen 交集时不会启动无意义的 Daemon。
    await topology.opencode.stop().catch(() => {});
    topology = await prepareTopology(assignments[0]?.model || localCatalog.options[0], rootTemp);
    const sessionState = [];
    for (let slot = 0; slot < args.sessions; slot += 1) {
      const folder = `v07-full-${Date.now().toString(36)}-${slot}`;
      const workspaceId = await createWorkspace(topology.relay.base, topology.owner.accessToken, folder, report.command_kinds || (report.command_kinds = []));
      const sessionId = await createSession(topology.relay.base, topology.owner.accessToken, workspaceId);
      const slotAssignments = assignmentsForSession(assignments, slot);
      const model = slotAssignments[0]?.model || localCatalog.options[slot % localCatalog.options.length];
      const leaseEpoch = await startSession({
        relayBase: topology.relay.base,
        ownerToken: topology.owner.accessToken,
        terminalId: (await waitForTerminal(topology.relay.base, topology.owner.accessToken, topology.terminal.deviceId)).id,
        sessionId,
        model,
        commandKinds: report.command_kinds,
      });
      sessionState.push({ slot, sessionId, model, leaseEpoch, terminalId: topology.terminal.deviceId });
    }

    const questionById = new Map(questions.map((question) => [question.id, question]));
    for (const assignment of assignments) {
      if (completed.has(assignment.case_id)) continue;
      const question = questionById.get(assignment.case_id);
      const session = sessionState[assignment.session_slot];
      if (!question || !session) {
        const error = new V07HarnessError("case 分配缺少会话", { failureClass: "test_harness_defect" });
        report.case_results.push({ case_id: assignment.case_id, status: "failed", ...reportFailure(error) });
        continue;
      }
      report.request_attempts += 1;
      try {
        const run = await runWithRetries(
          () => runQuestion({
            relayBase: topology.relay.base,
            ownerToken: topology.owner.accessToken,
            terminalId: session.terminalId,
            sessionId: session.sessionId,
            leaseEpoch: session.leaseEpoch,
            model: assignment.model,
            question,
            timeoutMs: args.timeoutMs,
            commandKinds: report.command_kinds,
          }),
          args.maxRetries,
        );
        report.request_attempts += Math.max(0, run.attempts - 1);
        report.case_results.push({
          case_id: assignment.case_id,
          language: question.language,
          type: question.type,
          session_slot: assignment.session_slot,
          model: assignment.model,
          status: "passed",
          attempts: run.attempts,
          ...run.result,
        });
        report.completed_case_count += 1;
        const nextCompleted = [...new Set([...completed, assignment.case_id])];
        completed.add(assignment.case_id);
        await writeCheckpoint(args.checkpoint, {
          ...identity,
          completed_case_ids: nextCompleted,
          failures: report.case_results.filter((item) => item.status === "failed"),
        });
      } catch (error) {
        const attempts = Number(error.attempts) || 1;
        report.request_attempts += Math.max(0, attempts - 1);
        const failure = reportFailure(error, attempts);
        report.failure_classes[failure.failure_class] = (report.failure_classes[failure.failure_class] || 0) + 1;
        report.case_results.push({
          case_id: assignment.case_id,
          language: question.language,
          type: question.type,
          session_slot: assignment.session_slot,
          model: assignment.model,
          status: "failed",
          ...failure,
        });
        await writeCheckpoint(args.checkpoint, {
          ...identity,
          completed_case_ids: [...completed],
          failures: report.case_results.filter((item) => item.status === "failed"),
        });
      }
    }
    const failed = report.case_results.filter((item) => item.status === "failed");
    const passed = report.case_results.filter((item) => item.status === "passed");
    report.completed_case_count = passed.length + report.resumed_case_count;
    report.usage = passed.reduce((sum, item) => ({
      input_tokens: sum.input_tokens + (Number(item.usage?.input_tokens) || 0),
      output_tokens: sum.output_tokens + (Number(item.usage?.output_tokens) || 0),
    }), { input_tokens: 0, output_tokens: 0 });
    report.status = failed.length === 0 && report.completed_case_count >= questions.length ? "passed" : "failed";
    report.real_model = report.request_attempts > 0 || report.resumed_case_count > 0;
    report.real_upstream = report.real_model;
    report.failure_class = failed.length ? failed[0].failure_class : null;
    report.remaining_risk = failed.length
      ? "full gate 保留失败 case 与分类；不得将部分通过称为完整通过。"
      : "已覆盖动态目录中的两个以上 Zen 免费模型与至少三个会话；报告不含题目/回复正文。";
    const file = write({ planId: "V07-RELEASE", name: "V07-06", report });
    return { exitCode: report.status === "passed" ? 0 : 1, file, report };
  } catch (error) {
    const classified = classifyHarnessError(error);
    if (error?.report && typeof error.report === "object") Object.assign(report, error.report);
    report.status = classified.status;
    report.failure_class = classified.failure_class;
    report.remaining_risk = classified.remaining_risk;
    report.real_model = report.request_attempts > 0;
    report.real_upstream = report.real_model;
    const file = write({ planId: "V07-RELEASE", name: "V07-06", report });
    return { exitCode: report.status === "blocked" ? 1 : 1, file, report };
  } finally {
    await stopTopology(topology);
    if (!args.keep) await rm(rootTemp, { recursive: true, force: true }).catch(() => {});
    else report.artifact_root = relative(ROOT, rootTemp);
  }
}

function printOutcome(outcome) {
  console.log(`v07 full gate: ${outcome.report.status} failure_class=${outcome.report.failure_class || "none"}`);
  console.log(`report: ${outcome.file}`);
}

async function main() {
  let args;
  try {
    args = parseFullGateArgs(process.argv.slice(2));
    if (args.help) {
      console.log(usage());
      return;
    }
    const outcome = await runZenFullGate(args);
    printOutcome(outcome);
    process.exitCode = outcome.exitCode;
  } catch (error) {
    const classified = classifyHarnessError(error);
    const report = initialReport(args || parseFullGateArgs([]));
    report.status = classified.status;
    report.failure_class = classified.failure_class;
    report.remaining_risk = classified.remaining_risk;
    const file = writeReport({ planId: "V07-RELEASE", name: "V07-06", report });
    printOutcome({ file, report });
    process.exitCode = 1;
  }
}

if (import.meta.url === `file://${process.argv[1]}`) await main();
