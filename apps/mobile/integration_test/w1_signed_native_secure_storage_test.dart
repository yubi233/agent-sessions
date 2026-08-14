import 'package:agent_sessions_mobile/crypto/box.dart';
import 'package:agent_sessions_mobile/domain/models.dart';
import 'package:agent_sessions_mobile/storage/encrypted_cache.dart';
import 'package:agent_sessions_mobile/storage/runtime_encrypted_cache.dart';
import 'package:agent_sessions_mobile/storage/secure_token_store.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // 此用例只在已配置 Android Keystore 或 Apple Development 签名的原生环境执行；
  // 本轮 MacBook local gate 不把缺少 Apple 签名伪装成安全存储通过。
  testWidgets('MOBILE-01：已签名原生环境使用安全存储与 Drift 文件密文缓存', (_) async {
    const platformStorage = FlutterSecureStorage(
      aOptions: AndroidOptions(
        storageNamespace: 'agent_sessions.p1.signed-native-storage-test',
      ),
    );
    final tokenStore = FlutterSecureTokenStore(storage: platformStorage);
    final identityStore = SecureDeviceIdentityStore(storage: platformStorage);
    final cache = createRuntimeEncryptedCacheStore();
    await tokenStore.clear();
    await identityStore.clear();
    await cache.clear();

    try {
      final initialIdentity = await identityStore.createOrRead();
      final persistedIdentity = SecureDeviceIdentityStore(
        storage: platformStorage,
      );
      expect(
        (await persistedIdentity.createOrRead()).identityPublicKey,
        initialIdentity.identityPublicKey,
      );

      final authTokens = AuthTokens(
        accessToken: 'signed-native-access-token',
        refreshToken: 'signed-native-refresh-token',
        expiresAt: DateTime.utc(2026, 8, 15),
        deviceId: 'signed-native-owner-device',
      );
      await tokenStore.write(authTokens);
      final persistedTokens = await FlutterSecureTokenStore(
        storage: platformStorage,
      ).read();
      expect(persistedTokens?.deviceId, 'signed-native-owner-device');
      expect(persistedTokens?.refreshToken, 'signed-native-refresh-token');

      // 候选密钥在恢复确认前不覆盖 active identity；提交后新的 store 实例也必须读到候选公钥。
      final candidate = await identityStore.createRecoveryCandidate();
      expect(
        candidate.identityPublicKey,
        isNot(initialIdentity.identityPublicKey),
      );
      expect(
        (await identityStore.createOrRead()).identityPublicKey,
        initialIdentity.identityPublicKey,
      );
      await identityStore.commitRecoveryCandidate();
      expect(
        (await persistedIdentity.createOrRead()).identityPublicKey,
        candidate.identityPublicKey,
      );

      final record = _record();
      await cache.write(record);
      final restored = await cache.read(record.cacheKey);
      expect(restored?.cursor, 7);
      expect(restored?.envelope.ciphertext, 'signed-native-ciphertext-only');
      expect(restored?.toJson().containsKey('plaintext'), isFalse);
    } finally {
      await tokenStore.clear();
      await identityStore.clear();
      await cache.clear();
    }
  });
}

EncryptedCacheRecord _record() => EncryptedCacheRecord(
  cacheKey: 'signed-native-session-index',
  cursor: 7,
  index: MinimalCacheIndex(
    entityId: 'signed-native-session',
    entityType: 'session',
    status: 'active',
    updatedAt: DateTime.utc(2026, 8, 14),
  ),
  envelope: const CryptoEnvelope(
    alg: algorithmVersion,
    keyId: 'signed-native-key-id',
    nonce: 'signed-native-nonce',
    ciphertext: 'signed-native-ciphertext-only',
    aadHash: 'signed-native-aad-hash',
    payloadVersion: 1,
  ),
);
