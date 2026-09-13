#!/usr/bin/env node
// 物理 Android integration gate：只复用用户已连接并授权的真机，不启动、关闭或修改设备设置。
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { baseReport, writeReport } from "../lib/report.mjs";
import {
  findAndroidAdb,
  listConnectedDevices,
  readDeviceMetadata,
  resolveIntegrationTests,
  runCommand,
  summarizeFlutterMachineOutput,
  waitForAndroidDevice,
} from "./android.mjs";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const MOBILE_ROOT = join(ROOT, "apps", "mobile");
const DEFAULT_CASES = [
  "E2E-ANDROID-02",
  "MOBILE-01",
  "PAIR-01",
  "PAIR-02",
  "PAIR-03",
];
const DEFAULT_DEVICE_TIMEOUT_MS = 60_000;
const DEFAULT_TEST_TIMEOUT_MS = 900_000;

class GateError extends Error {
  constructor(
    message,
    {
      status = "blocked",
      failureClass = "environment_or_startup_failure",
    } = {},
  ) {
    super(message);
    this.status = status;
    this.failureClass = failureClass;
  }
}

function positiveInteger(value, name) {
  const parsed = Number.parseInt(value, 10);
  if (!Number.isInteger(parsed) || parsed <= 0) {
    throw new GateError(`${name} 必须是正整数`, {
      status: "failed",
      failureClass: "test_harness_defect",
    });
  }
  return parsed;
}

export function parseDeviceArgs(argv, env = process.env) {
  const args = {
    deviceId: env.ANDROID_DEVICE_ID || "",
    tests: [],
    cases: [...DEFAULT_CASES],
    customCases: false,
    deviceTimeoutMs: positiveInteger(
      env.ANDROID_DEVICE_E2E_READY_TIMEOUT_MS ||
        String(DEFAULT_DEVICE_TIMEOUT_MS),
      "ANDROID_DEVICE_E2E_READY_TIMEOUT_MS",
    ),
    testTimeoutMs: positiveInteger(
      env.ANDROID_DEVICE_E2E_TEST_TIMEOUT_MS || String(DEFAULT_TEST_TIMEOUT_MS),
      "ANDROID_DEVICE_E2E_TEST_TIMEOUT_MS",
    ),
    diagnostic: false,
    // 云端验收 endpoint（计划 §2「不把 fixture 结果称为真实云端闭环」）：
    // 提供后 integration_test 以 --dart-define 注入 RELAY_BASE_URL 与可选自签指纹，
    // 报告如实标记 real_upstream=true / fixture_data=false。
    endpoint: env.ACC_RELAY_ENDPOINT || "",
    tlsFingerprint: env.ACC_TLS_FINGERPRINT || "",
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--device-id") {
      args.deviceId = argv[++index] || "";
      if (!args.deviceId) {
        throw new GateError("--device-id 必须带值", {
          status: "failed",
          failureClass: "test_harness_defect",
        });
      }
    } else if (arg === "--endpoint") {
      args.endpoint = argv[++index] || "";
      if (!args.endpoint) {
        throw new GateError("--endpoint 必须带值（例如 https://39.106.135.11）", {
          status: "failed",
          failureClass: "test_harness_defect",
        });
      }
    } else if (arg === "--tls-fingerprint") {
      args.tlsFingerprint = argv[++index] || "";
      if (!args.tlsFingerprint) {
        throw new GateError("--tls-fingerprint 必须带值（证书 DER 的 SHA-256）", {
          status: "failed",
          failureClass: "test_harness_defect",
        });
      }
    } else if (arg === "--test") args.tests.push(argv[++index] || "");
    else if (arg === "--case") {
      if (!args.customCases) {
        args.cases = [];
        args.customCases = true;
      }
      args.cases.push(argv[++index] || "");
    } else if (arg === "--device-timeout-ms") {
      args.deviceTimeoutMs = positiveInteger(
        argv[++index],
        "--device-timeout-ms",
      );
    } else if (arg === "--test-timeout-ms") {
      args.testTimeoutMs = positiveInteger(argv[++index], "--test-timeout-ms");
    } else if (arg === "--diagnostic") args.diagnostic = true;
    else if (arg === "--avd" || arg === "--keep-avd" || arg === "--headless") {
      throw new GateError("物理 Android gate 不接受 AVD 或 headless 参数", {
        status: "failed",
        failureClass: "test_harness_defect",
      });
    } else if (arg === "--help" || arg === "-h") {
      return { help: true };
    } else {
      throw new GateError(`未知参数：${arg}`, {
        status: "failed",
        failureClass: "test_harness_defect",
      });
    }
  }

  if (
    args.tests.some((test) => !test) ||
    args.cases.some((testCase) => !testCase)
  ) {
    throw new GateError("--device-id、--test 和 --case 必须带值", {
      status: "failed",
      failureClass: "test_harness_defect",
    });
  }
  return args;
}

