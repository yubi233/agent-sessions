// v0.7 真实链路共享 harness。
//
// 这里的职责是把“官方 Zen Free 目录 → 本机 OpenCode 目录 → Relay → Daemon →
// OpenCode Adapter”串成一个可重复、可清理的本地测试拓扑。harness 只保留白名单
// 摘要（模型 ID、事件类型、长度、哈希、usage），绝不把 token、prompt、回复正文或
// 完整会话/命令标识写进报告。
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, dirname, relative } from "node:path";
import { fileURLToPath } from "node:url";

import { startOpenCodeServe } from "../lib/opencode.mjs";
import { startRelay } from "../lib/relay.mjs";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
export const ZEN_MODELS_URL = "https://opencode.ai/zen/v1/models";
export const ZEN_PROVIDER_IDS = Object.freeze(["opencode", "opencode-zen", "zen"]);
export const DEFAULT_SMOKE_TIMEOUT_MS = 180_000;
export const FAILURE_CLASSES = Object.freeze([
  "provider_http_error",
  "provider_timeout",
  "model_contract_failure",
  "model_flakiness",
  "credential_or_quota_blocker",
  "environment_or_startup_failure",
  "test_harness_defect",
]);

export class V07HarnessError extends Error {
  constructor(message, { failureClass = "test_harness_defect", status = 0, details = null } = {}) {
    super(message);
    this.name = "V07HarnessError";
    this.failureClass = failureClass;
    this.status = status;
    this.details = details;
  }
}
export function sha256(value) {
  return createHash("sha256").update(String(value), "utf8").digest("hex");
}

export function shortHash(value) {
  return `sha256:${sha256(value).slice(0, 16)}`;
}

// 子进程只接收本轮测试需要的非敏感环境和 OpenCode 服务鉴权变量。
// API key 不从配置文件读取到 Node；OpenCode CLI 自己在本机认证目录内完成 provider 鉴权。
export function safeProcessEnvironment(extra = {}) {
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
  return {
    ...Object.fromEntries(
      names
        .filter((name) => typeof process.env[name] === "string")
        .map((name) => [name, process.env[name]]),
    ),
    ...extra,
  };
}

