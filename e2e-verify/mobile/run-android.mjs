#!/usr/bin/env node
// Android integration full-gate 入口：仅在 macOS 主机的可见 AVD 上运行 Flutter integration_test。
// v0.1 当前阶段不接入外接真机；默认 AVD 为 Nexus_5X_API_32，且不支持 headless。
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { baseReport, writeReport } from "../lib/report.mjs";
import {
  findAndroidTools,
  findRunningAvd,
  detachRetainedAvd,
  listAvdNames,
  resolveIntegrationTests,
  readDeviceMetadata,
  runCommand,
  startVisibleAvd,
  stopStartedAvd,
  stopUnreadyStartedAvd,
  summarizeFlutterMachineOutput,
  waitForAvdBoot,
} from "./android.mjs";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const MOBILE_ROOT = join(ROOT, "apps", "mobile");
const DEFAULT_AVD = "Nexus_5X_API_32";
const DEFAULT_CASES = ["MOBILE-01", "PAIR-01", "PAIR-02", "PAIR-03"];
// 首次 Flutter Android 构建可能编译 Gradle/插件超过十分钟；仍保留有界超时以防止 gate 无限卡住。
const DEFAULT_TEST_TIMEOUT_MS = 900_000;

class GateError extends Error {
  constructor(message, { status = "blocked", failureClass = "environment_or_startup_failure" } = {}) {
    super(message);
    this.status = status;
    this.failureClass = failureClass;
  }
}

function positiveInteger(value, name) {
  const parsed = Number.parseInt(value, 10);
  if (!Number.isInteger(parsed) || parsed <= 0) throw new GateError(`${name} 必须是正整数`, {
    status: "failed",
    failureClass: "test_harness_defect",
  });
  return parsed;
}

export function parseArgs(argv) {
  const args = {
    avd: process.env.ANDROID_AVD || DEFAULT_AVD,
    tests: [],
    cases: [...DEFAULT_CASES],
    customCases: false,
    bootTimeoutMs: positiveInteger(process.env.ANDROID_E2E_BOOT_TIMEOUT_MS || "180000", "ANDROID_E2E_BOOT_TIMEOUT_MS"),
    testTimeoutMs: positiveInteger(process.env.ANDROID_E2E_TEST_TIMEOUT_MS || String(DEFAULT_TEST_TIMEOUT_MS), "ANDROID_E2E_TEST_TIMEOUT_MS"),
    keepAvd: false,
    diagnostic: false,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--avd") args.avd = argv[++index] || "";
    else if (arg === "--device-id") {
      throw new GateError("v0.1 当前阶段只支持 macOS 可见 AVD；外接真机验证留待后续实机阶段", {
        status: "failed",
        failureClass: "test_harness_defect",
      });
    }
    else if (arg === "--test") args.tests.push(argv[++index] || "");
    else if (arg === "--case") {
      if (!args.customCases) {
        args.cases = [];
        args.customCases = true;
      }
      args.cases.push(argv[++index] || "");
    } else if (arg === "--boot-timeout-ms") args.bootTimeoutMs = positiveInteger(argv[++index], "--boot-timeout-ms");
    else if (arg === "--test-timeout-ms") args.testTimeoutMs = positiveInteger(argv[++index], "--test-timeout-ms");
    else if (arg === "--keep-avd") args.keepAvd = true;
    else if (arg === "--diagnostic") args.diagnostic = true;
    else if (arg === "--headless") {
      throw new GateError("Android integration gate 不支持 --headless；必须使用 macOS 上可见的 Android AVD", {
        status: "failed",
        failureClass: "test_harness_defect",
      });
    } else if (arg === "--help" || arg === "-h") {
      return { help: true };
    } else {
      throw new GateError(`未知参数：${arg}`, { status: "failed", failureClass: "test_harness_defect" });
    }
  }

  if (!args.avd) {
    throw new GateError("必须提供 --avd", { status: "failed", failureClass: "test_harness_defect" });
  }
  if (args.tests.some((test) => !test) || args.cases.some((testCase) => !testCase)) {
    throw new GateError("--test 和 --case 必须带值", { status: "failed", failureClass: "test_harness_defect" });
  }
  return args;
}

function usage() {
  return [
    "用法：node e2e-verify/mobile/run-android.mjs [选项]",
    "  --avd <name>                 AVD 名称，默认 Nexus_5X_API_32",
    "  --test <relative-path>      指定 apps/mobile 下的 integration_test 文件，可重复",
    "  --case <stable-id>          报告中的稳定测试 ID，可重复",
    "  --keep-avd                  保留本轮启动的 AVD（默认在 gate 后停止）",
    "  --diagnostic                 仅即时输出 Flutter 定向诊断，不写入报告",
    "  --boot-timeout-ms <ms>      AVD 启动等待上限",
    "  --test-timeout-ms <ms>      Flutter integration_test 等待上限",
    "  --headless                  不支持，Android 可见验收必须使用 macOS AVD",
  ].join("\n");
}