export function selectPhysicalDevice(devices, requestedId = "") {
  if (requestedId.startsWith("emulator-")) {
    throw new GateError("物理 Android gate 拒绝 emulator serial", {
      status: "failed",
      failureClass: "test_harness_defect",
    });
  }

  if (requestedId) {
    const selected = devices.find((device) => device.serial === requestedId);
    if (!selected)
      throw new GateError(`未找到指定 Android 设备 ${requestedId}`);
    if (selected.state !== "device") {
      throw new GateError(
        `Android 设备 ${requestedId} 当前状态为 ${selected.state}，请在设备上完成 ADB 授权`,
      );
    }
    return selected;
  }

  const physical = devices.filter(
    (device) =>
      !device.serial.startsWith("emulator-") && device.state === "device",
  );
  if (physical.length === 0) {
    const unavailable = devices.filter(
      (device) => !device.serial.startsWith("emulator-"),
    );
    if (unavailable.length > 0) {
      throw new GateError(
        "已发现物理 Android 设备，但设备尚未完成 ADB 授权或未处于 online 状态",
      );
    }
    throw new GateError("未发现已连接的物理 Android 设备");
  }
  if (physical.length > 1) {
    throw new GateError(
      "发现多台物理 Android 设备；请使用 --device-id 明确选择",
      {
        status: "failed",
        failureClass: "test_harness_defect",
      },
    );
  }
  return physical[0];
}

export function physicalFlutterIntegrationArgs(tests, serial, cloud = null) {
  // 不传 --no-uninstall，让 Flutter 在物理设备 gate 后清理测试 APK。
  // cloud（云端验收模式）：endpoint 必填，指纹可选——经 --dart-define 编译期注入，
  // 与 apps/mobile/lib/relay/acceptance_tls.dart 的放行通道一一对应。
  const defines = [];
  if (cloud?.endpoint) {
    defines.push(`--dart-define=RELAY_BASE_URL=${cloud.endpoint}`);
    if (cloud.tlsFingerprint) {
      defines.push(`--dart-define=ACC_TLS_FINGERPRINT=${cloud.tlsFingerprint}`);
    }
  }
  return ["test", ...defines, ...tests, "-d", serial, "--machine"];
}

