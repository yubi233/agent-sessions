// Web-Daemon 只读 transport：每次请求生成一次性 X25519 密钥。私钥只在本函数调用栈保留，
// 不写 sessionState、localStorage、IndexedDB 或任何可跨刷新恢复的页面状态。
import { relayURL, sessionState } from "./session";

const algorithm = "v1-x25519-hkdfsha256-aes256gcm";
const payloadVersion = 1;
const encoder = new TextEncoder();

export type WebReadKind =
  | "file.tree"
  | "file.read"
  | "code.read"
  | "git.status"
  | "git.changes"
  | "git.diff";

export interface WebReadRequest {
  path?: string;
  snapshot_token?: string;
  offset?: number;
  limit?: number;
}

export interface WebReadTransportInfo {
  terminal_id: string;
  workspace_id: string;
  encryption_public_key: string;
  algorithm: string;
}

interface RequestEnvelope {
  alg: string;
  payload_version: number;
  ephemeral_public_key: string;
  nonce: string;
  ciphertext: string;
  aad_hash: string;
}

interface ResponseEnvelope {
  alg: string;
  payload_version: number;
  nonce: string;
  ciphertext: string;
  aad_hash: string;
}

interface WebReadStatus {
  request_id: string;
  kind: WebReadKind;
  status: "accepted" | "running" | "succeeded" | "failed" | "rejected";
  error_code?: string;
  envelope?: ResponseEnvelope;
}

interface WebReadResponsePayload<T> {
  version: number;
  kind: WebReadKind;
  result: T;
}

export class WebReadTransportError extends Error {
  constructor(message: string, readonly code?: string) {
    super(message);
    this.name = "WebReadTransportError";
  }
}

// requestWebRead 是唯一允许 Web 页面发起的 POST。请求仍是严格只读：Relay 只收到临时公钥
// 可解的 envelope，服务器从 Session 推导目标 Terminal，浏览器不能提交 lease、workspace 或写 kind。
export async function requestWebRead<T>(
  sessionID: string,
  kind: WebReadKind,
  request: WebReadRequest,
  options: { pollIntervalMs?: number; timeoutMs?: number } = {},
): Promise<T> {
  const transport = await requestJSON<WebReadTransportInfo>(
    `/v1/sessions/${encodeURIComponent(sessionID)}/readonly-transport`,
  );
  if (transport.algorithm !== algorithm) {
    throw new WebReadTransportError("当前终端不支持安全只读传输");
  }
  const requestID = `webread_${crypto.randomUUID().toLowerCase()}`;
  const pair = await generateX25519Pair();
  const terminalPublic = await importX25519Public(decodeBase64(transport.encryption_public_key));
  const shared = await deriveSharedSecret(pair.privateKey, terminalPublic);
  try {
    const aad = encodeAAD({
      request_id: requestID,
      session_id: sessionID,
      workspace_id: transport.workspace_id,
      terminal_id: transport.terminal_id,
      kind,
      direction: "request",
    });
    const envelope: RequestEnvelope = {
      alg: algorithm,
      payload_version: payloadVersion,
      ephemeral_public_key: encodeBase64(new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey))),
      ...await sealPayload(shared, "request", aad, request),
    };
    await requestJSON(`/v1/sessions/${encodeURIComponent(sessionID)}/readonly-requests`, {
      method: "POST",
      body: JSON.stringify({ request_id: requestID, kind, envelope }),
    });
    const status = await pollWebReadStatus(sessionID, requestID, options);
    if (status.status !== "succeeded" || !status.envelope) {
      throw new WebReadTransportError("只读请求未返回可用结果", status.error_code);
    }
    const responseAAD = encodeAAD({
      request_id: requestID,
      session_id: sessionID,
      workspace_id: transport.workspace_id,
      terminal_id: transport.terminal_id,
      kind,
      direction: "response",
    });
    const plaintext = await openPayload(shared, "response", responseAAD, status.envelope);
    const payload = JSON.parse(new TextDecoder().decode(plaintext)) as WebReadResponsePayload<T>;
    if (payload.version !== payloadVersion || payload.kind !== kind || !("result" in payload)) {
      throw new WebReadTransportError("只读响应格式无效");
    }
    return payload.result;
  } finally {
    // Uint8Array 可以明确覆盖；CryptoKey 的私钥不可导出且在函数返回后不再被页面状态引用。
    shared.fill(0);
  }
}

async function pollWebReadStatus(sessionID: string, requestID: string, options: { pollIntervalMs?: number; timeoutMs?: number }): Promise<WebReadStatus> {
  const pollIntervalMs = options.pollIntervalMs ?? 200;
  const timeoutMs = options.timeoutMs ?? 15_000;
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const status = await requestJSON<WebReadStatus>(
      `/v1/sessions/${encodeURIComponent(sessionID)}/readonly-requests/${encodeURIComponent(requestID)}`,
    );
    if (status.status === "succeeded" || status.status === "failed" || status.status === "rejected") {
      return status;
    }
    await new Promise<void>((resolve) => window.setTimeout(resolve, pollIntervalMs));
  }
  throw new WebReadTransportError("只读请求超时");
}

async function requestJSON<T>(path: string, init: RequestInit = {}): Promise<T> {
  const headers = new Headers(init.headers);
  headers.set("Authorization", `Bearer ${sessionState.token}`);
  if (init.body && !headers.has("Content-Type")) headers.set("Content-Type", "application/json");
  const response = await fetch(`${relayURL}${path}`, { ...init, headers, cache: "no-store" });
  if (!response.ok) {
    let code: string | undefined;
    try {
      code = (await response.json() as { code?: string }).code;
    } catch {
      // 错误体不可用时只保留 HTTP 状态，避免把潜在上游文本写入浏览器状态。
    }
    throw new WebReadTransportError("只读请求被拒绝", code ?? String(response.status));
  }
  return await response.json() as T;
}

