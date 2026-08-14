import '../domain/models.dart';
import '../relay/fixture_relay_repository.dart';
import '../storage/encrypted_cache.dart';
import '../storage/secure_token_store.dart';

/// 仅供 MacBook 本地可见截图使用的确定性界面状态，绝不连接真实 Relay 或读取本机安全存储。
enum LocalVisualScenario { none, ownerReady, pairingPending }

LocalVisualScenario localVisualScenarioFromEnvironment(String value) =>
    switch (value) {
      'owner-ready' => LocalVisualScenario.ownerReady,
      'pairing-pending' => LocalVisualScenario.pairingPending,
      _ => LocalVisualScenario.none,
    };

class LocalVisualFixture {
  const LocalVisualFixture({
    required this.scenario,
    required this.relay,
    required this.tokens,
    required this.identities,
    required this.cache,
    this.pairingRequestId,
  });

  final LocalVisualScenario scenario;
  final FixtureRelayRepository relay;
  final InMemorySecureTokenStore tokens;
  final InMemoryDeviceIdentityStore identities;
  final InMemoryEncryptedCacheStore cache;
  final String? pairingRequestId;

  /// 将 owner 身份预写入纯内存依赖，使真实路由能在正常运行时自然落到目标页面。
  static Future<LocalVisualFixture?> create(String scenarioValue) async {
    final scenario = localVisualScenarioFromEnvironment(scenarioValue);
    if (scenario == LocalVisualScenario.none) return null;

    final relay = FixtureRelayRepository(
      clock: () => DateTime.utc(2026, 8, 14, 12),
    );
    final tokens = InMemorySecureTokenStore();
    final identities = InMemoryDeviceIdentityStore();
    final cache = InMemoryEncryptedCacheStore();
    final ownerTokens = await relay.register(
      const LoginCredentials(
        email: 'visual-owner@fixture.test',
        password: 'fixture-password',
      ),
    );
    final ownerDeviceId = ownerTokens.deviceId;
    if (ownerDeviceId == null || ownerDeviceId.isEmpty) {
      throw StateError('本地视觉 fixture 缺少 owner 设备绑定。');
    }
    await tokens.write(ownerTokens);
    await identities.bindDeviceId(ownerDeviceId);
    await identities.createOrRead();
    await identities.markOwnerBootstrapComplete(true);

    String? pairingRequestId;
    if (scenario == LocalVisualScenario.pairingPending) {
      final pairing = await relay.createPairing(
        const PairingRequestInput(
          role: DeviceRole.terminal,
          displayName: 'macOS Fixture Terminal',
          platform: 'macos',
          keys: DeviceRegistrationMaterial(
            identityPublicKey: 'visual-terminal-identity',
            encryptionPublicKey: 'visual-terminal-encryption',
          ),
        ),
      );
      pairingRequestId = pairing.id;
    }

    return LocalVisualFixture(
      scenario: scenario,
      relay: relay,
      tokens: tokens,
      identities: identities,
      cache: cache,
      pairingRequestId: pairingRequestId,
    );
  }
}
