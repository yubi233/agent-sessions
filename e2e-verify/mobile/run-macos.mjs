#!/usr/bin/env node
// MacBook 本地 Flutter gate：真实窗口负责可见验收，长期 widget/契约套件负责业务断言。
import { existsSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { baseReport, writeReport } from "../lib/report.mjs";
import {
  MACOS_INTEGRATION_TESTS,
  MACOS_MOBILE_CONTENT_SIZE,
  createMacosWindowObserver,
  hasFlutterTestSuccessOutput,
  macosDebugAppExecutable,
  macosSandboxVisualFrameDirectory,
  resolveMacosWidgetTests,
  runMacosFlutterBuild,
  runMacosFlutterWidgetTests,
  runMacosPrebuiltApp,
} from "./macos.mjs";
import {
  captureMacosWindowFrameSeries,
  waitForFlutterRenderFrameSeries,
  writeMacosScreenshotManifest,
} from "./macos-screenshot.mjs";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..");
const MOBILE_ROOT = join(ROOT, "apps", "mobile");
const DEFAULT_TIMEOUT_MS = 300_000;
const DEFAULT_CASES = [...new Set(MACOS_INTEGRATION_TESTS.flatMap((entry) => entry.testIds))];
const SCREENSHOT_FRAME_RATE_FPS = 5;
const SCREENSHOT_FRAME_DURATION_MS = 1_000;
const SCREENSHOT_SCENARIO_SETTLE_MS = 800;
const FLUTTER_RENDER_FRAME_TIMEOUT_MS = 15_000;
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
  Object.freeze({
    id: "VISUAL-MOBILE-03",
    directory: "visual-mobile-03-session-list",
    localVisualScenario: "session-list",
  }),
  Object.freeze({
    id: "VISUAL-MOBILE-04",
    directory: "visual-mobile-04-session-detail",
    localVisualScenario: "session-detail",
  }),
  Object.freeze({
    id: "VISUAL-MOBILE-05",
    directory: "visual-mobile-05-session-readonly",
    localVisualScenario: "session-readonly",
  }),
  Object.freeze({
    id: "VISUAL-MOBILE-06",
    directory: "visual-mobile-06-capability-panel",
    localVisualScenario: "session-capability",
  }),
  Object.freeze({
    id: "VISUAL-MOBILE-07",
    directory: "visual-mobile-07-skill-confirmation",
    localVisualScenario: "session-skill-confirmation",
  }),
  Object.freeze({
    id: "VISUAL-MOBILE-08",
    directory: "visual-mobile-08-attachment-composer",
    localVisualScenario: "session-attachments",
  }),
  Object.freeze({
    id: "VISUAL-MOBILE-09",
    directory: "visual-mobile-09-git-diff",
    localVisualScenario: "session-git-main",
  }),
  Object.freeze({
    id: "VISUAL-MOBILE-10",
    directory: "visual-mobile-10-git-restricted",
    localVisualScenario: "session-git-restricted",
  }),
  Object.freeze({
    id: "VISUAL-MOBILE-11",
    directory: "visual-mobile-11-delegation-proposed",
    localVisualScenario: "session-delegation-proposed",
  }),
  Object.freeze({
    id: "VISUAL-MOBILE-12",
    directory: "visual-mobile-12-delegation-approved",
    localVisualScenario: "session-delegation-approved",
  }),
  Object.freeze({
    id: "VISUAL-MOBILE-13",
    directory: "visual-mobile-13-delegation-restricted",
    localVisualScenario: "session-delegation-restricted",
  }),
  Object.freeze({
    id: "VISUAL-MOBILE-14",
    directory: "visual-mobile-14-lifecycle-recovery",
    localVisualScenario: "session-lifecycle-recovery",
  }),
  Object.freeze({
    id: "VISUAL-MOBILE-15",
    directory: "visual-mobile-15-quick-menu-resume",
    localVisualScenario: "session-quick-menu",
  }),
  Object.freeze({
    id: "VISUAL-MOBILE-16",
    directory: "visual-mobile-16-files-browse",
    localVisualScenario: "session-files-browse",
  }),
  Object.freeze({
    id: "VISUAL-MOBILE-17",
    directory: "visual-mobile-17-composer-controls",
    localVisualScenario: "session-composer-controls",
  }),
  Object.freeze({
    id: "VISUAL-MOBILE-18",
    directory: "visual-mobile-18-permission-usage",
    localVisualScenario: "session-composer-controls",
  }),
  Object.freeze({
    id: "VISUAL-MOBILE-19",
    directory: "visual-mobile-19-goal-edit",
    localVisualScenario: "session-goal-edit",
  }),
  Object.freeze({
    id: "VISUAL-MOBILE-20",
    directory: "visual-mobile-20-provider-unavailable",
    localVisualScenario: "session-provider-unavailable",
  }),
  Object.freeze({
    id: "VISUAL-MOBILE-21",
    directory: "visual-mobile-21-terminal-status",
    localVisualScenario: "terminal-status",
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
  waitForFlutterRenderFrames = waitForFlutterRenderFrameSeries,
  waitForStableFrame = wait,
}) {
  const outputDirectory = join(screenshotDirectory, scenario.directory);
  const sandboxDirectoryName = [
    "agent-sessions-visual",
    basename(dirname(screenshotDirectory)),
    scenario.directory,
  ].join("-");
  const sandboxFrameDirectory = macosSandboxVisualFrameDirectory(
    sandboxDirectoryName,
  );
  const smoke = await runPrebuiltApp({
    appPath,
    cwd: MOBILE_ROOT,
    observeWindow,
    localVisualScenario: scenario.localVisualScenario,
    localVisualFrameDirectoryName: sandboxDirectoryName,
    localVisualFrameCount: SCREENSHOT_FRAME_RATE_FPS,
    localVisualFrameIntervalMs: Math.round(1_000 / SCREENSHOT_FRAME_RATE_FPS),
    // onWindowObserved 会等待稳定并采完帧；随后才开始受控退出，保证不会截到退出中的窗口。
    stopAfterWindowMs: 400,
    onWindowObserved: async (window) => {
      await waitForStableFrame(SCREENSHOT_SCENARIO_SETTLE_MS);
      try {
        return await captureFrames({
          windowId: window.id,
          outputDirectory,
          scenarioId: scenario.id,
          fps: SCREENSHOT_FRAME_RATE_FPS,
          durationMs: SCREENSHOT_FRAME_DURATION_MS,
        });
      } catch {
        // 当前 macOS 已观察到真实窗口，但 Screen Recording 可能被系统拒绝；此时只等同一 app 的 render tree 帧。
        return waitForFlutterRenderFrames({
          outputDirectory,
          sourceDirectory: sandboxFrameDirectory,
          scenarioId: scenario.id,
          frameCount: SCREENSHOT_FRAME_RATE_FPS,
          timeoutMs: FLUTTER_RENDER_FRAME_TIMEOUT_MS,
        });
      }
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
    visualScenarios: [],
    diagnostic: false,
    help: false,
    testTimeoutMs: DEFAULT_TIMEOUT_MS,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const value = argv[index];
    if (value === "--help" || value === "-h") args.help = true;
    else if (value === "--test") args.tests.push(argv[++index] || "");
    else if (value === "--case") args.cases.push(argv[++index] || "");
    else if (value === "--visual-scenario") args.visualScenarios.push(argv[++index] || "");
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
  if (args.visualScenarios.some((scenario) => !scenario)) {
    throw new GateError("--visual-scenario 缺少已登记场景 ID。");
  }
  return args;
}

export function usage() {
  return [
    "用法：node e2e-verify/mobile/run-macos.mjs [options]",
    "  --test <relative-path>      指定 apps/mobile/test 下的 widget/契约用例，可重复",
    "  --case <stable-test-id>     写入报告的稳定测试 ID，可重复",
    "  --visual-scenario <id>      只采集已登记场景，报告标记为 targeted diagnostic，可重复",
    "  --test-timeout-ms <ms>      单个 Flutter widget/契约测试等待上限",
    "  --diagnostic                仅即时输出 Flutter 原始诊断，不写入报告",
    "  --help, -h                  显示帮助",
    "  --headless                  明确拒绝；本 gate 必须观测可见 macOS 窗口",
  ].join("\n");
}

/// 定向可见验收只能使用长期登记场景；未知 ID 不得临时写入报告或启动任意 fixture。
export function resolveMacosVisualScenarios(requestedScenarioIds = []) {
  if (requestedScenarioIds.length === 0) return MACOS_SCREENSHOT_SCENARIOS;
  const byId = new Map(MACOS_SCREENSHOT_SCENARIOS.map((scenario) => [scenario.id, scenario]));
  return [...new Set(requestedScenarioIds)].map((scenarioId) => {
    const scenario = byId.get(scenarioId);
    if (scenario == null) {
      throw new GateError(`视觉场景未登记：${scenarioId}`);
    }
    return scenario;
  });
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
  let visualScenarios = [];
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
    visualScenarios = resolveMacosVisualScenarios(args.visualScenarios);
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
        test_ids: args.cases.length ? args.cases : DEFAULT_CASES,
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
      for (const scenario of visualScenarios) {
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
      const missingScenarios = visualScenarios
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
      remainingRisk = args.visualScenarios.length > 0
        ? "这是已登记场景的定向本地 fixture 验收，不能替代完整 macOS gate；Android AVD/真机、真实上游和真实 Provider 未覆盖。"
        : "macOS 26 + Flutter 3.47 的 flutter test -d macos 存在官方 open/VM 握手回归；integration_test 保留给后续 Android 原生或工具链修复后的 macOS gate。";
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
            declaredScenarioIds: visualScenarios.map(
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
        gate_kind: args?.visualScenarios.length
          ? "flutter_macos_visible_widget_targeted_diagnostic"
          : "flutter_macos_visible_widget_gate",
        report_kind: args?.visualScenarios.length ? "targeted_diagnostic" : "full_gate",
        host_platform: "macos",
        real_device: false,
        simulated_device: false,
        visible_desktop_app: visibleDesktopApp,
        test_ids: args?.cases.length ? args.cases : DEFAULT_CASES,
        visual_scenario_ids: visualScenarios.map((scenario) => scenario.id),
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
          screenshot_capture_modes: [
            ...new Set(smoke.window.captureArtifacts.map((artifact) => artifact.captureMode)),
          ],
          maximum_window_count: smoke.window.maximumWindowCount,
          window_observation_attempts: smoke.window.observationAttempts,
          window_observer_errors: smoke.window.observerErrors,
          controlled_exit_requested: smoke.gracefulExitRequested,
        },
        visual_scenario_runs: visualScenarioRuns.map(({ scenario, smoke: scenarioSmoke, frames }) => ({
          id: scenario.id,
          frame_count: frames.length,
          capture_modes: [...new Set(frames.map((frame) => frame.captureMode))],
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
