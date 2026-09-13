import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { open, seal, type AAD, type Envelope } from "./index";

interface Vector {
  name: string;
  dek_hex?: string;
  plaintext?: string;
  expect_ok?: boolean;
  tamper_field?: string;
  aad?: AAD;
  envelope?: Envelope;
  // dek-wrap 类向量的字段（DEK 解包契约，消费方为移动端 Dart 侧，见 ADR-016 §3.2）。
  owner_private_key_b64url?: string;
  wrapped_dek_payload_b64url?: string;
  expected_dek?: string;
}

const vectors = JSON.parse(
  readFileSync(
    join(dirname(fileURLToPath(import.meta.url)), "../../crypto/testdata/vectors.json"),
    "utf8",
  ),
) as Vector[];

// envelope 开封向量：带 dek_hex/envelope/aad，走 seal/open 金标准 oracle。
const envelopeVectors = vectors.filter((v) => typeof v.dek_hex === "string");
// dek-wrap 向量：DEK 解包契约，unwrap 实现属移动端读取路径（apps/mobile/lib/crypto/box.dart），
// crypto-ts 不承载该能力；这里只做跨端 schema 形状回归，防止共享向量文件的字段漂移无人察觉。
const dekWrapVectors = vectors.filter((v) => typeof v.wrapped_dek_payload_b64url === "string");

describe("P0-CRYPTO-01 golden vectors", () => {
  it.each(envelopeVectors)("$name", async (v) => {
    const dek = Buffer.from(v.dek_hex as string, "hex");
    const env = { ...(v.envelope as Envelope) };
    const aad = { ...(v.aad as AAD) };
    if (v.tamper_field === "ciphertext") env.ciphertext += "AA";
    if (v.tamper_field === "aad") aad.event_seq += 1;
    if (v.tamper_field === "key_id") {
      aad.key_id = "wrong-key";
      env.key_id = "wrong-key";
    }
    if (v.expect_ok) {
      const pt = await open(dek, env, aad);
      expect(Buffer.from(pt).toString()).toBe(v.plaintext);
    } else {
      await expect(open(dek, env, aad)).rejects.toBeTruthy();
    }
  });

  it.each(dekWrapVectors)("$name 保持跨端契约形状（unwrap 消费方在移动端）", (v) => {
    expect(typeof v.owner_private_key_b64url).toBe("string");
    expect(v.owner_private_key_b64url!.length).toBeGreaterThan(0);
    expect(typeof v.wrapped_dek_payload_b64url).toBe("string");
    expect(v.wrapped_dek_payload_b64url!.length).toBeGreaterThan(0);
    // expected_dek 是确定性测试 DEK 的十六进制字符串形式；Dart 侧按 utf8 解码后与
    // 解包结果逐字节比对（见 apps/mobile/test/crypto_box_test.dart），此处断言同口径形状。
    expect(v.expected_dek).toMatch(/^[0-9a-f]+$/);
    expect((v.expected_dek as string).length % 2).toBe(0);
    expect((v.expected_dek as string).length).toBeGreaterThan(0);
  });

  it("向量文件不存在既非 envelope 也非 dek-wrap 的未知种类（防静默漂移）", () => {
    const known = envelopeVectors.length + dekWrapVectors.length;
    expect(known).toBe(vectors.length);
    expect(vectors.length).toBeGreaterThan(0);
  });
});

it("P0-CRYPTO-01 seals data that the same boundary can open", async () => {
  const dek = Buffer.alloc(32, 7);
  const aad: AAD = {
    entity_id: "session-1",
    event_type: "message.delta",
    protocol_version: 1,
    event_seq: 1,
    key_id: "key-1",
  };
  const envelope = await seal(dek, "key-1", 1, aad, Buffer.from("local encrypted draft"), Buffer.alloc(12, 9));
  const plaintext = await open(dek, envelope, aad);
  expect(Buffer.from(plaintext).toString()).toBe("local encrypted draft");
});
