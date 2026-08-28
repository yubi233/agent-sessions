// v0.7/P4 full gate checkpoint：只保存可复现身份和完成 case ID。
// 题目正文、模型回复、凭据和完整会话标识永远不进入 checkpoint。
import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname } from "node:path";
import { createHash } from "node:crypto";

export const CHECKPOINT_VERSION = "v07-full-gate-checkpoint-1";

function digest(value) {
  return createHash("sha256").update(JSON.stringify(value), "utf8").digest("hex");
}

function stamp() {
  return new Date().toISOString().replace(/[:.]/g, "-");
}

// buildCheckpointIdentity 把会影响 case 语义的版本和目录摘要纳入行为哈希。
// 任何一个字段变化都必须从新 run 开始，防止旧结果被错误恢复。
export function buildCheckpointIdentity({
  suiteVersion,
  seed,
  questionCount,
  generatorVersion,
  oracleVersion,
  modelCatalogSha256,
  modelOptions,
  assignments,
}) {
  const material = {
    checkpoint_version: CHECKPOINT_VERSION,
    suite_version: String(suiteVersion),
    seed: String(seed),
    question_count: Number(questionCount),
    generator_version: String(generatorVersion),
    oracle_version: String(oracleVersion),
    model_catalog_sha256: String(modelCatalogSha256),
    model_options: [...new Set((modelOptions ?? []).map((value) => String(value)))].sort(),
    assignments: (assignments ?? []).map((item) => ({
      case_id: String(item.case_id),
      session_slot: Number(item.session_slot),
      model: String(item.model),
    })),
  };
  return {
    ...material,
    behavior_hash: `sha256:${digest(material).slice(0, 32)}`,
  };
}

function compatible(checkpoint, identity) {
  if (!checkpoint || typeof checkpoint !== "object") return { ok: false, reason: "invalid_json" };
  const fields = [
    "checkpoint_version", "suite_version", "seed", "question_count", "generator_version",
    "oracle_version", "model_catalog_sha256", "behavior_hash",
  ];
  for (const field of fields) {
    if (checkpoint[field] !== identity[field]) return { ok: false, reason: `field:${field}` };
  }
  const actualOptions = JSON.stringify([...(checkpoint.model_options ?? [])].sort());
  const expectedOptions = JSON.stringify([...identity.model_options].sort());
  if (actualOptions !== expectedOptions) return { ok: false, reason: "field:model_options" };
  const actualAssignments = JSON.stringify(checkpoint.assignments ?? []);
  const expectedAssignments = JSON.stringify(identity.assignments ?? []);
  if (actualAssignments !== expectedAssignments) return { ok: false, reason: "field:assignments" };
  if (!Array.isArray(checkpoint.completed_case_ids)) return { ok: false, reason: "completed_case_ids" };
  return { ok: true };
}

async function moveToStale(path) {
  const base = `${path}.stale-${stamp()}`;
  let candidate = base;
  for (let index = 0; index < 100; index += 1) {
    try {
      await rename(path, candidate);
      return candidate;
    } catch (error) {
      if (error?.code !== "EEXIST") throw error;
      candidate = `${base}-${index + 1}`;
    }
  }
  throw new Error("无法为旧 checkpoint 分配 stale 文件名");
}

// prepareCheckpoint 读取一致 checkpoint；不一致或损坏时可恢复地改名保留。
export async function prepareCheckpoint(path, identity) {
  await mkdir(dirname(path), { recursive: true });
  let parsed;
  try {
    parsed = JSON.parse(await readFile(path, "utf8"));
  } catch (error) {
    if (error?.code === "ENOENT") return { action: "new", checkpoint: null, stalePath: null };
    const stalePath = await moveToStale(path);
    return { action: "stale", checkpoint: null, stalePath, mismatch: "invalid_json" };
  }
  const result = compatible(parsed, identity);
  if (result.ok) {
    return { action: "resume", checkpoint: parsed, stalePath: null, mismatch: null };
  }
  const stalePath = await moveToStale(path);
  return { action: "stale", checkpoint: null, stalePath, mismatch: result.reason };
}

function checkpointSafeShape(value) {
  const completed = [...new Set((value.completed_case_ids ?? []).map((id) => String(id)))].sort();
  const failures = Array.isArray(value.failures)
    ? value.failures.map((failure) => ({
      case_id: String(failure.case_id ?? ""),
      failure_class: String(failure.failure_class ?? "test_harness_defect"),
      attempts: Number(failure.attempts) || 0,
    }))
    : [];
  return {
    checkpoint_version: String(value.checkpoint_version ?? CHECKPOINT_VERSION),
    suite_version: String(value.suite_version ?? ""),
    seed: String(value.seed ?? ""),
    question_count: Number(value.question_count) || 0,
    generator_version: String(value.generator_version ?? ""),
    oracle_version: String(value.oracle_version ?? ""),
    model_catalog_sha256: String(value.model_catalog_sha256 ?? ""),
    model_options: [...new Set((value.model_options ?? []).map((model) => String(model)))].sort(),
    assignments: (value.assignments ?? []).map((item) => ({
      case_id: String(item.case_id ?? ""),
      session_slot: Number(item.session_slot) || 0,
      model: String(item.model ?? ""),
    })),
    behavior_hash: String(value.behavior_hash ?? ""),
    completed_case_ids: completed,
    failures,
    updated_at: new Date().toISOString(),
  };
}

// writeCheckpoint 使用同目录临时文件 + rename，避免中断时留下半个 JSON。
export async function writeCheckpoint(path, value) {
  await mkdir(dirname(path), { recursive: true });
  const safe = checkpointSafeShape(value);
  const temporary = `${path}.tmp-${process.pid}-${Date.now()}`;
  await writeFile(temporary, `${JSON.stringify(safe, null, 2)}\n`, "utf8");
  await rename(temporary, path);
  return safe;
}

export function checkpointMismatchReason(result) {
  if (!result || result.action !== "stale") return null;
  return String(result.mismatch || "checkpoint_mismatch");
}
