import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('P0-CRYPTO-01 Android device key material', () {
    test('Ed25519 identity signature can be verified', () async {
      final algorithm = Ed25519();
      final pair = await algorithm.newKeyPair();
      final message = Uint8List.fromList('agent-sessions-device'.codeUnits);
      final signature = await algorithm.sign(message, keyPair: pair);

      expect(await algorithm.verify(message, signature: signature), isTrue);
    });

    test('X25519 peers derive the same wrapping secret', () async {
      final algorithm = X25519();
      final sender = await algorithm.newKeyPair();
      final recipient = await algorithm.newKeyPair();
      final senderSecret = await algorithm.sharedSecretKey(
        keyPair: sender,
        remotePublicKey: await recipient.extractPublicKey(),
      );
      final recipientSecret = await algorithm.sharedSecretKey(
        keyPair: recipient,
        remotePublicKey: await sender.extractPublicKey(),
      );

      expect(await senderSecret.extractBytes(), await recipientSecret.extractBytes());
    });
  });
}
