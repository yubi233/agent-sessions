import 'dart:convert';
import 'dart:typed_data';

import 'package:agent_sessions_mobile/crypto/box.dart';
import 'package:agent_sessions_mobile/storage/secure_token_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// v0.9.2 §19.3 跨端公钥编码契约（Flutter 侧回归）。
///
/// 背景：Flutter 侧原先用 base64UrlEncode 编码设备公钥，而 Go 侧编码器（crypto.EncodePublic）
/// 产出 standard raw、Relay 的部分校验器（internal/domain.validX25519PublicKey）只认
/// standard 字母表。字母表分歧只在公钥分组落到 '+'/'/'（即 url-safe 的 '-'/'_'）时暴露，
/// 用随机字节很难稳定复现，因此这里用与 Go 侧相同的**固定向量**钉住契约。
const _goldenStandardRaw = '+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/s';
const _goldenUrlSafeRaw = '-_v7-_v7-_v7-_v7-_v7-_v7-_v7-_v7-_v7-_v7-_s';

Uint8List _goldenPublicKey() => Uint8List.fromList(List<int>.filled(32, 0xfb));

/// 按 standard 字母表解码（Dart 的 base64.decode 要求长度是 4 的倍数，故补 padding）。
Uint8List _decodeStandardRaw(String value) {
  final padded = value.padRight(value.length + (4 - value.length % 4) % 4, '=');
  return Uint8List.fromList(base64.decode(padded));
}

void main() {
  group('v0.9.2 跨端公钥编码契约（standard raw）', () {
    test('encodePublicKeyRawStd 与 Go crypto.EncodePublic 的固定向量逐字符一致', () {
      expect(encodePublicKeyRawStd(_goldenPublicKey()), _goldenStandardRaw);
    });

    test('固定向量确实落在能区分字母表的分组上（回归本身有效）', () {
      expect(_goldenStandardRaw.contains('+') || _goldenStandardRaw.contains('/'), isTrue);
      expect(_goldenUrlSafeRaw.contains('-') || _goldenUrlSafeRaw.contains('_'), isTrue);
      expect(_goldenStandardRaw, isNot(_goldenUrlSafeRaw));
    });

    test('编码结果不含 url-safe 字符与 padding，且可按 standard raw 解回原字节', () {
      final encoded = encodePublicKeyRawStd(_goldenPublicKey());
      expect(encoded.contains('-'), isFalse);
      expect(encoded.contains('_'), isFalse);
      expect(encoded.contains('='), isFalse);
      expect(_decodeStandardRaw(encoded), _goldenPublicKey());
    });

    test('随机公钥编码恒为 standard 字母表（不靠运气掩盖字母表分歧）', () {
      for (var i = 0; i < 64; i += 1) {
        final raw = Uint8List.fromList(
          List<int>.generate(32, (index) => (index * 31 + i * 7) % 256),
        );
        final encoded = encodePublicKeyRawStd(raw);
        expect(encoded.contains('-'), isFalse, reason: 'iteration $i');
        expect(encoded.contains('_'), isFalse, reason: 'iteration $i');
        expect(_decodeStandardRaw(encoded), raw, reason: 'iteration $i');
      }
    });

    test('设备注册上行的加密公钥走 standard raw（真实派生路径，非 fixture 常量）', () async {
      // 用播种路径派生真实 X25519 公钥：这条路径与生产 Keystore 实现共享
      // encodePublicKeyRawStd，能覆盖"手机上行的 encryption_public_key"实际取值。
      final seed = Uint8List.fromList(List<int>.generate(32, (index) => index + 1));
      final store = InMemoryDeviceIdentityStore(
        seedEncryptionPrivateKeyB64: base64Url.encode(seed),
      );
      final material = await store.createOrRead();
      final publicKey = material.encryptionPublicKey;
      expect(publicKey.contains('-'), isFalse);
      expect(publicKey.contains('_'), isFalse);
      expect(publicKey.contains('='), isFalse);
      expect(_decodeStandardRaw(publicKey), hasLength(32));
    });

    test('本地存储的私钥仍按 base64url 解码（既有安装不被本次改动破坏）', () {
      // 私钥是本地存储格式、不参与跨端契约：历史值一律是 base64url，必须继续可解。
      final raw = _goldenPublicKey();
      expect(decodeStoredKey(base64Url.encode(raw)), raw);
      expect(decodeStoredKey(_goldenUrlSafeRaw), raw);
    });
  });
}
