import 'package:agent_sessions_mobile/crypto/box.dart';
import 'package:agent_sessions_mobile/storage/encrypted_cache.dart';
import 'package:agent_sessions_mobile/storage/runtime_encrypted_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('MOBILE-01：MacBook 本地 Drift 只持久化密文 envelope', (_) async {
    final cache = createRuntimeEncryptedCacheStore();
    final record = _record();
    await cache.clear();

    try {
      await cache.write(record);
      final restored = await cache.read(record.cacheKey);

      expect(restored?.cursor, 7);
      expect(restored?.envelope.ciphertext, 'macos-ciphertext-only');
      expect(restored?.toJson().containsKey('plaintext'), isFalse);
    } finally {
      // 本地真实 SQLite 文件只留下结构，测试记录必须在用例结束前清空。
      await cache.clear();
    }
  });
}

EncryptedCacheRecord _record() => EncryptedCacheRecord(
  cacheKey: 'macos-session-index',
  cursor: 7,
  index: MinimalCacheIndex(
    entityId: 'macos-session',
    entityType: 'session',
    status: 'active',
    updatedAt: DateTime.utc(2026, 8, 14),
  ),
  envelope: const CryptoEnvelope(
    alg: algorithmVersion,
    keyId: 'macos-key-id',
    nonce: 'macos-nonce',
    ciphertext: 'macos-ciphertext-only',
    aadHash: 'macos-aad-hash',
    payloadVersion: 1,
  ),
);