function safeErrorSummary(error) {
  return String(error instanceof Error ? error.message : error)
    .replace(/(bearer\s+)[^\s"']+/gi, "$1[REDACTED]")
    .replace(/((?:api[_-]?key|token|password|secret)\s*[:=]\s*)[^\s,}"']+/gi, "$1[REDACTED]")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 600);
}

function isTimeoutError(error) {
  return error?.name === "TimeoutError" || error?.code === "ETIMEDOUT";
}

// 统一 JSON 请求：错误只带 HTTP 状态，不读取或打印可能含正文/凭据的响应体。
export async function requestJson(base, path, { token, method = "GET", body, timeoutMs = 30_000 } = {}) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const headers = { Accept: "application/json" };
    if (token) headers.Authorization = `Bearer ${token}`;
    if (body !== undefined) headers["Content-Type"] = "application/json";
    const response = await fetch(`${String(base).replace(/\/$/, "")}${path}`, {
      method,
      headers,
      body: body === undefined ? undefined : JSON.stringify(body),
      signal: controller.signal,
    });
    if (!response.ok) {
      throw new V07HarnessError(`${method} ${path} 返回 HTTP ${response.status}`, {
        failureClass: response.status === 401 || response.status === 403
          ? "credential_or_quota_blocker"
          : response.status === 408 || response.status === 429 || response.status >= 500
            ? "provider_timeout"
            : "provider_http_error",
        status: response.status,
      });
    }
    if (response.status === 204) return {};
    try {
      return await response.json();
    } catch (error) {
      throw new V07HarnessError(`${method} ${path} 响应不是 JSON`, {
        failureClass: "test_harness_defect",
        details: { parse_error: safeErrorSummary(error) },
      });
    }
  } catch (error) {
    if (error instanceof V07HarnessError) throw error;
    if (isTimeoutError(error) || error?.name === "AbortError") {
      throw new V07HarnessError(`${method} ${path} 请求超时`, { failureClass: "provider_timeout" });
    }
    throw new V07HarnessError(`${method} ${path} 网络请求失败`, {
      failureClass: "environment_or_startup_failure",
      details: { error: safeErrorSummary(error) },
    });
  } finally {
    clearTimeout(timer);
  }
}

function modelIdFromOfficialEntry(entry) {
  if (!entry || typeof entry !== "object") return "";
  const id = typeof entry.id === "string" ? entry.id.trim() : "";
  if (!id || /[\r\n\t/]/.test(id)) return "";
  // Zen 目录当前以 -free 标记轮换条目，big-pickle 是官方特殊免费条目。
  // 若未来 API 增加 free/pricing 字段，只在明确零价或 free=true 时接纳，
  // 不根据普通模型名称猜测价格。
  const explicitFree = entry.free === true || entry.is_free === true || entry.free === "true";
  const pricing = entry.pricing ?? entry.cost;
  const zeroPriced = pricing && typeof pricing === "object" &&
    Number(pricing.input ?? pricing.prompt ?? NaN) === 0 &&
    Number(pricing.output ?? pricing.completion ?? NaN) === 0;
  if (id === "big-pickle" || /-free$/i.test(id) || explicitFree || zeroPriced) return id;
  return "";
}

// 读取官方目录只保留排序后的免费 ID 与哈希；响应正文不写入日志或报告。
export async function discoverOfficialZenFreeModels({ url = ZEN_MODELS_URL, timeoutMs = 20_000 } = {}) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(url, { headers: { Accept: "application/json" }, signal: controller.signal });
    if (!response.ok) {
      throw new V07HarnessError(`官方 Zen 目录返回 HTTP ${response.status}`, {
        failureClass: response.status === 429 || response.status >= 500 ? "provider_timeout" : "provider_http_error",
        status: response.status,
      });
    }
    const payload = await response.json();
    if (!payload || !Array.isArray(payload.data)) {
      throw new V07HarnessError("官方 Zen 目录缺少 data 数组", { failureClass: "provider_http_error" });
    }
    const ids = [...new Set(payload.data.map(modelIdFromOfficialEntry).filter(Boolean))].sort();
    if (ids.length === 0) {
      throw new V07HarnessError("官方 Zen 目录没有可识别的免费模型", { failureClass: "provider_http_error" });
    }
    return {
      ids,
      count: ids.length,
      catalog_sha256: sha256(ids.join("\n")),
      source: url,
    };
  } catch (error) {
    if (error instanceof V07HarnessError) throw error;
    if (error?.name === "AbortError") {
      throw new V07HarnessError("官方 Zen 目录请求超时", { failureClass: "provider_timeout" });
    }
    throw new V07HarnessError("官方 Zen 目录网络不可用", {
      failureClass: "environment_or_startup_failure",
      details: { error: safeErrorSummary(error) },
    });
  } finally {
    clearTimeout(timer);
  }
}

function localProviderModels(payload) {
  if (!payload || typeof payload !== "object") return [];
  const providers = Array.isArray(payload.providers) && payload.providers.length > 0
    ? payload.providers
    : Array.isArray(payload.all) ? payload.all : [];
  const out = [];
  for (const provider of providers) {
    if (!provider || typeof provider !== "object") continue;
    const providerID = String(provider.id ?? "").trim().toLowerCase();
    if (!ZEN_PROVIDER_IDS.includes(providerID)) continue;
    const models = provider.models && typeof provider.models === "object" ? provider.models : {};
    for (const [mapID, raw] of Object.entries(models)) {
      const item = raw && typeof raw === "object" ? raw : {};
      const modelID = String(item.id ?? mapID).trim();
      if (!modelID || /[\r\n\t/]/.test(modelID)) continue;
      const effectiveProvider = String(item.providerID ?? providerID).trim().toLowerCase() || providerID;
      if (ZEN_PROVIDER_IDS.includes(effectiveProvider)) {
        out.push({ provider: effectiveProvider, id: modelID });
      }
    }
  }
  return out;
}

