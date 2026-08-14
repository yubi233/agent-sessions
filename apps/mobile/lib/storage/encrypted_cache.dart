import 'package:drift/drift.dart';

import '../crypto/box.dart';

/// 可落盘索引只保留不含正文的白名单字段，显示名、消息、diff 和附件名都不能放入这里。
class MinimalCacheIndex {
  const MinimalCacheIndex({
    required this.entityId,
    required this.entityType,
    required this.status,
    required this.updatedAt,
  });

  factory MinimalCacheIndex.fromJson(Map<String, dynamic> json) =>
      MinimalCacheIndex(
        entityId: _requiredString(json, 'entity_id'),
        entityType: _requiredString(json, 'entity_type'),
        status: _requiredString(json, 'status'),
        updatedAt: DateTime.parse(_requiredString(json, 'updated_at')),
      );

  final String entityId;
  final String entityType;
  final String status;
  final DateTime updatedAt;

  Map<String, dynamic> toJson() => {
    'entity_id': entityId,
    'entity_type': entityType,
    'status': status,
    'updated_at': updatedAt.toUtc().toIso8601String(),
  };
}

/// 密文缓存记录不包含已解密的 payload；plaintext 只能停留在业务层内存。
class EncryptedCacheRecord {
  const EncryptedCacheRecord({
    required this.cacheKey,
    required this.envelope,
    required this.cursor,
    required this.index,
  }) : assert(cursor >= 0);

  factory EncryptedCacheRecord.fromJson(Map<String, dynamic> json) {
    final cursor = json['cursor'];
    if (cursor is! num || cursor < 0) {
      throw const FormatException('缓存 cursor 无效。');
    }
    final envelope = CryptoEnvelope.fromJson(
      Map<String, dynamic>.from(json['envelope'] as Map),
    );
    _validateEnvelope(envelope);
    return EncryptedCacheRecord(
      cacheKey: _requiredString(json, 'cache_key'),
      envelope: envelope,
      cursor: cursor.toInt(),
      index: MinimalCacheIndex.fromJson(
        Map<String, dynamic>.from(json['index'] as Map),
      ),
    );
  }

  final String cacheKey;
  final CryptoEnvelope envelope;
  final int cursor;
  final MinimalCacheIndex index;

  /// 序列化格式刻意没有 plaintext 字段，审计可直接检查该不变量。
  Map<String, dynamic> toJson() {
    _validateEnvelope(envelope);
    return {
      'cache_key': cacheKey,
      'cursor': cursor,
      'index': index.toJson(),
      'envelope': {
        'alg': envelope.alg,
        'key_id': envelope.keyId,
        'nonce': envelope.nonce,
        'ciphertext': envelope.ciphertext,
        'aad_hash': envelope.aadHash,
        'payload_version': envelope.payloadVersion,
      },
    };
  }
}

abstract interface class EncryptedCacheStore {
  Future<EncryptedCacheRecord?> read(String cacheKey);

  Future<void> write(EncryptedCacheRecord record);

  Future<void> delete(String cacheKey);

  Future<void> clear();
}

/// Drift 持久化实现。schema 不含 plaintext 列，SQLite 仅保存 Relay 密文和最小索引。
class DriftEncryptedCacheStore implements EncryptedCacheStore {
  DriftEncryptedCacheStore(QueryExecutor executor) : _executor = executor;

  static const _table = 'encrypted_cache_entries';
  final QueryExecutor _executor;
  Future<void>? _schemaReady;

  @override
  Future<EncryptedCacheRecord?> read(String cacheKey) async {
    await _ensureSchema();
    final rows = await _executor.runSelect(
      'SELECT cache_key, alg, key_id, nonce, ciphertext, aad_hash, payload_version, cursor, '
      'entity_id, entity_type, status, updated_at_ms FROM $_table WHERE cache_key = ?',
      [cacheKey],
    );
    if (rows.isEmpty) {
      return null;
    }
    final row = rows.single;
    return EncryptedCacheRecord(
      cacheKey: row['cache_key']! as String,
      envelope: CryptoEnvelope(
        alg: row['alg']! as String,
        keyId: row['key_id']! as String,
        nonce: row['nonce']! as String,
        ciphertext: row['ciphertext']! as String,
        aadHash: row['aad_hash']! as String,
        payloadVersion: (row['payload_version']! as num).toInt(),
      ),
      cursor: (row['cursor']! as num).toInt(),
      index: MinimalCacheIndex(
        entityId: row['entity_id']! as String,
        entityType: row['entity_type']! as String,
        status: row['status']! as String,
        updatedAt: DateTime.fromMillisecondsSinceEpoch(
          (row['updated_at_ms']! as num).toInt(),
        ),
      ),
    );
  }

