// 统一管理 Vite Web 开发服务器，供 headed 浏览器回归与录屏复用。
import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const viteBin = join(ROOT, "apps", "web", "node_modules", "vite", "bin", "vite.js");

// startWeb 启动本仓库 Web 页面，并把 Relay 地址作为构建时环境变量传入。
export async function startWeb({ port = 15173, relayBase } = {}) {
  if (!existsSync(viteBin)) {
    throw new Error("Vite 未安装；请先运行 pnpm install");
  }
  const child = spawn(process.execPath, [viteBin, "--host", "127.0.0.1", "--port", String(port), "--strictPort"], {
    cwd: join(ROOT, "apps", "web"),
    env: { ...process.env, VITE_RELAY_URL: relayBase },
    stdio: ["ignore", "pipe", "pipe"],
  });
  let logs = "";
  child.stdout.on("data", (chunk) => (logs += chunk.toString()));
  child.stderr.on("data", (chunk) => (logs += chunk.toString()));
  const base = `http://127.0.0.1:${port}`;
  await waitForReady(base, child, () => logs);

  return {
    base,
    child,
    async stop() {
      if (child.exitCode !== null) return;
      child.kill("SIGTERM");
      await new Promise((resolveStop) => child.once("exit", resolveStop));
    },
  };
}

async function waitForReady(base, child, logs) {
  const deadline = Date.now() + 20_000;
  while (Date.now() < deadline) {
    if (child.exitCode !== null) {
      throw new Error(`web server exited early: ${logs()}`);
    }
    try {
      const response = await fetch(base);
      if (response.ok) return;
    } catch {
      // Vite 尚在启动，继续轮询明确的 HTTP 状态。
    }
    await new Promise((resolveDelay) => setTimeout(resolveDelay, 200));
  }
  throw new Error(`web server not ready within timeout: ${logs()}`);
}
