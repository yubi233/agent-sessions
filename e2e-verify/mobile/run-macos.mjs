#!/usr/bin/env node
// MacBook 本地 Flutter gate：真实窗口负责可见验收，长期 widget/契约套件负责业务断言。
import {
  closeSync,
  existsSync,
  openSync,
  readFileSync,
  rmSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { basename, dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { baseReport, writeReport } from "../lib/report.mjs";
import {
  MACOS_INTEGRATION_TESTS,
  macosSandboxVisualFrameDirectory,
  MACOS_MOBILE_CONTENT_SIZE,
  createMacosWindowObserver,
  hasFlutterTestSuccessOutput,
  isSuccessfulFlutterResult,
  macosDebugAppBundle,
  resolveMacosWidgetTests,
  runMacosFlutterBuild,
  runMacosFlutterWidgetTests,
  runMacosPrebuiltApp,
  terminateMacosAppProcessesForBundle,
} from "./macos.mjs";
import {
  captureMacosWindowFrameSeries,
  captureMacosWindowOrScreenFrameSeries,
  materializeStrictWindowEvidenceFrames,
  selectStrictWindowEvidenceFrames,
  waitForFlutterRenderFrameSeries,
  WINDOW_EVIDENCE_MINIMUM_CANDIDATE_FRAME_COUNT,
  WINDOW_EVIDENCE_FRAME_INTERVAL_MS,
  WINDOW_EVIDENCE_FPS,
  WINDOW_EVIDENCE_SELECTED_FRAME_COUNT,
  writeMacosScreenshotManifest,
} from "./macos-screenshot.mjs";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..");
const MOBILE_ROOT = join(ROOT, "apps", "mobile");
const DEFAULT_TIMEOUT_MS = 300_000;
const DEFAULT_CASES = [...new Set(MACOS_INTEGRATION_TESTS.flatMap((entry) => entry.testIds))];
const SCREENSHOT_FRAME_RATE_FPS = WINDOW_EVIDENCE_FPS;
const SCREENSHOT_MINIMUM_CANDIDATE_FRAME_COUNT = WINDOW_EVIDENCE_MINIMUM_CANDIDATE_FRAME_COUNT;
const SCREENSHOT_SELECTED_FRAME_COUNT = WINDOW_EVIDENCE_SELECTED_FRAME_COUNT;
const SCREENSHOT_SCENARIO_SETTLE_MS = 800;
// 候选帧不按 1 秒窗口截断；至少 300 帧以严格 5fps 完成长序列，超时仅用于环境故障回收。
const FLUTTER_RENDER_FRAME_TIMEOUT_MS = 75_000;
const WINDOW_RELEASE_TIMEOUT_MS = 15_000;
const WINDOW_RELEASE_POLL_MS = 200;
const VISUAL_SCENARIO_MAX_ATTEMPTS = 2;
const MACOS_GATE_LOCK_PATH = join(tmpdir(), "agent-sessions-flutter-macos-gate.lock");

// 报告可归档，但不应带出执行主机的绝对目录；证据只用仓库内相对引用。
function evidenceReference(path) {
  const projectRelativePath = relative(ROOT, path);
  return projectRelativePath.length > 0 && !projectRelativePath.startsWith("..")
    ? projectRelativePath
    : "[PATH REDACTED]";
}
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
    id: "VISUAL-MOBILE-33",
    directory: "visual-mobile-33-dsh-workspace-home",
    localVisualScenario: "dsh-workspace-home",
  }),
  Object.freeze({
    id: "VISUAL-MOBILE-34",
    directory: "visual-mobile-34-dsh-session-tool-timeline",
    localVisualScenario: "dsh-session-tool-timeline",
  }),
  Object.freeze({
    id: "VISUAL-MOBILE-35",
    directory: "visual-mobile-35-dsh-capability-gates",
    localVisualScenario: "dsh-capability-gates",
  }),
  Object.freeze({
    id: "VISUAL-MOBILE-36",
    directory: "visual-mobile-36-dsh-streaming-turn-phase",
    localVisualScenario: "dsh-streaming-turn-phase",
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
  Object.freeze({
    id: "VISUAL-MOBILE-29",
    directory: "visual-mobile-29-daemon-observation",
    localVisualScenario: "session-daemon-observation",
  }),
  Object.freeze({
    id: "VISUAL-MOBILE-22",
    directory: "visual-mobile-22-settings",
    localVisualScenario: "settings-index",
  }),
  Object.freeze({
    id: "VISUAL-MOBILE-23",
    directory: "visual-mobile-23-session-info",
    localVisualScenario: "session-info",
  }),
  Object.freeze({
    id: "VISUAL-MOBILE-24",
    directory: "visual-mobile-24-code-viewer",
    localVisualScenario: "code-viewer",
  }),
  Object.freeze({
    id: "VISUAL-MOBILE-25",
    directory: "visual-mobile-25-recent-sessions",
    localVisualScenario: "recent-sessions",
  }),
  Object.freeze({
    id: "VISUAL-MOBILE-26",
    directory: "visual-mobile-26-usage",
    localVisualScenario: "usage-screen",
  }),
  Object.freeze({
    id: "VISUAL-MOBILE-27",
    directory: "visual-mobile-27-command-palette",
    localVisualScenario: "command-palette",
  }),
  Object.freeze({
    id: "VISUAL-MOBILE-28",
    directory: "visual-mobile-28-message-deeplink",
    localVisualScenario: "message-deeplink",
  }),
  Object.freeze({
    id: "VISUAL-MOBILE-30",
    directory: "visual-mobile-30-v05-resident-stats",
    localVisualScenario: "session-detail",
  }),
  Object.freeze({
    id: "VISUAL-MOBILE-31",
    directory: "visual-mobile-31-v05-trajectory",
    localVisualScenario: "session-detail",
  }),
  Object.freeze({
    id: "VISUAL-MOBILE-32",
    directory: "visual-mobile-32-v05-composer-dock",
    localVisualScenario: "session-detail",
  }),
  // v0.8.5 中止与轨迹时间：发送后中止，轨迹出现唯一“已中止 · HH:mm:ss”，
  // 缺失时间显示“时间未知”；会话投影 stopped（实施记录 23 收口条件）。
  Object.freeze({
    id: "VISUAL-MOBILE-37",
    directory: "visual-mobile-37-dsh-abort-trajectory",
    localVisualScenario: "dsh-abort-trajectory",
  }),
  // v0.8.5 主计划只读投影：副标题工作区显示名（money，无写死兜底）+ Agent 预设
  // 只读 label + usage timing chips（首字/解码）+ 权限 mode 目录可点（实施记录 24）。
  Object.freeze({
    id: "VISUAL-MOBILE-38",
    directory: "visual-mobile-38-dsh-v085-readonly-projections",
    localVisualScenario: "dsh-v085-readonly-projections",
  }),
  // v0.8.7 打字机流式可见场景（V087-08/09）：fixture 时间释放回合（真实时钟
  // 40×400ms≈16s），气泡文本逐步生长；streamingGate 标记触发双门禁机读校验
  // （帧级长度采样单调增长 + 同回合埋点导出），见 validateV087StreamingGate。
  Object.freeze({
    id: "VISUAL-MOBILE-39",
    directory: "visual-mobile-39-dsh-v087-typewriter-streaming",
    localVisualScenario: "dsh-v087-typewriter-streaming",
    streamingGate: true,
  }),
]);

