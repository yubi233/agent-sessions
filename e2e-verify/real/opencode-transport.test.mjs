import assert from "node:assert/strict";
import test from "node:test";

import { classifyTransportResult } from "./opencode-transport-result.mjs";

test("OpenCode transport skip 归为凭据 blocker，不能标记真实模型通过", () => {
  const result = classifyTransportResult({
    code: 0,
    stdout:
      "live gate 标记 blocked\n--- SKIP: TestLiveTransport (0.00s)\nPASS\n",
  });
  assert.equal(result.status, "blocked");
  assert.equal(result.failureClass, "credential_or_quota_blocker");
  assert.equal(result.realModel, false);
  assert.equal(result.realUpstream, false);
});

test("OpenCode transport 只有脱敏 LIVE_SUMMARY 才可通过", () => {
  const result = classifyTransportResult({
    code: 0,
    stdout:
      'LIVE_SUMMARY {"observed_event_types":["turn_started"],"usage":{"input_tokens":2,"output_tokens":1}}\nPASS\n',
  });
  assert.equal(result.status, "passed");
  assert.equal(result.realModel, true);
  assert.deepEqual(result.summary.observed_event_types, ["turn_started"]);
});

test("OpenCode transport 零退出但缺 summary 归为失败", () => {
  const result = classifyTransportResult({ code: 0, stdout: "PASS\n" });
  assert.equal(result.status, "failed");
  assert.equal(result.realModel, false);
});
