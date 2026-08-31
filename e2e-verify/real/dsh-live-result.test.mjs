import assert from "node:assert/strict";
import test from "node:test";
import { classifyDshLiveFailure, dshZenTestModels } from "./dsh-live-result.mjs";

test("DSH Zen 测试池稳定声明三个模型", () => {
  assert.deepEqual([...dshZenTestModels], ["mimo-v2.5-free", "big-pickle", "ling-3.0-flash-fin-free"]);
});

test("DSH Zen 测试池的 429 FreeUsageLimitError 按 v0.8 约定通过", () => {
  for (const model of ["mimo-v2.5-free", "big-pickle", "ling-3.0-flash-fin-free"]) {
    const result = classifyDshLiveFailure({
      provider: "opencode-zen",
      model,
      message: "prompt 被拒绝: 429 FreeUsageLimitError: Rate limit exceeded",
    });

    assert.equal(result.status, "passed");
    assert.equal(result.passReason, "zen_quota_accepted");
    assert.equal(result.quotaAccepted, true);
    assert.equal(result.failureClass, null);
  }
});

test("非 Zen mimo 的 429 不得误判为通过", () => {
  const result = classifyDshLiveFailure({
    provider: "opencode-go",
    model: "deepseek-v4-flash",
    stderr: "429 FreeUsageLimitError: Rate limit exceeded",
  });

  assert.equal(result.status, "failed");
  assert.equal(result.quotaAccepted, false);
  assert.equal(result.failureClass, "model_contract_failure");
});

test("不在 DSH Zen 测试池的模型不得因 429 通过", () => {
  const result = classifyDshLiveFailure({
    provider: "opencode-zen",
    model: "nemotron-3-ultra-free",
    stderr: "429 FreeUsageLimitError: Rate limit exceeded",
  });

  assert.equal(result.status, "failed");
  assert.equal(result.quotaAccepted, false);
  assert.equal(result.failureClass, "model_contract_failure");
});

test("Zen mimo 的普通鉴权错误仍保持 blocked", () => {
  const result = classifyDshLiveFailure({
    provider: "opencode-zen",
    model: "mimo-v2.5-free",
    message: "MISSING_CREDENTIAL",
  });

  assert.equal(result.status, "blocked");
  assert.equal(result.quotaAccepted, false);
  assert.equal(result.failureClass, "credential_or_quota_blocker");
});