type AAD = {
  request_id: string;
  session_id: string;
  workspace_id: string;
  terminal_id: string;
  kind: WebReadKind;
  direction: "request" | "response";
};

// 字段顺序必须与 Go webReadAADPayload 一致，任何顺序/字段差异都会让 AAD hash 或 AES-GCM
// additionalData 校验失败，而不是静默把响应接到错误请求上。
function encodeAAD(aad: AAD): Uint8Array {
  return encoder.encode(JSON.stringify({
    request_id: aad.request_id,
    session_id: aad.session_id,
    workspace_id: aad.workspace_id,
    terminal_id: aad.terminal_id,
    kind: aad.kind,
    direction: aad.direction,
  }));
}

async function generateX25519Pair(): Promise<CryptoKeyPair> {
  const pair = await crypto.subtle.generateKey({ name: "X25519" }, true, ["deriveBits"]);
  if (!("privateKey" in pair) || !("publicKey" in pair)) throw new WebReadTransportError("浏览器不支持临时密钥");
  return pair;
}

async function importX25519Public(raw: Uint8Array): Promise<CryptoKey> {
  if (raw.byteLength !== 32) throw new WebReadTransportError("终端公钥格式无效");
  return crypto.subtle.importKey("raw", copyBuffer(raw), { name: "X25519" }, false, []);
}

async function deriveSharedSecret(privateKey: CryptoKey, terminalPublic: CryptoKey): Promise<Uint8Array> {
  const bits = await crypto.subtle.deriveBits({ name: "X25519", public: terminalPublic }, privateKey, 256);
  return new Uint8Array(bits);
}

async function sealPayload(shared: Uint8Array, direction: "request" | "response", aad: Uint8Array, payload: unknown): Promise<Omit<RequestEnvelope, "alg" | "payload_version" | "ephemeral_public_key">> {
  const nonce = crypto.getRandomValues(new Uint8Array(12));
  const key = await deriveAESKey(shared, direction);
  const ciphertext = await crypto.subtle.encrypt(
    { name: "AES-GCM", iv: copyBuffer(nonce), additionalData: copyBuffer(aad) },
    key,
    copyBuffer(encoder.encode(JSON.stringify(payload))),
  );
  return { nonce: encodeBase64(nonce), ciphertext: encodeBase64(new Uint8Array(ciphertext)), aad_hash: await hashHex(aad) };
}

async function openPayload(shared: Uint8Array, direction: "request" | "response", aad: Uint8Array, envelope: ResponseEnvelope): Promise<Uint8Array> {
  if (envelope.alg !== algorithm || envelope.payload_version !== payloadVersion || envelope.aad_hash !== await hashHex(aad)) {
    throw new WebReadTransportError("只读响应认证失败");
  }
  const nonce = decodeBase64(envelope.nonce);
  if (nonce.byteLength !== 12) throw new WebReadTransportError("只读响应 nonce 无效");
  const key = await deriveAESKey(shared, direction);
  try {
    const plaintext = await crypto.subtle.decrypt(
      { name: "AES-GCM", iv: copyBuffer(nonce), additionalData: copyBuffer(aad) },
      key,
      copyBuffer(decodeBase64(envelope.ciphertext)),
    );
    return new Uint8Array(plaintext);
  } catch {
    throw new WebReadTransportError("只读响应认证失败");
  }
}

async function deriveAESKey(shared: Uint8Array, direction: "request" | "response"): Promise<CryptoKey> {
  const hkdfKey = await crypto.subtle.importKey("raw", copyBuffer(shared), "HKDF", false, ["deriveBits"]);
  const bits = await crypto.subtle.deriveBits({
    name: "HKDF",
    hash: "SHA-256",
    salt: copyBuffer(encoder.encode("agent-sessions-web-read-v1")),
    info: copyBuffer(encoder.encode(direction)),
  }, hkdfKey, 256);
  return crypto.subtle.importKey("raw", bits, { name: "AES-GCM" }, false, ["encrypt", "decrypt"]);
}

async function hashHex(value: Uint8Array): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", copyBuffer(value)));
  return [...digest].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

function encodeBase64(value: Uint8Array): string {
  let binary = "";
  const chunkSize = 0x8000;
  for (let offset = 0; offset < value.length; offset += chunkSize) {
    binary += String.fromCharCode(...value.subarray(offset, Math.min(offset + chunkSize, value.length)));
  }
  return btoa(binary).replace(/=+$/, "");
}

function decodeBase64(value: string): Uint8Array {
  // Go/配对端允许标准 Base64 与 RawStdEncoding 两种公开密钥编码。标准编码的末尾 `=` 不是
  // 密文内容，不能因为浏览器只接受 raw 格式而让已配对 Terminal 的公钥在请求前失效。
  const hasPadding = value.includes("=");
  if (!/^[A-Za-z0-9+/]+={0,2}$/.test(value) || (hasPadding && value.length % 4 !== 0)) {
    throw new WebReadTransportError("密文编码无效");
  }
  const unpadded = value.replace(/=+$/, "");
  const padded = unpadded + "=".repeat((4 - unpadded.length % 4) % 4);
  try {
    const binary = atob(padded);
    return Uint8Array.from(binary, (character) => character.charCodeAt(0));
  } catch {
    throw new WebReadTransportError("密文编码无效");
  }
}

function copyBuffer(value: Uint8Array): ArrayBuffer {
  const output = new Uint8Array(value.byteLength);
  output.set(value);
  return output.buffer;
}