// 查询本机 OpenCode 的已连接 provider 目录，并与官方 Free ID 求交集。
// 只读取 provider/model/status/cost 白名单字段，永不把原始 provider 配置返回给调用方。
export async function discoverLocalZenFreeModels({ base, username = "opencode", password = "", official, timeoutMs = 20_000 } = {}) {
  if (!base || !official?.ids?.length) {
    throw new V07HarnessError("本机 Zen 目录发现参数不完整", { failureClass: "test_harness_defect" });
  }
  const headers = { Accept: "application/json" };
  if (password) headers.Authorization = `Basic ${Buffer.from(`${username}:${password}`).toString("base64")}`;
  let payload;
  let firstError = null;
  for (const path of ["/config/providers", "/provider"]) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    try {
      const response = await fetch(`${String(base).replace(/\/$/, "")}${path}`, { headers, signal: controller.signal });
      if (!response.ok) {
        firstError = new V07HarnessError(`本机 OpenCode ${path} 返回 HTTP ${response.status}`, {
          failureClass: response.status === 401 || response.status === 403 ? "credential_or_quota_blocker" : "provider_http_error",
          status: response.status,
        });
        continue;
      }
      payload = await response.json();
      if (localProviderModels(payload).length > 0) break;
    } catch (error) {
      firstError = error?.name === "AbortError"
        ? new V07HarnessError(`本机 OpenCode ${path} 请求超时`, { failureClass: "provider_timeout" })
        : new V07HarnessError(`本机 OpenCode ${path} 网络失败`, {
          failureClass: "environment_or_startup_failure",
          details: { error: safeErrorSummary(error) },
        });
    } finally {
      clearTimeout(timer);
    }
  }
  const local = localProviderModels(payload);
  const officialSet = new Set(official.ids);
  const options = [...new Set(local.filter((item) => officialSet.has(item.id)).map((item) => `${item.provider}/${item.id}`))].sort();
  if (options.length === 0) {
    // 服务健康但没有已认证的 Zen provider，通常是未完成 opencode auth login 或额度/权限不可用。
    throw new V07HarnessError("本机 OpenCode 未发现与官方目录交集的 Zen 免费模型", {
      failureClass: firstError?.failureClass === "credential_or_quota_blocker"
        ? "credential_or_quota_blocker"
        : "credential_or_quota_blocker",
      details: {
        local_provider_count: local.length,
        official_free_count: official.ids.length,
      },
    });
  }
  return {
    options,
    count: options.length,
    local_catalog_sha256: sha256(options.join("\n")),
    endpoints_tried: ["/config/providers", "/provider"],
  };
}

export function chooseZenModel(options, configured = process.env.AGENT_SESSIONS_OPENCODE_DEFAULT_MODEL) {
  const sorted = [...new Set((options ?? []).map((value) => String(value).trim()).filter(Boolean))].sort();
  if (sorted.length === 0) {
    throw new V07HarnessError("Zen 免费模型选项为空", { failureClass: "credential_or_quota_blocker" });
  }
  const candidate = String(configured ?? "").trim();
  return candidate && sorted.includes(candidate) ? candidate : sorted[0];
}

async function runProcess(file, args, { cwd = ROOT, env = safeProcessEnvironment(), timeoutMs = 60_000 } = {}) {
  return new Promise((resolve) => {
    let stdout = "";
    let stderr = "";
    let timedOut = false;
    let spawnFailure = null;
    const child = spawn(file, args, { cwd, env, stdio: ["ignore", "pipe", "pipe"] });
    const append = (target, chunk) => {
      // 诊断只保留有限长度；不会把原始 provider 输出写到报告。
      const value = String(chunk);
      return (target + value).slice(-16_384);
    };
    child.stdout.on("data", (chunk) => { stdout = append(stdout, chunk); });
    child.stderr.on("data", (chunk) => { stderr = append(stderr, chunk); });
    child.once("error", (error) => { spawnFailure = error; });
    const timer = setTimeout(() => {
      timedOut = true;
      if (child.exitCode === null) child.kill("SIGTERM");
    }, timeoutMs);
    child.once("close", (code, signal) => {
      clearTimeout(timer);
      resolve({ child, code, signal, stdout, stderr, timedOut, spawnFailure });
    });
  });
}

async function buildDaemon(binaryDir) {
  const binary = join(binaryDir, "daemon");
  const result = await runProcess("go", ["build", "-o", binary, "./apps/daemon"], {
    cwd: ROOT,
    env: safeProcessEnvironment(),
    timeoutMs: 120_000,
  });
  if (result.spawnFailure || result.timedOut || result.code !== 0) {
    throw new V07HarnessError("Daemon 构建失败", {
      failureClass: "environment_or_startup_failure",
      details: { exit_code: result.code, timed_out: result.timedOut },
    });
  }
  return binary;
}

async function postOwner(base, token, path, body) {
  return requestJson(base, path, { token, method: "POST", body });
}

