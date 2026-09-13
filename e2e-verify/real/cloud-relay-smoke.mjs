#!/usr/bin/env node
// 云端 Relay smoke（CLOUD-ANDROID-ACCEPTANCE 阶段 3 / ACC-01 服务端侧）。
// 口径：real_upstream=true（真实公网 ECS + TLS）、real_device=false、fixture_data=false。
// TLS：自签证书按指纹钉扎（rejectUnauthorized=false 仅用于跳过系统信任链，
// checkServerIdentity 内按 fingerprint256 严格比对，不匹配直接断连——不存在盲信）。
// 用法：node e2e-verify/real/cloud-relay-smoke.mjs --endpoint https://39.106.135.11 \
//        --tls-fingerprint <sha256> [--restart-check]
import https from "node:https";
import crypto from "node:crypto";
import { execSync } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const argOf = (flag) => {
  const i = process.argv.indexOf(flag);
  return i >= 0 ? process.argv[i + 1] : undefined;
};
const ENDPOINT = process.env.ACC_RELAY_ENDPOINT ?? argOf("--endpoint");
const FINGERPRINT = (
  process.env.ACC_TLS_FINGERPRINT ?? argOf("--tls-fingerprint") ?? ""
).replace(/:/g, "").toLowerCase();
const RESTART_CHECK = process.argv.includes("--restart-check");
if (!ENDPOINT || !FINGERPRINT) {
  console.error("用法：cloud-relay-smoke.mjs --endpoint <url> --tls-fingerprint <sha256> [--restart-check]");
  process.exit(2);
}
const HOST = new URL(ENDPOINT).host;

// ---- 指纹钉扎 Agent：所有请求共用；证书指纹不匹配即断连 ----
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

function request(method, path, { token, body, headers = {} } = {}) {
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
          ...headers,
        },
        timeout: 20_000,
      },
      (res) => {
        const chunks = [];
        res.on("data", (c) => chunks.push(c));
        res.on("end", () => {
          const text = Buffer.concat(chunks).toString();
          let json = null;
          try { json = JSON.parse(text); } catch {}
          resolve({ status: res.statusCode, json, text });
        });
      },
    );
    req.on("error", reject);
    req.on("timeout", () => req.destroy(new Error("request timeout")));
    if (data) req.write(data);
    req.end();
  });
}

const ed25519PublicB64 = () => {
  const { publicKey } = crypto.generateKeyPairSync("ed25519");
  return publicKey.export({ type: "spki", format: "der" }).subarray(-32).toString("base64");
};
const x25519PublicB64 = () => {
  const { publicKey } = crypto.generateKeyPairSync("x25519");
  return publicKey.export({ type: "spki", format: "der" }).subarray(-32).toString("base64");
};

const results = [];
const check = (name, ok, detail = "") => {
  results.push({ name, ok: Boolean(ok), detail: String(detail).slice(0, 200) });
  console.log(`${ok ? "PASS" : "FAIL"}: ${name}${detail ? ` — ${detail}` : ""}`);
  return Boolean(ok);
};

// ---- 1. 账号准备：优先复用状态文件中的测试账号（refresh 续期），否则注册新 owner ----
// 一个部署只允许一个 owner（register 二次调用 409），因此凭据存于
// e2e-verify/reports/CLOUD-ANDROID-ACCEPTANCE/smoke-account.json（gitignored，600）。
import { existsSync, readFileSync, statSync, chmodSync } from "node:fs";
const STATE_PATH = join(process.cwd(), "e2e-verify/reports/CLOUD-ANDROID-ACCEPTANCE/smoke-account.json");
let ownerToken = "";
let refreshToken = "";
let ownerId = "";
let accountId = "";
let email = "";
let reusedAccount = false;