export function classifyPhysicalFlutterResult(result, testSummary) {
  const output = `${result.stdout || ""}\n${result.stderr || ""}`;
  if (result.code === 0 && !result.timedOut) {
    return {
      status: "passed",
      failureClass: null,
      remainingRisk:
        "真实 Provider、Push、后台限制和网络切换未由当前 fixture integration_test 调用。",
    };
  }
  if (result.timedOut) {
    return {
      status: "failed",
      failureClass: "environment_or_startup_failure",
      remainingRisk:
        "物理 Android 上的 Flutter integration_test 超时；原始输出未写入报告。",
    };
  }
  if (result.code == null) {
    return {
      status: "failed",
      failureClass: "environment_or_startup_failure",
      remainingRisk: "Flutter CLI 在物理 Android integration_test 期间不可用。",
    };
  }
  if (/INSTALL_FAILED_USER_RESTRICTED|Install canceled by user/i.test(output)) {
    return {
      status: "failed",
      failureClass: "environment_or_startup_failure",
      remainingRisk:
        "物理 Android 拒绝安装测试 APK（INSTALL_FAILED_USER_RESTRICTED / Install canceled by user）；请在设备上允许 USB/ADB 安装后重试。",
    };
  }
  if (testSummary.test_failed > 0 || testSummary.done_success === false) {
    return {
      status: "failed",
      failureClass: "product_defect",
      remainingRisk:
        "至少一个物理 Android integration 断言失败；请用 --diagnostic 在本地终端复现。",
    };
  }
  return {
    status: "failed",
    failureClass: "test_harness_defect",
    remainingRisk: "Flutter runner 未产生可判定的物理 Android 测试结果。",
  };
}

function usage() {
  return [
    "用法：node e2e-verify/mobile/run-android-device.mjs [选项]",
    "  --device-id <adb-serial>    指定已授权的物理设备；仅连接一台时可省略",
    "  --test <relative-path>      指定 apps/mobile 下的 integration_test 文件，可重复",
    "  --case <stable-id>          报告中的稳定测试 ID，可重复",
    "  --endpoint <url>            云端验收模式：Relay HTTPS 地址（如 https://39.106.135.11），",
    "                              报告标记 real_upstream=true/fixture_data=false",
    "  --tls-fingerprint <sha256>  云端自签证书 DER SHA-256；经 --dart-define 注入客户端放行通道",
    "  --diagnostic                仅在当前终端输出 Flutter 原始诊断，不写入报告",
    "  --device-timeout-ms <ms>    物理设备 online/启动完成等待上限",
    "  --test-timeout-ms <ms>      Flutter integration_test 等待上限",
    "  --avd/--headless            不支持；模拟器使用 task test:android:e2e",
  ].join("\n");
}

function safeError(error) {
  return error instanceof Error
    ? error.message.replace(/(bearer\s+)[^\s]+/gi, "$1[REDACTED]")
    : "未知运行错误";
}

async function verifyFlutter() {
  const flutter = process.env.FLUTTER_BIN || "flutter";
  const result = await runCommand(flutter, ["--version"], {
    timeoutMs: 30_000,
  });
  if (result.code !== 0) {
    throw new GateError(
      "Flutter CLI 不可用；请先安装 Flutter 或设置 FLUTTER_BIN",
    );
  }
  return flutter;
}

async function rejectEmulatedDevice(adbPath, serial) {
  const result = await runCommand(
    adbPath,
    ["-s", serial, "shell", "getprop", "ro.kernel.qemu"],
    { timeoutMs: 5_000 },
  );
  if (result.code !== 0)
    throw new GateError("无法确认 Android 设备是否为物理设备");
  if (result.stdout.trim() === "1") {
    throw new GateError(
      "所选设备由 Android 报告为模拟器，不能用于物理设备 gate",
      {
        status: "failed",
        failureClass: "test_harness_defect",
      },
    );
  }
}

async function keepPhysicalDeviceAwake(adbPath, serial) {
  const previous = await runCommand(
    adbPath,
    [
      "-s",
      serial,
      "shell",
      "settings",
      "get",
      "global",
      "stay_on_while_plugged_in",
    ],
    { timeoutMs: 5_000 },
  );
  const previousValue =
    previous.code === 0 && /^\d+$/.test(previous.stdout.trim())
      ? previous.stdout.trim()
      : "0";
  const enabled = await runCommand(
    adbPath,
    ["-s", serial, "shell", "svc", "power", "stayon", "usb"],
    {
      timeoutMs: 5_000,
    },
  );
  if (enabled.code !== 0)
    throw new GateError("无法让物理 Android 在 USB 测试期间保持唤醒");
  return { attempted: true, previousValue, restored: false };
}

