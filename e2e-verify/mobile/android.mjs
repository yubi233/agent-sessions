// Android AVD 编排的可复用底层：只处理 SDK/ADB/Flutter 进程与本地测试文件，
// 不保存子进程原始输出，避免把测试正文、凭据或异常响应写入报告。
import { spawn } from "node:child_process";
import { existsSync, readdirSync } from "node:fs";
import { homedir } from "node:os";
import { isAbsolute, join, relative, resolve } from "node:path";

const MAX_CAPTURE_BYTES = 1_000_000;

function appendLimited(previous, chunk) {
  if (previous.length >= MAX_CAPTURE_BYTES) return previous;
  return `${previous}${chunk.toString()}`.slice(0, MAX_CAPTURE_BYTES);
}

// runCommand 以受控管道运行本地工具；输出仅用于即时判定，调用方不得原样写入报告。
export function runCommand(command, args, { cwd, env, timeoutMs = 30_000 } = {}) {
  return new Promise((resolveResult) => {
    let child;
    let stdout = "";
    let stderr = "";
    let timedOut = false;
    let settled = false;
    let timer = null;
    let forceKillTimer = null;

    const finish = (result) => {
      if (settled) return;
      settled = true;
      if (timer) clearTimeout(timer);
      if (forceKillTimer) clearTimeout(forceKillTimer);
      resolveResult({ stdout, stderr, timedOut, ...result });
    };

    try {
      child = spawn(command, args, {
        cwd,
        env,
        stdio: ["ignore", "pipe", "pipe"],
        windowsHide: true,
      });
    } catch (error) {
      finish({ code: null, signal: null, error: error instanceof Error ? error.message : String(error) });
      return;
    }

    timer = setTimeout(() => {
      timedOut = true;
      if (child.exitCode == null) child.kill("SIGTERM");
      // 超时后给工具一个有界的退出窗口；仍未退出时只强杀本轮创建的子进程。
      forceKillTimer = setTimeout(() => {
        if (child.exitCode == null) child.kill("SIGKILL");
      }, 10_000);
    }, timeoutMs);

    child.stdout.on("data", (chunk) => {
      stdout = appendLimited(stdout, chunk);
    });
    child.stderr.on("data", (chunk) => {
      stderr = appendLimited(stderr, chunk);
    });
    child.on("error", (error) => {
      finish({ code: null, signal: null, error: error instanceof Error ? error.message : String(error) });
    });
    child.on("close", (code, signal) => {
      finish({ code, signal, error: null });
    });
  });
}

// parseAdbDevices 解析 `adb devices -l`，仅保留设备标识和连接状态。
export function parseAdbDevices(output) {
  return output
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line && !line.startsWith("List of devices attached"))
    .map((line) => {
      const [serial, state, ...details] = line.split(/\s+/);
      return { serial, state, details: details.join(" ") };
    })
    .filter((device) => device.serial && device.state);
}

// Android SDK 路径只从明确环境变量或 macOS 标准 SDK 目录中解析。
// 当前 v0.1 gate 固定启动 macOS 上的可见 AVD，因此 runner 同时要求 ADB 与 Emulator。
export function findAndroidAdb(env = process.env) {
  const candidates = [
    env.ANDROID_SDK_ROOT,
    env.ANDROID_HOME,
    join(homedir(), "Library", "Android", "sdk"),
  ].filter(Boolean);

  for (const sdkRoot of [...new Set(candidates)]) {
    const adbPath = join(sdkRoot, "platform-tools", "adb");
    if (existsSync(adbPath)) return { sdkRoot, adbPath };
  }

  throw new Error("未找到 Android SDK 的 adb；请设置 ANDROID_SDK_ROOT 或 ANDROID_HOME");
}

export function findAndroidTools(env = process.env) {
  const { sdkRoot, adbPath } = findAndroidAdb(env);
  const emulatorPaths = [
    join(sdkRoot, "emulator", "emulator"),
    join(sdkRoot, "tools", "emulator"),
  ];
  const emulatorPath = emulatorPaths.find((candidate) => existsSync(candidate));
  if (emulatorPath) return { sdkRoot, adbPath, emulatorPath };

  throw new Error("未找到 Android SDK 的 Emulator；启动 AVD 时请安装 emulator 组件");
}

