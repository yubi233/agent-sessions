import assert from "node:assert/strict";
import test from "node:test";
import { runSuites } from "../lib/runner.mjs";
import { fixtureProviderEnv, openSuiteEnvironment } from "../lib/suite-environment.mjs";

function harness(outcomes) {
  const saved = [];
  const opened = [];
  const closed = [];
  const suites = [{
    id: "fixture", planId: "V094",
    async run({ report, relay }) {
      assert.equal(relay.base, `attempt-${saved.length + 1}`);
      return report({ suite: "fixture", ...outcomes[saved.length] });
    },
  }];
  return {
    saved, opened, closed,
    options: {
      suites,
      retryLimit: 1,
      openEnvironment: async () => {
        const id = opened.length + 1;
        opened.push(id);
        return { relay: { base: `attempt-${id}` }, stop: async () => { closed.push(id); }, logs: () => ({ relay: "diagnostic" }) };
      },
      saveAttempt: async (result) => { saved.push(result); },
    },
  };
}

test("V094 runner：可重试环境故障第二次通过，汇总只计一个套件并保留两次证据", async () => {
  const h = harness([{ status: "failed", failure_class: "environment_or_startup_failure", retryable: true }, { status: "passed" }]);
  const result = await runSuites(h.options);
  assert.equal(result.status, "passed");
  assert.equal(result.total, 1);
  assert.equal(result.flaky, 1);
  assert.deepEqual(result.results[0].attempts.map((x) => x.status), ["failed", "passed"]);
  assert.deepEqual(h.opened, [1, 2]);
  assert.deepEqual(h.closed, [1, 2]);
  assert.deepEqual(h.saved[0].service_logs, { relay: "diagnostic" });
});

for (const failureClass of ["product_defect", "test_harness_defect", "selector_or_dom_contract_defect", "credential_or_quota_blocker"]) {
  test(`V094 runner：${failureClass} 不自动重试`, async () => {
    const h = harness([{ status: "failed", failure_class: failureClass, retryable: true }]);
    const result = await runSuites(h.options);
    assert.equal(result.status, "failed");
    assert.equal(h.saved.length, 1);
  });
}

test("V094 runner：环境类别本身不足以重试，默认无重试", async () => {
  const h = harness([{ status: "failed", failure_class: "environment_or_startup_failure" }]);
  await runSuites(h.options);
  assert.equal(h.saved.length, 1);
  const h2 = harness([{ status: "failed", failure_class: "environment_or_startup_failure", retryable: true }]);
  await runSuites({ ...h2.options, retryLimit: 0 });
  assert.equal(h2.saved.length, 1);
});

test("V094 runner：异常仍归档并清理，后续套件正常运行", async () => {
  const h = harness([{ status: "passed" }]);
  h.options.suites[0].run = async () => { throw new Error("unexpected failure"); };
  const result = await runSuites(h.options);
  assert.equal(result.status, "failed");
  assert.equal(h.saved[0].failure_class, "test_harness_defect");
  assert.deepEqual(h.closed, [1]);
});

test("V094 runner：清理失败不能标绿或覆盖业务失败", async () => {
  const h = harness([{ status: "passed" }]);
  h.options.openEnvironment = async () => ({ relay: { base: "attempt-1" }, stop: async () => { throw new Error("cleanup"); } });
  const result = await runSuites(h.options);
  assert.equal(result.status, "failed");
  assert.match(h.saved[0].cleanup_error, /cleanup/);
});

test("V094 runner：环境配置不跨套件传播，独立环境均回收", async () => {
  const configs = [];
  const stopped = [];
  const services = Object.fromEntries(["Relay", "Web", "Admin"].map((name) => [`start${name}`, async (options) => {
    if (name === "Relay") configs.push(options.env);
    return { base: `${name}-${configs.length}`, stop: async () => { stopped.push(name); } };
  }]));
  const a = await openSuiteEnvironment({ relayEnv: { AGENT_SESSIONS_DSH_BIN: "/special.js" } }, "/built/relay", services);
  await a.stop();
  const b = await openSuiteEnvironment({}, "/built/relay", services);
  await b.stop();
  assert.equal(configs[0].AGENT_SESSIONS_DSH_BIN, "/special.js");
  assert.deepEqual(configs[1], fixtureProviderEnv);
  assert.notEqual(a.fixtureAccount, b.fixtureAccount);
  assert.deepEqual(stopped, ["Admin", "Web", "Relay", "Admin", "Web", "Relay"]);
});

test("V094 runner：部分启动失败也回收已启动服务", async () => {
  const stopped = [];
  await assert.rejects(openSuiteEnvironment({}, "/built/relay", {
    startRelay: async () => ({ base: "relay", stop: async () => { stopped.push("relay"); } }),
    startWeb: async () => { throw new Error("port occupied"); },
    startAdmin: async () => { throw new Error("must not start"); },
  }), /port occupied/);
  assert.deepEqual(stopped, ["relay"]);
});
