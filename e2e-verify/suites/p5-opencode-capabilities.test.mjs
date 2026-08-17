import assert from "node:assert/strict";
import test from "node:test";

import {
  classifyOpenCodeCapabilityFailure,
  selectFailClosedFallback,
} from "./p5-opencode-capabilities.mjs";

test("P5 OpenCode 缺失服务凭据时明确标记 blocked", () => {
  const outcome = classifyOpenCodeCapabilityFailure(
    new Error("OPENCODE_SERVER_PASSWORD 未配置，无法启动带 Basic Auth 的 opencode serve"),
  );
  assert.equal(outcome.status, "blocked");
  assert.equal(outcome.failureClass, "credential_or_quota_blocker");
});

test("P5 OpenCode 其他启动错误保持失败，不能伪装成凭据阻塞", () => {
  const outcome = classifyOpenCodeCapabilityFailure(new Error("opencode serve exited early (1)"));
  assert.equal(outcome.status, "failed");
  assert.equal(outcome.failureClass, "environment_or_startup_failure");
});

test("P5 OpenCode 共享回退复用 runner 的唯一 fixture owner", () => {
  const sharedAccount = async () => ({ email: "owner@test.dev" });
  const fallback = selectFailClosedFallback({
    suiteRelay: null,
    suiteWeb: null,
    ctx: {
      fixtureAccount: sharedAccount,
      relay: { base: "http://127.0.0.1:8787" },
      web: { base: "http://127.0.0.1:15173" },
    },
  });
  assert.equal(fallback.accountFactory, sharedAccount);
  assert.equal(fallback.relay.base, "http://127.0.0.1:8787");
  assert.equal(fallback.web.base, "http://127.0.0.1:15173");
});

test("P5 OpenCode 专用回退只在 Relay 与 Web 同时存在时使用", () => {
  const sharedAccount = async () => ({ email: "owner@test.dev" });
  const dedicated = selectFailClosedFallback({
    suiteRelay: { base: "http://127.0.0.1:9001" },
    suiteWeb: { base: "http://127.0.0.1:9002" },
    ctx: {
      fixtureAccount: sharedAccount,
      relay: { base: "http://127.0.0.1:8787" },
      web: { base: "http://127.0.0.1:15173" },
    },
  });
  assert.equal(dedicated.relay.base, "http://127.0.0.1:9001");
  assert.equal(dedicated.web.base, "http://127.0.0.1:9002");
  assert.notEqual(dedicated.accountFactory, sharedAccount);
});