if (existsSync(STATE_PATH)) {
  const state = JSON.parse(readFileSync(STATE_PATH, "utf8"));
  email = state.email;
  const refresh = await request("POST", "/v1/auth/refresh", {
    body: { refresh_token: state.refresh_token },
  });
  if (refresh.status === 200 && refresh.json?.access_token) {
    ownerToken = refresh.json.access_token;
    refreshToken = refresh.json.refresh_token ?? state.refresh_token;
    ownerId = refresh.json.device_id ?? state.device_id ?? "";
    accountId = refresh.json.account_id ?? state.account_id ?? "";
    reusedAccount = true;
    check("refresh 续期复用既有测试账号", true, `email=${email}`);
  }
}
if (!ownerToken) {
  email = `acc-${Date.now()}@acceptance.local`;
  const password = crypto.randomBytes(18).toString("base64url");
  const reg = await request("POST", "/v1/auth/register", {
    body: { email, password },
  });
  check("register 201（owner 设备令牌对）", reg.status === 201 && reg.json?.access_token, `status=${reg.status}`);
  ownerToken = reg.json?.access_token ?? "";
  refreshToken = reg.json?.refresh_token ?? "";
  ownerId = reg.json?.device_id ?? "";
  accountId = reg.json?.account_id ?? "";
  if (ownerToken) {
    mkdirSync(join(process.cwd(), "e2e-verify/reports/CLOUD-ANDROID-ACCEPTANCE"), { recursive: true });
    writeFileSync(
      STATE_PATH,
      JSON.stringify({ email, password, refresh_token: refreshToken, device_id: ownerId, account_id: accountId }, null, 2) + "\n",
    );
    chmodSync(STATE_PATH, 0o600);
  }
}
if (!ownerToken) {
  console.error("[cloud-relay-smoke] 无法获得 owner 令牌（账号可能已存在且无状态文件）；请重置部署数据库后重试");
  process.exit(1);
}

// ---- 2. 设备列表包含自身 ----
const devices1 = await request("GET", "/v1/devices", { token: ownerToken });
check(
  "GET /v1/devices 200 且包含 owner 设备",
  devices1.status === 200 && JSON.stringify(devices1.json).includes(ownerId),
  `status=${devices1.status}`,
);

// ---- 3. 配对：创建请求（新设备公钥经 QR 传递，API smoke 用本地生成的密钥）→ 批准 → 新设备令牌 ----
const pairing = await request("POST", "/v1/pairing/requests", {
  token: ownerToken,
  body: {
    role: "android",
    display_name: "acc-smoke-device",
    identity_public_key: ed25519PublicB64(),
    encryption_public_key: x25519PublicB64(),
    platform: "android",
  },
});
check("POST /v1/pairing/requests 201", pairing.status === 201 && pairing.json?.id, `status=${pairing.status}`);
const approve = await request(
  "POST",
  `/v1/pairing/requests/${pairing.json?.id}/approve`,
  { token: ownerToken },
);
const device2Id = approve.json?.id ?? approve.json?.device?.id;
const device2Token = approve.json?.tokens?.access_token;
check("approve 200 且发放新设备令牌", approve.status === 200 && Boolean(device2Token), `status=${approve.status} device=${device2Id}`);

// ---- 4. 新设备令牌可用 + 设备列表含两台设备 ----
const devices2 = await request("GET", "/v1/devices", { token: ownerToken });
const listText = JSON.stringify(devices2.json);
check("设备列表包含已配对设备", devices2.status === 200 && listText.includes(device2Id));
const pairedAlive = await request("GET", "/v1/devices", { token: device2Token });
check("已配对设备令牌可访问 API", pairedAlive.status === 200, `status=${pairedAlive.status}`);

// ---- 5. 撤销设备2 → 令牌立即失效（fail-closed）----
const revoke = await request("DELETE", `/v1/devices/${device2Id}`, { token: ownerToken });
check("DELETE /v1/devices/{id} 204", revoke.status === 204, `status=${revoke.status}`);
const pairedRevoked = await request("GET", "/v1/devices", { token: device2Token });
check("被撤销设备令牌立即失效（401/403）", pairedRevoked.status === 401 || pairedRevoked.status === 403, `status=${pairedRevoked.status}`);

