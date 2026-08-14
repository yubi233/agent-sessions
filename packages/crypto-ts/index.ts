// packages/crypto-ts/index.ts
export * from "./box";
export * from "./vectors";
export * from "./types";

import * as crypto from "crypto";

export const AlgorithmVersion = "v1-aes256gcm-hkdfsha256";

export class Box {
  static async seal(
    dek: Buffer,
    keyId: string,
    payloadVersion: number,
    aad: any,
    plaintext: Buffer,
    nonce: Buffer
  ): Promise<any> {
    // 实现与 Go 相同的 AES-256-GCM + HKDF 逻辑
    // 省略完整代码，保持与 Go 一致
  }

  static async open(dek: Buffer, envelope: any, aad: any): Promise<Buffer> {
    // 实现解密逻辑
  }
}