// listIntegrationTests 递归读取长期 integration_test 目录，稳定排序以保证 gate 可复现。
export function listIntegrationTests(mobileRoot) {
  const integrationRoot = join(mobileRoot, "integration_test");
  if (!existsSync(integrationRoot)) return [];
  const tests = [];

  const visit = (dir) => {
    for (const entry of readdirSync(dir, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
      const path = join(dir, entry.name);
      if (entry.isDirectory()) visit(path);
      else if (entry.isFile() && entry.name.endsWith("_test.dart")) tests.push(relative(mobileRoot, path));
    }
  };

  visit(integrationRoot);
  return tests;
}

// resolveIntegrationTests 验证显式文件不会逃逸 apps/mobile，避免把任意本地脚本当作 E2E 执行。
export function resolveIntegrationTests(mobileRoot, requestedTests) {
  if (requestedTests.length === 0) return listIntegrationTests(mobileRoot);

  return [...new Set(requestedTests.map((requested) => {
    if (isAbsolute(requested) || !requested.endsWith("_test.dart")) {
      throw new Error(`无效 integration_test 路径：${requested}`);
    }
    const absolute = resolve(mobileRoot, requested);
    const fromMobile = relative(mobileRoot, absolute);
    if (
      fromMobile.startsWith("..")
      || isAbsolute(fromMobile)
      || fromMobile.split(/[\\/]/)[0] !== "integration_test"
      || !existsSync(absolute)
    ) {
      throw new Error(`integration_test 不存在或不在 apps/mobile 内：${requested}`);
    }
    return fromMobile;
  }))];
}

// summarizeFlutterMachineOutput 仅提取 machine 输出中的事件计数，不保留测试名称或错误正文。
export function summarizeFlutterMachineOutput(output) {
  const summary = {
    machine_events: 0,
    test_started: 0,
    test_passed: 0,
    test_failed: 0,
    test_skipped: 0,
    tool_errors: 0,
    done_success: null,
  };

  for (const line of output.split(/\r?\n/)) {
    if (!line.trim()) continue;
    try {
      const event = JSON.parse(line);
      summary.machine_events += 1;
      if (event.type === "testStart") summary.test_started += 1;
      if (event.type === "testDone") {
        if (event.result === "success") summary.test_passed += 1;
        else if (event.result === "skipped") summary.test_skipped += 1;
        else summary.test_failed += 1;
      }
      if (event.type === "error") summary.tool_errors += 1;
      if (event.type === "done" && typeof event.success === "boolean") {
        summary.done_success = event.success;
      }
    } catch {
      // Flutter 工具的非 JSON 进度行不包含在报告摘要中。
    }
  }
  return summary;
}

export async function listAvdNames(emulatorPath) {
  const result = await runCommand(emulatorPath, ["-list-avds"]);
  if (result.code !== 0) throw new Error("无法读取 Android AVD 列表");
  return result.stdout.split(/\r?\n/).map((name) => name.trim()).filter(Boolean);
}

export async function listConnectedDevices(adbPath) {
  const result = await runCommand(adbPath, ["devices", "-l"]);
  if (result.code !== 0) throw new Error("adb devices 执行失败");
  return parseAdbDevices(result.stdout);
}

async function avdNameForSerial(adbPath, serial) {
  const result = await runCommand(adbPath, ["-s", serial, "emu", "avd", "name"], { timeoutMs: 5_000 });
  if (result.code !== 0) return null;
  return result.stdout
    .split(/\r?\n/)
    .map((line) => line.trim())
    .find((line) => line && line !== "OK") || null;
}

// findRunningAvd 通过 emulator console 名称识别已经运行的同名 AVD，绝不关闭它。
export async function findRunningAvd(adbPath, avdName) {
  const devices = await listConnectedDevices(adbPath);
  for (const device of devices) {
    if (device.state !== "device" || !device.serial.startsWith("emulator-")) continue;
    const name = await avdNameForSerial(adbPath, device.serial);
    if (name === avdName) return { ...device, avdName: name };
  }
  return null;
}

// visibleAvdArgs 保持 AVD 冷启动且禁用与业务无关的音频，不传 -no-window。
// 旧快照或 CoreAudio 初始化卡死时，仍必须保留真实 Android 图形窗口用于验收。
export function visibleAvdArgs(avdName) {
  return ["-avd", avdName, "-no-snapshot", "-no-audio", "-no-boot-anim"];
}

export function startVisibleAvd(emulatorPath, avdName) {
  const child = spawn(emulatorPath, visibleAvdArgs(avdName), {
    stdio: "ignore",
    windowsHide: false,
  });
  // spawn 错误必须被消费并交给启动等待逻辑判定，避免未处理 error 事件中断报告写入。
  child.launchError = null;
  child.on("error", (error) => {
    child.launchError = error instanceof Error ? error.message : String(error);
  });
  return child;
}

// detachRetainedAvd 只在用户要求保留本轮 AVD 时释放 Node 的子进程引用。
// AVD 本身保持可见运行，runner 则可在写完报告后正常退出，便于后续直接做定向诊断。
export function detachRetainedAvd(child) {
  if (child && typeof child.unref === "function") child.unref();
}

async function wait(ms) {
  await new Promise((resolveWait) => setTimeout(resolveWait, ms));
}

// waitForAvdBoot 同时确认 adb online 与 Android 系统 boot_completed，避免 Flutter 连接到半启动设备。
export async function waitForAvdBoot({ adbPath, avdName, timeoutMs, startedChild }) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (startedChild?.launchError) {
      throw new Error("Android Emulator 无法启动");
    }
    if (startedChild?.exitCode != null) {
      throw new Error("Android Emulator 在完成启动前退出");
    }
    const running = await findRunningAvd(adbPath, avdName);
    if (running) {
      const boot = await runCommand(adbPath, ["-s", running.serial, "shell", "getprop", "sys.boot_completed"], {
        timeoutMs: 5_000,
      });
      if (boot.code === 0 && boot.stdout.trim() === "1") return running;
    }
    await wait(1_000);
  }
  throw new Error(`Android AVD ${avdName} 未在 ${Math.round(timeoutMs / 1_000)} 秒内就绪`);
}

