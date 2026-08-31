import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import { classifyDshLiveFailure, dshZenTestModels } from "./dsh-live-result.mjs";

const REPO_ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");

test("DSH Zen 测试池稳定声明四个模型", () => {
  assert.deepEqual([...dshZenTestModels], ["deepseek-v4-flash-free", "mimo-v2.5-free", "big-pickle", "ling-3.0-flash-fin-free"]);
});

test("DSH Zen 测试池的 429 FreeUsageLimitError 按 v0.8 约定通过", () => {
  for (const model of ["deepseek-v4-flash-free", "mimo-v2.5-free", "big-pickle", "ling-3.0-flash-fin-free"]) {
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

test("Zen 网关把免费额度映射为 403 时仍按明确错误类型通过", () => {
  const result = classifyDshLiveFailure({
    provider: "opencode-zen",
    model: "big-pickle",
    message: "prompt 被拒绝: 403 FreeUsageLimitError: free model usage limit reached",
  });
  assert.equal(result.status, "passed");
  assert.equal(result.passReason, "zen_quota_accepted");
  assert.equal(result.quotaAccepted, true);
});

test("非 Zen mimo 的 429 不得误判为通过", () => {
  const result = classifyDshLiveFailure({
    provider: "opencode-go",
    model: "deepseek-v4-flash",
    stderr: "429 FreeUsageLimitError: Rate limit exceeded",
  });

  assert.equal(result.status, "failed");
  assert.equal(result.quotaAccepted, false);
  assert.equal(result.failureClass, "provider_http_error");
});

test("不在 DSH Zen 测试池的模型不得因 429 通过", () => {
  const result = classifyDshLiveFailure({
    provider: "opencode-zen",
    model: "nemotron-3-ultra-free",
    stderr: "429 FreeUsageLimitError: Rate limit exceeded",
  });

  assert.equal(result.status, "failed");
  assert.equal(result.quotaAccepted, false);
  assert.equal(result.failureClass, "provider_http_error");
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

test("Zen 免费模型访问被拒绝但未声明额度耗尽时保持 blocked", () => {
  const result = classifyDshLiveFailure({
    provider: "opencode-zen",
    model: "mimo-v2.5-free",
    message: "403 free model access forbidden",
  });
  assert.equal(result.status, "blocked");
  assert.equal(result.passReason, null);
  assert.equal(result.failureClass, "credential_or_quota_blocker");
});

test("可重试的 HTTP/超时错误返回稳定分类", () => {
  const http = classifyDshLiveFailure({
    provider: "opencode-zen",
    model: "big-pickle",
    message: "prompt 被拒绝：HTTP 503",
  });
  assert.equal(http.status, "failed");
  assert.equal(http.failureClass, "provider_http_error");
  assert.equal(http.diagnosticCode, "provider_http_retryable");

  const timeout = classifyDshLiveFailure({
    provider: "opencode-zen",
    model: "ling-3.0-flash-fin-free",
    message: "session/prompt 超时",
  });
  assert.equal(timeout.status, "failed");
  assert.equal(timeout.failureClass, "provider_timeout");
  assert.equal(timeout.diagnosticCode, "provider_timeout");
});

test("模型不可用不按额度命中放行", () => {
  const result = classifyDshLiveFailure({
    provider: "opencode-zen",
    model: "deepseek-v4-flash-free",
    message: "400 Upstream request failed: Model is unavailable.",
  });
  assert.equal(result.status, "failed");
  assert.equal(result.failureClass, "model_contract_failure");
  assert.equal(result.diagnosticCode, "model_unavailable");
  assert.equal(result.quotaAccepted, false);
});

test("失败分类报告不回显原始错误正文", () => {
  const secret = "credential-placeholder-should-not-appear";
  const result = classifyDshLiveFailure({
    provider: "opencode-zen",
    model: "mimo-v2.5-free",
    message: `HTTP 502 ${secret}`,
  });
  assert.equal(result.failureClass, "provider_http_error");
  assert.equal(JSON.stringify(result).includes(secret), false);
});

test("DSH 活动配置不再引用已下线模型", () => {
  const fixture = readFileSync(join(REPO_ROOT, "e2e-verify", "fixtures", "dsh", "cordis-oxalpha.yml"), "utf8");
  const cacheRunner = readFileSync(join(REPO_ROOT, "e2e-verify", "real", "dsh-cache-flutter-live.mjs"), "utf8");
  assert.equal(fixture.includes("ox-alpha-free"), false);
  assert.match(fixture, /provider:\s*opencode-zen/);
  assert.match(fixture, /model:\s*deepseek-v4-flash-free/);
  assert.equal(cacheRunner.includes("cordis-oxalpha.yml"), false);
  assert.match(cacheRunner, /\?\?\s*'deepseek-v4-flash-free'/);

  // 根配置属于本机忽略文件；存在时同样禁止旧模型回流，缺失时不阻断可移植测试。
  const rootConfigPath = join(REPO_ROOT, "cordis.yml");
  if (existsSync(rootConfigPath)) {
    assert.equal(readFileSync(rootConfigPath, "utf8").includes("ox-alpha-free"), false);
  }
});
