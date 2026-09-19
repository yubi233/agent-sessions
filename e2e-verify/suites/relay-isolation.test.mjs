import test from "node:test";
import assert from "node:assert/strict";
import { startRelay, buildRelay } from "../lib/relay.mjs";
import { createFixtureAccountFactory } from "../lib/fixture-account.mjs";

// 测试基础设施回归：浏览器 suite 必须使用动态端口和独立 SQLite，不能误连用户已有 Relay。
test("headed runner 为并发 fixture 分配隔离 Relay 端口与数据库", async () => {
  const first = await startRelay();
  const second = await startRelay();
  try {
    assert.notEqual(first.port, 0);
    assert.notEqual(second.port, 0);
    assert.notEqual(first.port, second.port);
    assert.notEqual(first.dbPath, second.dbPath);
    assert.match(first.base, new RegExp(`:${first.port}$`));
    assert.match(second.base, new RegExp(`:${second.port}$`));
    assert.notEqual(first.port, 8787, "默认 fixture 不得抢占项目开发 Relay 端口");
  } finally {
    await Promise.all([first.stop(), second.stop()]);
  }
});

test("V094：独立尝试可重复配对固定身份，复用构建不复用数据", async () => {
  const build = await buildRelay();
  try {
    for (let attempt = 0; attempt < 2; attempt += 1) {
      const relay = await startRelay({ binary: build.path });
      try {
        const account = await createFixtureAccountFactory(relay.base)();
        const headers = { "Content-Type": "application/json", Authorization: `Bearer ${account.accessToken}` };
        const pairing = await fetch(`${relay.base}/v1/pairing/requests`, {
          method: "POST", headers,
          body: JSON.stringify({ role: "terminal", display_name: "repeat-fixture", platform: "test", identity_public_key: "fixed-fixture-identity", encryption_public_key: "fixed-fixture-encryption" }),
        });
        assert.equal(pairing.status, 201);
        const { id } = await pairing.json();
        const approved = await fetch(`${relay.base}/v1/pairing/requests/${id}/approve`, { method: "POST", headers });
        assert.equal(approved.status, 200);
      } finally {
        await relay.stop();
        await relay.stop();
      }
    }
  } finally {
    build.stop();
  }
});
