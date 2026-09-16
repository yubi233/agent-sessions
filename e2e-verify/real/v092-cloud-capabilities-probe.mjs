#!/usr/bin/env node
// V092-01 定向诊断：云端 Relay 能力事实源探针（v0.9.2 P0 归因，2026-09-16）。
//
// 目的：在真实云端拓扑下取证「移动端看到的 Provider 可用性来自 Relay 进程内嵌
// DSH Adapter 的 Detect」。记录 /v1/capabilities 中 dsh 的 availability/version/
// fail-closed 中文原因，以及 terminals/workspaces/sessions 的脱敏投影计数。
//
// 口径：real_upstream=true（真实公网 ECS + TLS 指纹钉扎）、fixture_data=false、
// real_browser=false、headless=false、real_model=false（全程 GET/POST 登录，
// 不触发模型调用、不消耗 token、不修改服务端业务状态）。
//
// 安全：账号凭据取自本地 600 权限文件（默认 /tmp/acc-daemon/acc.txt，格式
// "email password"）；只输出 token 是否签发（布尔），绝不输出 token/凭据/正文；
// 终端/工作区/会话 ID 一律 sha256 前 12 位再入报告。
//
// 用法：
//   node e2e-verify/real/v092-cloud-capabilities-probe.mjs \
//     --endpoint https://39.106.135.11 \
//     --tls-fingerprint 7fbaab5b1a92fa157c9b75b04faae85d5a22374345c9e9cadcbbb0c53dad003f \
//     [--account-file /tmp/acc-daemon/acc.txt] [--out-dir <dir>]
import https from "node:https";
import crypto from "node:crypto";
import { mkdirSync, writeFileSync, readFileSync } from "node:fs";
import { join } from "node:path";

const args = process.argv.slice(2);
const argOf = (flag) => {
  const i = args.indexOf(flag);
  return i >= 0 ? args[i + 1] : undefined;
};

const ENDPOINT = process.env.V092_ENDPOINT ?? argOf("--endpoint") ?? "";
const FINGERPRINT = (
  process.env.V092_TLS_FINGERPRINT ??
  argOf("--tls-fingerprint") ??
  ""
)
  .replace(/:/g, "")
  .toLowerCase();
const ACCOUNT_FILE =
  process.env.V092_ACCOUNT_FILE ?? argOf("--account-file") ?? "/tmp/acc-daemon/acc.txt";
const TOKEN_FILE = process.env.V092_TOKEN_FILE ?? argOf("--token-file") ?? "";
const TIMESTAMP = new Date().toISOString().replace(/[:.]/g, "-");
const OUT_DIR =
  process.env.V092_OUT_DIR ??
  argOf("--out-dir") ??
  join("e2e-verify/reports", TIMESTAMP, "V092-ATTRIB");

if (!ENDPOINT || !FINGERPRINT) {
  console.error(
    "用法：v092-cloud-capabilities-probe.mjs --endpoint <url> --tls-fingerprint <sha256> [--account-file <path>|--token-file <path>]",
  );
  process.exit(2);
}

// ---- 指纹钉扎 Agent（与 cloud-relay-smoke.mjs 同口径，不存在盲信）----
const pinnedAgent = new https.Agent({
  rejectUnauthorized: false,
  checkServerIdentity(_host, cert) {
    if (cert.fingerprint256?.replace(/:/g, "").toLowerCase() !== FINGERPRINT) {
      return new Error(
        `TLS 指纹不匹配：server=${cert.fingerprint256} expected=${FINGERPRINT}`,
      );
    }
    return undefined;
  },
});

// request 统一 HTTPS 请求；Authorization 只在内存使用，不落日志。
function request(method, path, { token, body } = {}) {
  return new Promise((resolve, reject) => {
    const data = body === undefined ? null : JSON.stringify(body);
    const req = https.request(
      `${ENDPOINT}${path}`,
      {
        method,
        agent: pinnedAgent,
        headers: {
          ...(data ? { "Content-Type": "application/json" } : {}),
          ...(token ? { Authorization: `Bearer ${token}` } : {}),
          ...(data ? { "Content-Length": Buffer.byteLength(data) } : {}),
        },
        timeout: 20_000,
      },
      (res) => {
        const chunks = [];
        res.on("data", (c) => chunks.push(c));
        res.on("end", () => {
          const text = Buffer.concat(chunks).toString("utf8");
          let json = null;
          try {
            json = JSON.parse(text);
          } catch {
            /* 非 JSON 响应按原样长度记录 */
          }
          resolve({ status: res.statusCode, json, textLength: text.length });
        });
      },
    );
    req.on("timeout", () => req.destroy(new Error("request timeout")));
    req.on("error", reject);
    if (data) req.write(data);
    req.end();
  });
}

const sanitizeId = (value) =>
  typeof value === "string" && value.length > 0
    ? crypto.createHash("sha256").update(value).digest("hex").slice(0, 12)
    : null;
const countBy = (items, pick) => {
  const out = {};
  for (const item of items) {
    const key = String(pick(item) ?? "unknown");
    out[key] = (out[key] ?? 0) + 1;
  }
  return out;
};

const report = {
  suite: "V092-ATTRIB-cloud-capabilities",
  case_id: "V092-01",
  status: "running",
  real_upstream: true,
  real_model: false,
  real_browser: false,
  headless: false,
  fixture_data: false,
  local_test: false,
  endpoint_host: new URL(ENDPOINT).host,
  tls_fingerprint_pinned: true,
  credential_source: "unresolved",
  started_at: new Date().toISOString(),
  checks: {},
  finding: {},
  artifacts: [],
};

