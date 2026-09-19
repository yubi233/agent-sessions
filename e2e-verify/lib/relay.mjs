// 统一管理隔离 Relay 的构建、健康等待与回收；临时库不与用户服务共用。
import { spawn } from "node:child_process";
import { createServer } from "node:net";
import { mkdtempSync, existsSync, rmSync } from "node:fs";
import { join, dirname } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { stopProcess } from "./process.mjs";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");

// 显式传入 binary 时可在多个独立数据库间复用同一构建，所有权仍归构建调用方。
export async function startRelay({ port = 0, addr = "127.0.0.1", env = {}, binary } = {}) {
  const actualPort = port === 0 ? await reservePort(addr) : port;
  const dbDir = mkdtempSync(join(tmpdir(), "agent-sessions-relay-"));
  const dbPath = join(dbDir, "relay.db");
  let build;
  let child;
  let logs = "";
  try {
    if (!binary) build = await buildRelay();
    const dshDefaultConfig = join(ROOT, "cordis.yml");
    const defaults = existsSync(dshDefaultConfig) ? { AGENT_SESSIONS_DSH_CONFIG: dshDefaultConfig } : {};
    child = spawn(binary || build.path, ["--addr", `${addr}:${actualPort}`, "--db", dbPath], {
      stdio: ["ignore", "pipe", "pipe"],
      env: { ...process.env, ...defaults, ...env },
    });
    let spawnError;
    child.on("error", (error) => { spawnError = error; });
    child.stdout.on("data", (d) => { logs += d.toString(); });
    child.stderr.on("data", (d) => { logs += d.toString(); });
    const base = `http://${addr}:${actualPort}`;
    await waitForReady(base, child, () => logs, () => spawnError);
    let stopped = false;
    return {
      base, port: actualPort, addr, dbPath, child,
      logs: () => logs,
      async stop() {
        if (stopped) return;
        stopped = true;
        await stopProcess(child);
        rmSync(dbDir, { recursive: true, force: true });
        build?.stop();
      },
    };
  } catch (error) {
    if (child?.pid) await stopProcess(child);
    rmSync(dbDir, { recursive: true, force: true });
    build?.stop();
    throw error;
  }
}

async function reservePort(addr) {
  return new Promise((resolve, reject) => {
    const probe = createServer();
    probe.once("error", reject);
    probe.listen(0, addr, () => {
      const selected = probe.address()?.port;
      probe.close((error) => {
        if (error) reject(error);
        else if (!selected) reject(new Error("无法获取动态 Relay 端口"));
        else resolve(selected);
      });
    });
  });
}

export async function buildRelay() {
  const directory = mkdtempSync(join(tmpdir(), "agent-sessions-bin-"));
  const path = join(directory, "relay");
  try {
    await new Promise((resolve, reject) => {
      const child = spawn("go", ["build", "-o", path, "./apps/relay"], { cwd: ROOT, stdio: "ignore" });
      child.on("error", reject);
      child.on("exit", (code) => code === 0 ? resolve() : reject(new Error(`go build relay exited ${code}`)));
    });
    return { path, stop: () => rmSync(directory, { recursive: true, force: true }) };
  } catch (error) {
    rmSync(directory, { recursive: true, force: true });
    throw error;
  }
}

async function waitForReady(base, child, logs, spawnError) {
  const deadline = Date.now() + 20000;
  while (Date.now() < deadline) {
    if (spawnError()) throw spawnError();
    if (child.exitCode !== null || child.signalCode !== null) throw new Error(`relay exited early: ${logs()}`);
    try {
      const res = await fetch(`${base}/readyz`, { signal: AbortSignal.timeout(1000) });
      if (res.ok) return;
    } catch { /* 尚未就绪，继续等待。 */ }
    await new Promise((r) => setTimeout(r, 200));
  }
  throw new Error(`relay not ready within timeout: ${logs()}`);
}