async function ensurePhysicalDeviceAwake(adbPath, serial) {
  const power = await runCommand(
    adbPath,
    ["-s", serial, "shell", "dumpsys", "power"],
    {
      timeoutMs: 5_000,
    },
  );
  if (power.code !== 0 || !/mWakefulness=Awake/.test(power.stdout)) {
    throw new GateError(
      "物理 Android 屏幕处于休眠状态；请点亮并解锁设备后重试",
    );
  }
  const window = await runCommand(
    adbPath,
    ["-s", serial, "shell", "dumpsys", "window"],
    {
      timeoutMs: 5_000,
    },
  );
  if (
    window.code === 0 &&
    (/mShowingLockscreen=true/.test(window.stdout) ||
      /mDreamingLockscreen=true/.test(window.stdout))
  ) {
    throw new GateError("物理 Android 仍处于锁屏状态；请先解锁设备后重试");
  }
}

async function restorePhysicalDeviceAwake(adbPath, serial, screenState) {
  if (!screenState?.attempted) return { ...screenState, restored: false };
  const restored = await runCommand(
    adbPath,
    [
      "-s",
      serial,
      "shell",
      "settings",
      "put",
      "global",
      "stay_on_while_plugged_in",
      screenState.previousValue,
    ],
    { timeoutMs: 5_000 },
  );
  return { ...screenState, restored: restored.code === 0 };
}

function commandForReport(flutter, tests) {
  return `${flutter} ${physicalFlutterIntegrationArgs(tests, "[PHYSICAL_DEVICE]").join(" ")}`;
}

