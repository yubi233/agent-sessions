import assert from "node:assert/strict";
import test from "node:test";

import {
  MAX_PROVIDER_RETRIES,
  OPENCODE_LIVE_MODEL,
  isRecoverableProviderFailure,
  observeJsonEvents,
  parseOpenCodeLiveArgs,
  validateArithmeticResponse,
  validateComparisonResponse,
} from "./opencode-live.mjs";

test("OpenCode live smoke 固定默认模型并限制可恢复重试次数", () => {
  const args = parseOpenCodeLiveArgs([]);
  assert.equal(args.model, OPENCODE_LIVE_MODEL);
  assert.equal(args.retries, MAX_PROVIDER_RETRIES);
  assert.equal(parseOpenCodeLiveArgs(["--retries", "0"]).retries, 0);
  assert.throws(
    () => parseOpenCodeLiveArgs(["--retries", "4"]),
    /不能超过/,
  );
  assert.throws(
    () => parseOpenCodeLiveArgs(["--provider", "codex"]),
    /只实现 opencode/,
  );
});

test("OpenCode live smoke 只接受最小响应与比较审阅契约", () => {
  assert.deepEqual(validateArithmeticResponse('{"sum":42}'), {
    arithmetic_verified: true,
  });
  assert.throws(() => validateArithmeticResponse('{"sum":41}'), /算术/);
  assert.deepEqual(
    validateComparisonResponse('{"highest_priority_gap":"provider_transport"}'),
    { highest_priority_gap: "provider_transport" },
  );
  assert.throws(
    () => validateComparisonResponse('{"highest_priority_gap":"unknown"}'),
    /优先级/,
  );
  assert.equal(isRecoverableProviderFailure("provider_timeout"), true);
  assert.equal(isRecoverableProviderFailure("provider_http_error"), true);
  assert.equal(isRecoverableProviderFailure("model_contract_failure"), false);
});

test("OpenCode 1.17 顶层 text event 被识别为模型响应而非用户 prompt", () => {
  const observed = observeJsonEvents(
    '{"type":"step-start","sessionID":"fixture-session"}\n' +
      '{"type":"text","part":{"text":"{\\"sum\\":42}"}}\n' +
      '{"type":"step-finish","tokens":{"input":7,"output":3}}\n',
  );

  assert.equal(observed.assistant_text_observed, true);
  assert.equal(observed.assistant_text, '{"sum":42}');
  assert.deepEqual(observed.usage, {
    inputTokens: 7,
    observed: true,
    outputTokens: 3,
  });
  assert.deepEqual(observed.request_ids, [
    "sha256:d6440983c454c2e5",
  ]);
});
