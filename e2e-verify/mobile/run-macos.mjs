#!/usr/bin/env node
// MacBook 本地 Flutter gate：真实窗口负责可见验收，长期 widget/契约套件负责业务断言。
import { existsSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { baseReport, writeReport } from "../lib/report.mjs";
import {
  MACOS_INTEGRATION_TESTS,
  MACOS_MOBILE_CONTENT_SIZE,
  createMacosWindowObserver,
  hasFlutterTestSuccessOutput,
  macosDebugAppExecutable,
  resolveMacosWidgetTests,
  runMacosFlutterBuild,
  runMacosFlutterWidgetTests,
  runMacosPrebuiltApp,
} from "./macos.mjs";
import {
  captureMacosWindowFrameSeries,
  writeMacosScreenshotManifest,
} from "./macos-screenshot.mjs";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..");
const MOBILE_ROOT = join(ROOT, "apps", "mobile");
const DEFAULT_TIMEOUT_MS = 300_000;
const DEFAULT_CASES = [...new Set(MACOS_INTEGRATION_TESTS.flatMap((entry) => entry.testIds))];
const SCREENSHOT_FRAME_RATE_FPS = 5;
const SCREENSHOT_FRAME_DURATION_MS = 1_000;
const SCREENSHOT_SCENARIO_SETTLE_MS = 800;
export const MACOS_SCREENSHOT_SCENARIOS = Object.freeze([
  Object.freeze({
    id: "VISUAL-MOBILE-01",
    directory: "visual-mobile-01-login",
    localVisualScenario: null,
  }),
  Object.freeze({
    id: "VISUAL-MOBILE-02",
    directory: "visual-mobile-02-owner-ready",
    localVisualScenario: "owner-ready",
  }),
  Object.freeze({
    id: "VISUAL-PAIR-01",
    directory: "visual-pair-01-pending",
    localVisualScenario: "pairing-pending",
  }),
]);

function wait(milliseconds) {
  return new Promise((resolveWait) => setTimeout(resolveWait, milliseconds));
}

/// 每个视觉场景单独启动真实 Flutter 窗口，并在稳定后连续采样，避免截图工作侵入 integration_test 的退出链路。
export async function recordMacosVisualScenario({
  scenario,
  screenshotDirectory,
  appPath,
  observeWindow,
  runPrebuiltApp = runMacosPrebuiltApp,
  captureFrames = captureMacosWindowFrameSeries,
  waitForStableFrame = wait,
}) {
  const smoke = await runPrebuiltApp({
    appPath,
    cwd: MOBILE_ROOT,
    observeWindow,
    localVisualScenario: scenario.localVisualScenario,
    // onWindowObserved 会等待稳定并采完帧；随后才开始受控退出，保证不会截到退出中的窗口。
    stopAfterWindowMs: 400,
    onWindowObserved: async (window) => {
      await waitForStableFrame(SCREENSHOT_SCENARIO_SETTLE_MS);
      return captureFrames({
        windowId: window.id,
        outputDirectory: join(screenshotDirectory, scenario.directory),
        scenarioId: scenario.id,
        fps: SCREENSHOT_FRAME_RATE_FPS,
        durationMs: SCREENSHOT_FRAME_DURATION_MS,
      });
    },
  });

  // 预构建 app 由本轮 runner 在抓帧完成后 SIGTERM 回收；这属于受控成功退出，不应按 flutter run 的退出码规则判失败。
  const controlledExit = smoke.code === 0
    || (smoke.gracefulExitRequested && smoke.signal === "SIGTERM");
  if (
    smoke.timedOut
    || !controlledExit
    || !smoke.window.observed
    || !smoke.window.portraitMobileWindowObserved
  ) {
    throw new GateError(`视觉场景 ${scenario.id} 的可见 macOS 窗口未正常完成。`, {
      failureClass: "environment_or_startup_failure",
    });
  }
  if (smoke.window.captureError != null) {
    throw new GateError(`视觉场景 ${scenario.id} 的连续截图失败。`, {
      failureClass: "environment_or_startup_failure",
    });
  }
  const frames = smoke.window.captureArtifacts.filter(
    (artifact) => artifact?.scenarioId === scenario.id,
  );
  if (frames.length !== SCREENSHOT_FRAME_RATE_FPS) {
    throw new GateError(
      `视觉场景 ${scenario.id} 未采集到完整 ${SCREENSHOT_FRAME_RATE_FPS} 帧序列。`,
      { failureClass: "environment_or_startup_failure" },
    );
  }
  return { frames, smoke };
}

class GateError extends Error {
  constructor(message, { failureClass = "test_harness_defect" } = {}) {
    super(message);
    this.failureClass = failureClass;
  }
}

function positiveInteger(value, flag) {
  const parsed = Number.parseInt(value, 10);
  if (!Number.isFinite(parsed) || parsed <= 0) {
    throw new GateError(`${flag} 必须是正整数。`);
  }
  return parsed;
}

export function parseArgs(argv) {
  const args = {
    tests: [],
    cases: [],
    diagnostic: false,
    help: false,
    testTimeoutMs: DEFAULT_TIMEOUT_MS,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const value = argv[index];
    if (value === "--help" || value === "-h") args.help = true;
    else if (value === "--test") args.tests.push(argv[++index] || "");
    else if (value === "--case") args.cases.push(argv[++index] || "");
    else if (value === "--diagnostic") args.diagnostic = true;
    else if (value === "--test-timeout-ms") {
      args.testTimeoutMs = positiveInteger(argv[++index], "--test-timeout-ms");
    } else if (value === "--headless") {
      throw new GateError("MacBook Flutter gate 不支持 --headless。", {
        failureClass: "test_harness_defect",
      });
    } else if (value === "--device-id" || value === "-d") {
      throw new GateError("MacBook Flutter gate 固定使用 macOS，不接受 --device-id。", {
        failureClass: "test_harness_defect",
      });
    } else {
      throw new GateError(`未知参数：${value}`);
    }
  }
  if (args.tests.some((test) => !test)) throw new GateError("--test 缺少路径。");
  if (args.cases.some((testCase) => !testCase)) throw new GateError("--case 缺少稳定 ID。");
  return args;
}

export function usage() {
  return [
    "用法：node e2e-verify/mobile/run-macos.mjs [options]",
    "  --test <relative-path>      指定 apps/mobile/test 下的 widget/契约用例，可重复",
    "  --case <stable-test-id>     写入报告的稳定测试 ID，可重复",
    "  --test-timeout-ms <ms>      单个 Flutter widget/契约测试等待上限",
    "  --diagnostic                仅即时输出 Flutter 原始诊断，不写入报告",
    "  --help, -h                  显示帮助",
    "  --headless                  明确拒绝；本 gate 必须观测可见 macOS 窗口",
  ].join("\n");
}

function safeError(error) {
  const message = error instanceof Error ? error.message : String(error);
  return message
    .replace(/(bearer\s+)[^\s"']+/gi, "$1[REDACTED]")
    .replace(/([?&](?:token|password|secret)=)[^&#\s"']+/gi, "$1[REDACTED]")
    .slice(0, 500);
}

export function classifyFlutterFailure(result) {
  const output = `${result.stdout}\n${result.stderr}`;
  if (result.timedOut || result.code == null) return "environment_or_startup_failure";
  if (/Build process failed|No supported devices|Unable to find a device/i.test(output)) {
    return "environment_or_startup_failure";
  }
  if (
    /would not hit test|pumpAndSettle|TestFailure.*test harness|PathNotFoundException|stream_channel|flutter_tools.*(?:listener|finalization)/i.test(output)
  ) {
    return "test_harness_defect";
  }
  return "product_defect";
}

/// 原始 Flutter 输出不落盘；失败摘要只保留测试框架的有限高信号行，并继续经过统一脱敏。
export function summarizeFlutterFailure(output) {
  const lines = String(output)
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean);
  const relevant = lines.filter((line) => /exception|expected:|actual:|testfailure|test failed|finder|error:/i.test(line));
  return safeError((relevant.length > 0 ? relevant : lines.slice(-6)).slice(0, 6).join(" | "));
}

async function main() {
  const timestamp = new Date().toISOString().replace(/[:.]/g, "-");
  const startedAt = Date.now();
  let args = null;
  let tests = [];
  let status = "failed";
  let failureClass = "test_harness_defect";
  let remainingRisk = "";
  let testResults = [];
  let smoke = null;
  let visualScenarioRuns = [];
  let screenshotArtifacts = [];
  let screenshotEntries = [];
  let screenshotDirectory = null;
  let screenshotManifestPath = null;
  let windowObserver = null;
  let prebuiltBuild = null;
  let prebuiltAppPath = null;
  let command = "flutter build macos --debug --no-pub && node e2e-verify/mobile/run-macos.mjs";

  try {
    args = parseArgs(process.argv.slice(2));
    if (args.help) {
      process.stdout.write(`${usage()}\n`);
      return;
    }
    if (process.platform !== "darwin") {
      throw new GateError("本轮 Flutter local gate 只能在 macOS 主机执行。", {
        failureClass: "environment_or_startup_failure",
      });
    }
    if (!existsSync(join(MOBILE_ROOT, "macos", "Runner.xcodeproj"))) {
      throw new GateError("apps/mobile 缺少 macOS 平台壳。", {
        failureClass: "environment_or_startup_failure",
      });
    }

    tests = resolveMacosWidgetTests(MOBILE_ROOT, args.tests);
    windowObserver = await createMacosWindowObserver();
    const existingWindow = await windowObserver.observe();
    if (existingWindow.count > 0) {
      throw new GateError("检测到已有 Agent Sessions macOS 窗口，拒绝将用户实例当作本轮验收。", {
        failureClass: "environment_or_startup_failure",
      });
    }
    process.stdout.write("[macos-e2e] 构建本轮固定的 macOS debug App\n");
    prebuiltBuild = await runMacosFlutterBuild({ cwd: MOBILE_ROOT });
    if (prebuiltBuild.code !== 0 || prebuiltBuild.timedOut) {
      throw new GateError("Flutter macOS debug App 构建未完成。", {
        failureClass: classifyFlutterFailure(prebuiltBuild),
      });
    }
    prebuiltAppPath = macosDebugAppExecutable(MOBILE_ROOT);
    if (!existsSync(prebuiltAppPath)) {
      throw new GateError("Flutter macOS debug App 构建后未找到可执行文件。", {
        failureClass: "environment_or_startup_failure",
      });
    }
    for (const testPath of tests) {
      process.stdout.write(`[macos-e2e] 运行 Flutter widget/契约回归：${testPath}\n`);
      const result = await runMacosFlutterWidgetTests({
        testPath,
        cwd: MOBILE_ROOT,
        timeoutMs: args.testTimeoutMs,
      });
      if (args.diagnostic) {
        // 原始 Flutter 输出只留在当前终端，报告只保存退出码和测试计数。
        process.stdout.write(`[macos-e2e] ${testPath} diagnostic output (not persisted):\n`);
        process.stdout.write(`${result.stdout}${result.stderr}`);
        process.stdout.write("\n[macos-e2e] End Flutter diagnostic output\n");
      }
      const testSuccessOutputObserved = hasFlutterTestSuccessOutput(
        `${result.stdout}\n${result.stderr}`,
      );
      const passed = result.code === 0 && !result.timedOut && testSuccessOutputObserved;
      testResults.push({
        path: testPath,
        test_ids: DEFAULT_CASES,
        requires_visible_window: false,
        passed,
        exit_code: result.code,
        timed_out: result.timedOut,
        test_success_output_observed: testSuccessOutputObserved,
        failure_summary: passed ? null : summarizeFlutterFailure(`${result.stdout}\n${result.stderr}`),
        visible_desktop_app_during_test: false,
      });
      if (!passed) {
        failureClass = classifyFlutterFailure(result);
        remainingRisk = result.timedOut
          ? `${testPath} 超时；请检查 Flutter 测试环境。`
          : `${testPath} 的 Flutter widget/契约测试未通过。`;
        break;
      }
    }

    if (testResults.length === tests.length && testResults.every((result) => result.passed)) {
      // 业务断言全部通过后才开始 5fps 可见窗口采样，截图是补充证据而非提前替代 gate。
      process.stdout.write("[macos-e2e] 启动预构建 App 并采集 5fps 视觉证据\n");
      screenshotDirectory = join(ROOT, "e2e-verify", "screenshots", timestamp, "MOBILE");
      for (const scenario of MACOS_SCREENSHOT_SCENARIOS) {
        process.stdout.write(`[macos-e2e] 录制 5fps 视觉场景：${scenario.id}\n`);
        const visualRun = await recordMacosVisualScenario({
          scenario,
          screenshotDirectory,
          appPath: prebuiltAppPath,
          observeWindow: () => windowObserver.observe(),
        });
        visualScenarioRuns.push({ scenario, ...visualRun });
        screenshotEntries.push(...visualRun.frames);
        smoke ??= visualRun.smoke;
        if (args.diagnostic) {
          // 原始应用输出只留在当前终端，报告只保存窗口观测和帧元数据。
          process.stdout.write(`[macos-e2e] ${scenario.id} diagnostic output (not persisted):\n`);
          process.stdout.write(`${visualRun.smoke.stdout}${visualRun.smoke.stderr}`);
          process.stdout.write("\n[macos-e2e] End visual scenario diagnostic output\n");
        }
      }
      const capturedScenarioIds = new Set(
        screenshotEntries.map((artifact) => artifact.scenarioId).filter(Boolean),
      );
      const missingScenarios = MACOS_SCREENSHOT_SCENARIOS
        .map((scenario) => scenario.id)
        .filter((scenarioId) => !capturedScenarioIds.has(scenarioId));
      if (missingScenarios.length > 0) {
        throw new GateError(
          `本轮已登记截图未完整生成：${missingScenarios.join(", ")}。`,
          { failureClass: "environment_or_startup_failure" },
        );
      }
      status = "passed";
      failureClass = null;
      remainingRisk = "macOS 26 + Flutter 3.47 的 flutter test -d macos 存在官方 open/VM 握手回归；integration_test 保留给后续 Android 原生或工具链修复后的 macOS gate。";
    }
  } catch (error) {
    status = "failed";
    failureClass = error instanceof GateError ? error.failureClass : "test_harness_defect";
    remainingRisk = safeError(error);
  } finally {
    if (screenshotEntries.length > 0 && screenshotDirectory != null) {
      try {
        if (
          screenshotManifestPath == null
          && smoke?.window.portraitMobileWindow != null
        ) {
          screenshotManifestPath = writeMacosScreenshotManifest({
            outputDirectory: screenshotDirectory,
            timestamp,
            declaredScenarioIds: MACOS_SCREENSHOT_SCENARIOS.map(
              (scenario) => scenario.id,
            ),
            artifacts: screenshotEntries,
            targetMobileContentSize: MACOS_MOBILE_CONTENT_SIZE,
            windowFrame: {
              height: smoke.window.portraitMobileWindow.height,
              width: smoke.window.portraitMobileWindow.width,
            },
            windowMode: smoke.window.portraitMobileWindowMode,
            frameRateFps: SCREENSHOT_FRAME_RATE_FPS,
          });
        }
        screenshotArtifacts = [
          ...screenshotEntries.map((artifact) => artifact.path),
          ...(screenshotManifestPath != null ? [screenshotManifestPath] : []),
        ];
      } catch (error) {
        status = "failed";
        failureClass = "environment_or_startup_failure";
        remainingRisk = safeError(error);
      }
    }
    windowObserver?.dispose();
    if (args?.help) return;
    const visibleDesktopApp = Boolean(smoke?.window.observed);
    const report = baseReport({
      suite: "mobile-macos-local-gate",
      status,
      real_browser: false,
      real_model: false,
      real_upstream: false,
      fixture_data: true,
      local_test: true,
      headless: false,
      browser: "n/a",
      command,
      artifacts: screenshotArtifacts,
      failure_class: failureClass,
      remaining_risk: remainingRisk,
    });
    const reportPath = writeReport({
      planId: "MOBILE",
      name: "mobile-01-macos",
      report: {
        timestamp,
        ...report,
        gate_kind: "flutter_macos_visible_widget_gate",
        host_platform: "macos",
        real_device: false,
        simulated_device: false,
        visible_desktop_app: visibleDesktopApp,
        test_ids: args?.cases.length ? args.cases : DEFAULT_CASES,
        functional_widget_tests: tests,
        deferred_native_integration_tests: MACOS_INTEGRATION_TESTS.map((entry) => entry.path),
        native_integration_status: "deferred_due_to_flutter_macos_open_vm_handshake_regression",
        fixture_revision: "local-deterministic-fixture",
        prebuilt_debug_build: prebuiltBuild && {
          exit_code: prebuiltBuild.code,
          timed_out: prebuiltBuild.timedOut,
          app_executable: prebuiltAppPath,
        },
        visible_app_launcher: "prebuilt-macos-debug-app",
        target_mobile_content_size: MACOS_MOBILE_CONTENT_SIZE,
        macos_phone_canvas_mode: "480x960-logical-scaled-when-host-is-shorter",
        test_summary: {
          total: testResults.length,
          passed: testResults.filter((result) => result.passed).length,
          failed: testResults.filter((result) => !result.passed).length,
        },
        visible_desktop_smoke: smoke && {
          exit_code: smoke.code,
          timed_out: smoke.timedOut,
          graceful_exit_requested: smoke.gracefulExitRequested,
          visible_desktop_app: smoke.window.observed,
          portrait_mobile_window_observed: smoke.window.portraitMobileWindowObserved,
          observed_window_frame: smoke.window.portraitMobileWindow,
          observed_window_mode: smoke.window.portraitMobileWindowMode,
          screenshot_capture_error: smoke.window.captureError,
          screenshot_count: smoke.window.captureArtifacts.length,
          maximum_window_count: smoke.window.maximumWindowCount,
          window_observation_attempts: smoke.window.observationAttempts,
          window_observer_errors: smoke.window.observerErrors,
          controlled_exit_requested: smoke.gracefulExitRequested,
        },
        visual_scenario_runs: visualScenarioRuns.map(({ scenario, smoke: scenarioSmoke, frames }) => ({
          id: scenario.id,
          frame_count: frames.length,
          exit_code: scenarioSmoke.code,
          signal: scenarioSmoke.signal,
          timed_out: scenarioSmoke.timedOut,
          controlled_exit_requested: scenarioSmoke.gracefulExitRequested,
          observed_window_frame: scenarioSmoke.window.portraitMobileWindow,
          observed_window_mode: scenarioSmoke.window.portraitMobileWindowMode,
        })),
        test_results: testResults,
        duration_ms: Date.now() - startedAt,
      },
    });
    process.stdout.write(`[macos-e2e] ${status} -> ${reportPath}\n`);
    if (status !== "passed") process.exitCode = 1;
  }
}

const invokedPath = process.argv[1] ? resolve(process.argv[1]) : "";
if (invokedPath === fileURLToPath(import.meta.url)) {
  main().catch((error) => {
    process.stderr.write(`[macos-e2e] ${safeError(error)}\n`);
    process.exitCode = 1;
  });
}
