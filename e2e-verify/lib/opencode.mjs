// 统一管理真实 opencode serve 的生命周期：启动、端口解析、健康等待、停止。
// 供 headed 能力矩阵回归复用：serve 是真实本地服务，凭据只来自环境变量，不写入日志/报告。
import { spawn } from "node:child_process";
// startOpenCodeServe 启动真实 opencode serve（随机端口），等待 /global/health 健康后返回控制句柄。
// options.healthTimeoutMs 默认 60s：serve 启动慢，健康等待需要足够预算。
export async function startOpenCodeServe({
  port = 0,
  hostname = "127.0.0.1",
  healthTimeoutMs = 60_000,
} = {}) {
  const username = process.env.OPENCODE_SERVER_USERNAME || "opencode";
  const password = process.env.OPENCODE_SERVER_PASSWORD;
  if (!password) {
    throw new Error("OPENCODE_SERVER_PASSWORD 未配置，无法启动带 Basic Auth 的 opencode serve");
  }

  const child = spawn(
    "opencode",
    ["serve", "--port", String(port), "--hostname", hostname, "--pure", "--print-logs"],
    { stdio: ["ignore", "pipe", "pipe"], env: { ...process.env } },
  );

  let logs = "";
  child.stdout.on("data", (d) => (logs += d.toString()));
  child.stderr.on("data", (d) => (logs += d.toString()));

  // 从启动日志解析实际监听地址（--port 0 时由 serve 自选端口）。
  const base = await parseListeningBase(child, () => logs, healthTimeoutMs);
  // 健康等待：/global/health 返回 healthy+version 才算可用，超时视为启动失败。
  await waitForHealth(base, child, () => logs, healthTimeoutMs, username, password);

  return {
    base,
    hostname,
    child,
    username,
    async stop() {
      if (child.exitCode !== null) return;
      child.kill("SIGTERM");
      await new Promise((resolveStop) => child.once("exit", resolveStop));
    },
    logs() {
      return logs;
    },
  };
}

// parseListeningBase 等待 serve 输出 "opencode server listening on http://host:port"。
async function parseListeningBase(child, logs, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (child.exitCode != null) {
      throw new Error(`opencode serve exited early (${child.exitCode}): ${logs()}`);
    }
    const match = logs().match(/opencode server listening on (https?:\/\/[^\s]+)/);
    if (match) return match[1];
    await new Promise((resolveDelay) => setTimeout(resolveDelay, 200));
  }
  throw new Error(`opencode serve 未在 ${timeoutMs}ms 内输出监听地址: ${logs()}`);
}

// waitForHealth 轮询 /global/health，直到返回 healthy+version（凭据只存内存）。
async function waitForHealth(base, child, logs, timeoutMs, username, password) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (child.exitCode != null) {
      throw new Error(`opencode serve exited early (${child.exitCode}): ${logs()}`);
    }
    try {
      const authorization = `Basic ${Buffer.from(`${username}:${password}`).toString("base64")}`;
      const response = await fetch(`${base}/global/health`, {
        headers: { Authorization: authorization },
      });
      if (response.ok) {
        const body = await response.json();
        if (body.healthy && body.version) return body;
      }
    } catch {
      // serve 尚未就绪，继续轮询。
    }
    await new Promise((resolveDelay) => setTimeout(resolveDelay, 500));
  }
  throw new Error(`opencode serve /global/health 未在 ${timeoutMs}ms 内返回 healthy: ${logs()}`);
}
