// WEB-07 headed 真实本机旅程：隔离 Relay、真实配对 X25519 密钥、Daemon 二进制和临时 Git 根
// 共同验证 browser -> Daemon -> browser 的加密只读传输。所有源文件内容只用于页面可见断言，
// 不写入报告、截图、日志或 fixture；Relay SQLite 只检查其不存在。
import { spawn } from "node:child_process";
import { generateKeyPairSync } from "node:crypto";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

import { launchHeaded, browserLabel } from "../lib/browser.mjs";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const SOURCE = "package privatefixture\nconst localOnly = true\n";
const SOURCE_PATH = "src/private.go";

export const p4WebReadTransport = {
  id: "p4-web-read-transport",
  title: "P4-D Web-Daemon 加密文件与 Git headed 旅程",
  planId: "WEB",
  async run(ctx) {
    const { relay, web, report, headless = false, fixtureAccount } = ctx;
    const errors = [];
    const notes = [];
    let browser;
    let daemon;
    let temporaryRoot;
    let webReadRequestID = "";
    try {
      const account = await fixtureAccount();
      temporaryRoot = await mkdtemp(join(tmpdir(), "agent-sessions-p4d-"));
      const workspaceRoot = join(temporaryRoot, "workspace");
      const daemonState = join(temporaryRoot, "daemon-state");
      const daemonBin = join(temporaryRoot, "agent-sessions-daemon");
      await seedGitWorkspace(workspaceRoot);
      await buildDaemon(daemonBin);

      const keys = generateTerminalTransportKeys();
      const paired = await pairTerminal(relay.base, account, keys.publicKey);
      const daemonToken = await issueTerminalToken(relay.dbPath, paired.deviceId);

      // 首次启动只完成真实 Terminal hello，令 Relay 以 Daemon 自己的设备身份分配 terminal_id。
      daemon = startDaemon({ daemonBin, daemonState, relayBase: relay.base, token: daemonToken, privateKey: keys.privateKey });
      const firstTerminal = await waitForTerminal(relay.base, account.accessToken, paired.deviceId, { daemon });
      const terminalId = firstTerminal.id;
      await daemon.stop();
      daemon = null;

      const { workspaceId, sessionId } = await createBoundSession(relay.base, account, terminalId);
      await confirmWorkspace(daemonBin, daemonState, workspaceId, workspaceRoot);

      // 第二次是实际服务请求的 Daemon 进程；它重新 hello 后才会消费浏览器的受限命令流。
      daemon = startDaemon({ daemonBin, daemonState, relayBase: relay.base, token: daemonToken, privateKey: keys.privateKey });
      // Terminal 的 online 状态会保留到 stale 窗口结束，不能把上一个已退出 Daemon 的状态当作
      // 新进程已准备好。last_seen 递增证明第二个进程实际完成了一次 Relay hello。
      await waitForTerminal(relay.base, account.accessToken, paired.deviceId, {
        daemon,
        newerThanUnixMS: firstTerminal.last_seen_unix_ms,
      });

      browser = await launchHeaded({ headless });
      const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
      const readHTTP = [];
      page.on("response", (response) => {
        const path = new URL(response.url()).pathname;
        if (path.includes("/readonly-")) readHTTP.push(`${response.request().method()} ${path.split("/").slice(-1)[0]} ${response.status()}`);
        const requestMatch = path.match(/\/readonly-requests\/(webread_[a-z0-9_-]+)$/);
        if (requestMatch) webReadRequestID = requestMatch[1];
      });
      await loginWeb(page, web.base, account);
      await assertBrowserCryptoSupport(page);
      await openSession(page, sessionId);

      await page.getByTestId("session-files-link").click();
      await waitForReadableView(page, "files-tree", "files-error", readHTTP);
      await page.getByTestId("file-entry-src").click();
      await page.getByTestId(`file-entry-${SOURCE_PATH}`).waitFor({ state: "visible", timeout: 10_000 });
      await page.getByTestId(`file-entry-${SOURCE_PATH}`).click();
      await page.getByTestId("files-code").waitFor({ state: "visible", timeout: 10_000 });
      if (!(await page.getByTestId("files-code").innerText()).includes("localOnly = true")) {
        errors.push("代码页没有展示预期的本机只读结果");
      } else {
        notes.push("headed Chrome 完成文件树与代码读取；结果由当前页面临时密钥解封");
      }
      await assertNoStoredSource(page, errors, "代码读取后");

      // Reload 会销毁 JS 模块状态和临时私钥。页面需要重新登录，旧代码不得在 DOM 或 storage 中恢复。
      await page.reload({ waitUntil: "networkidle" });
      await page.getByTestId("files-error").waitFor({ state: "visible", timeout: 10_000 });
      if ((await page.locator("body").innerText()).includes(SOURCE)) {
        errors.push("刷新后旧代码仍留在文件页 DOM");
      } else {
        notes.push("刷新后临时私钥和已解密代码均未恢复");
      }
      await assertNoStoredSource(page, errors, "刷新后");

      await loginWeb(page, web.base, account);
      await openSession(page, sessionId);
      await page.getByTestId("session-git-link").click();
      await waitForReadableView(page, "git-changes", "git-error", readHTTP);
      await page.getByTestId(`git-file-${SOURCE_PATH}`).click();
      await page.getByTestId("git-diff").waitFor({ state: "visible", timeout: 10_000 });
      if (!(await page.getByTestId("git-diff").innerText()).includes("localOnly = true")) {
        errors.push("Git Diff 没有展示预期的本机只读结果");
      } else {
        notes.push("headed Chrome 完成 Git 状态、变更与 Diff 读取");
      }
      await assertNoStoredSource(page, errors, "Git Diff 后");

      // 回到不展示内容的详情页，验证组件卸载后不把解密代码残留到当前 DOM。
      await page.getByTestId("git-back").click();
      await page.getByTestId("session-detail-meta").waitFor({ state: "visible" });
      if ((await page.locator("body").innerText()).includes(SOURCE)) {
        errors.push("离开文件/Git 页面后解密代码仍留在 DOM");
      }
      const writeControls = await page.locator("textarea, [data-testid*='send'], [data-testid*='composer'], [data-testid*='restart']").count();
      if (writeControls > 0) {
        errors.push(`Web 只读旅程出现 ${writeControls} 个写控制`);
      }
      await assertRelayDoesNotPersistSource(relay.dbPath);
      notes.push("Relay SQLite 未检出测试源文件正文或 repo-relative 路径");
      await page.close();
    } catch (error) {
      errors.push(`P4-D 浏览器旅程异常：${error instanceof Error ? error.message : String(error)}`);
      if (webReadRequestID) {
        try {
          const state = await inspectWebReadDelivery(relay.dbPath, webReadRequestID);
          notes.push(`只读命令状态：command=${state.command_status} ack=${state.ack_kind || "none"} result=${state.result_status || "none"} error=${state.error_code || "none"}`);
        } catch {
          notes.push("只读命令状态诊断不可用");
        }
      }
      if (daemon) {
        notes.push(`Daemon 进程状态：${daemon.status()}`);
      }
    } finally {
      if (browser) await browser.close();
      if (daemon) await daemon.stop();
      if (temporaryRoot) await rm(temporaryRoot, { recursive: true, force: true });
    }

    return report({
      suite: "p4-web-read-transport",
      planId: "WEB",
      status: errors.length === 0 ? "passed" : "failed",
      real_browser: !headless,
      real_model: false,
      real_upstream: false,
      fixture_data: true,
      local_test: true,
      headless: Boolean(headless),
      browser: browserLabel(headless),
      command: "node e2e-verify/run.mjs --suite p4-web-read-transport",
      test_ids: ["WEB-07"],
      artifacts: [],
      failure_class: errors.length ? "product_defect" : null,
      remaining_risk: "真实本机 Daemon、浏览器和临时 Git 根已验证；不涉及真实 Provider、生产部署、Android 或浏览器 PWA/cache。",
      notes,
      errors,
    });
  },
};

