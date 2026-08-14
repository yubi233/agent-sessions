export const AlgorithmVersion = "v1-aes256gcm-hkdfsha256";

export interface AAD {
  entity_id: string;
  event_type: string;
  protocol_version: number;
  event_seq: number;
  key_id: string;
}

export interface Envelope {
  alg: string;
  key_id: string;
  nonce: string;
  ciphertext: string;
  aad_hash: string;
  payload_version: number;
}

function b64encode(buf: Uint8Array): string {
  return Buffer.from(buf).toString("base64url").replace(/=+$/, "");
}

function b64decode(s: string): Uint8Array<ArrayBuffer> {
  const pad = s.length % 4 === 0 ? "" : "=".repeat(4 - (s.length % 4));
  return Uint8Array.from(Buffer.from(s + pad, "base64url"));
}

// toArrayBuffer 将任意 Uint8Array（含 Node Buffer）复制为独立 ArrayBuffer，
// 以满足 WebCrypto 对 ArrayBuffer-backed BufferSource 的类型约束。
function toArrayBuffer(data: Uint8Array): ArrayBuffer {
  const ab = new ArrayBuffer(data.byteLength);
  new Uint8Array(ab).set(data);
  return ab;
}

// 与 Go encoding/json 保持相同字段顺序，保证 AAD hash 跨语言一致。
export function encodeAAD(aad: AAD): Uint8Array<ArrayBuffer> {
  return Uint8Array.from(
    Buffer.from(
      JSON.stringify({
        entity_id: aad.entity_id,
        event_type: aad.event_type,
        protocol_version: aad.protocol_version,
        event_seq: aad.event_seq,
        key_id: aad.key_id,
      }),
    ),
  );
}

export async function hashAAD(aad: AAD): Promise<{ hash: string; raw: Uint8Array<ArrayBuffer> }> {
  const raw = encodeAAD(aad);
  const digest = await crypto.subtle.digest("SHA-256", raw);
  return { hash: Buffer.from(digest).toString("hex"), raw };
}

export async function deriveContentKey(dek: Uint8Array, info: string): Promise<Uint8Array<ArrayBuffer>> {
  const key = await crypto.subtle.importKey("raw", toArrayBuffer(dek), "HKDF", false, ["deriveBits"]);
  const bits = await crypto.subtle.deriveBits(
    {
      name: "HKDF",
      hash: "SHA-256",
      salt: toArrayBuffer(new TextEncoder().encode("agent-sessions-v1")),
      info: toArrayBuffer(new TextEncoder().encode(info)),
    },
    key,
    256,
  );
  return new Uint8Array(bits);
}

// seal 使用与 Go 相同的 AES-256-GCM + AAD 绑定格式，供 Web 端本地密封敏感内容。
export async function seal(
  dek: Uint8Array,
  keyID: string,
  payloadVersion: number,
  aad: AAD,
  plaintext: Uint8Array,
  nonce: Uint8Array,
): Promise<Envelope> {
  if (nonce.byteLength !== 12) {
    throw new Error("nonce must be 12 bytes");
  }
  const scopedAAD = { ...aad, key_id: keyID };
  const { hash, raw } = await hashAAD(scopedAAD);
  const contentKey = await deriveContentKey(dek, "content");
  const cryptoKey = await crypto.subtle.importKey("raw", contentKey, "AES-GCM", false, ["encrypt"]);
  const ciphertext = await crypto.subtle.encrypt(
    { name: "AES-GCM", iv: toArrayBuffer(nonce), additionalData: raw },
    cryptoKey,
    toArrayBuffer(plaintext),
  );
  return {
    alg: AlgorithmVersion,
    key_id: keyID,
    nonce: b64encode(nonce),
    ciphertext: b64encode(new Uint8Array(ciphertext)),
    aad_hash: hash,
    payload_version: payloadVersion,
  };
}

export async function open(dek: Uint8Array, env: Envelope, aad: AAD): Promise<Uint8Array<ArrayBuffer>> {
  if (env.alg !== AlgorithmVersion) {
    throw new Error(`unsupported alg ${env.alg}`);
  }
  const next: AAD = { ...aad, key_id: env.key_id };
  const { hash, raw } = await hashAAD(next);
  if (hash !== env.aad_hash) {
    throw new Error("aad mismatch");
  }
  const contentKey = await deriveContentKey(dek, "content");
  const cryptoKey = await crypto.subtle.importKey("raw", contentKey, "AES-GCM", false, ["decrypt"]);
  const nonce = b64decode(env.nonce);
  const ciphertext = b64decode(env.ciphertext);
  const plain = await crypto.subtle.decrypt(
    { name: "AES-GCM", iv: nonce, additionalData: raw },
    cryptoKey,
    ciphertext,
  );
  return new Uint8Array(plain);
}

export { b64encode, b64decode };
