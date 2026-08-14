import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { open, seal, type AAD, type Envelope } from "./index";

interface Vector {
  name: string;
  dek_hex: string;
  plaintext: string;
  expect_ok: boolean;
  tamper_field?: string;
  aad: AAD;
  envelope: Envelope;
}

const vectors = JSON.parse(
  readFileSync(
    join(dirname(fileURLToPath(import.meta.url)), "../../crypto/testdata/vectors.json"),
    "utf8",
  ),
) as Vector[];

describe("P0-CRYPTO-01 golden vectors", () => {
  it.each(vectors)("$name", async (v) => {
    const dek = Buffer.from(v.dek_hex, "hex");
    const env = { ...v.envelope };
    const aad = { ...v.aad };
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
