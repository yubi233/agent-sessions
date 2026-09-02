#!/usr/bin/env node
// P6 Flutter 录屏入口：只在已通过的可见 macOS full gate 后，复用同一真实窗口与 fixture 场景生成 5fps MP4。
import { execFile } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { baseReport, writeReport } from "../lib/report.mjs";
import {
  createMacosWindowObserver,
  macosDebugAppBundle,
  runMacosFlutterBuild,
  terminateMacosAppProcessesForBundle,
} from "./macos.mjs";
import {
  MACOS_SCREENSHOT_SCENARIOS,
  recordMacosVisualScenario,
  waitForNoMacosWindows,
} from "./run-macos.mjs";
import {
  WINDOW_EVIDENCE_MINIMUM_CANDIDATE_FRAME_COUNT,
  WINDOW_EVIDENCE_FRAME_INTERVAL_MS,
  WINDOW_EVIDENCE_SELECTED_FRAME_COUNT,
} from "./macos-screenshot.mjs";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..");
const MOBILE_ROOT = join(ROOT, "apps", "mobile");
// 录屏属于测试产物，不能进入会话绑定的 testbox 工作区。
const SCREENCAST_ROOT = join(ROOT, "e2e-verify", "screencasts");
export const FLUTTER_RECORDING_FPS = 5;
export const FLUTTER_RECORDING_FRAME_COUNT = WINDOW_EVIDENCE_SELECTED_FRAME_COUNT;
export const FLUTTER_RECORDING_SCENARIO_MAX_ATTEMPTS = 2;
export const DEFAULT_FLUTTER_RECORDING_SCOPE = "v07";
// 录屏范围：P6 生命周期恢复、v0.2 快捷菜单/Resume、文件浏览、composer 控制面、
// P3 终端状态与 P3-A 设置中心/会话信息，以及 v0.5 resident shell / StatsLine / Trajectory / composer dock。
export const FLUTTER_RECORDING_SCENARIO_IDS = Object.freeze([
  "VISUAL-MOBILE-11",
  "VISUAL-MOBILE-12",
  "VISUAL-MOBILE-14",
  "VISUAL-MOBILE-15",
  "VISUAL-MOBILE-16",
  "VISUAL-MOBILE-17",
  "VISUAL-MOBILE-21",
  "VISUAL-MOBILE-22",
  "VISUAL-MOBILE-23",
  "VISUAL-MOBILE-24",
  "VISUAL-MOBILE-25",
  "VISUAL-MOBILE-26",
  "VISUAL-MOBILE-27",
  "VISUAL-MOBILE-28",
  "VISUAL-MOBILE-30",
  "VISUAL-MOBILE-31",
  "VISUAL-MOBILE-32",
]);
export const FLUTTER_RECORDING_SCOPES = Object.freeze({
  v07: Object.freeze({
    scenarioIds: FLUTTER_RECORDING_SCENARIO_IDS,
    requiredTestIds: Object.freeze([]),
  }),
  v081: Object.freeze({
    scenarioIds: Object.freeze(["VISUAL-MOBILE-33"]),
    requiredTestIds: Object.freeze(["V081-10"]),
  }),
});

function recordingScope(scope = DEFAULT_FLUTTER_RECORDING_SCOPE) {
  const selected = FLUTTER_RECORDING_SCOPES[scope];
  if (selected == null) {
    throw new RecordingError(
      `未知 Flutter 录屏范围：${scope}。可用范围：${Object.keys(FLUTTER_RECORDING_SCOPES).join(", ")}。`,
    );
  }
  return selected;
}

// 长期报告只存仓库内相对 artifact 引用，不能暴露执行主机目录。
function evidenceReference(path) {
  const projectRelativePath = relative(ROOT, path);
  return projectRelativePath.length > 0 && !projectRelativePath.startsWith("..")
    ? projectRelativePath
    : "[PATH REDACTED]";
}

class RecordingError extends Error {
  constructor(message, { failureClass = "test_harness_defect" } = {}) {
    super(message);
    this.failureClass = failureClass;
  }
}