async function seedGitWorkspace(root) {
  await mkdir(join(root, "src"), { recursive: true });
  await writeFile(join(root, SOURCE_PATH), "package privatefixture\n", "utf8");
  await run("git", ["init", "-q"], { cwd: root });
  await run("git", ["config", "user.email", "fixture@example.test"], { cwd: root });
  await run("git", ["config", "user.name", "Fixture"], { cwd: root });
  await run("git", ["add", SOURCE_PATH], { cwd: root });
  await run("git", ["commit", "-qm", "initial"], { cwd: root });
  await writeFile(join(root, SOURCE_PATH), SOURCE, "utf8");
}

async function buildDaemon(output) {
  await run("go", ["build", "-o", output, "./apps/daemon"], { cwd: ROOT });
}

function generateTerminalTransportKeys() {
  const pair = generateKeyPairSync("x25519");
  const privateDer = pair.privateKey.export({ format: "der", type: "pkcs8" });
  const publicDer = pair.publicKey.export({ format: "der", type: "spki" });
  const privateRaw = privateDer.subarray(-32);
  const publicRaw = publicDer.subarray(-32);
  if (privateRaw.length !== 32 || publicRaw.length !== 32) {
    throw new Error("无法导出 X25519 原始密钥");
  }
  return { privateKey: privateRaw.toString("base64"), publicKey: publicRaw.toString("base64") };
}

