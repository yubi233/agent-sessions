// OWN-06 双机编排器纯函数回归（不触碰 adb/设备/网络）。
// 覆盖：参数解析与端口护栏、双物理设备选择规则、flutter 参数构造、审批泵匹配。
import assert from "node:assert/strict";
import { test } from "node:test";
import {
  parsePairArgs,
  pairFlutterArgs,
  pumpApprovalOnce,
  selectPairDevices,
} from "./run-android-pair.mjs";

const physicalA = { serial: "abc111", state: "device" };
const physicalB = { serial: "def222", state: "device" };
const emulator = { serial: "emulator-5554", state: "device" };
const unauthorized = { serial: "ghi333", state: "unauthorized" };

function rejectsWith(promise, fragment) {
  return assert.rejects(promise, (error) => {
    assert.match(error.message, new RegExp(fragment));
    return true;
  });
}

test("parsePairArgs 默认值：隔离端口与状态目录", () => {
  const args = parsePairArgs([]);
  assert.equal(args.relayPort, 8797);
  assert.equal(args.lanPort, 8798);
  assert.equal(args.opencodePort, 4196);
  assert.equal(args.keepStack, false);
  assert.equal(args.noStack, false);
});

test("parsePairArgs 拒绝占用主栈端口（8787/4096）", () => {
  assert.throws(() => parsePairArgs(["--relay-port", "8787"]), /主栈冲突/);
  assert.throws(() => parsePairArgs(["--opencode-port", "4096"]), /主栈冲突/);
});

test("parsePairArgs 未知参数报 test_harness_defect 语义", () => {
  assert.throws(() => parsePairArgs(["--avd", "x"]), /未知参数/);
});

test("selectPairDevices 未指定 serial 时要求恰好两台物理设备", async () => {
  const pair = selectPairDevices([physicalA, physicalB]);
  assert.equal(pair.approver.serial, "abc111");
  assert.equal(pair.joiner.serial, "def222");

  // 未授权的额外设备被忽略（不阻塞旅程）。
  const pairWithUnauthorized = selectPairDevices([
    physicalA,
    unauthorized,
    physicalB,
  ]);
  assert.equal(pairWithUnauthorized.joiner.serial, "def222");

  // 已授权物理设备不足两台 → 拒绝；三台可授权设备无法自动定角色 → 拒绝。
  await rejectsWith(
    Promise.resolve().then(() => selectPairDevices([physicalA])),
    /恰好两台/,
  );
  await rejectsWith(
    Promise.resolve().then(() =>
      selectPairDevices([
        physicalA,
        physicalB,
        { serial: "jkl444", state: "device" },
      ]),
    ),
    /恰好两台/,
  );
});

test("selectPairDevices 拒绝 emulator 与重复设备", async () => {
  await rejectsWith(
    Promise.resolve().then(() =>
      selectPairDevices([physicalA, physicalB], { approverId: "emulator-5554" }),
    ),
    /emulator/,
  );
  await rejectsWith(
    Promise.resolve().then(() =>
      selectPairDevices([physicalA, physicalB], {
        approverId: "abc111",
        joinerId: "abc111",
      }),
    ),
    /同一台设备/,
  );
});

test("selectPairDevices 显式指定时校验存在与授权状态", async () => {
  await rejectsWith(
    Promise.resolve().then(() =>
      selectPairDevices([physicalA], { approverId: "missing" }),
    ),
    /未找到/,
  );
  await rejectsWith(
    Promise.resolve().then(() =>
      selectPairDevices([physicalA, unauthorized], { joinerId: "ghi333" }),
    ),
    /ADB 授权/,
  );
});

test("pairFlutterArgs 注入 RELAY_BASE_URL 且绑定指定 serial", () => {
  const args = pairFlutterArgs("integration_test/x_test.dart", "abc111", "http://10.0.0.2:8798");
  assert.deepEqual(args, [
    "test",
    "integration_test/x_test.dart",
    "-d",
    "abc111",
    "--dart-define=RELAY_BASE_URL=http://10.0.0.2:8798",
    "--machine",
  ]);
});

test("pumpApprovalOnce 只批准指定 displayName 的 pending 请求", async () => {
  const calls = [];
  const fakeFetch = async (url, options = {}) => {
    calls.push({ url, method: options.method ?? "GET" });
    if (url.endsWith("/v1/pairing/requests") && (options.method ?? "GET") === "GET") {
      return {
        status: 200,
        text: async () =>
          JSON.stringify({
            pairings: [
              { id: "p-joiner", status: "pending", display_name: "OWN06-Joiner-B" },
              { id: "p-approver", status: "pending", display_name: "OWN06-Approver-A", compare_code: "654321" },
              { id: "p-done", status: "approved", display_name: "OWN06-Approver-A" },
            ],
          }),
      };
    }
    return { status: 200, text: async () => JSON.stringify({ ok: 1 }) };
  };
  const originalFetch = globalThis.fetch;
  globalThis.fetch = fakeFetch;
  try {
    const result = await pumpApprovalOnce("127.0.0.1:8797", "token", "OWN06-Approver-A");
    assert.equal(result.approved, true);
    assert.equal(result.pairingId, "p-approver");
    assert.equal(result.compareCode, "654321");
    const approveCalls = calls.filter((call) => call.method === "POST");
    assert.equal(approveCalls.length, 1);
    assert.match(approveCalls[0].url, /p-approver\/approve$/);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("pumpApprovalOnce 清单不含目标时保持 not_found 不误批", async () => {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () => ({
    status: 200,
    text: async () => JSON.stringify({ pairings: [] }),
  });
  try {
    const result = await pumpApprovalOnce("127.0.0.1:8797", "token", "OWN06-Approver-A");
    assert.equal(result.approved, false);
    assert.equal(result.reason, "not_found");
  } finally {
    globalThis.fetch = originalFetch;
  }
});
