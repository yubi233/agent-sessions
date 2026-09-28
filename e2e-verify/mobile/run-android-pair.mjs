#!/usr/bin/env node
// OWN-06 双机真机配对旅程编排器（v0.10.0，ADR-017）。
//
// 旅程：旧手机（approver）先经 owner-pairing 加入（由本编排器持隔离栈终端 owner
// 令牌批准）→ 新手机（joiner）发起请求 → 旧手机在配对页以 UI（比对码核对 +
// 二次确认）批准 → joiner 领取令牌 → joiner 新建 DSH 会话发送最小消息（真实
// 模型）→ approver 实时看到回复 → 服务端交叉断言 ≥2 台 active android_owner。
//
// 关键决策：
//   1. integration test 每次运行都会清空设备应用数据，"现役 owner 手机"无法
//      跨运行保留凭据——因此旅程使用一套**隔离栈**（独立 state-dir/端口/DB），
//      两台手机都以全新身份加入，权限链自洽；主栈（soak，8787）完全不动。
//   2. 隔离栈复用 restart.sh 全部成熟机制（local-dev pairing 自动建立终端
//      owner + daemon 配对），仅以 env/flag 重定向状态目录与端口。
//   3. 真机入口走 relay-lan-bridge（LAN 端口 → 127.0.0.1 隔离 Relay）。
//
// 口径：real_device=true、real_model=true（joiner 发送收口）、fixture_data=false、
// local_test=true（隔离 Relay 在本机）。
//
// 用法：node e2e-verify/mobile/run-android-pair.mjs [选项]
//   --approver-id <serial>  旧手机 adb serial（缺省时必须恰好两台物理设备）
//   --joiner-id <serial>    新手机 adb serial（同上）
//   --lan-ip <ip>           真机访问本机的入口 IP（默认 ipconfig 探测 en0/en1）
//   --relay-port <port>     隔离 Relay 端口（默认 8797；绝不占主栈 8787）
//   --lan-port <port>       真机 LAN 入口端口（默认 8798）
//   --opencode-port <port>  隔离栈 OpenCode 端口（默认 4196；绝不占主栈 4096）
//   --state-dir <dir>       隔离栈状态目录（默认 .task/own06，旅程开始时重建）
//   --keep-stack            旅程结束后保留隔离栈（诊断用；默认停止）
//   --no-stack              不拉起隔离栈（已手工拉起并注入 AGENT_SESSIONS_OWNER_PAIRING=on 时）
//   --diagnostic            输出两台设备的 Flutter 原始输出（不落盘）
//   --test-timeout-ms <ms>  每个 flutter run 的上限（默认 30 分钟）
import { existsSync, mkdirSync, readFileSync, rmSync } from "node:fs";
import { spawn } from "node:child_process";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { baseReport, writeReport } from "../lib/report.mjs";
import {
  findAndroidAdb,
  listConnectedDevices,
  runCommand,
  summarizeFlutterMachineOutput,
  waitForAndroidDevice,
} from "./android.mjs";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const MOBILE_ROOT = join(ROOT, "apps", "mobile");
const APPROVER_TEST = "integration_test/own06_owner_approver_test.dart";
const JOINER_TEST = "integration_test/own06_pair_joiner_test.dart";
const APPROVER_DISPLAY_NAME = "OWN06-Approver-A";
const JOINER_DISPLAY_NAME = "OWN06-Joiner-B";
const DEFAULT_RELAY_PORT = 8797;
const DEFAULT_LAN_PORT = 8798;
const DEFAULT_OPENCODE_PORT = 4196;
const DEFAULT_TEST_TIMEOUT_MS = 1_800_000;
const APPROVAL_PUMP_TIMEOUT_MS = 720_000;
const STACK_READY_TIMEOUT_MS = 180_000;