function safeError(error) {
  return String(error instanceof Error ? error.message : error)
    .replace(/(bearer\s+)[^\s"']+/gi, "$1[REDACTED]")
    .replace(/([?&](?:token|password|secret)=)[^&#\s"']+/gi, "$1[REDACTED]")
    .replace(/\/(?:Users|private|var|tmp)\/[^\s"']+/g, "[PATH REDACTED]")
    .slice(0, 500);
}

export function isRetryableRecordingFailure(error) {
  return error?.failureClass === "environment_or_startup_failure";
}

function positiveInteger(value, flag) {
  const parsed = Number.parseInt(value, 10);
  if (!Number.isInteger(parsed) || parsed <= 0) {
    throw new RecordingError(`${flag} 必须是正整数。`);
  }
  return parsed;
}

export function parseRecordingArgs(argv) {
  const args = {
    gateReport: null,
    help: false,
    fps: FLUTTER_RECORDING_FPS,
    scope: DEFAULT_FLUTTER_RECORDING_SCOPE,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const value = argv[index];
    if (value === "--help" || value === "-h") args.help = true;
    else if (value === "--gate-report") args.gateReport = argv[++index] || "";
    else if (value === "--scope") args.scope = argv[++index] || "";
    else if (value === "--fps")
      args.fps = positiveInteger(argv[++index], "--fps");
    else if (value === "--headless") {
      throw new RecordingError(
        "Flutter 录屏拒绝 --headless，必须采集可见 macOS 窗口。",
        {
          failureClass: "test_harness_defect",
        },
      );
    } else {
      throw new RecordingError(`未知参数：${value}`);
    }
  }
  if (!args.help && (!args.gateReport || args.gateReport.trim().length === 0)) {
    throw new RecordingError(
      "录屏必须通过 --gate-report 指向本轮已通过的 macOS full gate 报告。",
      {
        failureClass: "checkpoint_mismatch",
      },
    );
  }
  if (args.fps !== FLUTTER_RECORDING_FPS) {
    throw new RecordingError(
      `P6 Flutter 录屏固定为 ${FLUTTER_RECORDING_FPS}fps。`,
    );
  }
  if (!args.help) recordingScope(args.scope);
  return args;
}

export function recordingUsage() {
  return [
    "用法：node e2e-verify/mobile/record-macos.mjs --gate-report <MOBILE/mobile-01-macos.json>",
    "  --gate-report <path>  本轮已通过的 macOS Flutter full gate 报告",
    "  --scope v07|v081     录制范围；默认 v07，v081 只录 DSH 工作区场景",
    "  --fps 5               固定 5fps；其他值会拒绝",
    "  --headless            明确拒绝；录屏必须观察可见 macOS 窗口",
  ].join("\n");
}

export function selectRecordingScenarios(
  scenarios = MACOS_SCREENSHOT_SCENARIOS,
  scope = DEFAULT_FLUTTER_RECORDING_SCOPE,
) {
  const byId = new Map(scenarios.map((scenario) => [scenario.id, scenario]));
  return recordingScope(scope).scenarioIds.map((id) => {
    const scenario = byId.get(id);
    if (scenario == null) {
      throw new RecordingError(`录屏场景未在 macOS 截图清单登记：${id}`);
    }
    return scenario;
  });
}

export function recordingScenarioIdsForScope(
  scope = DEFAULT_FLUTTER_RECORDING_SCOPE,
) {
  return [...recordingScope(scope).scenarioIds];
}

export function validatePassedGateReport(
  report,
  scope = DEFAULT_FLUTTER_RECORDING_SCOPE,
) {
  const expected = recordingScope(scope);
  if (report == null || typeof report !== "object") {
    throw new RecordingError("full gate 报告不是有效 JSON 对象。", {
      failureClass: "checkpoint_mismatch",
    });
  }
  if (report.status !== "passed") {
    throw new RecordingError("full gate 尚未通过，不能开始录屏。", {
      failureClass: "checkpoint_mismatch",
    });
  }
  if (report.headless !== false || report.visible_desktop_app !== true) {
    throw new RecordingError(
      "full gate 未证明可见 macOS Flutter 窗口，不能作为录屏前置。",
      {
        failureClass: "checkpoint_mismatch",
      },
    );
  }
  const visualRuns = Array.isArray(report.visual_scenario_runs)
    ? report.visual_scenario_runs
    : [];
  // 录屏范围内的每个场景都必须先通过连续 5fps 候选采集与筛选，缺任一场景都拒绝录屏。
  const missing = expected.scenarioIds.filter((id) => {
    const run = visualRuns.find((item) => item?.id === id);
    return run?.frame_count !== FLUTTER_RECORDING_FRAME_COUNT
      || !Number.isInteger(run?.candidate_frame_count)
      || run.candidate_frame_count < WINDOW_EVIDENCE_MINIMUM_CANDIDATE_FRAME_COUNT
      || run?.selected_frame_count !== FLUTTER_RECORDING_FRAME_COUNT
      || run?.frame_rate_fps !== FLUTTER_RECORDING_FPS
      || run?.frame_interval_ms !== WINDOW_EVIDENCE_FRAME_INTERVAL_MS
      || run?.candidate_collection_mode !== "long-series-minimum"
      || run?.collection_duration_limited !== false
      || run?.strict_frame_rate !== true;
  });
  if (missing.length > 0) {
    throw new RecordingError(
      `full gate 缺少以下场景的严格 5fps 连续截图证据：${missing.join(", ")}`,
      {
        failureClass: "checkpoint_mismatch",
      },
    );
  }
  const testIds = Array.isArray(report.test_ids) ? report.test_ids : [];
  const missingTestIds = expected.requiredTestIds.filter(
    (id) => !testIds.includes(id),
  );
  if (missingTestIds.length > 0) {
    throw new RecordingError(
      `full gate 不属于 ${scope} 录屏范围，缺少测试标识：${missingTestIds.join(", ")}`,
      {
        failureClass: "checkpoint_mismatch",
      },
    );
  }
  return report;
}

function loadPassedGateReport(
  gateReportPath,
  scope = DEFAULT_FLUTTER_RECORDING_SCOPE,
) {
  const resolvedPath = resolve(gateReportPath);
  if (!existsSync(resolvedPath)) {
    throw new RecordingError(`找不到 full gate 报告：${resolvedPath}`, {
      failureClass: "checkpoint_mismatch",
    });
  }
  try {
    return {
      path: resolvedPath,
      report: validatePassedGateReport(
        JSON.parse(readFileSync(resolvedPath, "utf-8")),
        scope,
      ),
    };
  } catch (error) {
    if (error instanceof RecordingError) throw error;
    throw new RecordingError("full gate 报告无法解析。", {
      failureClass: "checkpoint_mismatch",
    });
  }
}

function execFileResult(file, args, options = {}) {
  return new Promise((resolveResult) => {
    execFile(file, args, options, (error, stdout, stderr) => {
      resolveResult({
        code: typeof error?.code === "number" ? error.code : error ? null : 0,
        stderr: String(stderr || ""),
        stdout: String(stdout || ""),
      });
    });
  });
}

async function encodeMp4({ frameDirectory, outputPath, fps }) {
  const result = await execFileResult(
    "ffmpeg",
    [
      "-framerate",
      String(fps),
      "-i",
      join(frameDirectory, "frame-%04d.png"),
      "-c:v",
      "libx264",
      "-pix_fmt",
      "yuv420p",
      "-y",
      outputPath,
    ],
    { timeout: 60_000, maxBuffer: 64_000 },
  );
  if (
    result.code !== 0 ||
    !existsSync(outputPath) ||
    statSync(outputPath).size <= 0
  ) {
    throw new RecordingError("ffmpeg 未能生成完整 Flutter 录屏 MP4。", {
      failureClass: "environment_or_startup_failure",
    });
  }
}

async function inspectMp4({ path, fps }) {
  const result = await execFileResult(
    "ffprobe",
    [
      "-v",
      "error",
      "-select_streams",
      "v:0",
      "-show_entries",
      "stream=avg_frame_rate,nb_frames,width,height",
      "-of",
      "json",
      path,
    ],
    { timeout: 20_000, maxBuffer: 32_000 },
  );
  if (result.code !== 0) {
    throw new RecordingError("ffprobe 无法校验 Flutter 录屏 MP4。", {
      failureClass: "environment_or_startup_failure",
    });
  }
  const stream = JSON.parse(result.stdout).streams?.[0];
  const [numerator, denominator] = String(stream?.avg_frame_rate || "0/1")
    .split("/")
    .map(Number);
  const frameRate = denominator > 0 ? numerator / denominator : 0;
  if (!Number.isFinite(frameRate) || Math.abs(frameRate - fps) > 0.01) {
    throw new RecordingError(`Flutter 录屏帧率不是 ${fps}fps。`, {
      failureClass: "test_harness_defect",
    });
  }
  const frameCount = Number(stream?.nb_frames);
  if (!Number.isInteger(frameCount) || frameCount !== FLUTTER_RECORDING_FRAME_COUNT) {
    throw new RecordingError(`Flutter 录屏帧数不是预期的 ${FLUTTER_RECORDING_FRAME_COUNT} 帧。`, {
      failureClass: "test_harness_defect",
    });
  }
  return {
    frame_count: frameCount,
    frame_rate_fps: frameRate,
    height: Number(stream.height),
    path: evidenceReference(path),
    size_bytes: statSync(path).size,
    width: Number(stream.width),
  };
}

async function main() {
  const timestamp = new Date().toISOString().replace(/[:.]/g, "-");
  const startedAt = Date.now();
  const outputDirectory = join(SCREENCAST_ROOT, timestamp, "MOBILE");
  const frameDirectory = join(outputDirectory, "frames");
  const artifacts = [];
  const completedScenarios = [];
  let status = "failed";
  let failureClass = "test_harness_defect";
  let remainingRisk = "";
  let args = null;
  let gateReport = null;
  let windowObserver = null;

  try {
    args = parseRecordingArgs(process.argv.slice(2));
    if (args.help) {
      process.stdout.write(`${recordingUsage()}\n`);
      return;
    }
    if (process.platform !== "darwin") {
      throw new RecordingError("Flutter macOS 录屏只能在 macOS 主机执行。", {
        failureClass: "environment_or_startup_failure",
      });
    }
    gateReport = loadPassedGateReport(args.gateReport, args.scope);
    mkdirSync(frameDirectory, { recursive: true });
    windowObserver = await createMacosWindowObserver();
    if ((await windowObserver.observe()).count > 0) {
      throw new RecordingError(
        "检测到已有 Agent Sessions macOS 窗口，拒绝将用户实例录入测试证据。",
        {
          failureClass: "environment_or_startup_failure",
        },
      );
    }
    // 录屏重建固定 debug App，确保帧来自当前工作区源码；全量业务断言由 gate report 提供。
    const build = await runMacosFlutterBuild({ cwd: MOBILE_ROOT });
    if (build.code !== 0 || build.timedOut) {
      throw new RecordingError("Flutter macOS debug App 构建未完成。", {
        failureClass: "environment_or_startup_failure",
      });
    }
    const appPath = macosDebugAppBundle(MOBILE_ROOT);
    if (!existsSync(appPath)) {
      throw new RecordingError("构建后找不到 Flutter macOS debug App .app bundle。", {
        failureClass: "environment_or_startup_failure",
      });
    }

    for (const scenario of selectRecordingScenarios(
      MACOS_SCREENSHOT_SCENARIOS,
      args.scope,
    )) {
      let visualRun = null;
      const retryFailures = [];
      for (
        let attempt = 1;
        attempt <= FLUTTER_RECORDING_SCENARIO_MAX_ATTEMPTS;
        attempt += 1
      ) {
        process.stdout.write(
          `[flutter-record] 采集 ${scenario.id} 的连续 5fps 可见窗口帧（attempt ${attempt}/${FLUTTER_RECORDING_SCENARIO_MAX_ATTEMPTS}）\n`,
        );
        try {
          visualRun = await recordMacosVisualScenario({
            scenario,
            screenshotDirectory: frameDirectory,
            appPath,
            observeWindow: () => windowObserver.observe(),
            sandboxNamespace: `${timestamp}-attempt-${attempt}`,
          });
          break;
        } catch (error) {
          retryFailures.push({
            attempt,
            failure_class: error?.failureClass ?? "test_harness_defect",
            summary: safeError(error),
          });
          if (
            attempt >= FLUTTER_RECORDING_SCENARIO_MAX_ATTEMPTS
            || !isRetryableRecordingFailure(error)
          ) {
            throw error;
          }
          rmSync(join(frameDirectory, scenario.directory), {
            force: true,
            recursive: true,
          });
          rmSync(join(outputDirectory, `${scenario.directory}.mp4`), {
            force: true,
          });
          await terminateMacosAppProcessesForBundle({ appPath });
          const released = await waitForNoMacosWindows({
            observeWindow: () => windowObserver.observe(),
          });
          if (!released) throw error;
          process.stdout.write(
            `[flutter-record] ${scenario.id} 环境类采集失败，清理后重试：${safeError(error)}\n`,
          );
        }
      }
      const scenarioFrameDirectory = join(frameDirectory, scenario.directory);
      const mp4Path = join(outputDirectory, `${scenario.directory}.mp4`);
      await encodeMp4({
        frameDirectory: scenarioFrameDirectory,
        outputPath: mp4Path,
        fps: args.fps,
      });
      const video = await inspectMp4({ path: mp4Path, fps: args.fps });
      artifacts.push(
        evidenceReference(mp4Path),
        ...visualRun.frames.map((frame) => evidenceReference(frame.path)),
      );
      completedScenarios.push({
        candidate_collection_mode: "long-series-minimum",
        candidate_frame_count: WINDOW_EVIDENCE_MINIMUM_CANDIDATE_FRAME_COUNT,
        capture_modes: [
          ...new Set(visualRun.frames.map((frame) => frame.captureMode)),
        ],
        collection_duration_limited: false,
        frames: visualRun.frames.map((frame) => ({
          captured_offset_ms: frame.capturedOffsetMs,
          filename: frame.filename,
          frame_index: frame.frameIndex,
          source_frame_index: frame.sourceFrameIndex ?? frame.frameIndex,
          height: frame.height,
          sha256: frame.sha256,
          width: frame.width,
        })),
        id: scenario.id,
        attempt_count: retryFailures.length + 1,
        retry_failures: retryFailures,
        selected_frame_count: FLUTTER_RECORDING_FRAME_COUNT,
        observed_window_frame: visualRun.smoke.window.portraitMobileWindow,
        observed_window_mode: visualRun.smoke.window.portraitMobileWindowMode,
        video,
      });
    }
    status = "passed";
    failureClass = null;
    remainingRisk =
      "录屏使用 deterministic fixture 和可见 macOS 窗口，不代表真实 Provider、UnifiedPush distributor 或 Android AVD/真机验证。";
  } catch (error) {
    failureClass =
      error instanceof RecordingError
        ? error.failureClass
        : "test_harness_defect";
    remainingRisk = safeError(error);
  } finally {
    windowObserver?.dispose();
    if (args?.help) return;
    const manifestPath = join(outputDirectory, "manifest.json");
    if (completedScenarios.length > 0) {
      mkdirSync(outputDirectory, { recursive: true });
      writeFileSync(
        manifestPath,
        `${JSON.stringify(
          {
            command:
              "node e2e-verify/mobile/record-macos.mjs --scope <v07|v081> --gate-report <passed-mobile-gate-report>",
            completed_scenarios: completedScenarios,
            fixture_revision: "local-deterministic-fixture",
            fps: FLUTTER_RECORDING_FPS,
            candidate_frame_minimum: WINDOW_EVIDENCE_MINIMUM_CANDIDATE_FRAME_COUNT,
            selected_frame_count: FLUTTER_RECORDING_FRAME_COUNT,
            candidate_collection_mode: "long-series-minimum",
            collection_duration_limited: false,
            frame_interval_ms: WINDOW_EVIDENCE_FRAME_INTERVAL_MS,
            strict_frame_rate: true,
            full_gate_report: gateReport == null
              ? null
              : evidenceReference(gateReport.path),
            headless: false,
            host_platform: "macos",
            recording_scope: args.scope,
            recording_scenarios: recordingScenarioIdsForScope(args.scope),
            timestamp,
            validation: {
              fixture_data: true,
              local_test: true,
              real_browser: false,
              real_model: false,
              real_upstream: false,
              visible_desktop_app: true,
            },
          },
          null,
          2,
        )}\n`,
        "utf-8",
      );
      artifacts.unshift(evidenceReference(manifestPath));
    }
    const reportPath = writeReport({
      planId: "MOBILE",
      name: "mobile-p6-macos-recording",
      report: {
        timestamp,
        ...baseReport({
          suite: "mobile-p6-macos-fixture-recording",
          status,
          real_browser: false,
          real_model: false,
          real_upstream: false,
          fixture_data: true,
          local_test: true,
          headless: false,
          browser: "n/a",
          command:
            "node e2e-verify/mobile/record-macos.mjs --scope <v07|v081> --gate-report <passed-mobile-gate-report>",
          artifacts,
          failure_class: failureClass,
          remaining_risk: remainingRisk,
        }),
        duration_ms: Date.now() - startedAt,
        recording_scope: args?.scope ?? DEFAULT_FLUTTER_RECORDING_SCOPE,
        full_gate_report: gateReport == null
          ? null
          : evidenceReference(gateReport.path),
        gate_kind: "flutter_macos_fixture_recording",
        host_platform: "macos",
        recording_fps: FLUTTER_RECORDING_FPS,
        recording_frame_count: FLUTTER_RECORDING_FRAME_COUNT,
        candidate_frame_minimum: WINDOW_EVIDENCE_MINIMUM_CANDIDATE_FRAME_COUNT,
        candidate_collection_mode: "long-series-minimum",
        collection_duration_limited: false,
        frame_interval_ms: WINDOW_EVIDENCE_FRAME_INTERVAL_MS,
        strict_frame_rate: true,
        recording_scenario_ids: recordingScenarioIdsForScope(
          args?.scope ?? DEFAULT_FLUTTER_RECORDING_SCOPE,
        ),
        visible_desktop_app: completedScenarios.length > 0,
      },
    });
    process.stdout.write(`[flutter-record] ${status} -> ${reportPath}\n`);
    if (status !== "passed") process.exitCode = 1;
  }
}

const invokedPath = process.argv[1] ? resolve(process.argv[1]) : "";
if (invokedPath === fileURLToPath(import.meta.url)) {
  main().catch((error) => {
    process.stderr.write(`[flutter-record] ${safeError(error)}\n`);
    process.exitCode = 1;
  });
}
