import assert from "node:assert/strict";
import test from "node:test";

import {
  discoverOfficialZenFreeModels,
  discoverLocalZenFreeModels,
  chooseZenModel,
  classifyHarnessError,
  V07HarnessError,
} from "./v07-harness.mjs";
import { parseZenSmokeArgs, runZenSmoke } from "./v07-zen-smoke.mjs";

test("V07-05 未显式授权时不启动真实 runner 且写 blocked 报告", async () => {
  let called = false;
  const writes = [];
  const result = await runZenSmoke(parseZenSmokeArgs([]), {
    zenEnabled: false,
    run: async () => {
      called = true;
      throw new Error("must not run");
    },
    write: ({ report }) => {
      writes.push(report);
      return "reports/V07-05.json";
    },
  });
  assert.equal(called, false);
  assert.equal(result.exitCode, 2);
  assert.equal(result.report.status, "blocked");
  assert.equal(result.report.failure_class, "credential_or_quota_blocker");
  assert.equal(writes.length, 1);
});
test("V07-05 runner 成功只提升真实模型口径并保留摘要字段", async () => {
  const result = await runZenSmoke(parseZenSmokeArgs(["--model", "opencode/big-pickle"]), {
    zenEnabled: true,
    run: async () => ({
      report: {
        model: "opencode/big-pickle",
        request_attempts: 2,
        event_types: ["message.completed", "turn.completed"],
        usage: { input_tokens: 4, output_tokens: 3 },
      },
    }),
    write: ({ report }) => {
      assert.equal(report.status, "passed");
      assert.equal(report.real_model, true);
      assert.equal(report.real_upstream, true);
      assert.equal(report.request_attempts, 2);
      return "reports/V07-05.json";
    },
  });
  assert.equal(result.exitCode, 0);
});

test("V07-05 凭证目录 blocker 不会被误报为产品失败", async () => {
  const result = await runZenSmoke(parseZenSmokeArgs([]), {
    zenEnabled: true,
    run: async () => {
      throw new V07HarnessError("没有交集", { failureClass: "credential_or_quota_blocker" });
    },
    write: ({ report }) => report,
  });
  assert.equal(result.exitCode, 1);
  assert.equal(result.report.status, "blocked");
  assert.equal(result.report.failure_class, "credential_or_quota_blocker");
  assert.equal(result.report.real_model, false);
});

test("Zen 官方目录只接受明确 free 条目并按 ID 去重排序", async () => {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () => new Response(JSON.stringify({
    data: [
      { id: "z-free" },
      { id: "big-pickle" },
      { id: "paid-model" },
      { id: "zero-cost", pricing: { input: 0, output: 0 } },
      { id: "z-free" },
    ],
  }), { status: 200, headers: { "Content-Type": "application/json" } });
  try {
    const catalog = await discoverOfficialZenFreeModels({ url: "https://fixture.invalid/models" });
    assert.deepEqual(catalog.ids, ["big-pickle", "z-free", "zero-cost"]);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("本机 provider 目录只与 Zen provider 和官方 Free ID 求交集", async () => {
  const originalFetch = globalThis.fetch;
  const responses = {
    "/config/providers": {
      providers: [
        { id: "opencode", models: { "big-pickle": { id: "big-pickle", providerID: "opencode" } } },
        { id: "opencode-go", models: { "z-free": { id: "z-free", providerID: "opencode-go" } } },
      ],
    },
  };
  globalThis.fetch = async (url) => {
    const path = new URL(url).pathname;
    const body = responses[path] || {};
    return new Response(JSON.stringify(body), { status: 200 });
  };
  try {
    const catalog = await discoverLocalZenFreeModels({
      base: "http://127.0.0.1:1",
      official: { ids: ["big-pickle", "z-free"] },
    });
    assert.deepEqual(catalog.options, ["opencode/big-pickle"]);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("chooseZenModel 优先使用动态目录中的配置值，否则使用稳定排序首项", () => {
  assert.equal(chooseZenModel(["opencode/z-free", "opencode/big-pickle"], "opencode/z-free"), "opencode/z-free");
  assert.equal(chooseZenModel(["opencode/z-free", "opencode/big-pickle"], "opencode/unknown"), "opencode/big-pickle");
  assert.throws(() => chooseZenModel([]), /选项为空/);
});

test("失败分类只允许 workflow 中的稳定类别", () => {
  assert.equal(classifyHarnessError(new V07HarnessError("timeout", { failureClass: "provider_timeout" })).failure_class, "provider_timeout");
  assert.equal(classifyHarnessError(new Error("unexpected")).failure_class, "test_harness_defect");
});