async function registerOwner(relayBase) {
  const email = `v07-${Date.now()}-${Math.random().toString(16).slice(2)}@test.dev`;
  const response = await postOwner(relayBase, "", "/v1/auth/register", {
    email,
    password: "v07-local-test-pass-123",
  });
  if (!response.access_token) {
    throw new V07HarnessError("Relay owner 注册响应缺少 access token", { failureClass: "test_harness_defect" });
  }
  return { accessToken: response.access_token, refreshToken: response.refresh_token };
}

async function pairTerminal(relayBase, ownerToken) {
  // pairing 只需要非空公钥形状；smoke 不启用签名模式，私钥不会生成或落盘。
  const request = await postOwner(relayBase, ownerToken, "/v1/pairing/requests", {
    role: "terminal",
    display_name: "v07-real-smoke-terminal",
    platform: "darwin",
    identity_public_key: `v07-smoke-key-${sha256(String(Date.now())).slice(0, 24)}`,
    encryption_public_key: "v07-smoke-encryption-key",
  });
  if (!request.id) {
    throw new V07HarnessError("Terminal pairing 响应缺少 id", { failureClass: "test_harness_defect" });
  }
  const approved = await postOwner(relayBase, ownerToken, `/v1/pairing/requests/${encodeURIComponent(request.id)}/approve`);
  if (!approved.id || !approved.tokens?.access_token) {
    throw new V07HarnessError("Terminal pairing approval 响应不完整", { failureClass: "test_harness_defect" });
  }
  return {
    deviceId: approved.id,
    token: approved.tokens.access_token,
  };
}

async function waitForTerminal(relayBase, ownerToken, deviceId, timeoutMs = 30_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const body = await requestJson(relayBase, "/v1/terminals", { token: ownerToken, timeoutMs: 10_000 });
    const terminals = Array.isArray(body.terminals) ? body.terminals : [];
    const terminal = terminals.find((item) => item.device_id === deviceId || item.id === deviceId);
    if (terminal?.status === "online") return terminal;
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  throw new V07HarnessError("Daemon Terminal 未在期限内上线", { failureClass: "environment_or_startup_failure" });
}

function opaqueSessionEnvelope({ kind, sessionId, provider, model, message, workspaceRoot = "" }) {
  const fixturePayload = { session_id: sessionId, provider, model };
  if (message !== undefined) fixturePayload.message = message;
  return {
    kind,
    session_id: sessionId,
    workspace_root: workspaceRoot,
    provider,
    model,
    ciphertext: { fixture_payload: fixturePayload },
  };
}

async function waitCommand(relayBase, ownerToken, commandId, timeoutMs = 30_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const command = await requestJson(relayBase, `/v1/commands/${encodeURIComponent(commandId)}`, { token: ownerToken, timeoutMs: 10_000 });
    if (["succeeded", "failed", "rejected", "cancelled", "expired"].includes(command.status)) return command;
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  throw new V07HarnessError("Relay command 未在期限内收口", { failureClass: "provider_timeout" });
}

function fixturePayloadFromEnvelope(envelope) {
  if (!envelope || typeof envelope !== "object") return null;
  if (envelope.fixture_payload && typeof envelope.fixture_payload === "object") return envelope.fixture_payload;
  return null;
}

function snapshotSummary(snapshot) {
  const events = Array.isArray(snapshot?.events) ? snapshot.events : [];
  const eventTypes = [...new Set(events.map((event) => String(event?.event_type ?? "")).filter(Boolean))];
  const assistantTexts = [];
  let idleTerminal = false;
  for (const event of events) {
    if (event?.event_type === "turn.completed" && String(event?.terminal_status ?? "") === "idle") {
      idleTerminal = true;
    }
    const payload = fixturePayloadFromEnvelope(event?.envelope);
    if (payload?.kind === "assistant_message" && typeof payload.text === "string" && payload.text.trim()) {
      assistantTexts.push(payload.text);
    }
  }
  return {
    eventTypes,
    assistantTexts,
    assistantTextLength: assistantTexts.reduce((sum, value) => sum + value.length, 0),
    assistantTextHash: assistantTexts.length ? shortHash(assistantTexts.join("\n")) : null,
    hasMessageCompleted: eventTypes.includes("message.completed"),
    hasTurnCompleted: eventTypes.includes("turn.completed"),
    idleTerminal,
    sessionStatus: String(snapshot?.session?.status ?? ""),
    lastSeq: Number(snapshot?.session?.last_seq ?? 0) || 0,
  };
}

