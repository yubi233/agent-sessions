// 统一管理 Vite Web 开发服务器，供 headed 浏览器回归与录屏复用。
import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { stopProcess } from "./process.mjs";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const viteBin = join(ROOT, "apps", "web", "node_modules", "vite", "bin", "vite.js");

// startVite 启动任意应用目录下的 Vite dev server。
async function startVite({ appDir, port, relayBase }) {
  if (!existsSync(viteBin)) {
    throw new Error("Vite 未安装；请先运行 pnpm install");
  }
  const child = spawn(process.execPath, [viteBin, "--host", "127.0.0.1", "--port", String(port), "--strictPort"], {
    cwd: join(ROOT, "apps", appDir),
    env: { ...process.env, VITE_RELAY_URL: relayBase },
    stdio: ["ignore", "pipe", "pipe"],
  });
  let logs = "";
  let spawnError;
  child.on("error", (error) => { spawnError = error; });
  child.stdout.on("data", (chunk) => (logs += chunk.toString()));
  child.stderr.on("data", (chunk) => (logs += chunk.toString()));
  const base = `http://127.0.0.1:${port}`;
  try {
    await waitForReady(base, child, () => logs, () => spawnError);
  } catch (error) {
    if (child.pid) await stopProcess(child);
    throw error;
  }
  return { base, child, logs: () => logs, stop: () => stopProcess(child) };
}

// startWeb 启动 Web 只读客户端。
export async function startWeb({ port = 15173, relayBase } = {}) {
  return startVite({ appDir: "web", port, relayBase });
}

// startAdmin 启动 Admin 运维控制台。
export async function startAdmin({ port = 15174, relayBase } = {}) {
  return startVite({ appDir: "admin-web", port, relayBase });
}

async function waitForReady(base, child, logs, spawnError) {
  const deadline = Date.now() + 20_000;
  while (Date.now() < deadline) {
    if (spawnError()) throw spawnError();
    if (child.exitCode !== null || child.signalCode !== null) {
      throw new Error(`web server exited early: ${logs()}`);
    }
    try {
      const response = await fetch(base, { signal: AbortSignal.timeout(1000) });
      if (response.ok && /Local:.*127\.0\.0\.1:/.test(logs())) return;
    } catch {
      // Vite 尚在启动，继续轮询明确的 HTTP 状态。
    }
    await new Promise((resolveDelay) => setTimeout(resolveDelay, 200));
  }
  throw new Error(`web server not ready within timeout: ${logs()}`);
}
