// 统一管理 Relay 进程的生命周期：启动、健康等待、停止。
// 采用 go build 生成临时二进制后由子进程运行，避免 go run 的编译进程干扰停止。
import { spawn } from "node:child_process";
import { createServer } from "node:net";
import { mkdtempSync, existsSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { dirname } from "node:path";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");

// startRelay 启动一个隔离的 Relay 实例（独立临时 SQLite），返回控制句柄。
// options.env 可在进程环境之上追加覆盖项（如 AGENT_SESSIONS_OPENCODE_URL），
// 供需要把 Relay 接到真实 opencode serve 的回归场景使用；默认保持与 runner 环境一致。
// 默认 port=0 时由操作系统分配空闲端口，避免测试误连用户已有 Relay。
export async function startRelay({ port = 0, addr = "127.0.0.1", env = {} } = {}) {
  const actualPort = port === 0 ? await reservePort(addr) : port;
  const dbPath = join(mkdtempSync(join(tmpdir(), "agent-sessions-relay-")), "relay.db");
  const bin = await buildRelay();
  const args = ["--addr", `${addr}:${actualPort}`, "--db", dbPath];
  const child = spawn(bin, args, {
    stdio: ["ignore", "pipe", "pipe"],
    env: { ...process.env, ...env },
  });

  let logs = "";
  child.stdout.on("data", (d) => (logs += d.toString()));
  child.stderr.on("data", (d) => (logs += d.toString()));

  const base = `http://${addr}:${actualPort}`;
  // 等待 readyz 返回 200，超时视为启动失败。
  await waitForReady(base, child, logs);

  return {
    base,
    port: actualPort,
    addr,
    dbPath,
    child,
    async stop() {
      child.kill("SIGTERM");
      await new Promise((r) => child.once("exit", r));
      // 清理本轮创建的临时数据库目录，不触碰用户数据。
      if (existsSync(dirname(dbPath))) {
        try {
          rmSync(dirname(dbPath), { recursive: true, force: true });
        } catch {
          /* 忽略清理失败 */
        }
      }
    },
    logs() {
      return logs;
    },
  };
}

// reservePort 只短暂占用系统分配的端口，关闭监听后立即交给本轮 Relay。
// 若端口在这段极短窗口内被抢占，Relay 健康检查会失败并由 runner 如实报告。
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

async function buildRelay() {
  const bin = join(mkdtempSync(join(tmpdir(), "agent-sessions-bin-")), "relay");
  return new Promise((resolve, reject) => {
    const child = spawn("go", ["build", "-o", bin, "./apps/relay"], {
      cwd: ROOT,
      stdio: "ignore",
    });
    child.on("error", reject);
    child.on("exit", (code) => {
      if (code === 0) resolve(bin);
      else reject(new Error(`go build relay exited ${code}`));
    });
  });
}

async function waitForReady(base, child, logsRef) {
  const deadline = Date.now() + 20000;
  while (Date.now() < deadline) {
    if (child.exitCode != null) {
      throw new Error(`relay exited early: ${logsRef}`);
    }
    try {
      const res = await fetch(`${base}/readyz`);
      if (res.ok) return;
    } catch {
      /* 尚未就绪，继续等待 */
    }
    await new Promise((r) => setTimeout(r, 200));
  }
  throw new Error(`relay not ready within timeout: ${logsRef}`);
}