async function waitForTurn(relayBase, ownerToken, sessionId, { timeoutMs = DEFAULT_SMOKE_TIMEOUT_MS, afterSeq = 0 } = {}) {
  const deadline = Date.now() + timeoutMs;
  let latest = null;
  while (Date.now() < deadline) {
    const snapshot = await requestJson(
      relayBase,
      `/v1/sessions/${encodeURIComponent(sessionId)}/snapshot?after_seq=${Math.max(0, afterSeq)}`,
      { token: ownerToken, timeoutMs: 15_000 },
    );
    latest = snapshotSummary(snapshot);
    if (latest.hasMessageCompleted && latest.hasTurnCompleted && latest.idleTerminal && latest.sessionStatus === "idle") {
      return { snapshot, summary: latest };
    }
    await new Promise((resolve) => setTimeout(resolve, 500));
  }
  throw new V07HarnessError("真实模型回合未出现 message.completed + turn.completed(idle)", {
    failureClass: "provider_timeout",
    details: latest ? {
      event_types: latest.eventTypes,
      session_status: latest.sessionStatus,
      last_seq: latest.lastSeq,
    } : null,
  });
}

async function waitForUsage(relayBase, ownerToken, sessionId, timeoutMs = 20_000) {
  const deadline = Date.now() + timeoutMs;
  let latest = null;
  while (Date.now() < deadline) {
    latest = await requestJson(relayBase, `/v1/sessions/${encodeURIComponent(sessionId)}/controls`, { token: ownerToken, timeoutMs: 10_000 });
    const usage = latest?.usage;
    if (usage && Number(usage.input_tokens) > 0 && Number(usage.output_tokens) > 0) return latest;
    await new Promise((resolve) => setTimeout(resolve, 500));
  }
  throw new V07HarnessError("真实回合未产生正数 usage 投影", {
    failureClass: "model_contract_failure",
    details: {
      input_tokens: Number(latest?.usage?.input_tokens) || 0,
      output_tokens: Number(latest?.usage?.output_tokens) || 0,
    },
  });
}

async function startDaemon(binary, { relayBase, terminal, opencodeBase, model, workspaceRoot, stateDir }) {
  const env = safeProcessEnvironment({
    AGENT_SESSIONS_OPENCODE_URL: opencodeBase,
    AGENT_SESSIONS_EVENT_LOCAL_DEV_PLAINTEXT: "1",
    AGENT_SESSIONS_WORKSPACE_ROOT: workspaceRoot,
    AGENT_SESSIONS_OPENCODE_DEFAULT_MODEL: model,
    // 测试拓扑明确使用 bearer 双轨；不读取调用者可能遗留的 required 配置。
    AGENT_SESSIONS_TERMINAL_SIGNATURE_MODE: "optional",
    ...(process.env.OPENCODE_SERVER_USERNAME ? { OPENCODE_SERVER_USERNAME: process.env.OPENCODE_SERVER_USERNAME } : {}),
    ...(process.env.OPENCODE_SERVER_PASSWORD ? { OPENCODE_SERVER_PASSWORD: process.env.OPENCODE_SERVER_PASSWORD } : {}),
  });
  const child = spawn(binary, [
    "run",
    "--relay-base",
    relayBase,
    "--access-token",
    terminal.token,
    "--state-dir",
    stateDir,
  ], { cwd: ROOT, env, stdio: ["ignore", "pipe", "pipe"] });
  let stdout = "";
  let stderr = "";
  child.stdout.on("data", (chunk) => { stdout = `${stdout}${String(chunk)}`.slice(-16_384); });
  child.stderr.on("data", (chunk) => { stderr = `${stderr}${String(chunk)}`.slice(-16_384); });
  child.once("error", () => {});
  return {
    child,
    logs: () => ({ stdout: shortHash(stdout), stderr: shortHash(stderr) }),
    async stop() {
      if (child.exitCode !== null) return;
      child.kill("SIGTERM");
      await new Promise((resolve) => {
        const timer = setTimeout(() => {
          if (child.exitCode === null) child.kill("SIGKILL");
        }, 3_000);
        child.once("exit", () => { clearTimeout(timer); resolve(); });
      });
    },
  };
}

