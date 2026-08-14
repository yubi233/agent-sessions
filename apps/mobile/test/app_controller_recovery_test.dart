import 'package:agent_sessions_mobile/domain/models.dart';
import 'package:agent_sessions_mobile/relay/fixture_relay_repository.dart';
import 'package:agent_sessions_mobile/state/app_controller.dart';
import 'package:agent_sessions_mobile/storage/encrypted_cache.dart';
import 'package:agent_sessions_mobile/storage/secure_token_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MOBILE-01 恢复候选身份', () {
    test('恢复响应绑定错误时保留旧 active identity', () async {
      final identities = InMemoryDeviceIdentityStore();
      final before = await identities.createOrRead();
      final controller = AppController(
        relay: _MismatchedRecoveryRelay(),
        tokenStore: InMemorySecureTokenStore(),
        identityStore: identities,
        encryptedCache: InMemoryEncryptedCacheStore(),
      );

      await controller.restoreWithRecoveryCode(
        'recover@fixture.test',
        'RECOVERY-FIXTURE-0001',
      );

      // Relay 设备和 token 串线属于协议失败，候选私钥被丢弃，旧身份仍可安全使用。
      final after = await identities.createOrRead();
      expect(after.identityPublicKey, before.identityPublicKey);
      expect(after.encryptionPublicKey, before.encryptionPublicKey);
      expect(controller.isAuthenticated, isFalse);
      expect(controller.errorMessage, 'Relay 返回的设备令牌绑定不一致。');
    });

    test('恢复成功后才用候选 identity 覆盖旧 active identity', () async {
      final identities = InMemoryDeviceIdentityStore();
      final before = await identities.createOrRead();
      final tokens = InMemorySecureTokenStore();
      final controller = AppController(
        relay: FixtureRelayRepository(),
        tokenStore: tokens,
        identityStore: identities,
        encryptedCache: InMemoryEncryptedCacheStore(),
      );

      await controller.restoreWithRecoveryCode(
        'recover@fixture.test',
        'RECOVERY-FIXTURE-0001',
      );

      final after = await identities.createOrRead();
      expect(after.identityPublicKey, isNot(before.identityPublicKey));
      expect(after.identityPublicKey, 'fixture-recovery-ed25519-public-key');
      expect(after.encryptionPublicKey, 'fixture-recovery-x25519-public-key');
      expect((await tokens.read())?.deviceId, 'recovered-android-fixture');
      expect(controller.isAuthenticated, isTrue);
    });
  });
}

/// 模拟不可信的恢复 DTO：业务层必须在切换本机私钥前发现 device/token 不一致。
class _MismatchedRecoveryRelay extends FixtureRelayRepository {
  @override
  Future<RecoveryResult> restoreWithRecoveryCode(
    RecoveryCodeInput input,
  ) async => RecoveryResult(
    device: const Device(
      id: 'relay-device-a',
      role: DeviceRole.androidOwner,
      status: DeviceStatus.active,
      displayName: 'Mismatched recovery device',
      platform: 'android',
    ),
    tokens: AuthTokens(
      accessToken: 'fixture-access-mismatch',
      refreshToken: 'fixture-refresh-mismatch',
      expiresAt: DateTime.utc(2026, 8, 14, 1),
      deviceId: 'relay-device-b',
    ),
  );
}
