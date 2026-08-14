import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_sessions_mobile/crypto/box.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final vectors = jsonDecode(
    File('../../packages/crypto/testdata/vectors.json').readAsStringSync(),
  ) as List<dynamic>;

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
}

List<int> _hex(String value) => [
      for (var index = 0; index < value.length; index += 2)
        int.parse(value.substring(index, index + 2), radix: 16),
    ];