function safeError(error) {
  // 报告只记录失败类别和不含工具输出的短摘要，避免意外记录应用正文或环境凭据。
  return error instanceof Error ? error.message.replace(/(bearer\s+)[^\s]+/gi, "$1[REDACTED]") : "未知运行错误";
}

async function verifyFlutter() {
  const flutter = process.env.FLUTTER_BIN || "flutter";
  const result = await runCommand(flutter, ["--version"], { timeoutMs: 30_000 });
  if (result.code !== 0) {
    throw new GateError("Flutter CLI 不可用；请先安装 Flutter 或设置 FLUTTER_BIN", {
      failureClass: "environment_or_startup_failure",
    });
  }
  return flutter;
}

async function acquireAndroidDevice({ args, tools }) {
  try {
    const reusable = await findRunningAvd(tools.adbPath, args.avd);
    if (reusable) {
      const ready = await waitForAvdBoot({
        adbPath: tools.adbPath,
        avdName: args.avd,
        timeoutMs: args.bootTimeoutMs,
      });
      return {
        serial: ready.serial,
        avdName: args.avd,
        source: "reused_avd",
        startedByRunner: false,
        child: null,
      };
    }

    const avdNames = await listAvdNames(tools.emulatorPath);
    if (!avdNames.includes(args.avd)) {
      throw new GateError(`未找到 AVD ${args.avd}；可用 AVD: ${avdNames.join(", ") || "无"}`, {
        failureClass: "environment_or_startup_failure",
      });
    }

    process.stdout.write(`[android-e2e] 启动可见 AVD: ${args.avd}\n`);
    const child = startVisibleAvd(tools.emulatorPath, args.avd);
    let ready;
    try {
      ready = await waitForAvdBoot({
        adbPath: tools.adbPath,
        avdName: args.avd,
        timeoutMs: args.bootTimeoutMs,
        startedChild: child,
      });
    } catch (error) {
      // serial 尚不可用时也只终止本轮 spawn 的直接子进程，不扫描或影响其他模拟器。
      const cleanup = await stopUnreadyStartedAvd(child);
      throw new GateError(
        `Android AVD 启动失败${cleanup.stopped ? "，本轮进程已清理" : "，本轮进程清理未确认"}`,
        { failureClass: "environment_or_startup_failure" },
      );
    }
    return {
      serial: ready.serial,
      avdName: args.avd,
      source: "started_avd",
      startedByRunner: true,
      child,
    };
  } catch (error) {
    if (error instanceof GateError) throw error;
    throw new GateError("macOS Android AVD 环境不可用", { failureClass: "environment_or_startup_failure" });
  }
}

// flutterIntegrationArgs 固定保留 machine 事件用于脱敏摘要，并避免每次 full gate 卸载 AVD 应用。
// 正常退出仍是通过条件；该参数只减少不必要的清理，不会绕过 stopApp/DDS 的退出检查。
export function flutterIntegrationArgs(tests, serial) {
  return ["test", ...tests, "-d", serial, "--machine", "--no-uninstall"];
}

function commandForReport(flutter, tests, serial) {
  return `${flutter} ${flutterIntegrationArgs(tests, serial).join(" ")}`;
}

