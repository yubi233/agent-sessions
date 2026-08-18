// 物理 Android runner 的纯 Node 回归：不读取 ADB，也不触碰已连接设备。
import assert from "node:assert/strict";
import test from "node:test";
import {
  classifyPhysicalFlutterResult,
  parseDeviceArgs,
  physicalFlutterIntegrationArgs,
  selectPhysicalDevice,
} from "./run-android-device.mjs";

const physical = {
  serial: "USB-DEVICE",
  state: "device",
  details: "usb:2-1 product:phone model:Physical",
};

test("物理 Android gate 可自动选择唯一 online 真机并忽略 AVD", () => {
  assert.deepEqual(
    selectPhysicalDevice([
      { serial: "emulator-5554", state: "device", details: "model:Pixel" },
      physical,
    ]),
    physical,
  );
});

test("物理 Android gate 在多台真机时要求显式 device id", () => {
  const second = {
    serial: "SECOND-DEVICE",
    state: "device",
    details: "usb:2-2",
  };
  assert.throws(() => selectPhysicalDevice([physical, second]), /--device-id/);
  assert.deepEqual(
    selectPhysicalDevice([physical, second], second.serial),
    second,
  );
});

test("物理 Android gate 拒绝 emulator、unauthorized 和缺失设备", () => {
  assert.throws(
    () =>
      selectPhysicalDevice(
        [{ serial: "emulator-5554", state: "device", details: "" }],
        "emulator-5554",
      ),
    /拒绝 emulator serial/,
  );
  assert.throws(
    () =>
      selectPhysicalDevice(
        [{ ...physical, state: "unauthorized" }],
        physical.serial,
      ),
    /完成 ADB 授权/,
  );
  assert.throws(
    () => selectPhysicalDevice([], physical.serial),
    /未找到指定 Android 设备/,
  );
});

test("物理 Android gate 参数不接受 AVD 和 headless 语义", () => {
  assert.throws(
    () => parseDeviceArgs(["--avd", "Pixel"]),
    /不接受 AVD 或 headless/,
  );
  assert.throws(
    () => parseDeviceArgs(["--headless"]),
    /不接受 AVD 或 headless/,
  );
  assert.equal(
    parseDeviceArgs(["--device-id", physical.serial]).deviceId,
    physical.serial,
  );
  assert.equal(
    parseDeviceArgs([], { ANDROID_DEVICE_ID: physical.serial }).deviceId,
    physical.serial,
  );
  assert.throws(() => parseDeviceArgs(["--device-id"]), /--device-id 必须带值/);
});

test("物理 Android Flutter 测试不保留测试 APK", () => {
  const args = physicalFlutterIntegrationArgs(
    ["integration_test/w1_signed_native_secure_storage_test.dart"],
    physical.serial,
  );
  assert.deepEqual(args, [
    "test",
    "integration_test/w1_signed_native_secure_storage_test.dart",
    "-d",
    physical.serial,
    "--machine",
  ]);
  assert.equal(args.includes("--no-uninstall"), false);
});

test("物理 Android gate 将用户取消安装归类为设备环境问题", () => {
  const result = classifyPhysicalFlutterResult(
    {
      code: 1,
      timedOut: false,
      stdout:
        "adb: failed to install app-debug.apk: Failure [INSTALL_FAILED_USER_RESTRICTED: Install canceled by user]",
      stderr: "",
    },
    { test_failed: 1, done_success: false },
  );
  assert.equal(result.status, "failed");
  assert.equal(result.failureClass, "environment_or_startup_failure");
  assert.match(result.remainingRisk, /允许 USB\/ADB 安装/);
});
