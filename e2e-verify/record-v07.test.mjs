import assert from "node:assert/strict";
import test from "node:test";

import {
  V07_RECORDING_FPS,
  V07_RECORDING_QUALITY,
  V07_RECORDING_PROVIDER,
  V07_RECORDING_STEPS,
  parseRecordingArgs,
  validateGateReport,
} from "./record-v07.mjs";

test("V07-10 录屏参数固定为 headed CDP 6fps/jpeg65，并要求 gate 报告", () => {
  const args = parseRecordingArgs(["--gate-report", "report.json", "--fixture"]);
  assert.equal(args.fps, V07_RECORDING_FPS);
  assert.equal(args.quality, V07_RECORDING_QUALITY);
  assert.equal(args.fixture, true);
  assert.equal(V07_RECORDING_PROVIDER, "codex");
  assert.equal(V07_RECORDING_STEPS[2], "打开会话列表");
  assert.throws(() => parseRecordingArgs(["--fixture"]), /gate-report/);
  assert.throws(() => parseRecordingArgs(["--gate-report", "report.json"]), /--fixture/);
  assert.throws(() => parseRecordingArgs(["--gate-report", "report.json", "--fps", "3", "--fixture"]), /固定为 6fps/);
  assert.throws(() => parseRecordingArgs(["--gate-report", "report.json", "--headless"]), /headless/);
});

test("V07-10 真实 gate 默认放行，fixture gate 必须显式声明", () => {
  const realGate = {
    status: "passed",
    headless: false,
    real_browser: true,
    real_model: true,
    real_upstream: true,
  };
  assert.equal(validateGateReport(realGate).status, "passed");
  const fixtureGate = {
    status: "passed",
    headless: false,
    real_browser: true,
    real_model: false,
    real_upstream: false,
    fixture_data: true,
    local_test: true,
  };
  assert.throws(() => validateGateReport(fixtureGate), /--fixture/);
  assert.equal(validateGateReport(fixtureGate, { allowFixture: true }).status, "passed");
  assert.throws(() => validateGateReport({ ...fixtureGate, real_browser: false }, { allowFixture: true }), /headed/);
  assert.throws(() => validateGateReport({ status: "blocked", headless: false }, { allowFixture: true }), /尚未/);
});