async function main() {
  const timestamp = new Date().toISOString().replace(/[:.]/g, "-");
  const startedAt = Date.now();
  let args = null;
  let flutter = null;
  let tests = [];
  let device = null;
  let verifiedPhysicalDevice = false;
  let status = "failed";
  let failureClass = "test_harness_defect";
  let remainingRisk = "";
  let testSummary = null;
  let command = "node e2e-verify/mobile/run-android-device.mjs";
  let screenState = null;
  let selectedSerial = "";
  let adbPath = null;

  try {
    args = parseDeviceArgs(process.argv.slice(2));
    if (args.help) {
      process.stdout.write(`${usage()}\n`);
      return;
    }
    // 云端验收模式（计划 ACC-02..05）：提供 --endpoint/ACC_RELAY_ENDPOINT 即视为
    // 真实云端链路验证；报告与 dart-define 均按该口径切换。
    const cloud = args.endpoint
      ? { endpoint: args.endpoint, tlsFingerprint: args.tlsFingerprint }
      : null;

    ({ adbPath } = findAndroidAdb());
    flutter = await verifyFlutter();
    tests = resolveIntegrationTests(MOBILE_ROOT, args.tests);
    if (tests.length === 0) {
      throw new GateError(
        "未发现 apps/mobile/integration_test/*_test.dart，无法执行物理 Android gate",
        {
          status: "failed",
          failureClass: "test_harness_defect",
        },
      );
    }

    const connected = await listConnectedDevices(adbPath);
    const selected = selectPhysicalDevice(connected, args.deviceId);
    selectedSerial = selected.serial;
    screenState = await keepPhysicalDeviceAwake(adbPath, selected.serial);
    await ensurePhysicalDeviceAwake(adbPath, selected.serial);
    await waitForAndroidDevice(adbPath, selected.serial, args.deviceTimeoutMs);
    await rejectEmulatedDevice(adbPath, selected.serial);
    verifiedPhysicalDevice = true;
    const metadata = await readDeviceMetadata(adbPath, selected.serial);
    device = {
      model: metadata.model,
      android_version: metadata.android_version,
      api_level: metadata.api_level,
      adb_serial_recorded: false,
    };
    command = commandForReport(flutter, tests);
    process.stdout.write(
      `[android-device-e2e] 使用物理设备 ${device.model} (Android ${device.android_version}, API ${device.api_level})，运行 ${tests.length} 个 integration_test 文件\n`,
    );

    const result = await runCommand(
      flutter,
      physicalFlutterIntegrationArgs(tests, selected.serial, cloud),
      { cwd: MOBILE_ROOT, timeoutMs: args.testTimeoutMs },
    );
    if (args.diagnostic) {
      process.stdout.write(
        "[android-device-e2e] Flutter diagnostic output (not persisted):\n",
      );
      process.stdout.write(`${result.stdout}${result.stderr}`);
      process.stdout.write(
        "\n[android-device-e2e] End Flutter diagnostic output\n",
      );
    }
    testSummary = summarizeFlutterMachineOutput(
      `${result.stdout}\n${result.stderr}`,
    );
    ({ status, failureClass, remainingRisk } = classifyPhysicalFlutterResult(
      result,
      testSummary,
    ));
  } catch (error) {
    status = error instanceof GateError ? error.status : "failed";
    failureClass =
      error instanceof GateError ? error.failureClass : "test_harness_defect";
    remainingRisk = safeError(error);
  } finally {
    if (args?.help) return;
    if (screenState && selectedSerial && adbPath) {
      screenState = await restorePhysicalDeviceAwake(
        adbPath,
        selectedSerial,
        screenState,
      );
    }
    const report = baseReport({
      suite: "android-physical-device-gate",
      status,
      real_browser: false,
      real_model: false,
      // 云端 endpoint 模式 = 真实上游链路；fixture 模式保持 false（计划 §2 不得混淆口径）。
      real_upstream: Boolean(cloud?.endpoint),
      fixture_data: !cloud?.endpoint,
      local_test: !cloud?.endpoint,
      headless: false,
      browser: "n/a",
      command,
      artifacts: [],
      failure_class: failureClass,
      remaining_risk: remainingRisk,
    });
    const reportPath = writeReport({
      planId: "ANDROID",
      name: "e2e-android-02",
      report: {
        timestamp,
        ...report,
        gate_kind: "android_physical_device_integration",
        real_device: verifiedPhysicalDevice,
        simulated_device: false,
        device_mode: "physical_android",
        host_platform: process.platform,
        visible_device: verifiedPhysicalDevice,
        real_provider_called: false,
        push_called: false,
        background_recovery_tested: false,
        network_switch_tested: false,
        test_ids: args?.cases || DEFAULT_CASES,
        integration_tests: tests,
        // fixture 口径仅在本地模式登记；云端模式记录 endpoint 与指纹启用情况。
        fixture_revision: cloud?.endpoint ? null : "local-deterministic-fixture",
        cloud: cloud?.endpoint
          ? {
              provider: "aliyun",
              endpoint: cloud.endpoint,
              tls_fingerprint_applied: Boolean(cloud.tlsFingerprint),
              tls_mode: "self-signed-fingerprint-pinning",
            }
          : null,
        device,
        diagnostic_mode: Boolean(args?.diagnostic),
        cleanup: {
          device_settings_changed: Boolean(screenState?.attempted),
          device_settings_restored: Boolean(screenState?.restored),
          device_stopped: false,
          test_apk_cleanup: "flutter_default",
        },
        test_summary: testSummary,
        duration_ms: Date.now() - startedAt,
      },
    });
    process.stdout.write(`[android-device-e2e] ${status} -> ${reportPath}\n`);
    if (status !== "passed") process.exitCode = 1;
  }
}

const invokedPath = process.argv[1] ? resolve(process.argv[1]) : "";
if (invokedPath === fileURLToPath(import.meta.url)) {
  main().catch((error) => {
    process.stderr.write(`[android-device-e2e] ${safeError(error)}\n`);
    process.exitCode = 1;
  });
}
