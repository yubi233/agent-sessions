import 'package:agent_sessions_mobile/crypto/box.dart';
import 'package:agent_sessions_mobile/storage/encrypted_cache.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MOBILE-01 Drift 密文缓存', () {
    test('只保存 envelope、cursor 和 minimal-index，不建立 plaintext 列', () async {
      final executor = NativeDatabase.memory();
      final store = DriftEncryptedCacheStore(executor);
      final record = _record(cursor: 42);

      await store.write(record);
      final restored = await store.read(record.cacheKey);
      final columns = await executor.runSelect(
        'PRAGMA table_info(encrypted_cache_entries)',
        const [],
      );
      final rawRows = await executor.runSelect(
        'SELECT ciphertext, cursor FROM encrypted_cache_entries',
        const [],
      );

      expect(restored?.cursor, 42);
      expect(restored?.envelope.ciphertext, 'ciphertext-only-value');
      expect(columns.map((row) => row['name']), isNot(contains('plaintext')));
      expect(
        columns.map((row) => row['name']),
        containsAll(<String>['ciphertext', 'cursor', 'entity_id']),
      );
      expect(rawRows.single['ciphertext'], 'ciphertext-only-value');
      await executor.close();
    });

    test('更新同一 cache key 保持 cursor 单调记录且可清理', () async {
      final executor = NativeDatabase.memory();
      final store = DriftEncryptedCacheStore(executor);
      await store.write(_record(cursor: 1));
      await store.write(_record(cursor: 2));

      expect((await store.read('session-index-1'))?.cursor, 2);
      await store.clear();
      expect(await store.read('session-index-1'), isNull);
      await executor.close();
    });

    test('缺少 envelope 密文字段的记录不会进入缓存', () {
      expect(
        () => EncryptedCacheRecord.fromJson({
          'cache_key': 'key',
          'cursor': 0,
          'index': {
            'entity_id': 'entity',
            'entity_type': 'session',
            'status': 'active',
            'updated_at': DateTime.utc(2026).toIso8601String(),
          },
          'envelope': {
            'alg': algorithmVersion,
            'key_id': 'key-id',
            'nonce': 'nonce',
            'ciphertext': '',
            'aad_hash': 'hash',
            'payload_version': 1,
          },
        }),
        throwsFormatException,
      );
    });
  });
}

EncryptedCacheRecord _record({required int cursor}) => EncryptedCacheRecord(
  cacheKey: 'session-index-1',
  cursor: cursor,
  index: MinimalCacheIndex(
    entityId: 'session-1',
    entityType: 'session',
    status: 'active',
    updatedAt: DateTime.utc(2026, 8, 14),
  ),
  envelope: const CryptoEnvelope(
    alg: algorithmVersion,
    keyId: 'key-id',
    nonce: 'nonce',
    ciphertext: 'ciphertext-only-value',
    aadHash: 'hash',
    payloadVersion: 1,
  ),
);
