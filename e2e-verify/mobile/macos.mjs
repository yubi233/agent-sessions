// MacBook Flutter 本地 gate 的可复用底层：只启动 macOS 桌面应用，不接入 Android、AVD 或真实上游。
import { execFile, spawn } from "node:child_process";
import { existsSync, mkdtempSync, rmSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { dirname, isAbsolute, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import {
  WINDOW_EVIDENCE_MINIMUM_CANDIDATE_FRAME_COUNT,
  WINDOW_EVIDENCE_FRAME_INTERVAL_MS,
} from "./macos-screenshot.mjs";

const MAX_CAPTURE_BYTES = 1_000_000;
const CHILD_ENV_SENSITIVE_KEY = /(api.?key|authorization|cookie|password|secret|token|private.?key|access.?key|refresh.?token)/i;

export const MACOS_APP_PROCESS = "agent_sessions_mobile";
export const MACOS_APP_BUNDLE_IDENTIFIER = "com.agentsessions.agentSessionsMobile";
export const MACOS_MOBILE_CONTENT_SIZE = Object.freeze({ height: 960, width: 480 });
// Flutter macOS 的冷构建在受限本机环境中实测可超过 15 分钟；20 分钟是构建预算，不影响窗口采样超时。
export const MACOS_BUILD_TIMEOUT_MS = 1_200_000;
const MACOS_DEBUG_APP_EXECUTABLE = join(
  "build",
  "macos",
  "Build",
  "Products",
  "Debug",
  "agent_sessions_mobile.app",
  "Contents",
  "MacOS",
  MACOS_APP_PROCESS,
);
const MACOS_WINDOW_WIDTH_TOLERANCE = 4;
const MACOS_WINDOW_TITLE_BAR_ALLOWANCE = 48;
const MACOS_SCALED_PREVIEW_MIN_HEIGHT = 720;
const MACOS_RESIZED_WINDOW_MAX_WIDTH = 720;
const MACOS_WINDOW_OBSERVER_SOURCE = join(
  dirname(fileURLToPath(import.meta.url)),
  "macos-window-info.swift",
);

// 只有显式登记的用例进入本轮 full gate；已签名 Keychain 用例不能在无开发证书的 MacBook 上被悄悄跳过。
export const MACOS_INTEGRATION_TESTS = Object.freeze([
  Object.freeze({
    path: "integration_test/w1_auth_pairing_flow_test.dart",
    testIds: Object.freeze(["MOBILE-01", "PAIR-01", "PAIR-02", "PAIR-03"]),
    // 集成断言由 Flutter test 宿主执行；真实窗口由本文件的 flutter run smoke 单独证明。
    requiresVisibleWindow: false,
  }),
  Object.freeze({
    path: "integration_test/w1_visual_owner_fixture_test.dart",
    testIds: Object.freeze(["MOBILE-01"]),
    requiresVisibleWindow: false,
  }),
  Object.freeze({
    path: "integration_test/w1_macos_drift_cache_test.dart",
    testIds: Object.freeze(["MOBILE-01"]),
    requiresVisibleWindow: false,
  }),
]);

function appendLimited(previous, chunk) {
  if (previous.length >= MAX_CAPTURE_BYTES) return previous;
  return `${previous}${chunk.toString()}`.slice(0, MAX_CAPTURE_BYTES);
}

function safeChildEnv(env = process.env) {
  // Flutter 本地 fixture 不需要任何真实上游凭据；避免把宿主机敏感变量传给构建、测试或桌面应用子进程。
  return Object.fromEntries(
    Object.entries(env).filter(([key]) => !CHILD_ENV_SENSITIVE_KEY.test(key)),
  );
}

export function listMacosIntegrationTests(mobileRoot) {
  return MACOS_INTEGRATION_TESTS.map((entry) => {
    const absolute = resolve(mobileRoot, entry.path);
    if (!existsSync(absolute)) {
      throw new Error(`已登记的 macOS integration_test 不存在：${entry.path}`);
    }
    return entry;
  });
}

// resolveMacosIntegrationTests 只接受已登记且位于 apps/mobile/integration_test 下的用例，避免误把签名专用诊断纳入当前 gate。
export function resolveMacosIntegrationTests(mobileRoot, requestedTests = []) {
  const registered = listMacosIntegrationTests(mobileRoot);
  if (requestedTests.length === 0) return registered;

  const byPath = new Map(registered.map((entry) => [entry.path, entry]));
  return [...new Set(requestedTests)].map((requested) => {
    if (isAbsolute(requested) || !requested.endsWith("_test.dart")) {
      throw new Error(`无效 macOS integration_test 路径：${requested}`);
    }
    const absolute = resolve(mobileRoot, requested);
    const fromMobile = relative(mobileRoot, absolute);
    if (
      fromMobile.startsWith("..")
      || isAbsolute(fromMobile)
      || fromMobile.split(/[\\/]/)[0] !== "integration_test"
      || !byPath.has(fromMobile)
    ) {
      throw new Error(`该用例未登记为本轮 macOS gate：${requested}`);
    }
    return byPath.get(fromMobile);
  });
}

// 当前 MacBook gate 的业务断言使用稳定的 test/ 长期套件；integration_test/ 保留给后续 Android 原生或修复后的 macOS 工具链。
export function resolveMacosWidgetTests(mobileRoot, requestedTests = []) {
  if (requestedTests.length === 0) return ["test"];

  return [...new Set(requestedTests)].map((requested) => {
    if (isAbsolute(requested) || !requested.endsWith("_test.dart")) {
      throw new Error(`无效 macOS widget 测试路径：${requested}`);
    }
    const absolute = resolve(mobileRoot, requested);
    const fromMobile = relative(mobileRoot, absolute);
    if (
      fromMobile.startsWith("..")
      || isAbsolute(fromMobile)
      || fromMobile.split(/[\\/]/)[0] !== "test"
      || !existsSync(absolute)
    ) {
      throw new Error(`该用例不在 apps/mobile/test 下：${requested}`);
    }
    return fromMobile;
  });
}

// flutterMacosArgs 固定使用 macOS 设备和 --no-pub，避免测试时隐式解析或升级依赖。
export function flutterMacosArgs(testPath) {
  return ["test", testPath, "-d", "macos", "--no-pub"];
}

// 可见窗口使用已构建的 debug app，绕开 macOS 26/Xcode 26 上 flutter run 的设备发现和前台拉起回归。
export function flutterMacosBuildArgs() {
  return ["build", "macos", "--debug", "--no-pub"];
}

// 构建产物路径由 Flutter macOS debug 约定和固定产品名组成，不接受外部传入的进程或 bundle 路径。
export function macosDebugAppExecutable(mobileRoot) {
  return resolve(mobileRoot, MACOS_DEBUG_APP_EXECUTABLE);
}

/// 沙箱 App 只允许写自己的 Data/tmp；runner 用固定 bundle id 读取再复制到交付目录。
export function macosSandboxVisualFrameDirectory(
  directoryName,
  homeDirectory = homedir(),
) {
  if (typeof directoryName !== "string" || !/^[A-Za-z0-9_-]{1,120}$/.test(directoryName)) {
    throw new Error("macOS Flutter sandbox 截图目录名无效。 ");
  }
  return join(
    homeDirectory,
    "Library",
    "Containers",
    MACOS_APP_BUNDLE_IDENTIFIER,
    "Data",
    "tmp",
    directoryName,
  );
}

// widget/契约回归不绑定桌面 device；可见用户界面证据由单独的 flutter run 场景提供。
export function flutterWidgetTestArgs(testPath = "test") {
  // Flutter 3.47 在当前 macOS/Xcode 组合下并行 listener 清理不稳定，单 worker 保持测试结果与清理顺序一致。
  return ["test", testPath, "--no-pub", "--concurrency=1"];
}

// flutterMacosSmokeArgs 启动真实 lib/main.dart；LOCAL_FIXTURE_MODE 只在本地 smoke 中关闭未签名 macOS Keychain 写入。
export function flutterMacosSmokeArgs({ localVisualScenario = null } = {}) {
  const args = [
    "run",
    "-d",
    "macos",
    "--no-pub",
    "--dart-define=LOCAL_FIXTURE_MODE=true",
  ];
  // 场景名来自本地固定清单，只影响 fixture 路由，不进入真实 Relay 或安全存储边界。
  if (localVisualScenario != null) {
    args.push(`--dart-define=LOCAL_VISUAL_SCENARIO=${localVisualScenario}`);
  }
  return args;
}

export function macosWindowObserverArgs(processName = MACOS_APP_PROCESS) {
  // 进程名只来自固定登记值，防止把命令行文本传入原生查询程序。
  if (processName !== MACOS_APP_PROCESS) {
    throw new Error("macOS 窗口观测器只允许登记的 Flutter 应用进程名。");
  }
  return ["--process-name", processName];
}

export function parseMacosWindowObservation(output) {
  try {
    const value = JSON.parse(String(output));
    const windows = Array.isArray(value?.windows)
      ? value.windows.flatMap((window) => {
          const id = Number(window?.id);
          const pid = Number(window?.pid);
          const width = Number(window?.width);
          const height = Number(window?.height);
          if (
            !Number.isInteger(id)
            || !Number.isInteger(pid)
            || pid <= 1
            || !Number.isFinite(width)
            || !Number.isFinite(height)
            || width <= 1
            || height <= 1
          ) {
            return [];
          }
          return [{ id, pid, width, height }];
        })
      : [];
    return { count: windows.length, windows };
  } catch {
    return { count: 0, windows: [] };
  }
}

export function parseMacosWindowCount(output) {
  return parseMacosWindowObservation(output).count;
}

// CoreGraphics 返回整个 NSWindow 边界，包含标题栏。小屏 MacBook 会将 960pt 外壳压缩，
// Flutter 内部仍以 480x960 逻辑画布等比预览，因此报告必须区分原生尺寸和缩放预览。
export function macosPortraitWindowMode(window) {
  const fixedWidth = Math.abs(window.width - MACOS_MOBILE_CONTENT_SIZE.width)
    <= MACOS_WINDOW_WIDTH_TOLERANCE;
  if (
    !fixedWidth
    && !(
      window.width >= MACOS_MOBILE_CONTENT_SIZE.width
      && window.width <= MACOS_RESIZED_WINDOW_MAX_WIDTH
      && window.height >= MACOS_SCALED_PREVIEW_MIN_HEIGHT
      && window.height > window.width * 1.4
    )
  ) {
    return "invalid";
  }
  if (
    fixedWidth
    &&
    window.height >= MACOS_MOBILE_CONTENT_SIZE.height
    && window.height <= MACOS_MOBILE_CONTENT_SIZE.height + MACOS_WINDOW_TITLE_BAR_ALLOWANCE
  ) {
    return "native";
  }
  if (!fixedWidth) {
    return "resized_preview";
  }
  if (window.height >= MACOS_SCALED_PREVIEW_MIN_HEIGHT) {
    return "scaled_preview";
  }
  return "invalid";
}

export function isMacosPortraitMobileWindow(window) {
  return macosPortraitWindowMode(window) !== "invalid";
}

function execFileResult(file, args, options = {}) {
  return new Promise((resolveResult) => {
    execFile(file, args, options, (error, stdout, stderr) => {
      resolveResult({
        code: typeof error?.code === "number" ? error.code : error ? null : 0,
        error,
        stdout,
        stderr,
      });
    });
  });
}

// CoreGraphics 不需要辅助功能自动化权限，避免 AppleScript 在受限终端持续失败。
export async function createMacosWindowObserver({
  compiler = "swiftc",
  source = MACOS_WINDOW_OBSERVER_SOURCE,
} = {}) {
  if (!existsSync(source)) {
    throw new Error(`缺少 macOS CoreGraphics 窗口观测源码：${source}`);
  }
  const temporaryDirectory = mkdtempSync(join(tmpdir(), "agent-sessions-window-observer-"));
  const executable = join(temporaryDirectory, "observe-macos-window");
  const compile = await execFileResult(
    compiler,
    [source, "-o", executable],
    { timeout: 60_000, windowsHide: true, maxBuffer: 128_000 },
  );
  if (compile.code !== 0) {
    rmSync(temporaryDirectory, { force: true, recursive: true });
    throw new Error("Swift CoreGraphics 窗口观测器编译失败；请检查 Xcode Command Line Tools。");
  }

  let disposed = false;
  return {
    async observe() {
      if (disposed) {
        return { count: 0, observerError: true, windows: [] };
      }
      const result = await execFileResult(
        executable,
        macosWindowObserverArgs(),
        { timeout: 1_000, windowsHide: true, maxBuffer: 32_000 },
      );
      const observation = result.code === 0
        ? parseMacosWindowObservation(result.stdout)
        : { count: 0, windows: [] };
      return { ...observation, observerError: result.code !== 0 };
    },
    dispose() {
      if (disposed) return;
      disposed = true;
      // 目录仅由本次编译创建，删除不会触及用户工程或已有应用。
      rmSync(temporaryDirectory, { force: true, recursive: true });
    },
  };
}

async function unavailableWindowObserver() {
  return { count: 0, observerError: true, windows: [] };
}

// Flutter test 的成功文本是回收本轮 macOS 子应用前的唯一条件，不能用信号退出伪造成功。
export function hasFlutterTestSuccessOutput(output) {
  return /All tests passed!/.test(String(output));
}

// 直接 Flutter 子进程已成功退出且输出包含测试成功标记，才允许进入可见窗口验收。
export function isSuccessfulFlutterResult(result) {
  return result.code === 0 && !result.timedOut && hasFlutterTestSuccessOutput(
    `${result.stdout}\n${result.stderr}`,
  );
}

// runMacosFlutterProcess 在子进程存活期间轮询窗口，原始输出仅保留在内存供诊断，绝不写入报告。
export function runMacosFlutterProcess({
  flutter = "flutter",
  args,
  cwd,
  timeoutMs = 300_000,
  observeWindow = unavailableWindowObserver,
  onWindowObserved = null,
  onOutput = null,
  stopAfterWindowMs = null,
  closeObservedWindowsAfterMs = null,
  stopAfterOutputPattern = null,
  stopAfterOutputMs = null,
  terminateObservedWindows = false,
  terminateProcess = process.kill,
  env = process.env,
}) {
  return new Promise((resolveResult) => {
    let child;
    let stdout = "";
    let stderr = "";
    let timedOut = false;
    let settled = false;
    let timer = null;
    let forceKillTimer = null;
    let pollTimer = null;
    let stopTimer = null;
    let outputStopTimer = null;
    let observedWindowCloseTimer = null;
    let forcedChildStopTimer = null;
    let polling = false;
    let gracefulExitRequested = false;
    let outputExitRequested = false;
    let observedWindowExitRequested = false;
    let observedWindowCallbackStarted = false;
    let outputCallbackChain = Promise.resolve();
    let parentSignalReceived = false;
    let parentSignalCleanupTimer = null;
    let onParentSignal = () => {};
    const window = {
      captureArtifacts: [],
      captureError: null,
      observed: false,
      maximumWindowCount: 0,
      observationAttempts: 0,
      observerErrors: 0,
      observedAppProcessIds: new Set(),
      lastObservedWindow: null,
      portraitMobileWindowObserved: false,
      portraitMobileWindow: null,
      portraitMobileWindowMode: null,
    };

    const finish = (result) => {
      if (settled) return;
      settled = true;
      if (timer) clearTimeout(timer);
      if (forceKillTimer) clearTimeout(forceKillTimer);
      if (pollTimer) clearInterval(pollTimer);
      if (stopTimer) clearTimeout(stopTimer);
      if (outputStopTimer) clearTimeout(outputStopTimer);
      if (observedWindowCloseTimer) clearTimeout(observedWindowCloseTimer);
      if (forcedChildStopTimer) clearTimeout(forcedChildStopTimer);
      if (parentSignalCleanupTimer) clearTimeout(parentSignalCleanupTimer);
      process.off("SIGINT", onParentSignal);
      process.off("SIGTERM", onParentSignal);
      resolveResult({
        stdout,
        stderr,
        timedOut,
        window,
        gracefulExitRequested,
        outputExitRequested,
        observedWindowExitRequested,
        ...result,
      });
    };

    const requestGracefulExit = () => {
      if (gracefulExitRequested || !child || child.exitCode != null) return;
      gracefulExitRequested = true;
      try {
        if (child.stdin.writable) child.stdin.write("q\n");
      } catch {
        // 子进程已关闭 stdin 时由 close 事件收敛；不将清理动作误报为测试结果。
      }
      if (terminateObservedWindows) {
        // PID 只来自本轮后观察到的固定应用进程，绝不枚举或终止用户已有实例。
        for (const pid of window.observedAppProcessIds) {
          try {
            terminateProcess(pid, "SIGTERM");
          } catch {
            // 已退出的本轮 app 无需升级为失败。
          }
        }
        forcedChildStopTimer = setTimeout(() => {
          if (child.exitCode == null) child.kill("SIGTERM");
        }, 5_000);
      }
    };

    const requestObservedWindowExit = () => {
      if (observedWindowExitRequested || !child || child.exitCode != null) return;
      observedWindowExitRequested = true;
      // macOS integration_test 有时要等 app 退出才刷新最终文本；仅关闭本轮 CoreGraphics 已观测到的 app。
      for (const pid of window.observedAppProcessIds) {
        try {
          terminateProcess(pid, "SIGTERM");
        } catch {
          // 已退出的本轮测试 app 无需将清理动作升级成失败。
        }
      }
      forcedChildStopTimer = setTimeout(() => {
        if (child.exitCode == null) child.kill("SIGTERM");
      }, 10_000);
    };

    // 外层命令被中断时，直接启动的预构建 App 不会自动随 shell 退出；必须回收本轮子进程。
    onParentSignal = () => {
      if (parentSignalReceived) return;
      parentSignalReceived = true;
      if (child?.exitCode != null) return;
      try {
        child?.kill("SIGTERM");
      } catch {
        // 子进程已退出时，close 事件会完成清理。
      }
      parentSignalCleanupTimer = setTimeout(() => {
        if (child?.exitCode == null) child?.kill("SIGKILL");
      }, 5_000);
    };

    const scheduleOutputExit = () => {
      if (stopAfterOutputPattern == null || stopAfterOutputMs == null || outputStopTimer) return;
      stopAfterOutputPattern.lastIndex = 0;
      if (!stopAfterOutputPattern.test(`${stdout}\n${stderr}`)) return;
      outputExitRequested = true;
      outputStopTimer = setTimeout(requestGracefulExit, stopAfterOutputMs);
    };

    const scheduleOutputCallback = () => {
      if (onOutput == null) return;
      // 截图触发标记只在子进程内存输出中匹配，回调结果才会进入受控证据目录。
      const output = `${stdout}\n${stderr}`;
      outputCallbackChain = outputCallbackChain.then(async () => {
        try {
          const artifact = await onOutput({ output, window });
          if (artifact == null) return;
          if (Array.isArray(artifact)) {
            window.captureArtifacts.push(...artifact.filter(Boolean));
            return;
          }
          window.captureArtifacts.push(artifact);
        } catch {
          window.captureError = "output-evidence-capture-failed";
        }
      });
    };

    const pollWindow = async () => {
      if (polling || settled) return;
      polling = true;
      try {
        const observation = await observeWindow();
        window.observationAttempts += 1;
        if (observation.observerError) window.observerErrors += 1;
        window.maximumWindowCount = Math.max(
          window.maximumWindowCount,
          observation.count || 0,
        );
        for (const observedWindow of observation.windows || []) {
          window.lastObservedWindow = observedWindow;
          if (Number.isInteger(observedWindow.pid) && observedWindow.pid > 1) {
            window.observedAppProcessIds.add(observedWindow.pid);
          }
          if (isMacosPortraitMobileWindow(observedWindow)) {
            window.portraitMobileWindowObserved = true;
            window.portraitMobileWindow ??= observedWindow;
            window.portraitMobileWindowMode ??= macosPortraitWindowMode(observedWindow);
            if (onWindowObserved != null && !observedWindowCallbackStarted) {
              observedWindowCallbackStarted = true;
              try {
                const artifact = await onWindowObserved(window.portraitMobileWindow);
                if (Array.isArray(artifact)) {
                  window.captureArtifacts.push(...artifact.filter(Boolean));
                } else if (artifact != null) {
                  window.captureArtifacts.push(artifact);
                }
              } catch {
                // 回调只用于截图等证据；具体失败由上层 gate 以固定脱敏信息报告。
                window.captureError = "window-evidence-capture-failed";
              }
            }
          }
        }
        if (observation.count > 0) window.observed = true;
        // 初始 XIB 窗口会在下一次主循环切换为 480x960；不能因短暂的非竖屏窗口提前结束本轮场景。
        if (window.portraitMobileWindowObserved) {
          if (stopAfterWindowMs != null && !stopTimer) {
            stopTimer = setTimeout(requestGracefulExit, stopAfterWindowMs);
          }
          if (closeObservedWindowsAfterMs != null && !observedWindowCloseTimer) {
            observedWindowCloseTimer = setTimeout(
              requestObservedWindowExit,
              closeObservedWindowsAfterMs,
            );
          }
        }
      } catch {
        window.observationAttempts += 1;
        window.observerErrors += 1;
      } finally {
        polling = false;
      }
    };

    try {
      child = spawn(flutter, args, {
        cwd,
        env: safeChildEnv(env),
        stdio: ["pipe", "pipe", "pipe"],
        windowsHide: false,
      });
    } catch (error) {
      finish({
        code: null,
        signal: null,
        error: error instanceof Error ? error.message : String(error),
      });
      return;
    }

    process.once("SIGINT", onParentSignal);
    process.once("SIGTERM", onParentSignal);

    pollTimer = setInterval(() => {
      void pollWindow();
    }, 300);
    void pollWindow();
    timer = setTimeout(() => {
      timedOut = true;
      if (terminateObservedWindows) {
        // 超时也必须回收本轮已观测的 App；仅终止 /usr/bin/open 会留下
        // LaunchServices 启动的 Flutter 进程，污染下一次 gate。
        for (const pid of window.observedAppProcessIds) {
          try {
            terminateProcess(pid, "SIGTERM");
          } catch {
            // 已退出的本轮 app 无需升级为失败。
          }
        }
      }
      if (child.exitCode == null) child.kill("SIGTERM");
      forceKillTimer = setTimeout(() => {
        if (terminateObservedWindows) {
          for (const pid of window.observedAppProcessIds) {
            try {
              terminateProcess(pid, "SIGKILL");
            } catch {
              // 已退出的本轮 app 无需升级为失败。
            }
          }
        }
        if (child.exitCode == null) child.kill("SIGKILL");
      }, 10_000);
    }, timeoutMs);

    child.stdout.on("data", (chunk) => {
      stdout = appendLimited(stdout, chunk);
      scheduleOutputExit();
      scheduleOutputCallback();
    });
    child.stderr.on("data", (chunk) => {
      stderr = appendLimited(stderr, chunk);
      scheduleOutputExit();
      scheduleOutputCallback();
    });
    child.on("error", (error) => {
      finish({
        code: null,
        signal: null,
        error: error instanceof Error ? error.message : String(error),
      });
    });
    const finishAfterChildExit = (code, signal) => {
      // Flutter 工具可能让后代进程暂时持有 stdout/stderr，导致 close 晚于已成功的 exit。
      // 业务判定以启动的直接子进程 exit 为准，截图回调仍在 finish 前完成。
      void outputCallbackChain.finally(() => finish({ code, signal, error: null }));
    };
    child.on("exit", finishAfterChildExit);
    // 保留 close 兼容 spawn 异常或平台事件顺序差异；finish 的幂等保护避免重复结算。
    child.on("close", finishAfterChildExit);
  });
}

// runMacosFlutterTest 运行长期集成断言；窗口证据由独立 smoke 建立，避免依赖 flutter test 的异步 foreground 日志。
export function runMacosFlutterTest({
  flutter = "flutter",
  testPath,
  cwd,
  timeoutMs = 300_000,
  observeWindow = unavailableWindowObserver,
  onOutput = null,
  env = process.env,
  runProcess = runMacosFlutterProcess,
}) {
  return runProcess({
    flutter,
    args: flutterMacosArgs(testPath),
    cwd,
    timeoutMs,
    observeWindow,
    onOutput,
    // runner 不得在成功路径直接 SIGTERM，否则会触发 flutter_tools listener 清理竞态。
    env,
  });
}

// macOS 26 的 Flutter device integration attach 存在 open/VM 握手回归，当前本地 gate 只在这里运行不依赖 device attach 的长期业务回归。
export function runMacosFlutterWidgetTests({
  flutter = "flutter",
  testPath = "test",
  cwd,
  timeoutMs = 300_000,
  env = process.env,
  runProcess = runMacosFlutterProcess,
}) {
  return runProcess({
    flutter,
    args: flutterWidgetTestArgs(testPath),
    cwd,
    timeoutMs,
    // 业务回归不创建桌面应用窗口，避免把无窗口状态记成观测器异常。
    observeWindow: async () => ({ count: 0, observerError: false, windows: [] }),
    env,
  });
}

// 构建只生成本轮固定的 debug bundle；不启动窗口，也不把 Xcode 构建输出写入报告。
export function runMacosFlutterBuild({
  flutter = "flutter",
  cwd,
  timeoutMs = MACOS_BUILD_TIMEOUT_MS,
  env = process.env,
  runProcess = runMacosFlutterProcess,
}) {
  return runProcess({
    flutter,
    args: flutterMacosBuildArgs(),
    cwd,
    timeoutMs,
    observeWindow: async () => ({ count: 0, observerError: false, windows: [] }),
    env,
  });
}

// 已构建 app 必须通过 LaunchServices 启动，否则直接执行 bundle 内 Mach-O 可能有 Dart VM 却没有可观察窗口。
// debug 模式读取本地环境变量以选择确定性 fixture；release、Web 和 Android 不读取这些变量。
export function runMacosPrebuiltApp({
  appPath,
  cwd,
  timeoutMs = 90_000,
  observeWindow = unavailableWindowObserver,
  onWindowObserved = null,
  localVisualScenario = null,
  localVisualFrameDirectoryName = null,
  localVisualFrameCount = 0,
  localVisualFrameIntervalMs = 0,
  stopAfterWindowMs = 1_000,
  env = process.env,
  runProcess = runMacosFlutterProcess,
}) {
  const hasFrameRecorder = localVisualFrameDirectoryName != null;
  if (
    hasFrameRecorder &&
    (typeof localVisualFrameDirectoryName !== "string"
      || !/^[A-Za-z0-9_-]{1,120}$/.test(localVisualFrameDirectoryName)
      || !Number.isInteger(localVisualFrameCount)
      || localVisualFrameCount !== WINDOW_EVIDENCE_MINIMUM_CANDIDATE_FRAME_COUNT
      || !Number.isInteger(localVisualFrameIntervalMs)
      || localVisualFrameIntervalMs !== WINDOW_EVIDENCE_FRAME_INTERVAL_MS)
  ) {
    throw new Error("Flutter 渲染截图必须使用严格 5fps 候选采集参数。 ");
  }
  if (!hasFrameRecorder && (localVisualFrameCount !== 0 || localVisualFrameIntervalMs !== 0)) {
    throw new Error("未设置截图目录时不能启动 Flutter 渲染截图。 ");
  }
  const fixtureEnv = {
    ...env,
    LOCAL_FIXTURE_MODE: "true",
    // 空值会覆盖宿主机残留场景，避免登录场景意外继承上一轮 pairing fixture。
    LOCAL_VISUAL_SCENARIO: localVisualScenario ?? "",
    // 仅 debug fixture 启用；目录与帧率均由本地 runner 固定传入，不能来自 UI 或 Relay。
    LOCAL_VISUAL_FRAME_DIRECTORY: localVisualFrameDirectoryName ?? "",
    LOCAL_VISUAL_FRAME_COUNT: hasFrameRecorder ? String(localVisualFrameCount) : "",
    LOCAL_VISUAL_FRAME_INTERVAL_MS: hasFrameRecorder ? String(localVisualFrameIntervalMs) : "",
  };
  return runProcess({
    // -W 等待本轮应用退出；-n 避免复用用户已有实例，随后仍只清理本轮观察到的 PID。
    flutter: "/usr/bin/open",
    args: ["-W", "-n", appPath],
    cwd,
    timeoutMs,
    observeWindow,
    onWindowObserved,
    stopAfterWindowMs,
    // 只有 CoreGraphics 在本轮启动后观测到的 PID 会被终止，避免结束用户已有的 App 实例。
    terminateObservedWindows: true,
    env: fixtureEnv,
  });
}

// 兼容旧诊断入口：正式 gate 改用 runMacosPrebuiltApp，避免重新触发 flutter run 的 macOS 工具链回归。
export function runMacosVisibleSmoke({
  flutter = "flutter",
  cwd,
  // 首次 macOS/Xcode 原生资产构建可能超过三分钟；保留上限但不把冷构建误判为窗口启动失败。
  timeoutMs = 480_000,
  observeWindow = unavailableWindowObserver,
  onWindowObserved = null,
  localVisualScenario = null,
  stopAfterWindowMs = 1_000,
  env = process.env,
}) {
  return runMacosFlutterProcess({
    flutter,
    args: flutterMacosSmokeArgs({ localVisualScenario }),
    cwd,
    timeoutMs,
    observeWindow,
    onWindowObserved,
    stopAfterWindowMs,
    env,
  });
}