async function pairTerminal(relayBase, account, encryptionPublicKey) {
  const pending = await api(relayBase, "/v1/pairing/requests", {
    token: account.accessToken,
    method: "POST",
    body: {
      role: "terminal",
      display_name: "p4d-web-read-terminal",
      platform: "test",
      identity_public_key: "p4d-e2e-identity",
      encryption_public_key: encryptionPublicKey,
    },
  });
  const device = await api(relayBase, `/v1/pairing/requests/${encodeURIComponent(pending.id)}/approve`, {
    token: account.accessToken,
    method: "POST",
  });
  if (!device.id) throw new Error("配对终端未返回 device id");
  return { deviceId: device.id };
}

async function issueTerminalToken(databasePath, deviceID) {
  const result = await run("go", ["run", "./e2e-verify/helpers/issue_terminal_token.go", "-db", databasePath, "-device", deviceID], { cwd: ROOT, capture: true });
  const token = result.stdout.trim();
  if (!token) throw new Error("临时 Terminal token 签发失败");
  return token;
}

async function inspectWebReadDelivery(databasePath, commandID) {
  const result = await run("go", ["run", "./e2e-verify/helpers/issue_terminal_token.go", "-db", databasePath, "-inspect-command", commandID], { cwd: ROOT, capture: true });
  const state = JSON.parse(result.stdout);
  if (!state || typeof state.command_status !== "string") throw new Error("malformed web read diagnostic");
  return state;
}

function startDaemon({ daemonBin, daemonState, relayBase, token, privateKey }) {
  const child = spawn(daemonBin, ["run", "--state-dir", daemonState, "--fixture-adapter"], {
    cwd: ROOT,
    env: {
      ...process.env,
      AGENT_SESSIONS_RELAY_BASE: relayBase,
      AGENT_SESSIONS_DAEMON_TOKEN: token,
      AGENT_SESSIONS_WEB_READ_PRIVATE_KEY_B64: privateKey,
    },
    stdio: ["ignore", "ignore", "pipe"],
  });
  child.stderr.resume();
  return {
    child,
    async stop() {
      if (child.exitCode !== null) return;
      child.kill("SIGTERM");
      await new Promise((resolve) => child.once("exit", resolve));
    },
    status() {
      if (child.exitCode === null) return "running";
      return child.signalCode ? `exited_by_${child.signalCode}` : `exited_${child.exitCode}`;
    },
  };
}

async function waitForTerminal(relayBase, ownerToken, deviceID, { daemon, newerThanUnixMS = 0 } = {}) {
  const deadline = Date.now() + 15_000;
  while (Date.now() < deadline) {
    if (daemon?.status() !== "running") {
      throw new Error(`Daemon 在 Relay hello 前退出：${daemon.status()}`);
    }
    const response = await fetch(`${relayBase}/v1/terminals`, { headers: { Authorization: `Bearer ${ownerToken}` } });
    if (response.ok) {
      const body = await response.json();
      const terminal = body.terminals?.find((item) => item.device_id === deviceID && item.status === "online");
      if (terminal?.id && Number(terminal.last_seen_unix_ms) > newerThanUnixMS) return terminal;
    }
    await delay(100);
  }
  throw new Error("Daemon 未在限定时间内上线");
}

async function createBoundSession(relayBase, account, terminalID) {
  const workspace = await api(relayBase, "/v1/workspaces", {
    token: account.accessToken,
    method: "POST",
    body: {
      project_id: `p4d-web-project-${Date.now()}`,
      terminal_id: terminalID,
      // Relay 只使用该测试占位根；真正路径只在下方 workspace-confirm 写入本机 Daemon state。
      canonical_root: "/fixture/p4d-web-read",
      status: "active",
    },
  });
  const session = await api(relayBase, "/v1/sessions", {
    token: account.accessToken,
    method: "POST",
    body: { workspace_id: workspace.id, provider: "fixture" },
  });
  if (!workspace.id || !session.id) throw new Error("未能创建受绑定的 P4-D 会话");
  return { workspaceId: workspace.id, sessionId: session.id };
}