  @override
  Future<void> write(EncryptedCacheRecord record) async {
    await _ensureSchema();
    _validateEnvelope(record.envelope);
    await _executor.runCustom(
      'INSERT INTO $_table ('
      'cache_key, alg, key_id, nonce, ciphertext, aad_hash, payload_version, cursor, '
      'entity_id, entity_type, status, updated_at_ms'
      ') VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(cache_key) DO UPDATE SET '
      'alg = excluded.alg, key_id = excluded.key_id, nonce = excluded.nonce, '
      'ciphertext = excluded.ciphertext, aad_hash = excluded.aad_hash, '
      'payload_version = excluded.payload_version, cursor = excluded.cursor, '
      'entity_id = excluded.entity_id, entity_type = excluded.entity_type, '
      'status = excluded.status, updated_at_ms = excluded.updated_at_ms',
      [
        record.cacheKey,
        record.envelope.alg,
        record.envelope.keyId,
        record.envelope.nonce,
        record.envelope.ciphertext,
        record.envelope.aadHash,
        record.envelope.payloadVersion,
        record.cursor,
        record.index.entityId,
        record.index.entityType,
        record.index.status,
        record.index.updatedAt.millisecondsSinceEpoch,
      ],
    );
  }

  @override
  Future<void> delete(String cacheKey) async {
    await _ensureSchema();
    await _executor.runCustom('DELETE FROM $_table WHERE cache_key = ?', [
      cacheKey,
    ]);
  }

  @override
  Future<void> clear() async {
    await _ensureSchema();
    await _executor.runCustom('DELETE FROM $_table');
  }

  Future<void> _ensureSchema() => _schemaReady ??= _openAndCreateSchema();

  Future<void> _openAndCreateSchema() async {
    // 直接使用 QueryExecutor 时仍须遵守 Drift 生命周期，否则 native/web executor 都会拒绝首条 SQL。
    await _executor.ensureOpen(const _CacheDatabaseUser());
    await _createSchema();
  }

  Future<void> _createSchema() => _executor.runCustom('''
    CREATE TABLE IF NOT EXISTS $_table (
      cache_key TEXT PRIMARY KEY NOT NULL,
      alg TEXT NOT NULL,
      key_id TEXT NOT NULL,
      nonce TEXT NOT NULL,
      ciphertext TEXT NOT NULL,
      aad_hash TEXT NOT NULL,
      payload_version INTEGER NOT NULL,
      cursor INTEGER NOT NULL CHECK(cursor >= 0),
      entity_id TEXT NOT NULL,
      entity_type TEXT NOT NULL,
      status TEXT NOT NULL,
      updated_at_ms INTEGER NOT NULL
    )
  ''');
}

class _CacheDatabaseUser implements QueryExecutorUser {
  const _CacheDatabaseUser();

  @override
  int get schemaVersion => 1;

  @override
  Future<void> beforeOpen(
    QueryExecutor executor,
    OpeningDetails details,
  ) async {}
}

/// 单元与 integration fixture 使用，不会跨进程持久化任何内容。
class InMemoryEncryptedCacheStore implements EncryptedCacheStore {
  final Map<String, EncryptedCacheRecord> _records = {};

  @override
  Future<EncryptedCacheRecord?> read(String cacheKey) async =>
      _records[cacheKey];

  @override
  Future<void> write(EncryptedCacheRecord record) async {
    _records[record.cacheKey] = EncryptedCacheRecord.fromJson(record.toJson());
  }

  @override
  Future<void> delete(String cacheKey) async {
    _records.remove(cacheKey);
  }

  @override
  Future<void> clear() async {
    _records.clear();
  }
}

void _validateEnvelope(CryptoEnvelope envelope) {
  if (envelope.keyId.isEmpty ||
      envelope.nonce.isEmpty ||
      envelope.ciphertext.isEmpty) {
    throw const FormatException('密文 envelope 缺少必要字段。');
  }
}

String _requiredString(Map<String, dynamic> json, String field) {
  final value = json[field];
  if (value is! String || value.isEmpty) {
    throw FormatException('缓存缺少 $field。');
  }
  return value;
}