async function main() {
  const timestamp = new Date().toISOString().replace(/[:.]/g, "-");
  const startedAt = Date.now();
  let args = null;
  let acquisition = null;
  let tools = null;
  let flutter = null;
  let tests = [];
  let device = null;
  let status = "failed";
  let failureClass = "test_harness_defect";
  let remainingRisk = "";
  let testSummary = null;
  let command = "node e2e-verify/mobile/run-android.mjs";
  let cleanup = { attempted: false, stopped: false, forced: false };

  try {
    args = parseArgs(process.argv.slice(2));
    if (args.help) {
      process.stdout.write(`${usage()}\n`);
      return;
    }

    if (process.platform !== "darwin") {
      throw new GateError("v0.1 当前 Android full gate 仅支持在 macOS 主机执行可见 AVD 模拟", {
        failureClass: "environment_or_startup_failure",
      });
    }

    try {
      // 当前阶段固定使用 macOS SDK 的 Emulator 与 ADB，拒绝外接真机路径。
      tools = findAndroidTools();
    } catch {
      throw new GateError("Android SDK 工具不可用", { failureClass: "environment_or_startup_failure" });
    }
    flutter = await verifyFlutter();
    tests = resolveIntegrationTests(MOBILE_ROOT, args.tests);
    if (tests.length === 0) {
      throw new GateError("未发现 apps/mobile/integration_test/*_test.dart，无法执行 Android integration gate", {
        failureClass: "test_harness_defect",
      });
    }

    acquisition = await acquireAndroidDevice({ args, tools });
    device = await readDeviceMetadata(tools.adbPath, acquisition.serial);
    command = commandForReport(flutter, tests, acquisition.serial);
    process.stdout.write(`[android-e2e] 使用 macOS 可见 AVD ${device.model} (${device.serial})，运行 ${tests.length} 个 integration_test 文件\n`);

    // flutter test 在指定 adb serial 上安装并驱动应用；AVD 窗口保持可见，未启用 headless。
    const result = await runCommand(
      flutter,
      flutterIntegrationArgs(tests, acquisition.serial),
      { cwd: MOBILE_ROOT, timeoutMs: args.testTimeoutMs },
    );
    if (args.diagnostic) {
      // 原始 Flutter 输出只用于当前本地终端排障，报告仍仅保存脱敏事件计数。
      process.stdout.write("[android-e2e] Flutter diagnostic output (not persisted):\n");
      process.stdout.write(`${result.stdout}${result.stderr}`);
      process.stdout.write("\n[android-e2e] End Flutter diagnostic output\n");
    }
    testSummary = summarizeFlutterMachineOutput(`${result.stdout}\n${result.stderr}`);
    if (result.code === 0 && !result.timedOut) {
      status = "passed";
      failureClass = null;
    } else if (result.timedOut) {
      status = "failed";
      failureClass = "environment_or_startup_failure";
      remainingRisk = "Flutter integration_test 超时；报告未保存原始测试输出，请在可见 AVD 中复现并查看本地终端。";
    } else if (result.code == null) {
      status = "failed";
      failureClass = "environment_or_startup_failure";
      remainingRisk = "Flutter CLI 在 Android integration_test 期间不可用；报告未保存原始工具输出。";
    } else if (testSummary.test_failed > 0 || testSummary.done_success === false) {
      status = "failed";
      failureClass = "product_defect";
      remainingRisk = "至少一个 Android integration 断言失败；请依据稳定测试 ID 和 Flutter 终端输出定位。";
    } else {
      status = "failed";
      failureClass = "test_harness_defect";
      remainingRisk = "Flutter integration runner 未完成可判定的测试结果；请检查本地 Android/Flutter 环境。";
    }
  } catch (error) {
    status = error instanceof GateError ? error.status : "failed";
    failureClass = error instanceof GateError ? error.failureClass : "test_harness_defect";
    remainingRisk = safeError(error);
  } finally {
    if (acquisition?.startedByRunner && tools && !args?.keepAvd) {
      // 只关闭本轮 spawn 的 AVD；复用的用户模拟器和其他 emulator 均不会受影响。
      cleanup = await stopStartedAvd({
        adbPath: tools.adbPath,
        serial: acquisition.serial,
        child: acquisition.child,
      });
      if (!cleanup.stopped) {
        remainingRisk = `${remainingRisk}${remainingRisk ? "；" : ""}本轮 AVD 清理未确认完成，需人工检查。`;
      }
    } else if (acquisition?.startedByRunner && args?.keepAvd) {
      // 保留可见模拟器供 targeted diagnostic 使用，但不能让 child handle 阻塞 runner 进程退出。
      detachRetainedAvd(acquisition.child);
      cleanup = { attempted: false, stopped: false, forced: false, retained_by_request: true };
    }

    if (args?.help) return;
    const report = baseReport({
      suite: "android-integration-gate",
      status,
      real_browser: false,
      real_model: false,
      real_upstream: false,
      fixture_data: true,
      local_test: true,
      headless: false,
      browser: "n/a",
      command,
      artifacts: [],
      failure_class: failureClass,
      remaining_risk: remainingRisk,
    });
    const reportPath = writeReport({
      planId: "ANDROID",
      name: "android-integration-gate",
      report: {
        timestamp,
        ...report,
        gate_kind: "android_integration",
        real_device: false,
        simulated_device: Boolean(acquisition),
        device_mode: "macos_visible_android_avd",
        host_platform: "macos",
        visible_device: Boolean(acquisition),
        test_ids: args?.cases || DEFAULT_CASES,
        integration_tests: tests,
        fixture_revision: "local-deterministic-fixture",
        device,
        avd: acquisition?.avdName || args?.avd || null,
        device_source: acquisition?.source || "not_acquired",
        started_by_runner: Boolean(acquisition?.startedByRunner),
        diagnostic_mode: Boolean(args?.diagnostic),
        cleanup,
        test_summary: testSummary,
        duration_ms: Date.now() - startedAt,
      },
    });
    process.stdout.write(`[android-e2e] ${status} -> ${reportPath}\n`);
    if (status !== "passed") process.exitCode = 1;
  }
}

const invokedPath = process.argv[1] ? resolve(process.argv[1]) : "";
if (invokedPath === fileURLToPath(import.meta.url)) {
  main().catch((error) => {
    process.stderr.write(`[android-e2e] ${safeError(error)}\n`);
    process.exitCode = 1;
  });
}
