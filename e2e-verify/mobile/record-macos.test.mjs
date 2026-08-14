import assert from "node:assert/strict";
import test from "node:test";

import {
  FLUTTER_RECORDING_FPS,
  FLUTTER_RECORDING_SCENARIO_IDS,
  parseRecordingArgs,
  selectRecordingScenarios,
  validatePassedGateReport,
} from "./record-macos.mjs";

test("P6 Flutter 录屏固定使用 5fps、gate report 和三个预登记场景", () => {
  const args = parseRecordingArgs([
    "--gate-report",
    "e2e-verify/reports/example/MOBILE/mobile-01-macos.json",
  ]);

  assert.equal(args.fps, FLUTTER_RECORDING_FPS);
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

test("P6 Flutter 录屏拒绝没有 VISUAL-MOBILE-14 证据的 full gate", () => {
  assert.throws(
    () =>
      validatePassedGateReport({
        status: "passed",
        headless: false,
        visible_desktop_app: true,
        visual_scenario_runs: [],
      }),
    /VISUAL-MOBILE-14/,
  );
  assert.equal(
    validatePassedGateReport({
      status: "passed",
      headless: false,
      visible_desktop_app: true,
      visual_scenario_runs: [{ id: "VISUAL-MOBILE-14", frame_count: 5 }],
    }).status,
    "passed",
  );
});
