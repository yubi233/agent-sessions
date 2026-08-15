import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_sessions_mobile/crypto/box.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final vectors =
      jsonDecode(
            File(
              '../../packages/crypto/testdata/vectors.json',
            ).readAsStringSync(),
          )
          as List<dynamic>;

  group('P0-CRYPTO-01 Dart golden vectors', () {
    for (final raw in vectors.cast<Map<String, dynamic>>()) {
      test(raw['name'] as String, () async {
        final envelope = Map<String, dynamic>.from(raw['envelope'] as Map);
        final aad = Map<String, dynamic>.from(raw['aad'] as Map);
        switch (raw['tamper_field']) {
          case 'ciphertext':
            envelope['ciphertext'] = '${envelope['ciphertext']}AA';
          case 'aad':
            aad['event_seq'] = (aad['event_seq'] as int) + 1;
          case 'key_id':
            envelope['key_id'] = 'wrong-key';
            aad['key_id'] = 'wrong-key';
        }
        final operation = CryptoBox.open(
          dek: Uint8List.fromList(_hex(raw['dek_hex'] as String)),
          envelope: CryptoEnvelope.fromJson(envelope),
          aad: AssociatedData.fromJson(aad),
        );

        if (raw['expect_ok'] as bool) {
          expect(utf8.decode(await operation), raw['plaintext']);
        } else {
          await expectLater(operation, throwsA(isA<Object>()));
        }
      });
    }
  });

  group('v0.2/P3 seal 与 open 往返', () {
    test('seal 产生的 envelope 可由 open 解回原文明文', () async {
      final dek = Uint8List.fromList(
        List<int>.generate(32, (index) => index + 1),
      );
      final nonce = Uint8List.fromList(
        List<int>.generate(12, (index) => index * 3 + 7),
      );
      const aad = AssociatedData(
        entityId: 'sess-1',
        eventType: 'attachment:chunk',
        protocolVersion: 1,
        eventSeq: 2,
        keyId: 'dek-1',
      );
      final plaintext = Uint8List.fromList(
        utf8.encode('密封的附件块正文'),
      );

      final envelope = await CryptoBox.seal(
        dek: dek,
        keyId: 'dek-1',
        payloadVersion: 1,
        aad: aad,
        plaintext: plaintext,
        nonce: nonce,
      );

      // 密文非空、字段形状与 Go 的 Envelope 对齐（alg/key_id/nonce/ciphertext/aad_hash/payload_version）。
      expect(envelope.alg, algorithmVersion);
      expect(envelope.keyId, 'dek-1');
      expect(envelope.payloadVersion, 1);
      expect(envelope.ciphertext, isNotEmpty);
      expect(envelope.ciphertext.contains('='), isFalse,
          reason: 'Go RawStdEncoding 兼容：无填充 base64');

      final opened = await CryptoBox.open(
        dek: dek,
        envelope: envelope,
        aad: aad,
      );
      expect(utf8.decode(opened), '密封的附件块正文');
    });

    test('AAD 篡改导致 open 失败（防挪用到其他会话/块）', () async {
      final dek = Uint8List.fromList(
        List<int>.generate(32, (index) => index + 1),
      );
      final envelope = await CryptoBox.seal(
        dek: dek,
        keyId: 'dek-1',
        payloadVersion: 1,
        aad: const AssociatedData(
          entityId: 'sess-1',
          eventType: 'attachment:chunk',
          protocolVersion: 1,
          eventSeq: 0,
          keyId: 'dek-1',
        ),
        plaintext: Uint8List.fromList(utf8.encode('内容')),
        nonce: Uint8List.fromList(List<int>.generate(12, (index) => index)),
      );
      // 换到另一个会话的 AAD 必须解密失败。
      await expectLater(
        CryptoBox.open(
          dek: dek,
          envelope: envelope,
          aad: const AssociatedData(
            entityId: 'sess-other',
            eventType: 'attachment:chunk',
            protocolVersion: 1,
            eventSeq: 0,
            keyId: 'dek-1',
          ),
        ),
        throwsA(isA<Object>()),
      );
    });
  });
}

List<int> _hex(String value) => [
  for (var index = 0; index < value.length; index += 2)
    int.parse(value.substring(index, index + 2), radix: 16),
];