export async function waitForAndroidDevice(adbPath, serial, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const devices = await listConnectedDevices(adbPath);
    const device = devices.find((candidate) => candidate.serial === serial);
    if (device?.state === "device") {
      const boot = await runCommand(adbPath, ["-s", serial, "shell", "getprop", "sys.boot_completed"], {
        timeoutMs: 5_000,
      });
      if (boot.code === 0 && boot.stdout.trim() === "1") return device;
    }
    await wait(1_000);
  }
  throw new Error(`Android 设备 ${serial} 未在 ${Math.round(timeoutMs / 1_000)} 秒内就绪`);
}

function safeDeviceValue(value) {
  return value
    .trim()
    .replace(/[^a-zA-Z0-9._() -]/g, "_")
    .slice(0, 120) || "unknown";
}

// readDeviceMetadata 只读取设备型号/系统版本等验收所需元数据，不访问应用数据或用户配置。
export async function readDeviceMetadata(adbPath, serial) {
  const readProperty = async (property) => {
    const result = await runCommand(adbPath, ["-s", serial, "shell", "getprop", property], { timeoutMs: 5_000 });
    return result.code === 0 ? safeDeviceValue(result.stdout) : "unknown";
  };

  return {
    serial: safeDeviceValue(serial),
    model: await readProperty("ro.product.model"),
    android_version: await readProperty("ro.build.version.release"),
    api_level: await readProperty("ro.build.version.sdk"),
  };
}

function waitForChildExit(child, timeoutMs) {
  if (child.exitCode != null) return Promise.resolve(true);
  return new Promise((resolveResult) => {
    const timer = setTimeout(() => {
      child.removeListener("exit", onExit);
      resolveResult(false);
    }, timeoutMs);
    const onExit = () => {
      clearTimeout(timer);
      resolveResult(true);
    };
    child.once("exit", onExit);
  });
}

// stopUnreadyStartedAvd 用于 AVD 尚未拿到 serial 时的失败清理，仍只终止本轮直接 spawn 的进程。
export async function stopUnreadyStartedAvd(child) {
  if (!child || child.exitCode != null) return { attempted: false, stopped: child?.exitCode != null };
  const signalled = child.kill("SIGTERM");
  return { attempted: true, stopped: await waitForChildExit(child, 10_000), signalled };
}

// stopStartedAvd 仅接触本轮 child 对应的 serial；复用的 AVD 或外接真机绝不会由此函数停止。
export async function stopStartedAvd({ adbPath, serial, child }) {
  if (!child || child.exitCode != null) {
    return { attempted: false, stopped: child?.exitCode != null, forced: false };
  }

  const emulatorStop = await runCommand(adbPath, ["-s", serial, "emu", "kill"], { timeoutMs: 10_000 });
  let stopped = await waitForChildExit(child, 20_000);
  let forced = false;
  if (!stopped && child.exitCode == null) {
    forced = child.kill("SIGTERM");
    stopped = await waitForChildExit(child, 10_000);
  }
  return {
    attempted: true,
    stopped,
    forced,
    adb_emu_kill_exit_code: emulatorStop.code,
  };
}