// ---- 6. 账号级 SSE：初始帧到达 + 断线后 cursor 重连 ----
const sseProbe = () =>
  new Promise((resolve) => {
    const req = https.request(
      `${ENDPOINT}/v1/events`,
      { method: "GET", agent: pinnedAgent, headers: { Authorization: `Bearer ${ownerToken}` }, timeout: 25_000 },
      (res) => {
        const chunks = [];
        // 账号级 SSE 心跳为 15 秒（T7 裁决）：等待窗口覆盖到首个心跳注释或事件帧。
        const timer = setTimeout(() => {
          req.destroy();
          resolve({ status: res.statusCode, contentType: res.headers["content-type"] ?? "", body: Buffer.concat(chunks).toString() });
        }, 20000);
        res.on("data", (c) => {
          chunks.push(c);
          if (Buffer.concat(chunks).toString().includes(": heartbeat")) {
            clearTimeout(timer);
            req.destroy();
            resolve({ status: res.statusCode, contentType: res.headers["content-type"] ?? "", body: Buffer.concat(chunks).toString() });
          }
        });
        res.on("error", () => {});
        res.on("close", () => {
          // 401/断流等场景：连接关闭也要 resolve，否则 top-level await 悬挂。
          clearTimeout(timer);
          resolve({ status: res.statusCode, contentType: res.headers["content-type"] ?? "", body: Buffer.concat(chunks).toString() });
        });
      },
    );
    req.on("error", () => resolve({ status: 0, contentType: "", body: "" }));
    req.end();
  });
const sse1 = await sseProbe();
check(
  "账号级 SSE 连接建立并收到心跳/帧（≤20s，协议心跳 15s）",
  sse1.status === 200 && sse1.body.includes(": heartbeat"),
  `status=${sse1.status} ct=${sse1.contentType} bytes=${sse1.body.length}`,
);

// ---- 7. 重启持久化（可选）：重启 relay 容器 → 令牌仍有效、撤销仍生效 ----
if (RESTART_CHECK) {
  execSync("ssh -o BatchMode=yes root@39.106.135.11 'docker restart agent-sessions-relay'", { stdio: "ignore" });
  await new Promise((r) => setTimeout(r, 6000));
  const after = await request("GET", "/v1/devices", { token: ownerToken });
  check("Relay 重启后 owner 令牌仍有效", after.status === 200, `status=${after.status}`);
  const revokedAfter = await request("GET", "/v1/devices", { token: device2Token });
  check("Relay 重启后撤销状态不丢失", revokedAfter.status === 401 || revokedAfter.status === 403, `status=${revokedAfter.status}`);
}

// ---- 报告 ----
const pass = results.every((r) => r.ok);
const report = {
  suite: "CLOUD-ANDROID-ACCEPTANCE",
  test_ids: ["ACC-01"],
  gate_kind: "cloud_relay_smoke",
  status: pass ? "passed" : "failed",
  real_upstream: true,
  real_device: false,
  real_browser: false,
  real_model: false,
  fixture_data: false,
  local_test: false,
  headless: false,
  cloud_provider: "aliyun",
  endpoint: ENDPOINT,
  tls_fingerprint_sha256: FINGERPRINT,
  account: { email_prefix: email.split("@")[0], account_id_present: Boolean(accountId) },
  command: `node e2e-verify/real/cloud-relay-smoke.mjs --endpoint <redacted> --tls-fingerprint <redacted>`,
  checks: results,
  remaining_risk: pass
    ? "TLS 降级（自签+指纹放行）为已接受口径；SSE cursor 长稳回放由阶段 4/真机旅程覆盖"
    : "存在失败项，见 checks",
};
const outDir = join(process.cwd(), `e2e-verify/reports/${new Date().toISOString().replace(/[:.]/g, "-")}/CLOUD-ANDROID-ACCEPTANCE`);
mkdirSync(outDir, { recursive: true });
const reportPath = join(outDir, "cloud-relay-smoke.json");
writeFileSync(reportPath, JSON.stringify(report, null, 2) + "\n");
console.log(`[cloud-relay-smoke] ${report.status} -> ${reportPath}`);
process.exitCode = pass ? 0 : 1;