// runZenSessionSmoke 执行 P3 唯一允许的真实模型单轮往返。
// 返回的对象只含报告安全摘要；内部 token/正文变量在本函数外不可见。
export async function runZenSessionSmoke({
  timeoutMs = DEFAULT_SMOKE_TIMEOUT_MS,
  keepArtifacts = false,
  model: requestedModel = "",
} = {}) {
  const rootTemp = await mkdtemp(join(tmpdir(), "agent-sessions-v07-smoke-"));
  const daemonState = join(rootTemp, "daemon-state");
  const workspaceRoot = join(rootTemp, "workspace-root");
  const binaryDir = join(rootTemp, "bin");
  await mkdir(daemonState, { recursive: true });
  await mkdir(workspaceRoot, { recursive: true });
  await mkdir(binaryDir, { recursive: true });

  let opencode = null;
  let relay = null;
  let daemon = null;
  let owner = null;
  let terminal = null;
  let model = requestedModel;
  let modelCatalog = null;
  let officialCatalog = null;
  let sessionId = "";
  const startedAt = Date.now();
  const report = {
    topology: "official-zen-catalog -> opencode-serve -> relay -> daemon -> adapter",
    auth_mode: null,
    official_catalog: null,
    local_catalog: null,
    request_attempts: 0,
    command_kinds: [],
    event_types: [],
    assistant_text_length: 0,
    assistant_text_sha256: null,
    terminal_status: null,
    session_status: null,
    session_last_seq: 0,
    usage: { input_tokens: 0, output_tokens: 0 },
    daemon_logs_sha256: null,
  };

  try {
    officialCatalog = await discoverOfficialZenFreeModels();
    report.official_catalog = {
      count: officialCatalog.count,
      sha256: officialCatalog.catalog_sha256,
      source: ZEN_MODELS_URL,
    };

    opencode = await startOpenCodeServe();
    report.auth_mode = opencode.auth_mode;
    modelCatalog = await discoverLocalZenFreeModels({
      base: opencode.base,
      username: opencode.username,
      password: process.env.OPENCODE_SERVER_PASSWORD || "",
      official: officialCatalog,
    });
    report.local_catalog = {
      count: modelCatalog.count,
      sha256: modelCatalog.local_catalog_sha256,
      endpoints: modelCatalog.endpoints_tried,
    };
    model = chooseZenModel(modelCatalog.options, requestedModel);

    relay = await startRelay({
      env: {
        AGENT_SESSIONS_OPENCODE_URL: opencode.base,
        AGENT_SESSIONS_TERMINAL_SIGNATURE_MODE: "optional",
      },
    });
    owner = await registerOwner(relay.base);
    terminal = await pairTerminal(relay.base, owner.accessToken);
    const binary = await buildDaemon(binaryDir);
    daemon = await startDaemon(binary, {
      relayBase: relay.base,
      terminal,
      opencodeBase: opencode.base,
      model,
      workspaceRoot,
      stateDir: daemonState,
    });
    await waitForTerminal(relay.base, owner.accessToken, terminal.deviceId);

    // 先通过 v0.7 create-with-folder 命令创建隔离 Git 工作区，证明 daemon 本机授权根边界。
    const folderName = `v07-smoke-${Date.now().toString(36)}`;
    const workspaceCreate = await postOwner(relay.base, owner.accessToken, "/v1/workspaces/create-with-folder", { name: folderName });
    report.command_kinds.push("workspace.create");
    const workspaceCommand = workspaceCreate.command_id ? await waitCommand(relay.base, owner.accessToken, workspaceCreate.command_id) : workspaceCreate;
    if (workspaceCommand.status !== "succeeded" && workspaceCreate.status !== "succeeded") {
      throw new V07HarnessError("workspace.create 未成功收口", {
        failureClass: "product_defect",
        details: { status: workspaceCommand.status ?? workspaceCreate.status },
      });
    }
    const workspaceId = workspaceCreate.workspace_id || workspaceCommand.workspace_id;
    if (!workspaceId) throw new V07HarnessError("workspace.create 成功响应缺少 workspace_id", { failureClass: "test_harness_defect" });

    const session = await postOwner(relay.base, owner.accessToken, "/v1/sessions", {
      workspace_id: workspaceId,
      provider: "opencode",
    });
    sessionId = session.id;
    if (!sessionId) throw new V07HarnessError("创建 OpenCode session 响应缺少 id", { failureClass: "test_harness_defect" });
    const terminalView = await waitForTerminal(relay.base, owner.accessToken, terminal.deviceId);
    const lease = await postOwner(relay.base, owner.accessToken, `/v1/sessions/${encodeURIComponent(sessionId)}/lease`);
    const leaseEpoch = Number(lease.lease_epoch);
    if (!Number.isInteger(leaseEpoch) || leaseEpoch <= 0) throw new V07HarnessError("session lease 不合法", { failureClass: "product_defect" });

    const startEnvelope = opaqueSessionEnvelope({ kind: "session.start", sessionId, provider: "opencode", model });
    const startCommand = await postOwner(relay.base, owner.accessToken, `/v1/sessions/${encodeURIComponent(sessionId)}/commands`, {
      kind: "session.start",
      idempotency_key: `v07-smoke-start-${Date.now()}`,
      lease_epoch: leaseEpoch,
      target_terminal_id: terminalView.id,
      ciphertext: startEnvelope,
    });
    report.command_kinds.push("session.start");
    report.request_attempts += 1;
    const startResult = await waitCommand(relay.base, owner.accessToken, startCommand.id);
    if (startResult.status !== "succeeded") throw new V07HarnessError("session.start 未成功", { failureClass: "product_defect" });

    const safeQuestion = "请回答一个无敏感内容的固定测试问题：2 加 2 等于多少？请用一句简短中文回答。";
    const sendEnvelope = opaqueSessionEnvelope({ kind: "session.send", sessionId, provider: "opencode", model, message: safeQuestion });
    const sendCommand = await postOwner(relay.base, owner.accessToken, `/v1/sessions/${encodeURIComponent(sessionId)}/commands`, {
      kind: "session.send",
      idempotency_key: `v07-smoke-send-${Date.now()}`,
      lease_epoch: leaseEpoch,
      target_terminal_id: terminalView.id,
      ciphertext: sendEnvelope,
    });
    report.command_kinds.push("session.send");
    report.request_attempts += 1;
    const sendResult = await waitCommand(relay.base, owner.accessToken, sendCommand.id, 30_000);
    if (sendResult.status !== "succeeded") throw new V07HarnessError("session.send 未成功", { failureClass: "product_defect" });

    const turn = await waitForTurn(relay.base, owner.accessToken, sessionId, { timeoutMs });
    const controls = await waitForUsage(relay.base, owner.accessToken, sessionId);
    report.event_types = turn.summary.eventTypes;
    report.assistant_text_length = turn.summary.assistantTextLength;
    report.assistant_text_sha256 = turn.summary.assistantTextHash;
    report.terminal_status = turn.summary.idleTerminal ? "idle" : null;
    report.session_status = turn.summary.sessionStatus;
    report.session_last_seq = turn.summary.lastSeq;
    report.usage = {
      input_tokens: Number(controls.usage?.input_tokens) || 0,
      output_tokens: Number(controls.usage?.output_tokens) || 0,
    };
    if (!report.assistant_text_length || !report.usage.input_tokens || !report.usage.output_tokens) {
      throw new V07HarnessError("真实模型 smoke 断言未满足", { failureClass: "model_contract_failure" });
    }
    report.terminal_id_hash = shortHash(terminalView.id);
    report.session_id_hash = shortHash(sessionId);
    report.model = model;
    report.provider = "opencode";
    report.duration_ms = Date.now() - startedAt;
    return { model, report, attempts: report.request_attempts };
  } catch (error) {
    if (daemon) report.daemon_logs_sha256 = daemon.logs();
    if (error instanceof V07HarnessError) throw Object.assign(error, { report, model, attempts: report.request_attempts });
    throw Object.assign(new V07HarnessError("v0.7 smoke harness 未预期异常", {
      failureClass: "test_harness_defect",
      details: { error: safeErrorSummary(error) },
    }), { report, model, attempts: report.request_attempts });
  } finally {
    if (daemon) await daemon.stop().catch(() => {});
    if (relay) await relay.stop().catch(() => {});
    if (opencode) await opencode.stop().catch(() => {});
    if (!keepArtifacts) await rm(rootTemp, { recursive: true, force: true }).catch(() => {});
    else report.artifact_root = relative(ROOT, rootTemp);
  }
}

export function classifyHarnessError(error) {
  const failureClass = error instanceof V07HarnessError && FAILURE_CLASSES.includes(error.failureClass)
    ? error.failureClass
    : "test_harness_defect";
  const status = failureClass === "credential_or_quota_blocker" ? "blocked" : "failed";
  return {
    status,
    failure_class: failureClass,
    remaining_risk: safeErrorSummary(error),
    details: error instanceof V07HarnessError ? error.details : null,
  };
}