function finish(status, exitCode) {
  report.status = status;
  report.finished_at = new Date().toISOString();
  mkdirSync(OUT_DIR, { recursive: true });
  const outPath = join(OUT_DIR, "cloud-capabilities-probe.json");
  report.artifacts.push(outPath);
  writeFileSync(outPath, JSON.stringify(report, null, 2) + "\n");
  console.log(
    `[v092-probe] status=${status} report=${outPath} dsh_available=${report.finding.dsh_available_in_relay_capabilities} reason=${report.finding.dsh_start_reason ?? "-"}`,
  );
  process.exit(exitCode);
}

try {
  // ---- 0. 凭据解析：token 文件直用；账号文件支持 JSON（ACC smoke 状态）与
  //         "email password" 文本（cloud-credentials.mjs 同款）两种形态 ----
  let token = "";
  let credentialSource = "";
  if (TOKEN_FILE) {
    token = readFileSync(TOKEN_FILE, "utf8").trim();
    credentialSource = `file:${TOKEN_FILE}`;
    report.credential_source = credentialSource;
    report.checks.login = { mode: "token-file", token_present: token.length > 0 };
  } else {
    credentialSource = `file:${ACCOUNT_FILE}`;
    report.credential_source = credentialSource;
    const raw = readFileSync(ACCOUNT_FILE, "utf8").trim();
    let email;
    let password;
    try {
      const parsed = JSON.parse(raw);
      email = parsed.email;
      password = parsed.password;
    } catch {
      [email, password] = raw.split(/\s+/);
    }
    // ---- 1. 账号登录（read-only 令牌足够完成全部 GET 取证）----
    const login = await request("POST", "/v1/auth/login", {
      body: { email, password },
    });
    report.checks.login = {
      mode: "password",
      status: login.status,
      token_issued: Boolean(login.json?.access_token),
      response_keys: login.json ? Object.keys(login.json).sort() : [],
    };
    token = login.json?.access_token ?? "";
  }
  if (!token) {
    finish("blocked", 1);
  }

  // ---- 2. 能力矩阵：dsh 的可用性/reason 是 P0 关键证据 ----
  const caps = await request("GET", "/v1/capabilities", { token });
  const providers = Array.isArray(caps.json?.providers) ? caps.json.providers : [];
  report.checks.capabilities = {
    status: caps.status,
    provider_count: providers.length,
    providers: providers.map((p) => ({
      kind: p.kind,
      version: p.version ?? "",
      available: Boolean(p.available),
      start_reason:
        (p.capabilities ?? []).find((c) => c.name === "start")?.reason ?? null,
      unsupported_count: (p.capabilities ?? []).filter(
        (c) => c.status === "unsupported",
      ).length,
    })),
  };

  // ---- 3. 终端投影（脱敏）----
  const terminals = await request("GET", "/v1/terminals", { token });
  const terminalRows = Array.isArray(terminals.json?.terminals)
    ? terminals.json.terminals
    : [];
  report.checks.terminals = {
    status: terminals.status,
    count: terminalRows.length,
    entries: terminalRows.map((t) => ({
      id_hash: sanitizeId(t.id),
      availability: t.availability ?? t.status ?? null,
      platform: t.platform ?? null,
    })),
  };

  // ---- 4. 工作区投影（脱敏计数）----
  const workspaces = await request("GET", "/v1/workspaces", { token });
  const workspaceRows = Array.isArray(workspaces.json?.workspaces)
    ? workspaces.json.workspaces
    : [];
  report.checks.workspaces = {
    status: workspaces.status,
    count: workspaceRows.length,
    origins: countBy(workspaceRows, (w) => w.origin),
  };

  // ---- 5. 会话投影（脱敏计数）----
  const sessions = await request("GET", "/v1/sessions", { token });
  const sessionRows = Array.isArray(sessions.json?.sessions)
    ? sessions.json.sessions
    : [];
  report.checks.sessions = {
    status: sessions.status,
    count: sessionRows.length,
    providers: countBy(sessionRows, (s) => s.provider),
    statuses: countBy(sessionRows, (s) => s.status),
  };

  // ---- 6. 归因结论：L1（能力事实源在 Relay 进程）是否成立 ----
  const dsh = providers.find((p) => p.kind === "dsh");
  const dshAvailable = dsh ? Boolean(dsh.available) : null;
  const dshReason =
    dsh?.capabilities?.find((c) => c.name === "start")?.reason ?? null;
  report.finding = {
    dsh_available_in_relay_capabilities: dshAvailable,
    dsh_version_in_relay_capabilities: dsh?.version ?? null,
    dsh_start_reason: dshReason,
    interpretation:
      dshAvailable === false
        ? "L1 成立：云端 Relay 进程内嵌 DSH Adapter 探测失败，移动端 /v1/capabilities 消费同一矩阵，composer 将显示 Provider 不可用（与真机现象一致）。"
        : "L1 不成立：云端 Relay 报告 dsh 可用；需要重新检查移动端门控链路（改用 V092-02 诊断）。",
  };
  finish("passed", 0);
} catch (error) {
  report.failure_class = "environment_or_startup_failure";
  report.error = String(error?.message ?? error);
  finish("blocked", 1);
}
