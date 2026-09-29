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
import { existsSync, mkdirSync, openSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { randomUUID } from "node:crypto";
import { spawn } from "node:child_process";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { baseReport, writeReport } from "../lib/report.mjs";
import {
  findAndroidAdb,
  findAndroidTools,
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
    joinerAvd: env.OWN06_JOINER_AVD || "",
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
    stackOnly: false,
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
    else if (arg === "--joiner-avd") args.joinerAvd = takeValue(arg);
    else if (arg === "--lan-ip") args.lanIp = takeValue(arg);
    else if (arg === "--relay-port") args.relayPort = positiveInteger(takeValue(arg), arg);
    else if (arg === "--lan-port") args.lanPort = positiveInteger(takeValue(arg), arg);
    else if (arg === "--opencode-port") args.opencodePort = positiveInteger(takeValue(arg), arg);
    else if (arg === "--state-dir") args.stateDir = resolve(ROOT, takeValue(arg));
    else if (arg === "--keep-stack") args.keepStack = true;
    else if (arg === "--no-stack") args.noStack = true;
    else if (arg === "--stack-only") args.stackOnly = true;
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

async function relayApi(relayAddr, path, { method = "GET", token = "", payload = null } = {}) {
  // 防御性剥 scheme：调用方偶发传整 URL 时主机名会变成 "http:"（ENOTFOUND）。
  const authority = relayAddr.replace(/^https?:\/\//, "");
  let response;
  try {
    response = await fetch(`http://${authority}${path}`, {
      method,
      headers: {
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
        ...(payload ? { "Content-Type": "application/json" } : {}),
      },
      body: payload ? JSON.stringify(payload) : undefined,
    });
  } catch (error) {
    // "fetch failed" 不带原因：透出底层 cause（ECONNREFUSED/ECONNRESET/代理…），
    // 否则隔离栈问题只能靠猜。
    const cause = error?.cause?.code ?? error?.cause?.message ?? error?.message;
    throw new GateError(
      `Relay 请求失败 ${method} http://${authority}${path}: ${cause}`,
    );
  }
  const text = await response.text();
  let body = null;
  try {
    body = JSON.parse(text);
  } catch {
    body = { raw: text.slice(0, 200) };
  }
  return { status: response.status, body };
}

// createOwnerAuth：owner 令牌的 401 自愈封装——访问令牌 15 分钟过期，
// 长旅程（审批泵 12 分钟窗 + 末尾交叉断言）必须能拿刷新令牌重签。
function createOwnerAuth(relayAddr, initialAccess, refreshToken) {
  let access = initialAccess;
  return {
    async api(path, opts = {}) {
      let res = await relayApi(relayAddr, path, { ...opts, token: access });
      if (res.status === 401 && refreshToken) {
        const refreshed = await relayApi(relayAddr, "/v1/auth/refresh", {
          method: "POST",
          payload: { refresh_token: refreshToken },
        });
        if (refreshed.status !== 200 || !refreshed.body?.access_token) {
          throw new GateError(
            `owner 访问令牌过期且刷新失败（HTTP ${refreshed.status}）`,
          );
        }
        access = refreshed.body.access_token;
        res = await relayApi(relayAddr, path, { ...opts, token: access });
      }
      return res;
    },
  };
}

// 审批泵：以终端 owner 令牌轮询 pending 清单，只批准 approver 的请求
//（joiner 的请求必须由 approver 手机以 UI 批准——这是 OWN-06 被测路径）。
export async function pumpApprovalOnce(auth, displayName) {
  const list = await auth.api("/v1/pairing/requests");
  if (list.status !== 200) return { approved: false, reason: `list ${list.status}` };
  const pending = (list.body?.pairings ?? []).find(
    (pairing) => pairing.status === "pending" && pairing.display_name === displayName,
  );
  if (!pending) {
    return { approved: false, reason: "not_found" };
  }
  const approved = await auth.api(
    `/v1/pairing/requests/${pending.id}/approve`,
    { method: "POST" },
  );
  if (approved.status !== 200) {
    return { approved: false, reason: `approve ${approved.status}` };
  }
  return { approved: true, pairingId: pending.id, compareCode: pending.compare_code ?? "" };
}

export async function assertTwoActiveOwners(auth) {
  const devices = await auth.api("/v1/devices");
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

// relayEnv 是隔离 Relay 进程的环境：owner-pairing 总开关 + 能力矩阵探测用的
// OpenCode URL/DSH 配置（与 start_relay 给 relayctl 的透传口径一致）。
function relayEnv(args) {
  const env = {
    ...process.env,
    AGENT_SESSIONS_OWNER_PAIRING: "on",
    AGENT_SESSIONS_OPENCODE_URL: `http://127.0.0.1:${args.opencodePort}`,
  };
  if (process.env.AGENT_SESSIONS_DSH_BIN) {
    env.AGENT_SESSIONS_DSH_BIN = process.env.AGENT_SESSIONS_DSH_BIN;
  }
  if (!process.env.AGENT_SESSIONS_DSH_CONFIG && existsSync(join(ROOT, "cordis.yml"))) {
    env.AGENT_SESSIONS_DSH_CONFIG = join(ROOT, "cordis.yml");
  }
  return env;
}

// startIsolatedRelay 自管隔离 Relay 进程（pid/日志都在隔离 state-dir 下）。
// 不走 restart.sh/relayctl.sh 的 Relay 生命周期：它们的 pid 文件是 clone 级共享
// （.task/relay.pid），一个 clone 只允许一个 Relay 实例——隔离栈必须与主栈
// （soak，8787）并存，故此处独立拉起、独立收停（2026-09-29 预检实证的冲突）。
async function startIsolatedRelay(args) {
  // 端口预检：残留监听会让新进程 bind 失败、readyz 却被旧进程应答——必须
  // 先确认端口空闲再 spawn（残留时给出明确处置指引而非神秘失败）。
  try {
    const stale = await fetch(`http://127.0.0.1:${args.relayPort}/readyz`);
    if (stale.ok || stale.status) {
      throw new GateError(
        `端口 ${args.relayPort} 已被监听（上次运行残留？）——` +
          `kill $(cat ${join(args.stateDir, "relay.pid")}) 或换 --relay-port 后重试`,
      );
    }
  } catch (error) {
    if (error instanceof GateError) throw error;
    // 连接失败 = 端口空闲，继续。
  }
  const bin = join(args.stateDir, "relay");
  const built = await runCommand("go", ["build", "-o", bin, "./apps/relay"], {
    cwd: ROOT,
    timeoutMs: 120_000,
  });
  if (built.code !== 0) {
    throw new GateError(`隔离 Relay 构建失败：${(built.stderr || "").slice(-400)}`);
  }
  const log = openSync(join(args.stateDir, "relay.log"), "a");
  const child = spawn(
    bin,
    ["--addr", `127.0.0.1:${args.relayPort}`, "--db", join(args.stateDir, "relay.db")],
    { cwd: ROOT, env: relayEnv(args), stdio: ["ignore", log, log], detached: true },
  );
  child.unref();
  writeFileSync(join(args.stateDir, "relay.pid"), String(child.pid), "utf8");
  const deadline = Date.now() + 30_000;
  while (Date.now() < deadline) {
    if (child.exitCode !== null) {
      throw new GateError(
        `隔离 Relay 启动即退出（code=${child.exitCode}）——见 ${args.stateDir}/relay.log`,
      );
    }
    try {
      const ready = await fetch(`http://127.0.0.1:${args.relayPort}/readyz`);
      if (ready.ok) {
        // readyz 应答 + 子进程存活双确认，避免把残留进程误判为自己。
        try {
          process.kill(child.pid, 0);
          return child.pid;
        } catch {
          throw new GateError("隔离 Relay readyz 通过但子进程已退出——端口竞争");
        }
      }
    } catch (error) {
      if (error instanceof GateError) throw error;
      // 尚未就绪，继续等待。
    }
    await new Promise((resolveSleep) => setTimeout(resolveSleep, 1_000));
  }
  throw new GateError("隔离 Relay readyz 超时（30s）");
}

// stopIsolatedRelay 按 pid 文件收停隔离 Relay；只杀自己记录的 pid。
function stopIsolatedRelay(args) {
  const pidFile = join(args.stateDir, "relay.pid");
  if (!existsSync(pidFile)) return;
  const pid = Number.parseInt(readFileSync(pidFile, "utf8").trim(), 10);
  if (!Number.isInteger(pid) || pid <= 0) return;
  try {
    process.kill(pid, "SIGTERM");
  } catch {
    return; // 进程已不存在。
  }
  const deadline = Date.now() + 10_000;
  while (Date.now() < deadline) {
    try {
      process.kill(pid, 0); // 仍在 → 等待。
    } catch {
      return; // 已退出。
    }
    // 同步等待 200ms（Node 无内置 sync sleep；Atomics.wait 阻塞当前线程）。
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 200);
  }
  try {
    process.kill(pid, "SIGKILL");
  } catch {
    // 已退出。
  }
}

// bootstrapIsolatedOwner 在隔离库上完成首 owner 注册与 Terminal 配对，返回
// {ownerToken, daemonToken}。restart.sh 的 local-dev 自动配对硬性依赖
// WITH_RELAY=true（ensure_daemon_token 分支），--no-relay 下直接拒绝——编排器
// 自管 Relay 后这部分也自己来（隔离库全新，register 未关闭即首 owner）。
async function bootstrapIsolatedOwner(args) {
  // relayApi 的地址参数口径是 host:port（不带 scheme）。
  const base = `127.0.0.1:${args.relayPort}`;
  await relayApi(base, "/readyz");
  const password = `own06-${crypto.randomUUID()}`;
  const registered = await relayApi(base, "/v1/auth/register", {
    method: "POST",
    payload: { email: "own06-isolated@example.invalid", password },
  });
  if (registered.status !== 201) {
    throw new GateError(
      `隔离库首 owner 注册失败（HTTP ${registered.status}）：${JSON.stringify(registered.body).slice(0, 200)}`,
    );
  }
  const ownerToken = registered.body.access_token;
  if (!ownerToken) {
    throw new GateError("注册响应缺 access_token");
  }
  const ownerRefresh = registered.body.refresh_token;
  if (!ownerRefresh) throw new GateError("注册响应缺 refresh_token");
  writeFileSync(join(args.stateDir, "local-owner-token"), ownerToken, "utf8");
  writeFileSync(join(args.stateDir, "local-owner-refresh"), ownerRefresh, "utf8");

  const pairing = await relayApi(base, "/v1/pairing/requests", {
    method: "POST",
    token: ownerToken,
    payload: {
      role: "terminal",
      display_name: "OWN06 Isolated Terminal",
      platform: "local",
      identity_public_key: "own06-terminal-identity-public-key",
      encryption_public_key: "own06-terminal-encryption-public-key",
    },
  });
  if (pairing.status !== 201) {
    throw new GateError(
      `隔离 Terminal 配对请求失败（HTTP ${pairing.status}）：${JSON.stringify(pairing.body).slice(0, 200)}`,
    );
  }
  const approved = await relayApi(
    base,
    `/v1/pairing/requests/${pairing.body.id}/approve`,
    { method: "POST", token: ownerToken },
  );
  if (approved.status !== 200) {
    throw new GateError(
      `隔离 Terminal 配对批准失败（HTTP ${approved.status}）：${JSON.stringify(approved.body).slice(0, 200)}`,
    );
  }
  const daemonToken = approved.body?.tokens?.access_token;
  if (!daemonToken) {
    throw new GateError("Terminal 配对批准响应缺令牌");
  }
  writeFileSync(join(args.stateDir, "local-daemon-token"), daemonToken, "utf8");
  return { ownerToken, ownerRefresh, daemonToken };
}

async function startPairStack(args) {
  // 隔离世界确定性：旅程状态目录整体重建（只含本旅程的进程/DB/日志）。
  rmSync(args.stateDir, { recursive: true, force: true });
  mkdirSync(args.stateDir, { recursive: true });
  // 1) 隔离 Relay 先行（独立 pid 文件，见 startIsolatedRelay 注释）。
  await startIsolatedRelay(args);
  // 2) 首 owner + Terminal 配对（编排器自办，令牌落 stateDir 供 --no-stack 复用）。
  const { ownerToken, ownerRefresh, daemonToken } = await bootstrapIsolatedOwner(args);
  // 3) restart.sh 以 --no-relay + env 令牌只管隔离 daemon（OpenCode 4196）。
  const started = await runCommand(
    "bash",
    [
      "./restart.sh",
      "restart",
      "--state-dir",
      args.stateDir,
      "--relay-addr",
      `127.0.0.1:${args.relayPort}`,
      "--no-relay",
      "--no-flutter",
      "--no-web",
      "--no-admin",
      "--opencode-port",
      String(args.opencodePort),
    ],
    {
      cwd: ROOT,
      env: {
        ...stackEnv(args),
        AGENT_SESSIONS_DAEMON_TOKEN: daemonToken,
      },
      timeoutMs: STACK_READY_TIMEOUT_MS,
    },
  );
  if (started.code !== 0) {
    throw new GateError(
      `隔离栈启动失败：${(started.stderr || started.stdout || "").slice(-800)}`,
    );
  }
  // daemon 进程存活（hello/心跳随后自然发生；旅程用例会对执行侧事实断言）。
  const daemonPidFile = join(args.stateDir, "daemon.pid");
  const daemonDeadline = Date.now() + 30_000;
  while (!existsSync(daemonPidFile)) {
    if (Date.now() > daemonDeadline) {
      throw new GateError("隔离 daemon pid 文件未出现（restart.sh 未拉起 daemon）");
    }
    await new Promise((resolveSleep) => setTimeout(resolveSleep, 1_000));
  }
  return { ownerToken, ownerRefresh };
}

async function stopPairStack(args) {
  await runCommand(
    "bash",
    ["./restart.sh", "stop", "--state-dir", args.stateDir],
    { cwd: ROOT, env: stackEnv(args), timeoutMs: 60_000 },
  );
  // restart.sh 对本栈无 relay-owned 标记（--no-relay），隔离 Relay 由编排器收停。
  stopIsolatedRelay(args);
}

// startAvdJoiner 启动指定 AVD 作为加入端（用户授权的演练形态）。返回
// {serial, state:"device"}；等待 sys.boot_completed=1。AVD 天然免 ADB 授权。
async function startAvdJoiner(adbPath, avdName) {
  const { emulatorPath } = findAndroidTools();
  const log = openSync("/tmp/own06-avd.log", "a");
  const child = spawn(
    emulatorPath,
    ["-avd", avdName, "-no-window", "-no-snapshot", "-no-audio", "-no-boot-anim", "-wipe-data"],
    { cwd: ROOT, stdio: ["ignore", log, log], detached: true },
  );
  child.unref();
  const deadline = Date.now() + 300_000;
  while (Date.now() < deadline) {
    const devices = await listConnectedDevices(adbPath);
    const emu = devices.find(
      (device) => device.serial.startsWith("emulator-") && device.state === "device",
    );
    if (emu) {
      const boot = await runCommand(
        adbPath,
        ["-s", emu.serial, "shell", "getprop", "sys.boot_completed"],
        { timeoutMs: 5_000 },
      );
      if (boot.stdout.trim() === "1") return emu;
    }
    await new Promise((resolveSleep) => setTimeout(resolveSleep, 3_000));
  }
  throw new GateError(`AVD ${avdName} 300s 内未完成启动——见 /tmp/own06-avd.log`);
}

// seedDSHWorkspaces 触发 daemon 的 DSH 工作区扫描并等待结果（发送链路前提：
// 加入端 UI 的工作区列表必须有可选工作区）。已存在工作区时幂等直通。
async function seedDSHWorkspaces(auth) {
  const list = await auth.api("/v1/workspaces");
  if (list.status === 200) {
    const existing = list.body?.workspaces?.length ?? 0;
    if (existing > 0) return existing;
  }
  const sync = await auth.api("/v1/workspaces/sync-dsh", {
    method: "POST",
    payload: {},
  });
  // 200（同步完成）或 202（异步受理，轮询 command 结果）都算触发成功。
  if (sync.status !== 200 && sync.status !== 202) {
    throw new GateError(`sync-dsh 触发失败（HTTP ${sync.status}）`);
  }
  const commandId = sync.body?.command_id;
  if (!commandId) throw new GateError("sync-dsh 响应缺 command_id");
  const deadline = Date.now() + 120_000;
  for (;;) {
    const state = await auth.api(`/v1/workspaces/sync-dsh/${commandId}`);
    if (state.status === 200 && state.body?.status === "succeeded") break;
    if (state.status === 200 && state.body?.status === "failed") {
      throw new GateError("sync-dsh 失败：隔离 daemon 未发现 DSH 工作区");
    }
    if (Date.now() > deadline) {
      throw new GateError("sync-dsh 结果轮询超时（120s）");
    }
    await new Promise((resolveSleep) => setTimeout(resolveSleep, 2_000));
  }
  const after = await auth.api("/v1/workspaces");
  const count = after.body?.workspaces?.length ?? 0;
  if (count === 0) {
    throw new GateError("同步后仍无 DSH 工作区——发送链路前提缺失");
  }
  return count;
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
  let ownerRefresh = "";
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
    if (args.stackOnly) {
      // 设备日预检：只验证「隔离栈自拉 + owner-pairing 开关生效 + 审批通道
      // 可用 + LAN 桥起停」，不要求任何设备在场——把设备日才可能暴露的
      // 编排缺陷提前到现在清掉。
      // 进入即标记：startPairStack 半途失败也必须走 teardown（否则隔离
      // Relay 残留占端口，下一次运行 bind 失败——2026-09-29 预检实证）。
      stackManaged = true;
      const stackBoot = await startPairStack(args);
      ownerToken = stackBoot.ownerToken;
      ownerRefresh = stackBoot.ownerRefresh;
      process.stdout.write("[own06-pair][stack-only] 隔离栈就绪，探测开关…\n");
      const probe = await relayApi(`127.0.0.1:${args.relayPort}`, "/v1/owner-pairing/requests", {
        method: "POST",
        payload: {
          display_name: "OWN06-PREFLIGHT-PROBE",
          platform: "preflight",
          identity_public_key: "preflight-identity",
          encryption_public_key: "preflight-encryption",
        },
      });
      if (probe.status !== 201) {
        throw new GateError(
          `owner-pairing 开关探测失败（HTTP ${probe.status}，期望 201）——` +
            `AGENT_SESSIONS_OWNER_PAIRING 未传播到隔离 Relay 或路由缺失：${JSON.stringify(probe.body).slice(0, 200)}`,
          { status: "failed", failureClass: "product_defect" },
        );
      }
      const pendingList = await createOwnerAuth(
        `127.0.0.1:${args.relayPort}`,
        ownerToken,
        ownerRefresh,
      ).api("/v1/pairing/requests");
      if (pendingList.status !== 200) {
        throw new GateError(
          `终端 owner 令牌读取 pending 清单失败（HTTP ${pendingList.status}）——审批泵不可用`,
          { status: "failed", failureClass: "product_defect" },
        );
      }
      bridgeChild = startLanBridge(args);
      await new Promise((resolveBridge) => setTimeout(resolveBridge, 2_000));
      if (bridgeChild.exitCode !== null) {
        throw new GateError("relay-lan-bridge 启动即退出——端口被占用或 python 不可用");
      }
      process.stdout.write(
        "[own06-pair][stack-only] 预检通过：隔离栈/开关/审批通道/LAN 桥全部可用\n",
      );
      status = "passed";
      failureClass = null;
      remainingRisk = "stack-only 预检：未覆盖设备侧旅程（OWN-06 执行时仍需真机调参）";
      return;
    }
    const { adbPath } = findAndroidAdb();
    let joinerBaseUrl = "";
    let approverBaseUrl = "";
    if (args.joinerAvd) {
      // 用户授权的演练形态：approver = 恰好一台物理真机；joiner = 本地 AVD。
      const connected = await listConnectedDevices(adbPath);
      const physical = connected.filter(
        (device) =>
          !device.serial.startsWith("emulator-") && device.state === "device",
      );
      const approver = args.approverId
        ? physical.find((device) => device.serial === args.approverId)
        : physical.length === 1
          ? physical[0]
          : null;
      if (!approver) {
        throw new GateError(
          `--joiner-avd 模式需要恰好一台物理设备作 approver（当前 ${physical.length} 台）或用 --approver-id 指定`,
        );
      }
      devices = { approver, joiner: null };
      await ensureDeviceReady(adbPath, devices.approver.serial, 60_000);
      lanIp = args.lanIp || (await detectLanIp());
      if (!lanIp) {
        throw new GateError("无法自动探测 LAN IP；请用 --lan-ip 指定");
      }
      approverBaseUrl = `http://${lanIp}:${args.lanPort}`;
    } else {
      const connected = await listConnectedDevices(adbPath);
      devices = selectPairDevices(connected, {
        approverId: args.approverId,
        joinerId: args.joinerId,
      });
      await ensureDeviceReady(adbPath, devices.approver.serial, 60_000);
      await ensureDeviceReady(adbPath, devices.joiner.serial, 60_000);
      lanIp = args.lanIp || (await detectLanIp());
      if (!lanIp) {
        throw new GateError(
          "无法自动探测 LAN IP；请用 --lan-ip 指定真机可达的本机地址",
        );
      }
      approverBaseUrl = `http://${lanIp}:${args.lanPort}`;
      joinerBaseUrl = approverBaseUrl;
    }
    process.stdout.write(
      `[own06-pair] approver=${devices.approver.serial}\n`,
    );

    if (!args.noStack) {
      // 进入即标记：startPairStack 半途失败也必须走 teardown（否则隔离
      // Relay 残留占端口，下一次运行 bind 失败——2026-09-29 预检实证）。
      stackManaged = true;
      const stackBoot = await startPairStack(args);
      ownerToken = stackBoot.ownerToken;
      ownerRefresh = stackBoot.ownerRefresh;
      process.stdout.write("[own06-pair] 隔离栈已就绪（owner-pairing=on）\n");
    } else {
      const tokenFile = join(args.stateDir, "local-owner-token");
      const refreshFile = join(args.stateDir, "local-owner-refresh");
      if (!existsSync(tokenFile)) {
        throw new GateError("--no-stack 模式需要已存在的 local-owner-token");
      }
      ownerToken = readFileSync(tokenFile, "utf8").trim();
      ownerRefresh = existsSync(refreshFile)
        ? readFileSync(refreshFile, "utf8").trim()
        : "";
    }
    bridgeChild = startLanBridge(args);
    await new Promise((resolveBridge) => setTimeout(resolveBridge, 2_000));
    if (bridgeChild.exitCode !== null) {
      throw new GateError("relay-lan-bridge 启动即退出——端口被占用或 python 不可用");
    }

    // owner 令牌自愈：长旅程必须能拿刷新令牌重签（访问令牌 15 分钟过期）。
    const ownerAuth = createOwnerAuth(`127.0.0.1:${args.relayPort}`, ownerToken, ownerRefresh);

    // 残留治理：清理上轮旅程遗留的 pending owner 请求——单 pending 治理下，
    // 陈旧请求会让本轮双端创建全部 409（--no-stack 复用世界时的关键清理）。
    const stalePending = await ownerAuth.api("/v1/pairing/requests");
    for (const pairing of stalePending.body?.pairings ?? []) {
      if (pairing.status === "pending" && pairing.role === "android_owner") {
        await ownerAuth.api(`/v1/pairing/requests/${pairing.id}/cancel`, {
          method: "POST",
        });
        process.stdout.write(
          `[own06-pair] 已清理遗留 pending：${pairing.display_name}\n`,
        );
      }
    }

    // 发送链路前提：隔离栈必须有可选的 DSH 工作区（daemon 扫描幂等）。
    const workspaceCount = await seedDSHWorkspaces(ownerAuth);
    process.stdout.write(
      `[own06-pair] DSH 工作区就绪：${workspaceCount} 个\n`,
    );

    const flutter = process.env.FLUTTER_BIN || "flutter";
    let approverDone = false;
    const approverRun = runCommand(
      flutter,
      pairFlutterArgs(APPROVER_TEST, devices.approver.serial, approverBaseUrl),
      { cwd: MOBILE_ROOT, timeoutMs: args.testTimeoutMs },
    ).then((result) => {
      approverDone = true;
      return result;
    });

    // 审批泵：只批 approver 的请求。顺序化——approver 加入成功后才启动
    // joiner，消除单 pending 名额竞争（2026-09-29 run11/17 实证的双端死锁）。
    const pumpDeadline = Date.now() + APPROVAL_PUMP_TIMEOUT_MS;
    let approverPaired = false;
    while (Date.now() < pumpDeadline && !approverPaired && !approverDone) {
      const pump = await pumpApprovalOnce(ownerAuth, APPROVER_DISPLAY_NAME);
      if (pump.approved) {
        approverPaired = true;
        process.stdout.write(
          `[own06-pair] 终端 owner 已批准 approver（比对码 ${pump.compareCode}）\n`,
        );
      } else {
        await new Promise((resolvePump) => setTimeout(resolvePump, 2_000));
      }
    }

    if (args.joinerAvd) {
      process.stdout.write(`[own06-pair] 启动 AVD joiner：${args.joinerAvd}\n`);
      devices.joiner = await startAvdJoiner(adbPath, args.joinerAvd);
      // AVD 的宿主别名是 10.0.2.2（NAT 网关即宿主机）。
      joinerBaseUrl = `http://10.0.2.2:${args.lanPort}`;
    }
    const joinerSerial = devices.joiner.serial;
    process.stdout.write(
      `[own06-pair] joiner=${joinerSerial} base=${joinerBaseUrl}\n`,
    );

    const joinerRun = runCommand(
      flutter,
      pairFlutterArgs(JOINER_TEST, devices.joiner.serial, joinerBaseUrl),
      { cwd: MOBILE_ROOT, timeoutMs: args.testTimeoutMs },
    );

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
    serverCrossCheck = await assertTwoActiveOwners(ownerAuth);

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
    if (devices.joiner && devices.joiner.serial.startsWith("emulator-")) {
      try {
        const { adbPath: adbForAvd } = findAndroidAdb();
        await runCommand(adbForAvd, ["-s", devices.joiner.serial, "emu", "kill"], {
          timeoutMs: 15_000,
        });
      } catch {
        // AVD 收停失败不掩盖旅程结果。
      }
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
        gate_kind: args?.stackOnly
          ? "own06_isolated_stack_preflight"
          : "android_two_device_owner_pairing_journey",
        real_device: Boolean(devices.approver),
        simulated_device: false,
        device_mode: args?.stackOnly
          ? "stack_preflight"
          : args?.joinerAvd
            ? "physical_approver+avd_joiner"
            : "two_physical_android",
        joiner_avd: args?.joinerAvd || null,
        host_platform: process.platform,
        visible_device: true,
        real_provider_called: status === "passed",
        push_called: false,
        background_recovery_tested: false,
        network_switch_tested: false,
        test_ids: [args?.stackOnly ? "OWN-06-PREFLIGHT" : "OWN-06"],
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