function wait(milliseconds) {
  return new Promise((resolveWait) => setTimeout(resolveWait, milliseconds));
}

function visualScenarioSandboxDirectoryName({
  screenshotDirectory,
  scenario,
  sandboxNamespace = null,
}) {
  return [
    "agent-sessions-visual",
    sandboxNamespace ?? basename(dirname(screenshotDirectory)),
    scenario.directory,
  ].join("-");
}

function clearVisualScenarioAttemptArtifacts({ screenshotDirectory, scenario }) {
  rmSync(join(screenshotDirectory, scenario.directory), { force: true, recursive: true });
  rmSync(
    macosSandboxVisualFrameDirectory(
      visualScenarioSandboxDirectoryName({ screenshotDirectory, scenario }),
    ),
    { force: true, recursive: true },
  );
}

function isProcessAlive(processId) {
  if (!Number.isInteger(processId) || processId <= 1) return false;
  try {
    process.kill(processId, 0);
    return true;
  } catch (error) {
    return error?.code === "EPERM";
  }
}

// macOS App、窗口观察器和截图目录均为单实例资源；用独占锁避免两个 full gate 相互污染证据。
export function acquireMacosGateLock({
  file = MACOS_GATE_LOCK_PATH,
  processId = process.pid,
  processAlive = isProcessAlive,
} = {}) {
  const owner = `${processId}-${Date.now()}`;
  const lock = JSON.stringify({ owner, pid: processId, started_at: new Date().toISOString() });

  for (let attempt = 0; attempt < 2; attempt += 1) {
    try {
      const descriptor = openSync(file, "wx", 0o600);
      try {
        writeFileSync(descriptor, lock, "utf8");
      } finally {
        closeSync(descriptor);
      }
      return () => {
        try {
          const current = JSON.parse(readFileSync(file, "utf8"));
          if (current?.owner === owner) unlinkSync(file);
        } catch {
          // 锁已经被本轮清理或被后续进程接管时，不删除不属于自己的文件。
        }
      };
    } catch (error) {
      if (error?.code !== "EEXIST" || attempt > 0) throw error;
      let previous = null;
      try {
        previous = JSON.parse(readFileSync(file, "utf8"));
      } catch {
        // 损坏锁不能证明有活跃 gate，下一步按陈旧锁回收。
      }
      if (processAlive(previous?.pid)) {
        throw new GateError(`已有 macOS Flutter gate 正在运行（pid ${previous.pid}），拒绝并发执行。`, {
          failureClass: "environment_or_startup_failure",
        });
      }
      try {
        unlinkSync(file);
      } catch (unlinkError) {
        if (unlinkError?.code !== "ENOENT") throw unlinkError;
      }
    }
  }
  throw new GateError("无法获取 macOS Flutter gate 锁。", {
    failureClass: "environment_or_startup_failure",
  });
}

