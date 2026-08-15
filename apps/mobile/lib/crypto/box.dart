import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

const algorithmVersion = 'v1-aes256gcm-hkdfsha256';

/// 跨端 envelope 的最小字段；Android 只在本地解密，Relay 永远不读取 plaintext。
class CryptoEnvelope {
  const CryptoEnvelope({
    required this.alg,
    required this.keyId,
    required this.nonce,
    required this.ciphertext,
    required this.aadHash,
    required this.payloadVersion,
  });

  factory CryptoEnvelope.fromJson(Map<String, dynamic> json) => CryptoEnvelope(
    alg: json['alg'] as String,
    keyId: json['key_id'] as String,
    nonce: json['nonce'] as String,
    ciphertext: json['ciphertext'] as String,
    aadHash: json['aad_hash'] as String,
    payloadVersion: json['payload_version'] as int,
  );

  final String alg;
  final String keyId;
  final String nonce;
  final String ciphertext;
  final String aadHash;
  final int payloadVersion;

  Map<String, dynamic> toJson() => {
    'alg': alg,
    'key_id': keyId,
    'nonce': nonce,
    'ciphertext': ciphertext,
    'aad_hash': aadHash,
    'payload_version': payloadVersion,
  };

  String toJsonString() => jsonEncode(toJson());
}

/// AAD 绑定实体、事件类型、协议版本、序号和 key id，避免密文跨范围重放。
class AssociatedData {
  const AssociatedData({
    required this.entityId,
    required this.eventType,
    required this.protocolVersion,
    required this.eventSeq,
    required this.keyId,
  });

  factory AssociatedData.fromJson(Map<String, dynamic> json) => AssociatedData(
    entityId: json['entity_id'] as String,
    eventType: json['event_type'] as String,
    protocolVersion: json['protocol_version'] as int,
    eventSeq: json['event_seq'] as int,
    keyId: json['key_id'] as String,
  );

  final String entityId;
  final String eventType;
  final int protocolVersion;
  final int eventSeq;
  final String keyId;

  AssociatedData withKeyId(String value) => AssociatedData(
    entityId: entityId,
    eventType: eventType,
    protocolVersion: protocolVersion,
    eventSeq: eventSeq,
    keyId: value,
  );

  Uint8List encode() => Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'entity_id': entityId,
        'event_type': eventType,
        'protocol_version': protocolVersion,
        'event_seq': eventSeq,
        'key_id': keyId,
      }),
    ),
  );
}

/// CryptoBox 实现与 Go/TypeScript 相同的 HKDF + AES-256-GCM 解密流程。
class CryptoBox {
  CryptoBox._();

  static final _aesGcm = AesGcm.with256bits();
  static final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  static final _sha256 = Sha256();

  /// 与 Go `Seal` 对齐：HKDF 派生内容密钥 -> AES-256-GCM 加密 -> ciphertext||tag。
  /// 密文使用无填充 base64（Go RawStdEncoding 兼容），nonce 必须 96-bit 且不重复。
  static Future<CryptoEnvelope> seal({
    required Uint8List dek,
    required String keyId,
    required int payloadVersion,
    required AssociatedData aad,
    required Uint8List plaintext,
    required Uint8List nonce,
  }) async {
    if (nonce.length != 12) {
      throw StateError('nonce must be 12 bytes');
    }
    final contentKey = await _deriveContentKey(dek);
    final scopedAad = aad.withKeyId(keyId).encode();
    final aadHashBytes = await _sha256.hash(scopedAad);
    final box = await _aesGcm.encrypt(
      plaintext,
      secretKey: contentKey,
      nonce: nonce,
      aad: scopedAad,
    );
    // Go 的 GCM 输出为 ciphertext||tag；Dart 将 tag 单独表达为 Mac，这里拼接还原。
    final combined = Uint8List.fromList([...box.cipherText, ...box.mac.bytes]);
    return CryptoEnvelope(
      alg: algorithmVersion,
      keyId: keyId,
      nonce: _encodeNoPadding(nonce),
      ciphertext: _encodeNoPadding(combined),
      aadHash: _hex(aadHashBytes.bytes),
      payloadVersion: payloadVersion,
    );
  }

  static Future<SecretKey> _deriveContentKey(Uint8List dek) async {
    final contentKey = await _hkdf.deriveKey(
      secretKey: SecretKey(dek),
      nonce: utf8.encode('agent-sessions-v1'),
      info: utf8.encode('content'),
    );
    return contentKey;
  }

  /// 无填充 base64（Go RawStdEncoding 兼容）；open 侧的 decode 也能消费。
  static String _encodeNoPadding(Uint8List bytes) =>
      base64.encode(bytes).replaceAll('=', '');

  static Future<Uint8List> open({
    required Uint8List dek,
    required CryptoEnvelope envelope,
    required AssociatedData aad,
  }) async {
    if (envelope.alg != algorithmVersion) {
      throw StateError('unsupported alg ${envelope.alg}');
    }
    final scopedAad = aad.withKeyId(envelope.keyId).encode();
    final aadHash = await _sha256.hash(scopedAad);
    if (_hex(aadHash.bytes) != envelope.aadHash) {
      throw StateError('aad mismatch');
    }
    final contentKey = await _deriveContentKey(dek);
    final combined = _decodeBase64Url(envelope.ciphertext);
    if (combined.length < 16) {
      throw StateError('ciphertext too short');
    }
    // Go 的 GCM 输出为 ciphertext||tag；Dart SecretBox 将 tag 单独表达为 Mac。
    final splitAt = combined.length - 16;
    final box = SecretBox(
      combined.sublist(0, splitAt),
      nonce: _decodeBase64Url(envelope.nonce),
      mac: Mac(combined.sublist(splitAt)),
    );
    return Uint8List.fromList(
      await _aesGcm.decrypt(box, secretKey: contentKey, aad: scopedAad),
    );
  }

  static Uint8List _decodeBase64Url(String value) =>
      Uint8List.fromList(base64Url.decode(base64Url.normalize(value)));

  static String _hex(List<int> bytes) =>
      bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}
