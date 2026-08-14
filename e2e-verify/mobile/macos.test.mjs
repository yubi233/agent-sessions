// MacBook Flutter gate 的纯 Node 回归：不启动 Xcode、Flutter 或桌面窗口。
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import {
  MACOS_APP_PROCESS,
  MACOS_MOBILE_CONTENT_SIZE,
  flutterMacosBuildArgs,
  flutterMacosArgs,
  flutterMacosSmokeArgs,
  flutterWidgetTestArgs,
  hasFlutterTestSuccessOutput,
  isMacosPortraitMobileWindow,
  listMacosIntegrationTests,
  macosDebugAppExecutable,
  macosWindowObserverArgs,
  macosPortraitWindowMode,
  parseMacosWindowCount,
  parseMacosWindowObservation,
  resolveMacosIntegrationTests,
  resolveMacosWidgetTests,
  runMacosFlutterBuild,
  runMacosFlutterTest,
  runMacosFlutterWidgetTests,
  runMacosPrebuiltApp,
} from "./macos.mjs";
import {
  classifyFlutterFailure,
  parseArgs,
  summarizeFlutterFailure,
} from "./run-macos.mjs";

function mobileFixtureRoot() {
  const root = mkdtempSync(join(tmpdir(), "macos-runner-"));
  const integration = join(root, "integration_test");
  const tests = join(root, "test");
  mkdirSync(integration, { recursive: true });
  mkdirSync(tests, { recursive: true });
  writeFileSync(join(integration, "w1_auth_pairing_flow_test.dart"), "void main() {}\n");
  writeFileSync(join(integration, "w1_visual_owner_fixture_test.dart"), "void main() {}\n");
  writeFileSync(join(integration, "w1_macos_drift_cache_test.dart"), "void main() {}\n");
  writeFileSync(join(tests, "widget_test.dart"), "void main() {}\n");
  return root;
}

test("macOS full gate 只发现已登记的长期 integration_test", () => {
  const root = mobileFixtureRoot();
  assert.deepEqual(
    listMacosIntegrationTests(root).map((entry) => entry.path),
    [
      "integration_test/w1_auth_pairing_flow_test.dart",
      "integration_test/w1_visual_owner_fixture_test.dart",
      "integration_test/w1_macos_drift_cache_test.dart",
    ],
  );
  assert.deepEqual(
    resolveMacosIntegrationTests(root, ["integration_test/w1_auth_pairing_flow_test.dart"]).map((entry) => entry.path),
    ["integration_test/w1_auth_pairing_flow_test.dart"],
  );
  assert.throws(
    () => resolveMacosIntegrationTests(root, ["integration_test/w1_signed_native_secure_storage_test.dart"]),
    /未登记/,
  );
  assert.throws(() => resolveMacosIntegrationTests(root, ["../outside_test.dart"]), /未登记|无效/);
  assert.deepEqual(resolveMacosWidgetTests(root), ["test"]);
  assert.deepEqual(resolveMacosWidgetTests(root, ["test/widget_test.dart"]), ["test/widget_test.dart"]);
  assert.throws(() => resolveMacosWidgetTests(root, ["integration_test/w1_auth_pairing_flow_test.dart"]), /不在/);
});

test("macOS Flutter 命令固定设备、禁止隐式 pub 解析", () => {
  assert.deepEqual(
    flutterMacosArgs("integration_test/w1_auth_pairing_flow_test.dart"),
    ["test", "integration_test/w1_auth_pairing_flow_test.dart", "-d", "macos", "--no-pub"],
  );
  assert.deepEqual(flutterWidgetTestArgs("test/widget_test.dart"), ["test", "test/widget_test.dart", "--no-pub", "--concurrency=1"]);
  assert.deepEqual(
    flutterMacosSmokeArgs(),
    ["run", "-d", "macos", "--no-pub", "--dart-define=LOCAL_FIXTURE_MODE=true"],
  );
  assert.deepEqual(flutterMacosBuildArgs(), ["build", "macos", "--debug", "--no-pub"]);
  assert.equal(
    macosDebugAppExecutable("/fixture/mobile"),
    "/fixture/mobile/build/macos/Build/Products/Debug/agent_sessions_mobile.app/Contents/MacOS/agent_sessions_mobile",
  );
});

test("macOS gate 拒绝 headless 和外部设备参数", () => {
  assert.equal(parseArgs([]).diagnostic, false);
  assert.equal(parseArgs(["--diagnostic"]).diagnostic, true);
  assert.throws(() => parseArgs(["--headless"]), /不支持 --headless/);
  assert.throws(() => parseArgs(["--device-id", "android-device"]), /固定使用 macOS/);
});