class GateError extends Error {
  constructor(
    message,
    { status = "blocked", failureClass = "environment_or_startup_failure" } = {},
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

export function parsePairArgs(argv, env = process.env) {
  const args = {
    approverId: env.ANDROID_APPROVER_ID || "",
    joinerId: env.ANDROID_JOINER_ID || "",
    lanIp: env.OWN06_LAN_IP || "",
    relayPort: positiveInteger(
      env.OWN06_RELAY_PORT || String(DEFAULT_RELAY_PORT),
      "OWN06_RELAY_PORT",
    ),
    lanPort: positiveInteger(
      env.OWN06_LAN_PORT || String(DEFAULT_LAN_PORT),
      "OWN06_LAN_PORT",
    ),
    opencodePort: positiveInteger(
      env.OWN06_OPENCODE_PORT || String(DEFAULT_OPENCODE_PORT),
      "OWN06_OPENCODE_PORT",
    ),
    stateDir: resolve(ROOT, env.OWN06_STATE_DIR || ".task/own06"),
    keepStack: false,
    noStack: false,
    diagnostic: false,
    testTimeoutMs: positiveInteger(
      env.OWN06_TEST_TIMEOUT_MS || String(DEFAULT_TEST_TIMEOUT_MS),
      "OWN06_TEST_TIMEOUT_MS",
    ),
    help: false,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const takeValue = (name) => {
      const value = argv[++index];
      if (!value) {
        throw new GateError(`${name} 必须带值`, {
          status: "failed",
          failureClass: "test_harness_defect",
        });
      }
      return value;
    };
    if (arg === "--approver-id") args.approverId = takeValue(arg);
    else if (arg === "--joiner-id") args.joinerId = takeValue(arg);
    else if (arg === "--lan-ip") args.lanIp = takeValue(arg);
    else if (arg === "--relay-port") args.relayPort = positiveInteger(takeValue(arg), arg);
    else if (arg === "--lan-port") args.lanPort = positiveInteger(takeValue(arg), arg);
    else if (arg === "--opencode-port") args.opencodePort = positiveInteger(takeValue(arg), arg);
    else if (arg === "--state-dir") args.stateDir = resolve(ROOT, takeValue(arg));
    else if (arg === "--keep-stack") args.keepStack = true;
    else if (arg === "--no-stack") args.noStack = true;
    else if (arg === "--diagnostic") args.diagnostic = true;
    else if (arg === "--test-timeout-ms") args.testTimeoutMs = positiveInteger(takeValue(arg), arg);
    else if (arg === "--help" || arg === "-h") args.help = true;
    else {
      throw new GateError(`未知参数：${arg}`, {
        status: "failed",
        failureClass: "test_harness_defect",
      });
    }
  }
  if (args.relayPort === 8787 || args.opencodePort === 4096) {
    throw new GateError(
      "隔离栈端口与主栈冲突（8787/4096）；请换端口",
      { status: "failed", failureClass: "test_harness_defect" },
    );
  }
  return args;
}

// 两台物理设备的选择：显式指定优先；未指定时要求恰好两台在线物理设备。
export function selectPairDevices(devices, { approverId = "", joinerId = "" } = {}) {
  const physical = devices.filter(
    (device) => !device.serial.startsWith("emulator-") && device.state === "device",
  );
  const pick = (requestedId, role) => {
    if (requestedId.startsWith("emulator-")) {
      throw new GateError(`OWN-06 拒绝 emulator serial（${role}）`, {
        status: "failed",
        failureClass: "test_harness_defect",
      });
    }
    if (requestedId) {
      const selected = devices.find((device) => device.serial === requestedId);
      if (!selected) {
        throw new GateError(`未找到${role}设备 ${requestedId}`);
      }
      if (selected.state !== "device") {
        throw new GateError(
          `${role}设备 ${requestedId} 状态为 ${selected.state}，请完成 ADB 授权`,
        );
      }
      return selected;
    }
    return null;
  };
  const approver = pick(approverId, "approver（旧手机）");
  const joiner = pick(joinerId, "joiner（新手机）");
  if (approver && joiner && approver.serial === joiner.serial) {
    throw new GateError("approver 与 joiner 不能是同一台设备", {
      status: "failed",
      failureClass: "test_harness_defect",
    });
  }
  if (!approver || !joiner) {
    if (physical.length !== 2) {
      throw new GateError(
        `OWN-06 需要恰好两台已授权物理 Android 设备（当前 ${physical.length} 台）` +
          (approverId || joinerId
            ? "；或用 --approver-id/--joiner-id 明确指定"
            : ""),
      );
    }
    return { approver: approver ?? physical[0], joiner: joiner ?? physical[1] };
  }
  return { approver, joiner };
}

export function pairFlutterArgs(testPath, serial, relayBaseUrl) {
  return [
    "test",
    testPath,
    "-d",
    serial,
    `--dart-define=RELAY_BASE_URL=${relayBaseUrl}`,
    "--machine",
  ];
}

async function detectLanIp() {
  for (const iface of ["en0", "en1"]) {
    const result = await runCommand("ipconfig", ["getifaddr", iface], {
      timeoutMs: 5_000,
    });
    if (result.code === 0 && result.stdout.trim()) return result.stdout.trim();
  }
  return "";
}

async function relayApi(relayAddr, path, { method = "GET", token = "" } = {}) {
  const response = await fetch(`http://${relayAddr}${path}`, {
    method,
    headers: token ? { Authorization: `Bearer ${token}` } : {},
  });
  const text = await response.text();
  let body = null;
  try {
    body = JSON.parse(text);
  } catch {
    body = { raw: text.slice(0, 200) };
  }
  return { status: response.status, body };
}

// 审批泵：以终端 owner 令牌轮询 pending 清单，只批准 approver 的请求
//（joiner 的请求必须由 approver 手机以 UI 批准——这是 OWN-06 被测路径）。
export async function pumpApprovalOnce(relayAddr, token, displayName) {
  const list = await relayApi(relayAddr, "/v1/pairing/requests", { token });
  if (list.status !== 200) return { approved: false, reason: `list ${list.status}` };
  const pending = (list.body?.pairings ?? []).find(
    (pairing) => pairing.status === "pending" && pairing.display_name === displayName,
  );
  if (!pending) return { approved: false, reason: "not_found" };
  const approved = await relayApi(
    relayAddr,
    `/v1/pairing/requests/${pending.id}/approve`,
    { method: "POST", token },
  );
  if (approved.status !== 200) {
    return { approved: false, reason: `approve ${approved.status}` };
  }
  return { approved: true, pairingId: pending.id, compareCode: pending.compare_code ?? "" };
}

export async function assertTwoActiveOwners(relayAddr, token) {
  const devices = await relayApi(relayAddr, "/v1/devices", { token });
  if (devices.status !== 200) {
    throw new GateError(`服务端设备清单读取失败（${devices.status}）`, {
      status: "failed",
      failureClass: "product_defect",
    });
  }
  const activeOwners = (devices.body?.devices ?? []).filter(
    (device) => device.role === "android_owner" && device.status === "active",
  );
  const names = new Set(activeOwners.map((device) => device.display_name));
  const bothPresent =
    names.has(APPROVER_DISPLAY_NAME) && names.has(JOINER_DISPLAY_NAME);
  if (activeOwners.length < 2 || !bothPresent) {
    throw new GateError(
      `服务端交叉断言失败：active android_owner=${activeOwners.length}，` +
        `双机设备行齐全=${bothPresent}（不撤销断言或加入断言未成立）`,
      { status: "failed", failureClass: "product_defect" },
    );
  }
  return { activeOwners: activeOwners.length, bothPresent };
}

function stackEnv(args) {
  return {
    ...process.env,
    AGENT_SESSIONS_SQLITE_PATH: join(args.stateDir, "relay.db"),
    AGENT_SESSIONS_OPENCODE_PORT: String(args.opencodePort),
    AGENT_SESSIONS_OWNER_PAIRING: "on",
  };
}

async function startPairStack(args) {
  // 隔离世界确定性：旅程状态目录整体重建（只含本旅程的进程/DB/日志）。
  rmSync(args.stateDir, { recursive: true, force: true });
  mkdirSync(args.stateDir, { recursive: true });
  const started = await runCommand(
    "bash",
    [
      "./restart.sh",
      "restart",
      "--state-dir",
      args.stateDir,
      "--relay-addr",
      `127.0.0.1:${args.relayPort}`,
      "--no-flutter",
      "--no-web",
      "--no-admin",
      "--opencode-port",
      String(args.opencodePort),
    ],
    {
      cwd: ROOT,
      env: stackEnv(args),
      timeoutMs: STACK_READY_TIMEOUT_MS,
    },
  );
  if (started.code !== 0) {
    throw new GateError(
      `隔离栈启动失败：${(started.stderr || started.stdout || "").slice(-800)}`,
    );
  }
  const deadline = Date.now() + 30_000;
  while (Date.now() < deadline) {
    try {
      const ready = await fetch(`http://127.0.0.1:${args.relayPort}/readyz`);
      if (ready.ok) break;
    } catch {
      // 尚未就绪，继续等待。
    }
    await new Promise((resolveSleep) => setTimeout(resolveSleep, 1_000));
  }
  const tokenFile = join(args.stateDir, "local-owner-token");
  if (!existsSync(tokenFile)) {
    throw new GateError(
      "隔离栈未产出终端 owner 令牌（local-owner-token）——local-dev pairing 未完成",
    );
  }
  return readFileSync(tokenFile, "utf8").trim();
}

async function stopPairStack(args) {
  await runCommand(
    "bash",
    ["./restart.sh", "stop", "--state-dir", args.stateDir],
    { cwd: ROOT, env: stackEnv(args), timeoutMs: 60_000 },
  );
}

function startLanBridge(args) {
  return spawn(
    "python3",
    [
      join(ROOT, "e2e-verify", "tools", "relay-lan-bridge.py"),
      "--listen",
      `0.0.0.0:${args.lanPort}`,
      "--target",
      `127.0.0.1:${args.relayPort}`,
    ],
    { cwd: ROOT, stdio: ["ignore", "pipe", "pipe"], detached: false },
  );
}

async function ensureDeviceReady(adbPath, serial, timeoutMs) {
  await runCommand(
    adbPath,
    ["-s", serial, "shell", "svc", "power", "stayon", "usb"],
    { timeoutMs: 5_000 },
  );
  await waitForAndroidDevice(adbPath, serial, timeoutMs);
  const qemu = await runCommand(
    adbPath,
    ["-s", serial, "shell", "getprop", "ro.kernel.qemu"],
    { timeoutMs: 5_000 },
  );
  if (qemu.stdout.trim() === "1") {
    throw new GateError(`设备 ${serial} 是模拟器，OWN-06 只接受物理设备`, {
      status: "failed",
      failureClass: "test_harness_defect",
    });
  }
}

function usage() {
  return [
    "用法：node e2e-verify/mobile/run-android-pair.mjs [选项]",
    "  --approver-id <serial>   旧手机 adb serial（缺省要求恰好两台物理设备）",
    "  --joiner-id <serial>     新手机 adb serial",
    "  --lan-ip <ip>            真机入口 IP（默认探测 en0/en1）",
    "  --relay-port/--lan-port/--opencode-port  隔离栈端口（默认 8797/8798/4196）",
    "  --state-dir <dir>        隔离栈状态目录（默认 .task/own06，开始时重建）",
    "  --keep-stack             结束后保留隔离栈",
    "  --no-stack               不拉起隔离栈（手工已拉起时）",
    "  --diagnostic             输出 Flutter 原始输出",
    "  --test-timeout-ms <ms>   每个 flutter run 上限（默认 1800000）",
  ].join("\n");
}

function safeError(error) {
  return error instanceof Error
    ? error.message.replace(/(bearer\s+)[^\s]+/gi, "$1[REDACTED]")
    : "未知运行错误";
}

async function main() {
  const timestamp = new Date().toISOString().replace(/[:.]/g, "-");
  const startedAt = Date.now();
  let args = null;
  let status = "failed";
  let failureClass = "test_harness_defect";
  let remainingRisk = "";
  let bridgeChild = null;
  let stackManaged = false;
  let ownerToken = "";
  let devices = { approver: null, joiner: null };
  let approverSummary = null;
  let joinerSummary = null;
  let serverCrossCheck = null;
  let lanIp = "";

  try {
    args = parsePairArgs(process.argv.slice(2));
    if (args.help) {
      process.stdout.write(`${usage()}\n`);
      return;
    }
    const { adbPath } = findAndroidAdb();
    const connected = await listConnectedDevices(adbPath);
    devices = selectPairDevices(connected, {
      approverId: args.approverId,
      joinerId: args.joinerId,
    });
    process.stdout.write(
      `[own06-pair] approver=${devices.approver.serial} joiner=${devices.joiner.serial}\n`,
    );
    await ensureDeviceReady(adbPath, devices.approver.serial, 60_000);
    await ensureDeviceReady(adbPath, devices.joiner.serial, 60_000);

    lanIp = args.lanIp || (await detectLanIp());
    if (!lanIp) {
      throw new GateError(
        "无法自动探测 LAN IP；请用 --lan-ip 指定真机可达的本机地址",
      );
    }
    const relayBaseUrl = `http://${lanIp}:${args.lanPort}`;
    process.stdout.write(`[own06-pair] RELAY_BASE_URL=${relayBaseUrl}\n`);

    if (!args.noStack) {
      ownerToken = await startPairStack(args);
      stackManaged = true;
      process.stdout.write("[own06-pair] 隔离栈已就绪（owner-pairing=on）\n");
    } else {
      const tokenFile = join(args.stateDir, "local-owner-token");
      if (!existsSync(tokenFile)) {
        throw new GateError("--no-stack 模式需要已存在的 local-owner-token");
      }
      ownerToken = readFileSync(tokenFile, "utf8").trim();
    }
    bridgeChild = startLanBridge(args);
    await new Promise((resolveBridge) => setTimeout(resolveBridge, 2_000));
    if (bridgeChild.exitCode !== null) {
      throw new GateError("relay-lan-bridge 启动即退出——端口被占用或 python 不可用");
    }

    const flutter = process.env.FLUTTER_BIN || "flutter";
    let approverDone = false;
    const approverRun = runCommand(
      flutter,
      pairFlutterArgs(APPROVER_TEST, devices.approver.serial, relayBaseUrl),
      { cwd: MOBILE_ROOT, timeoutMs: args.testTimeoutMs },
    ).then((result) => {
      approverDone = true;
      return result;
    });
    // joiner 错后 30s：降低同项目并发 Gradle 构建的锁竞争。
    await new Promise((resolveStagger) => setTimeout(resolveStagger, 30_000));
    const joinerRun = runCommand(
      flutter,
      pairFlutterArgs(JOINER_TEST, devices.joiner.serial, relayBaseUrl),
      { cwd: MOBILE_ROOT, timeoutMs: args.testTimeoutMs },
    );

    // 审批泵：只批 approver 的请求；joiner 由 approver 手机 UI 批准。
    const pumpDeadline = Date.now() + APPROVAL_PUMP_TIMEOUT_MS;
    let approverPaired = false;
    while (Date.now() < pumpDeadline && !approverPaired && !approverDone) {
      const pump = await pumpApprovalOnce(
        `127.0.0.1:${args.relayPort}`,
        ownerToken,
        APPROVER_DISPLAY_NAME,
      );
      if (pump.approved) {
        approverPaired = true;
        process.stdout.write(
          `[own06-pair] 终端 owner 已批准 approver（比对码 ${pump.compareCode}）\n`,
        );
      } else {
        await new Promise((resolvePump) => setTimeout(resolvePump, 2_000));
      }
    }

    const approverResult = await approverRun;
    approverSummary = summarizeFlutterMachineOutput(
      `${approverResult.stdout}\n${approverResult.stderr}`,
    );
    if (args.diagnostic) {
      process.stdout.write(`[own06-pair][approver]\n${approverResult.stdout}${approverResult.stderr}\n`);
    }
    const joinerResult = await joinerRun;
    joinerSummary = summarizeFlutterMachineOutput(
      `${joinerResult.stdout}\n${joinerResult.stderr}`,
    );
    if (args.diagnostic) {
      process.stdout.write(`[own06-pair][joiner]\n${joinerResult.stdout}${joinerResult.stderr}\n`);
    }

    const bothPassed =
      approverResult.code === 0 &&
      !approverResult.timedOut &&
      joinerResult.code === 0 &&
      !joinerResult.timedOut &&
      approverSummary.test_failed === 0 &&
      joinerSummary.test_failed === 0;

    // 服务端交叉断言：双 active owner 设备行（不撤销 + 加入成功的事实收口）。
    serverCrossCheck = await assertTwoActiveOwners(
      `127.0.0.1:${args.relayPort}`,
      ownerToken,
    );

    if (!bothPassed) {
      status = "failed";
      failureClass = "product_defect";
      remainingRisk =
        "至少一台设备的 OWN-06 integration 断言失败；用 --diagnostic 复现。";
    } else {
      status = "passed";
      failureClass = null;
      remainingRisk =
        "Push、后台限制、网络切换与云端拓扑未由本地隔离栈旅程覆盖（OWN-08 云端演练另测）。";
    }
  } catch (error) {
    status = error instanceof GateError ? error.status : "failed";
    failureClass =
      error instanceof GateError ? error.failureClass : "test_harness_defect";
    remainingRisk = safeError(error);
  } finally {
    if (bridgeChild && bridgeChild.exitCode === null) {
      bridgeChild.kill("SIGTERM");
    }
    if (args && stackManaged && !args.keepStack) {
      try {
        await stopPairStack(args);
      } catch (error) {
        process.stdout.write(`[own06-pair] 隔离栈停止失败：${safeError(error)}\n`);
      }
    }
    if (args?.help) return;
    const deviceInfo = (device) =>
      device
        ? {
            adb_serial_recorded: false,
            state: device.state,
          }
        : null;
    const report = baseReport({
      suite: "own06-pair-journey",
      status,
      real_browser: false,
      real_model: status === "passed",
      real_upstream: false,
      fixture_data: false,
      local_test: true,
      headless: false,
      browser: "n/a",
      command: "node e2e-verify/mobile/run-android-pair.mjs",
      artifacts: [],
      failure_class: failureClass,
      remaining_risk: remainingRisk,
    });
    const reportPath = writeReport({
      planId: "OWN-06",
      name: "own06-pair-journey",
      report: {
        timestamp,
        ...report,
        gate_kind: "android_two_device_owner_pairing_journey",
        real_device: Boolean(devices.approver && devices.joiner),
        simulated_device: false,
        device_mode: "two_physical_android",
        host_platform: process.platform,
        visible_device: true,
        real_provider_called: status === "passed",
        push_called: false,
        background_recovery_tested: false,
        network_switch_tested: false,
        test_ids: ["OWN-06"],
        integration_tests: [APPROVER_TEST, JOINER_TEST],
        fixture_revision: null,
        lan_ip_recorded: Boolean(lanIp),
        relay_isolation: {
          managed_stack: stackManaged,
          state_dir_recorded: Boolean(args?.stateDir),
          owner_pairing: "on",
        },
        approver_summary: approverSummary,
        joiner_summary: joinerSummary,
        server_cross_check: serverCrossCheck,
        devices: {
          approver: deviceInfo(devices.approver),
          joiner: deviceInfo(devices.joiner),
        },
        diagnostic_mode: Boolean(args?.diagnostic),
        cleanup: {
          lan_bridge_stopped: true,
          stack_stopped: stackManaged && !args?.keepStack,
          test_apk_cleanup: "flutter_default",
        },
        duration_ms: Date.now() - startedAt,
      },
    });
    process.stdout.write(`[own06-pair] ${status} -> ${reportPath}\n`);
    if (status !== "passed") process.exitCode = 1;
  }
}

const invokedPath = process.argv[1] ? resolve(process.argv[1]) : "";
if (invokedPath === fileURLToPath(import.meta.url)) {
  main().catch((error) => {
    process.stderr.write(`[own06-pair] ${safeError(error)}\n`);
    process.exitCode = 1;
  });
}
