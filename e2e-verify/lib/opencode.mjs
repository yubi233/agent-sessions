// 统一管理真实 opencode serve 的生命周期：启动、端口解析、健康等待、停止。
// 供 headed 能力矩阵回归复用：serve 是真实本地服务，凭据只来自环境变量，不写入日志/报告。
import { spawn } from "node:child_process";
import { createServer } from "node:net";

// OpenCode serve 会把 --port 0 解释成默认端口 4096（而不是随机端口）。
// smoke/浏览器套件必须先取得一个真正空闲的端口，避免误连用户正在运行的服务。
async function reservePort(hostname) {
  return new Promise((resolve, reject) => {
    const probe = createServer();
    probe.once("error", reject);
    probe.listen(0, hostname, () => {
      const address = probe.address();
      const port = typeof address === "object" && address ? address.port : 0;
      probe.close((error) => {
        if (error) reject(error);
        else if (!port) reject(new Error("无法取得 OpenCode 动态端口"));
        else resolve(port);
      });
    });
  });
}

// 真实 OpenCode 进程只需要本机配置目录、语言环境和显式服务鉴权变量。
// 不把当前 shell 中无关的 API key、cookie 或测试 token 传给子进程。
function safeOpenCodeEnvironment() {
  const names = [
    "HOME",
    "LANG",
    "LC_ALL",
    "PATH",
    "TMPDIR",
    "TERM",
    "NO_COLOR",
    "XDG_CONFIG_HOME",
    "XDG_DATA_HOME",
    "XDG_CACHE_HOME",
    "OPENCODE_SERVER_USERNAME",
    "OPENCODE_SERVER_PASSWORD",
  ];
  return Object.fromEntries(
    names
      .filter((name) => typeof process.env[name] === "string")
      .map((name) => [name, process.env[name]]),
  );
}

function safeLogSummary(value) {
  return String(value)
    .replace(/(bearer\s+)[^\s"']+/gi, "$1[REDACTED]")
    .replace(/((?:api[_-]?key|token|password|secret)\s*[:=]\s*)[^\s,}"']+/gi, "$1[REDACTED]")
    .replace(/\s+/g, " ")
    .trim()
    .slice(-800);
}

// startOpenCodeServe 启动真实 opencode serve（随机端口），等待 /global/health 健康后返回控制句柄。
// options.healthTimeoutMs 默认 60s：serve 启动慢，健康等待需要足够预算。
export async function startOpenCodeServe({
  port = 0,
  hostname = "127.0.0.1",
  healthTimeoutMs = 60_000,
} = {}) {
  const username = process.env.OPENCODE_SERVER_USERNAME || "opencode";
  const password = process.env.OPENCODE_SERVER_PASSWORD;
  const actualPort = port === 0 ? await reservePort(hostname) : port;
  const binary = process.env.OPENCODE_BIN || "opencode";

  const child = spawn(
    binary,
    ["serve", "--port", String(actualPort), "--hostname", hostname, "--pure", "--print-logs"],
    { stdio: ["ignore", "pipe", "pipe"], env: safeOpenCodeEnvironment() },
  );

  let logs = "";
  child.stdout.on("data", (d) => (logs += d.toString()));
  child.stderr.on("data", (d) => (logs += d.toString()));

  try {
    // 从启动日志解析实际监听地址；actualPort 已由本 helper 预留，不依赖 serve 的
    // 非标准 --port 0 行为。
    const base = await parseListeningBase(child, () => logs, healthTimeoutMs);
    // 健康等待：/global/health 返回 healthy+version 才算可用。无密码的本地
    // unsecured 模式也必须显式标注，不能在报告中伪称 Basic Auth。
    await waitForHealth(base, child, () => logs, healthTimeoutMs, username, password);

    return {
      base,
      hostname,
      port: actualPort,
      child,
      username,
      auth_mode: password ? "basic" : "unsecured",
      async stop() {
        if (child.exitCode !== null) return;
        child.kill("SIGTERM");
        await new Promise((resolveStop) => {
          child.once("exit", resolveStop);
          // 某些 OpenCode 版本在无活动连接时不会及时退出，避免套件泄漏进程。
          setTimeout(() => {
            if (child.exitCode === null) child.kill("SIGKILL");
          }, 3_000).unref();
        });
      },
      logs() {
        return logs;
      },
    };
  } catch (error) {
    if (child.exitCode === null) child.kill("SIGTERM");
    const message = error instanceof Error ? error.message : String(error);
    throw new Error(`${message}；启动日志摘要：${safeLogSummary(logs)}`);
  }
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
      const headers = {};
      if (password) {
        headers.Authorization = `Basic ${Buffer.from(`${username}:${password}`).toString("base64")}`;
      }
      const response = await fetch(`${base}/global/health`, {
        headers,
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

export { reservePort };