test("桌面窗口观测器只接受固定应用进程名、结构化窗口元数据和竖屏尺寸", () => {
  const observation = parseMacosWindowObservation(
    '{"count":1,"windows":[{"id":41,"pid":301,"width":480,"height":988}]}',
  );
  assert.equal(parseMacosWindowCount(JSON.stringify(observation)), 1);
  assert.deepEqual(observation.windows[0], { id: 41, pid: 301, width: 480, height: 988 });
  assert.equal(isMacosPortraitMobileWindow(observation.windows[0]), true);
  assert.equal(macosPortraitWindowMode(observation.windows[0]), "native");
  assert.equal(
    macosPortraitWindowMode({ id: 43, pid: 303, width: 480, height: 800 }),
    "scaled_preview",
  );
  assert.equal(
    isMacosPortraitMobileWindow({ id: 42, pid: 302, width: 960, height: 480 }),
    false,
  );
  assert.deepEqual(MACOS_MOBILE_CONTENT_SIZE, { height: 960, width: 480 });
  assert.equal(parseMacosWindowCount("unexpected"), 0);
  assert.deepEqual(macosWindowObserverArgs(), ["--process-name", MACOS_APP_PROCESS]);
  assert.throws(() => macosWindowObserverArgs("untrusted-process"), /只允许/);
});

test("macOS integration 由 Flutter 生命周期关闭宿主，runner 不发送成功路径的 SIGTERM", () => {
  assert.equal(hasFlutterTestSuccessOutput("00:12 +1: All tests passed!"), true);
  assert.equal(hasFlutterTestSuccessOutput("00:12 +1: Test failed"), false);
  const onOutput = () => null;
  const options = runMacosFlutterTest({
    testPath: "integration_test/w1_auth_pairing_flow_test.dart",
    cwd: "/fixture/mobile",
    onOutput,
    runProcess: (received) => received,
  });
  assert.equal(options.stopAfterOutputPattern, undefined);
  assert.equal(options.closeObservedWindowsAfterMs, undefined);
  assert.equal(options.terminateObservedWindows, undefined);
  assert.equal(options.onOutput, onOutput);
});

test("macOS 本地 gate 的 widget 回归不绑定 device attach", () => {
  const options = runMacosFlutterWidgetTests({
    testPath: "test/widget_test.dart",
    cwd: "/fixture/mobile",
    runProcess: (received) => received,
  });
  assert.deepEqual(options.args, ["test", "test/widget_test.dart", "--no-pub", "--concurrency=1"]);
  assert.equal(options.observeWindow().then != null, true);
  assert.equal(options.stopAfterOutputPattern, undefined);
});

test("macOS 可见截图从预构建 App 启动，并只给本轮观测窗口受控退出", () => {
  const build = runMacosFlutterBuild({
    cwd: "/fixture/mobile",
    runProcess: (received) => received,
  });
  assert.deepEqual(build.args, ["build", "macos", "--debug", "--no-pub"]);
  assert.equal(build.observeWindow().then != null, true);

  const prebuilt = runMacosPrebuiltApp({
    appPath: "/fixture/mobile/build/macos/Build/Products/Debug/agent_sessions_mobile.app/Contents/MacOS/agent_sessions_mobile",
    cwd: "/fixture/mobile",
    localVisualScenario: "owner-ready",
    env: { LOCAL_VISUAL_SCENARIO: "stale-host-value" },
    runProcess: (received) => received,
  });
  assert.deepEqual(prebuilt.args, []);
  assert.equal(
    prebuilt.flutter,
    "/fixture/mobile/build/macos/Build/Products/Debug/agent_sessions_mobile.app/Contents/MacOS/agent_sessions_mobile",
  );
  assert.equal(prebuilt.env.LOCAL_FIXTURE_MODE, "true");
  assert.equal(prebuilt.env.LOCAL_VISUAL_SCENARIO, "owner-ready");
  assert.equal(prebuilt.terminateObservedWindows, true);

  const login = runMacosPrebuiltApp({
    appPath: prebuilt.flutter,
    cwd: "/fixture/mobile",
    localVisualScenario: null,
    env: { LOCAL_VISUAL_SCENARIO: "stale-host-value" },
    runProcess: (received) => received,
  });
  assert.equal(login.env.LOCAL_VISUAL_SCENARIO, "");
});

test("macOS Flutter 失败摘要只保留有限的测试框架信号", () => {
  assert.match(
    summarizeFlutterFailure("token=secret\nExpected: finder\nActual: no widget\nTest failed."),
    /Expected: finder.*Actual: no widget.*Test failed/i,
  );
  assert.doesNotMatch(
    summarizeFlutterFailure("token=secret\nExpected: finder\nActual: no widget\nTest failed."),
    /secret/,
  );
});

test("macOS Flutter 工具 listener 清理竞态归为 harness，不误报产品缺陷", () => {
  assert.equal(
    classifyFlutterFailure({
      code: 79,
      stderr: "PathNotFoundException: Deletion failed\nflutter_tools listener finalization",
      stdout: "",
      timedOut: false,
    }),
    "test_harness_defect",
  );
  assert.equal(
    classifyFlutterFailure({
      code: 1,
      stderr: "",
      stdout: "Expected: revoked\nActual: pending",
      timedOut: false,
    }),
    "product_defect",
  );
});
