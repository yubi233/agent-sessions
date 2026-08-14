// Android 编排模块的纯回归：不启动模拟器、不连接 ADB，仅验证解析与路径边界。
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { sanitizeReport } from "../lib/report.mjs";
import { detachRetainedAvd, findAndroidAdb, findAndroidTools, listIntegrationTests, parseAdbDevices, resolveIntegrationTests, summarizeFlutterMachineOutput, visibleAvdArgs } from "./android.mjs";
import { flutterIntegrationArgs, parseArgs } from "./run-android.mjs";

test("parseAdbDevices 只保留设备序列号和状态", () => {
  const devices = parseAdbDevices("List of devices attached\nemulator-5554 device product:sdk model:Pixel\nABC123 unauthorized usb:1-1\n");
  assert.deepEqual(devices, [
    { serial: "emulator-5554", state: "device", details: "product:sdk model:Pixel" },
    { serial: "ABC123", state: "unauthorized", details: "usb:1-1" },
  ]);
});

test("macOS AVD gate 需要完整的 adb/Emulator 工具边界", () => {
  const root = mkdtempSync(join(tmpdir(), "android-sdk-"));
  const platformTools = join(root, "platform-tools");
  mkdirSync(platformTools, { recursive: true });
  writeFileSync(join(platformTools, "adb"), "fixture");

  assert.deepEqual(findAndroidAdb({ ANDROID_SDK_ROOT: root }), { sdkRoot: root, adbPath: join(platformTools, "adb") });
  assert.throws(() => findAndroidTools({ ANDROID_SDK_ROOT: root }), /Emulator/);
});

test("可见 AVD 冷启动不复用快照或音频，但绝不传 no-window", () => {
  const args = visibleAvdArgs("Nexus_5X_API_32");
  assert.deepEqual(args, [
    "-avd",
    "Nexus_5X_API_32",
    "-no-snapshot",
    "-no-audio",
    "-no-boot-anim",
  ]);
  assert.equal(args.includes("-no-window"), false);
});

test("保留 AVD 时释放 runner 子进程引用但不终止模拟器", () => {
  let unrefCalls = 0;
  detachRetainedAvd({ unref: () => { unrefCalls += 1; } });
  detachRetainedAvd(null);
  assert.equal(unrefCalls, 1);
});

test("resolveIntegrationTests 只接受 apps/mobile 内的 integration_test", () => {
  const root = mkdtempSync(join(tmpdir(), "android-runner-"));
  const integration = join(root, "integration_test");
  mkdirSync(integration, { recursive: true });
  writeFileSync(join(integration, "w1_auth_pairing_flow_test.dart"), "void main() {}\n");
  writeFileSync(join(integration, "helper.dart"), "void helper() {}\n");

  assert.deepEqual(listIntegrationTests(root), ["integration_test/w1_auth_pairing_flow_test.dart"]);
  assert.deepEqual(resolveIntegrationTests(root, ["integration_test/w1_auth_pairing_flow_test.dart"]), [
    "integration_test/w1_auth_pairing_flow_test.dart",
  ]);
  assert.throws(() => resolveIntegrationTests(root, ["../outside_test.dart"]));
});

test("summarizeFlutterMachineOutput 不保留测试正文，仅统计事件", () => {
  const summary = summarizeFlutterMachineOutput([
    '{"type":"testStart","test":{"id":1,"name":"sensitive body"}}',
    '{"type":"testDone","testID":1,"result":"success"}',
    '{"type":"done","success":true}',
  ].join("\n"));
  assert.deepEqual(summary, {
    machine_events: 3,
    test_started: 1,
    test_passed: 1,
    test_failed: 0,
    test_skipped: 0,
    tool_errors: 0,
    done_success: true,
  });
});

test("Android full gate 保留 machine 摘要并避免卸载可复用 AVD 应用", () => {
  assert.deepEqual(
    flutterIntegrationArgs(["integration_test/w1_auth_pairing_flow_test.dart"], "emulator-5554"),
    [
      "test",
      "integration_test/w1_auth_pairing_flow_test.dart",
      "-d",
      "emulator-5554",
      "--machine",
      "--no-uninstall",
    ],
  );
});

test("v0.1 当前 Android gate 拒绝外接真机和 headless 参数", () => {
  assert.throws(() => parseArgs(["--device-id", "USB-DEVICE"]), /只支持 macOS 可见 AVD/);
  assert.throws(() => parseArgs(["--headless"]), /不支持 --headless/);
});

test("Android 定向诊断只显式开启，不改变默认 full gate", () => {
  assert.equal(parseArgs([]).diagnostic, false);
  assert.equal(parseArgs(["--diagnostic"]).diagnostic, true);
});

test("Android Keystore 存储禁用自动备份", () => {
  const manifest = readFileSync(
    new URL("../../apps/mobile/android/app/src/main/AndroidManifest.xml", import.meta.url),
    "utf8",
  );
  assert.match(manifest, /android:allowBackup="false"/);
});

test("Android Manifest 保持可被原生构建工具解析", () => {
  const manifest = new URL("../../apps/mobile/android/app/src/main/AndroidManifest.xml", import.meta.url);
  assert.doesNotThrow(() => execFileSync("xmllint", ["--noout", manifest.pathname], { stdio: "pipe" }));
});

test("Android Gradle 仅允许显式 HTTPS Google Maven 镜像并保留官方回退", () => {
  const settings = readFileSync(
    new URL("../../apps/mobile/android/settings.gradle.kts", import.meta.url),
    "utf8",
  );
  const build = readFileSync(
    new URL("../../apps/mobile/android/build.gradle.kts", import.meta.url),
    "utf8",
  );
  const properties = readFileSync(
    new URL("../../apps/mobile/android/gradle.properties", import.meta.url),
    "utf8",
  );
  for (const source of [settings, build]) {
    assert.match(source, /AGENT_SESSIONS_GOOGLE_MAVEN_MIRROR/);
    assert.match(source, /startsWith\("https:\/\/"\)/);
    assert.match(source, /google\(\)/);
  }
  assert.match(properties, /org\.gradle\.internal\.http\.connectionTimeout=120000/);
  assert.match(properties, /org\.gradle\.internal\.http\.socketTimeout=180000/);
});

test("sanitizeReport 移除凭据和正文扩展字段", () => {
  const report = sanitizeReport({
    authorization: "Bearer should-not-be-stored",
    raw_message: "session body should-not-be-stored",
    command: "curl '?token=should-not-be-stored'",
    request_ids: ["safe-request-id"],
  });
  assert.deepEqual(report, {
    authorization: "[REDACTED]",
    raw_message: "[REDACTED]",
    command: "curl '?token=[REDACTED]'",
    request_ids: ["safe-request-id"],
  });
});
