import assert from "node:assert/strict";
import test from "node:test";

import {
  FLUTTER_RECORDING_FRAME_COUNT,
  FLUTTER_RECORDING_FPS,
  FLUTTER_RECORDING_SCENARIO_MAX_ATTEMPTS,
  FLUTTER_RECORDING_SCENARIO_IDS,
  isRetryableRecordingFailure,
  parseRecordingArgs,
  selectRecordingScenarios,
  validatePassedGateReport,
} from "./record-macos.mjs";
import {
  WINDOW_EVIDENCE_MINIMUM_CANDIDATE_FRAME_COUNT,
  WINDOW_EVIDENCE_FRAME_INTERVAL_MS,
} from "./macos-screenshot.mjs";

test("P6 Flutter 录屏固定使用 5fps、gate report 和三个预登记场景", () => {
  const args = parseRecordingArgs([
    "--gate-report",
    "e2e-verify/reports/example/MOBILE/mobile-01-macos.json",
  ]);

  assert.equal(args.fps, FLUTTER_RECORDING_FPS);
  assert.equal(FLUTTER_RECORDING_SCENARIO_MAX_ATTEMPTS, 2);
  assert.equal(args.gateReport.endsWith("mobile-01-macos.json"), true);
  assert.deepEqual(
    selectRecordingScenarios().map((scenario) => scenario.id),
    FLUTTER_RECORDING_SCENARIO_IDS,
  );
  assert.throws(() => parseRecordingArgs(["--headless"]), /headless/);
  assert.throws(
    () => parseRecordingArgs(["--gate-report", "report.json", "--fps", "3"]),
    /固定为 5fps/,
  );
});

test("P6 Flutter 录屏只重试可恢复的环境型采集失败", () => {
  assert.equal(
    isRetryableRecordingFailure({ failureClass: "environment_or_startup_failure" }),
    true,
  );
  assert.equal(
    isRetryableRecordingFailure({ failureClass: "test_harness_defect" }),
    false,
  );
  assert.equal(isRetryableRecordingFailure(new Error("unexpected")), false);
});

test("P6/v0.2-P5 Flutter 录屏拒绝缺少任一登记场景证据的 full gate", () => {
  assert.throws(
    () =>
      validatePassedGateReport({
        status: "passed",
        headless: false,
        visible_desktop_app: true,
        visual_scenario_runs: [],
      }),
    /缺少以下场景/,
  );
  // 只给部分场景证据仍必须被拒绝。
  assert.throws(
    () =>
      validatePassedGateReport({
        status: "passed",
        headless: false,
        visible_desktop_app: true,
        visual_scenario_runs: [{
          id: "VISUAL-MOBILE-14",
          frame_count: FLUTTER_RECORDING_FRAME_COUNT,
          candidate_frame_count: WINDOW_EVIDENCE_MINIMUM_CANDIDATE_FRAME_COUNT,
          selected_frame_count: FLUTTER_RECORDING_FRAME_COUNT,
          frame_rate_fps: FLUTTER_RECORDING_FPS,
          frame_interval_ms: WINDOW_EVIDENCE_FRAME_INTERVAL_MS,
          candidate_collection_mode: "long-series-minimum",
          collection_duration_limited: false,
          strict_frame_rate: true,
        }],
      }),
    /VISUAL-MOBILE-15/,
  );
  // 全部登记场景都有 5fps 证据才放行。
  assert.equal(
    validatePassedGateReport({
      status: "passed",
      headless: false,
      visible_desktop_app: true,
      visual_scenario_runs: FLUTTER_RECORDING_SCENARIO_IDS.map((id) => ({
        id,
        frame_count: FLUTTER_RECORDING_FRAME_COUNT,
        candidate_frame_count: WINDOW_EVIDENCE_MINIMUM_CANDIDATE_FRAME_COUNT,
        selected_frame_count: FLUTTER_RECORDING_FRAME_COUNT,
        frame_rate_fps: FLUTTER_RECORDING_FPS,
        frame_interval_ms: WINDOW_EVIDENCE_FRAME_INTERVAL_MS,
        candidate_collection_mode: "long-series-minimum",
        collection_duration_limited: false,
        strict_frame_rate: true,
      })),
    }).status,
    "passed",
  );
});
