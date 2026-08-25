import test from "node:test";
import assert from "node:assert/strict";
import { startRelay } from "../lib/relay.mjs";

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