// 每个场景都启动独立 App；只有窗口系统确认上一实例已退出后，才允许开始下一场景。
export async function waitForNoMacosWindows({
  observeWindow,
  timeoutMs = WINDOW_RELEASE_TIMEOUT_MS,
  pollIntervalMs = WINDOW_RELEASE_POLL_MS,
  delay = wait,
}) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const observation = await observeWindow();
    if (!observation.observerError && observation.count === 0) return true;
    await delay(pollIntervalMs);
  }
  return false;
}

/// 每个视觉场景单独启动真实 Flutter 窗口，并在稳定后连续采样，避免截图工作侵入 integration_test 的退出链路。
export async function recordMacosVisualScenario({
  scenario,
  screenshotDirectory,
  appPath,
  observeWindow,
  sandboxNamespace = null,
  runPrebuiltApp = runMacosPrebuiltApp,
  // v0.8.6：窗口级抓帧失败（Space/Stage Manager 组合）时回退主屏捕获。
  captureFrames = captureMacosWindowOrScreenFrameSeries,
  waitForFlutterRenderFrames = waitForFlutterRenderFrameSeries,
  waitForStableFrame = wait,
  waitForWindowExit = waitForNoMacosWindows,
  localVisualTelemetryDirectory = null,
}) {
  const outputDirectory = join(screenshotDirectory, scenario.directory);
  const candidateDirectory = join(outputDirectory, ".candidates");
  const sandboxDirectoryName = visualScenarioSandboxDirectoryName({
    screenshotDirectory,
    scenario,
    sandboxNamespace,
  });
  const sandboxFrameDirectory = macosSandboxVisualFrameDirectory(
    sandboxDirectoryName,
  );
  const smoke = await runPrebuiltApp({
    appPath,
    cwd: MOBILE_ROOT,
    observeWindow,
    localVisualScenario: scenario.localVisualScenario,
    localVisualTelemetryDirectory: sandboxDirectoryName,
    localVisualFrameDirectoryName: sandboxDirectoryName,
    localVisualFrameCount: SCREENSHOT_MINIMUM_CANDIDATE_FRAME_COUNT,
    localVisualFrameIntervalMs: WINDOW_EVIDENCE_FRAME_INTERVAL_MS,
    // onWindowObserved 会等待稳定并采完帧；随后才开始受控退出，保证不会截到退出中的窗口。
    stopAfterWindowMs: 400,
    onWindowObserved: async (window) => {
      await waitForStableFrame(SCREENSHOT_SCENARIO_SETTLE_MS);
      try {
        const candidates = await captureFrames({
          windowId: window.id,
          outputDirectory: candidateDirectory,
          scenarioId: scenario.id,
          fps: SCREENSHOT_FRAME_RATE_FPS,
          frameCount: SCREENSHOT_MINIMUM_CANDIDATE_FRAME_COUNT,
        });
        const selected = selectStrictWindowEvidenceFrames({
          frames: candidates,
          selectedFrameCount: SCREENSHOT_SELECTED_FRAME_COUNT,
        });
        return materializeStrictWindowEvidenceFrames({
          frames: selected,
          outputDirectory,
        });
      } catch (windowCaptureError) {
        // 当前 macOS 已观察到真实窗口，但 Screen Recording 可能被系统拒绝；此时只等同一 app 的 render tree 帧。
        console.warn(`[macos-e2e] 窗口抓帧失败（${scenario.id}）:`, windowCaptureError?.message ?? windowCaptureError);
        // v0.8.7 流式门禁（§6.1）：帧序列仅为人审证据，机读判定以 App 侧采样
        // 为准（与 fps 解耦）。宿主负载下严格 5fps 采集受阻时降级保留已捕获
        // 帧，采样校验器仍把守双门禁；降级事实写入 run 结果，不静默降级。
        if (scenario.streamingGate === true) {
          return { frames: [], captureDegraded: true };
        }
        try {
          const candidates = await waitForFlutterRenderFrames({
            outputDirectory: candidateDirectory,
            sourceDirectory: sandboxFrameDirectory,
            scenarioId: scenario.id,
            frameCount: SCREENSHOT_MINIMUM_CANDIDATE_FRAME_COUNT,
            fps: SCREENSHOT_FRAME_RATE_FPS,
            copyFrames: false,
            timeoutMs: FLUTTER_RENDER_FRAME_TIMEOUT_MS,
          });
          const selected = selectStrictWindowEvidenceFrames({
            frames: candidates,
            selectedFrameCount: SCREENSHOT_SELECTED_FRAME_COUNT,
          });
          return materializeStrictWindowEvidenceFrames({
            frames: selected,
            outputDirectory,
          });
        } catch (fallbackError) {
          console.warn(`[macos-e2e] render-tree 兜底失败（${scenario.id}）:`, fallbackError?.message ?? fallbackError);
          throw fallbackError;
        }
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
    const lifecycle = [
      `code=${smoke.code ?? "null"}`,
      `signal=${smoke.signal ?? "none"}`,
      `timed_out=${smoke.timedOut}`,
      `controlled_exit=${controlledExit}`,
      `window_observed=${smoke.window.observed}`,
      `portrait_window=${smoke.window.portraitMobileWindowObserved}`,
      `last_window=${smoke.window.lastObservedWindow == null
        ? "none"
        : `${smoke.window.lastObservedWindow.width}x${smoke.window.lastObservedWindow.height}`}`,
    ].join(", ");
    throw new GateError(`视觉场景 ${scenario.id} 的可见 macOS 窗口未正常完成（${lifecycle}）。`, {
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
  rmSync(candidateDirectory, { force: true, recursive: true });
  if (
    scenario.streamingGate !== true
    && frames.length !== SCREENSHOT_SELECTED_FRAME_COUNT
  ) {
    throw new GateError(
      `视觉场景 ${scenario.id} 未保留完整 ${SCREENSHOT_SELECTED_FRAME_COUNT} 帧连续 5fps 证据。`,
      { failureClass: "environment_or_startup_failure" },
    );
  }
  let streamingGate = null;
  if (scenario.streamingGate === true) {
    // 门禁 1+2 的机读判定：被测 App 在回合终态把采样+埋点写入沙箱容器 tmp
    // （LOCAL_VISUAL_TELEMETRY_DIRECTORY 目录名经 open --env 传入；App 视角的
    // systemTemp 即该容器 tmp），runner 侧按同一目录名解析回收；缺失即门禁
    // 失败，不得静默降级。
    const evidencePath = `${macosSandboxVisualFrameDirectory(
      sandboxDirectoryName,
    )}/streaming-gate.json`;
    if (!existsSync(evidencePath)) {
      throw new GateError(
        `视觉场景 ${scenario.id} 未产出 streaming-gate 证据文件。`,
        { failureClass: "product_defect" },
      );
    }
    streamingGate = validateV087StreamingGate({
      payload: JSON.parse(readFileSync(evidencePath, "utf8")),
    });
    if (!streamingGate.passed) {
      throw new GateError(
        `视觉场景 ${scenario.id} 流式门禁未通过：${streamingGate.failures.join("；")}。`,
        { failureClass: "product_defect" },
      );
    }
    writeFileSync(
      join(outputDirectory, "streaming-gate-verdict.json"),
      `${JSON.stringify(streamingGate, null, 2)}\n`,
    );
  }
  const windowReleased = await waitForWindowExit({ observeWindow });
  if (!windowReleased) {
    throw new GateError(`视觉场景 ${scenario.id} 退出后窗口未在规定时间内释放。`, {
      failureClass: "environment_or_startup_failure",
    });
  }
  return {
    frames,
    smoke,
    streamingGate,
    capture_degraded: scenario.streamingGate === true
      ? smoke.window.captureError != null
        || frames.length !== SCREENSHOT_SELECTED_FRAME_COUNT
      : false,
  };
}

// v0.8.7 双门禁机读判定（迭代计划 §6.1/§6.2，参数=P0 裁决定稿）：
//   门禁 1：时间释放回合内，渲染气泡的已释放前缀长度随采样序列单调不减，
//           且严格递增次数 ≥3（首帧即全文/平台化判失败）；
//   门禁 2：同回合移动端埋点（P1 schema v1）——stream_delta ≥20 条、
//           ts 严格递增、cumulative_chars 单调不减、首字延迟与终态对账在位。
// 证据必须出自 P1 埋点与 App 侧采样（print/临时脚本不合格）；缺失即失败。
export function validateV087StreamingGate({
  payload,
  minimumSamples = 30,
  minimumStrictIncreases = 3,
  minimumDeltas = 20,
  minimumFinalChars = 500,
}) {
  const failures = [];
  const samples = Array.isArray(payload?.samples) ? payload.samples : [];
  const usable = samples.filter(
    (sample) => Number.isFinite(sample?.revealed) && Number.isFinite(sample?.target_chars),
  );
  if (usable.length < minimumSamples) {
    failures.push(`采样样本不足（${usable.length} < ${minimumSamples}）`);
  }
  let strictIncreases = 0;
  let previous = -1;
  for (const sample of usable) {
    if (previous >= 0) {
      if (sample.revealed < previous) {
        failures.push(`已释放长度回退：${previous} -> ${sample.revealed}`);
        break;
      }
      if (sample.revealed > previous) strictIncreases += 1;
    }
    previous = sample.revealed;
  }
  if (strictIncreases < minimumStrictIncreases) {
    failures.push(`严格递增次数不足（${strictIncreases} < ${minimumStrictIncreases}，首帧即全文/平台化形态）`);
  }
  const last = usable.at(-1);
  if (last == null || last.revealed !== last.target_chars) {
    failures.push("终态释放未追平已到达全文（对账不收敛）");
  }
  if (last != null && last.target_chars < minimumFinalChars) {
    failures.push(`终态全文长度异常（${last.target_chars} < ${minimumFinalChars}）`);
  }

  const telemetry = payload?.telemetry;
  const events = Array.isArray(telemetry?.events) ? telemetry.events : [];
  const deltas = events.filter((event) => event?.type === "stream_delta");
  const firstDelta = events.find((event) => event?.type === "stream_first_delta");
  const reconcile = events.find((event) => event?.type === "stream_completed_reconcile");
  if (deltas.length < minimumDeltas) {
    failures.push(`stream_delta 记录不足（${deltas.length} < ${minimumDeltas}）`);
  }
  const timestamps = events.map((event) => event?.ts).filter((ts) => typeof ts === "string");
  for (let index = 1; index < timestamps.length; index += 1) {
    if (timestamps[index] < timestamps[index - 1]) {
      failures.push("埋点时间戳出现回退");
      break;
    }
  }
  // v0.8.7 V087-12 真实回合修正：thought 与 assistant 是两条独立累积的流
  // （各自从 0 递增到各自终长），全局串行检查会误判"非单调"。按身份分组
  // 后逐组校验单调性，组间不比较。
  // V087-12 真实回合事实：模型输出按 step 分多条消息（thought 与 assistant 都
  // 可能是多块），sink 以「累计回退」检测新块并递增 block 序号。校验按
  // （身份, block）分段：块内累计必须单调（打字机核心主张——每块都是逐步
  // 生长的），块间允许重置；至少一个 assistant 块要有实质增长。
  const blockState = new Map();
  let bestBlockGrowth = 0;
  for (const delta of deltas) {
    const identity = `${delta.kind ?? "assistant"}|${delta.message_id ?? ""}`;
    const block = Number.isFinite(delta.block) ? delta.block : 0;
    const blockKey = `${identity}#${block}`;
    const previous = blockState.get(blockKey) ?? 0;
    if (!Number.isFinite(delta.cumulative_chars) || delta.cumulative_chars < previous) {
      failures.push(`埋点块内累计长度非单调（${blockKey}: ${previous} -> ${delta.cumulative_chars}）`);
      break;
    }
    blockState.set(blockKey, delta.cumulative_chars);
    if ((delta.kind ?? "assistant") === "assistant") {
      bestBlockGrowth = Math.max(bestBlockGrowth, delta.cumulative_chars);
    }
  }
  if (bestBlockGrowth < minimumDeltas) {
    failures.push(`assistant 块内增长不足（最大块累计 ${bestBlockGrowth} < ${minimumDeltas}）`);
  }
  if (firstDelta == null || !Number.isFinite(firstDelta.latency_ms)) {
    failures.push("缺少 stream_first_delta（首字延迟未记录）");
  }
  if (reconcile?.consistent !== true) {
    failures.push("stream_completed_reconcile 缺失或对账不一致");
  }
  return {
    passed: failures.length === 0,
    failures,
    sample_count: usable.length,
    strict_increases: strictIncreases,
    delta_events: deltas.length,
    first_delta_latency_ms: firstDelta?.latency_ms ?? null,
    final_chars: reconcile?.final_chars ?? null,
  };
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
    .replace(/\/(?:Users|private|var|tmp)\/[^\s"']+/g, "[PATH REDACTED]")
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
  let releaseGateLock = null;
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

    releaseGateLock = acquireMacosGateLock();
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
    prebuiltAppPath = macosDebugAppBundle(MOBILE_ROOT);
    if (!existsSync(prebuiltAppPath)) {
      throw new GateError("Flutter macOS debug App 构建后未找到 .app bundle。", {
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
      const passed = isSuccessfulFlutterResult(result);
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
      process.stdout.write("[macos-e2e] 启动预构建 App，持续采集 5fps 候选帧并筛选连续视觉证据\n");
      screenshotDirectory = join(ROOT, "e2e-verify", "screenshots", timestamp, "MOBILE");
      for (const scenario of visualScenarios) {
        let visualRun = null;
        const attemptFailures = [];
        for (let attempt = 1; attempt <= VISUAL_SCENARIO_MAX_ATTEMPTS; attempt += 1) {
          process.stdout.write(
            `[macos-e2e] 采集并筛选 5fps 视觉场景：${scenario.id}（attempt ${attempt}/${VISUAL_SCENARIO_MAX_ATTEMPTS}）\n`,
          );
          if (attempt > 1) {
            clearVisualScenarioAttemptArtifacts({ screenshotDirectory, scenario });
          }
          try {
            visualRun = await recordMacosVisualScenario({
              scenario,
              screenshotDirectory,
              appPath: prebuiltAppPath,
              observeWindow: () => windowObserver.observe(),
            });
            break;
          } catch (error) {
            const attemptFailureClass = error instanceof GateError
              ? error.failureClass
              : "test_harness_defect";
            attemptFailures.push({
              attempt,
              failure_class: attemptFailureClass,
              summary: safeError(error),
            });
            await terminateMacosAppProcessesForBundle({ appPath: prebuiltAppPath });
            await waitForNoMacosWindows({ observeWindow: () => windowObserver.observe() });
            if (
              attempt >= VISUAL_SCENARIO_MAX_ATTEMPTS
              || attemptFailureClass !== "environment_or_startup_failure"
            ) {
              throw error;
            }
            process.stdout.write(
              `[macos-e2e] ${scenario.id} 环境类采样失败，清理后重试：${safeError(error)}\n`,
            );
          }
        }
        visualScenarioRuns.push({
          scenario,
          ...visualRun,
          attempt_count: attemptFailures.length + 1,
          retry_failures: attemptFailures,
        });
        screenshotEntries.push(...visualRun.frames);
        smoke ??= visualRun.smoke;
        if (args.diagnostic) {
          // 原始应用输出只留在当前终端，报告只保存窗口观测和帧元数据。
          process.stdout.write(`[macos-e2e] ${scenario.id} diagnostic output (not persisted):\n`);
          process.stdout.write(`${visualRun.smoke.stdout}${visualRun.smoke.stderr}`);
          process.stdout.write("\n[macos-e2e] End visual scenario diagnostic output\n");
        }
      }
      // v0.8.7 流式门禁场景允许降级采集（§6.1：机读判定与帧节拍解耦）：
      // streaming-gate 判据通过的 run 视为已完整采集，即便人审帧序列为空。
      const capturedScenarioIds = new Set([
        ...screenshotEntries.map((artifact) => artifact.scenarioId).filter(Boolean),
        ...visualScenarioRuns
          .filter((run) => run.streamingGate?.passed === true)
          .map((run) => run.scenario.id),
      ]);
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
            candidateFrameCount: SCREENSHOT_MINIMUM_CANDIDATE_FRAME_COUNT,
            selectedFrameCount: SCREENSHOT_SELECTED_FRAME_COUNT,
            candidateCollectionMode: "long-series-minimum",
            collectionDurationLimited: false,
            strictFrameRate: true,
          });
        }
        screenshotArtifacts = [
          ...screenshotEntries.map((artifact) => evidenceReference(artifact.path)),
          ...(screenshotManifestPath != null
            ? [evidenceReference(screenshotManifestPath)]
            : []),
        ];
      } catch (error) {
        status = "failed";
        failureClass = "environment_or_startup_failure";
        remainingRisk = safeError(error);
      }
    }
    windowObserver?.dispose();
    releaseGateLock?.();
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
          app_executable_name: prebuiltAppPath == null ? null : basename(prebuiltAppPath),
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
        visual_scenario_runs: visualScenarioRuns.map(({ scenario, smoke: scenarioSmoke, frames, attempt_count, retry_failures }) => ({
          id: scenario.id,
          frame_count: frames.length,
          candidate_frame_count: SCREENSHOT_MINIMUM_CANDIDATE_FRAME_COUNT,
          selected_frame_count: SCREENSHOT_SELECTED_FRAME_COUNT,
          candidate_collection_mode: "long-series-minimum",
          collection_duration_limited: false,
          frame_rate_fps: SCREENSHOT_FRAME_RATE_FPS,
          frame_interval_ms: WINDOW_EVIDENCE_FRAME_INTERVAL_MS,
          strict_frame_rate: true,
          attempt_count,
          retry_failures,
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
