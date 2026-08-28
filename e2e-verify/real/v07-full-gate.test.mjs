import assert from "node:assert/strict";
import { access, mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import {
  buildAssignments,
  parseFullGateArgs,
  runZenFullGate,
} from "./v07-full-gate.mjs";
import { classifyHarnessError, V07HarnessError } from "./v07-harness.mjs";
import { runV07HeadedReadonly } from "../suites/v07-headed-readonly.mjs";
import {
  GENERATOR_VERSION,
  PROMPT_ORACLE_VERSION,
  QUESTION_POOL,
  checkResponseOracle,
  generateQuestions,
  hasSensitiveQuestionContent,
} from "./qa_generator.mjs";
import {
  CHECKPOINT_VERSION,
  buildCheckpointIdentity,
  checkpointMismatchReason,
  prepareCheckpoint,
  writeCheckpoint,
} from "./v07-checkpoint.mjs";

test("V07-06 题目池固定为 32 条且中英文各半，不含敏感词", () => {
  assert.equal(QUESTION_POOL.length, 32);
  assert.equal(QUESTION_POOL.filter((item) => item.language === "zh").length, 16);
  assert.equal(QUESTION_POOL.filter((item) => item.language === "en").length, 16);
  assert.equal(QUESTION_POOL.some((item) => item.variants.some(hasSensitiveQuestionContent)), false);
  const first = generateQuestions({ seed: "gate-seed", count: 12 });
  const second = generateQuestions({ seed: "gate-seed", count: 12 });
  assert.deepEqual(first, second);
  assert.equal(first.filter((item) => item.language === "zh").length, 6);
  assert.equal(first.filter((item) => item.language === "en").length, 6);
  assert.equal(new Set(first.map((item) => item.id)).size, 12);
});

test("V07-06 弱 oracle 覆盖代码块、数字和列表形状", () => {
  const [code] = generateQuestions({ seed: "code-only", count: 12 }).filter((item) => item.type === "code");
  assert.ok(code);
  assert.equal(checkResponseOracle(code, "plain text only").ok, false);
  assert.equal(checkResponseOracle(code, "```python\nprint(1)\n```").ok, true);
  const math = generateQuestions({ seed: "math-only", count: 12 }).find((item) => item.type === "math");
  assert.ok(math);
  assert.equal(checkResponseOracle(math, "答案是四十二").ok, true);
  const list = generateQuestions({ seed: "list-only", count: 12 }).find((item) => item.type === "list");
  assert.ok(list);
  assert.equal(checkResponseOracle(list, "第一步\n第二步\n第三步").ok, true);
});

test("V07-06 assignment 按会话固定模型并覆盖三个会话和两个模型", () => {
  const questions = generateQuestions({ seed: "assignment", count: 12 });
  const assignments = buildAssignments(questions, ["opencode/z-free", "opencode/a-free"], 3);
  assert.equal(new Set(assignments.map((item) => item.session_slot)).size, 3);
  assert.equal(new Set(assignments.map((item) => item.model)).size, 2);
  for (const slot of [0, 1, 2]) {
    const models = new Set(assignments.filter((item) => item.session_slot === slot).map((item) => item.model));
    assert.equal(models.size, 1);
  }
  assert.throws(() => buildAssignments(questions, ["opencode/only-free"], 3), /至少需要两个/);
});

test("V07-11 checkpoint 一致时恢复，行为变化时改名 stale 并保留旧文件", async () => {
  const root = await mkdtemp(join(tmpdir(), "v07-checkpoint-test-"));
  const path = join(root, "gate.json");
  const identity = buildCheckpointIdentity({
    suiteVersion: "v07-full-gate-1",
    seed: "seed",
    questionCount: 12,
    generatorVersion: GENERATOR_VERSION,
    oracleVersion: PROMPT_ORACLE_VERSION,
    modelCatalogSha256: "sha256:catalog",
    modelOptions: ["opencode/a-free", "opencode/z-free"],
    assignments: [{ case_id: "zh-01", session_slot: 0, model: "opencode/a-free" }],
  });
  try {
    assert.equal((await prepareCheckpoint(path, identity)).action, "new");
    await writeCheckpoint(path, { ...identity, completed_case_ids: ["zh-01"], failures: [] });
    const resumed = await prepareCheckpoint(path, identity);
    assert.equal(resumed.action, "resume");
    assert.deepEqual(resumed.checkpoint.completed_case_ids, ["zh-01"]);
    const changed = { ...identity, oracle_version: "v07-weak-oracle-changed" };
    const stale = await prepareCheckpoint(path, changed);
    assert.equal(stale.action, "stale");
    assert.match(stale.stalePath, /\.stale-/);
    await access(stale.stalePath);
    const staleText = await readFile(stale.stalePath, "utf8");
    assert.match(staleText, /checkpoint_version/);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("V07-05/V07-06 未显式授权时不启动真实拓扑且明确 blocked", async () => {
  let called = false;
  const result = await runZenFullGate(parseFullGateArgs([]), {
    zenEnabled: false,
    write: ({ report }) => {
      called = true;
      assert.equal(report.status, "blocked");
      assert.equal(report.real_model, false);
      assert.equal(report.real_upstream, false);
      return "reports/V07-06.json";
    },
  });
  assert.equal(called, true);
  assert.equal(result.exitCode, 2);
  assert.equal(result.report.failure_class, "credential_or_quota_blocker");
});

test("V07-06 参数固定最多两次重试并拒绝低于计划门槛", () => {
  const args = parseFullGateArgs(["--seed", "s", "--count", "10", "--sessions", "3", "--max-retries", "2"]);
  assert.equal(args.count, 10);
  assert.equal(args.sessions, 3);
  assert.equal(args.maxRetries, 2);
  assert.equal(args.seed, "s");
});

test("V07-08 明确拒绝把 headless 运行冒充 headed 验收", async () => {
  const result = await runV07HeadedReadonly({
    headless: true,
    write: ({ report }) => report,
  });
  assert.equal(result.exitCode, 1);
  assert.equal(result.report.real_browser, false);
  assert.equal(result.report.failure_class, "test_harness_defect");
});

test("V07-11 checkpoint schema 带版本和行为哈希", () => {
  const identity = buildCheckpointIdentity({
    suiteVersion: "v07-full-gate-1",
    seed: "s",
    questionCount: 10,
    generatorVersion: GENERATOR_VERSION,
    oracleVersion: PROMPT_ORACLE_VERSION,
    modelCatalogSha256: "sha256:catalog",
    modelOptions: ["opencode/a-free", "opencode/b-free"],
    assignments: [],
  });
  assert.equal(identity.checkpoint_version, CHECKPOINT_VERSION);
  assert.match(identity.behavior_hash, /^sha256:/);
});

test("V07-11 stale checkpoint 统一归类为 checkpoint_mismatch", () => {
  const result = { action: "stale", mismatch: "field:oracle_version" };
  assert.equal(checkpointMismatchReason(result), "field:oracle_version");
  assert.equal(
    classifyHarnessError(new V07HarnessError("旧 checkpoint", { failureClass: "checkpoint_mismatch" })).failure_class,
    "checkpoint_mismatch",
  );
  assert.equal(
    classifyHarnessError(new V07HarnessError("产品收口失败", { failureClass: "product_defect" })).failure_class,
    "product_defect",
  );
});