async function confirmWorkspace(daemonBin, daemonState, workspaceID, workspaceRoot) {
  await run(daemonBin, ["workspace-confirm", "--state-dir", daemonState, "--workspace-id", workspaceID, "--workspace-root", workspaceRoot], { cwd: ROOT });
}

async function loginWeb(page, webBase, account) {
  await page.goto(`${webBase}/#/`, { waitUntil: "networkidle" });
  await page.getByTestId("login-email").fill(account.email);
  await page.getByTestId("login-password").fill(account.password);
  await page.getByTestId("login-submit").click();
  await page.getByTestId("auth-ok").waitFor({ state: "visible", timeout: 10_000 });
}

async function openSession(page, sessionID) {
  await page.click('a[href="#/sessions"]');
  await page.getByTestId("sessions-list").waitFor({ state: "visible", timeout: 10_000 });
  await page.getByTestId(`session-link-${sessionID}`).click();
  await page.getByTestId("session-detail-meta").waitFor({ state: "visible", timeout: 10_000 });
}

async function assertNoStoredSource(page, errors, stage) {
  const persisted = await page.evaluate(() => ({
    local: Object.values(localStorage).join("\n"),
    session: Object.values(sessionStorage).join("\n"),
  }));
  if (persisted.local.includes(SOURCE) || persisted.session.includes(SOURCE)) {
    errors.push(`${stage}时浏览器 storage 保留了解密代码`);
  }
}

async function assertBrowserCryptoSupport(page) {
  const support = await page.evaluate(async () => {
    if (!globalThis.isSecureContext || !globalThis.crypto?.subtle) {
      return { ok: false, reason: "secure_context_or_webcrypto_missing" };
    }
    try {
      const pair = await globalThis.crypto.subtle.generateKey({ name: "X25519" }, true, ["deriveBits"]);
      return { ok: "publicKey" in pair && "privateKey" in pair, reason: "x25519" };
    } catch (error) {
      return { ok: false, reason: error instanceof Error ? error.name : "x25519_failed" };
    }
  });
  if (!support.ok) throw new Error(`headed 浏览器不支持 WebCrypto X25519：${support.reason}`);
}

// waitForReadableView 在内容读取失败时只回传产品定义的可见错误文案。它避免把 HTTP body、
// source、token 或密文写入长期报告，同时让 headed 失败具备可操作的根因线索。
async function waitForReadableView(page, successTestID, errorTestID, readHTTP) {
  const success = page.getByTestId(successTestID);
  const error = page.getByTestId(errorTestID);
  let outcome;
  try {
    outcome = await Promise.race([
      success.waitFor({ state: "visible", timeout: 10_000 }).then(() => "success"),
      error.waitFor({ state: "visible", timeout: 10_000 }).then(() => "error"),
    ]);
  } catch {
    throw new Error(`${successTestID} 等待超时（只读 HTTP: ${readHTTP.join(", ") || "无响应"}）`);
  }
  if (outcome === "success") return;
  throw new Error(`${successTestID} 读取失败：${await error.innerText()}（只读 HTTP: ${readHTTP.join(", ") || "无响应"}）`);
}

async function assertRelayDoesNotPersistSource(databasePath) {
  for (const path of [databasePath, `${databasePath}-wal`, `${databasePath}-shm`]) {
    try {
      const bytes = await readFile(path);
      if (bytes.includes(Buffer.from(SOURCE)) || bytes.includes(Buffer.from(SOURCE_PATH))) {
        throw new Error("Relay SQLite 存在受保护文件内容或 repo-relative 路径");
      }
    } catch (error) {
      if (error?.code === "ENOENT") continue;
      throw error;
    }
  }
}

async function api(base, path, { token, method = "GET", body } = {}) {
  const headers = {};
  if (token) headers.Authorization = `Bearer ${token}`;
  if (body !== undefined) headers["Content-Type"] = "application/json";
  const response = await fetch(`${base}${path}`, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  if (!response.ok) throw new Error(`${method} ${path} returned ${response.status}`);
  return response.json();
}

function run(command, args, { cwd = ROOT, env = {}, capture = false } = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      cwd,
      env: { ...process.env, ...env },
      stdio: ["ignore", capture ? "pipe" : "ignore", capture ? "pipe" : "ignore"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout?.on("data", (chunk) => { stdout += String(chunk); });
    child.stderr?.on("data", (chunk) => { stderr += String(chunk); });
    child.once("error", reject);
    child.once("exit", (code) => {
      if (code === 0) resolve({ stdout, stderr });
      else reject(new Error(`${command} exited ${code}`));
    });
  });
}

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}
