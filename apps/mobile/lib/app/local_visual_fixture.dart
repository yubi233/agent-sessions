import '../domain/models.dart';
import '../domain/session_models.dart';
import '../relay/fixture_relay_repository.dart';
import '../storage/encrypted_cache.dart';
import '../storage/secure_token_store.dart';

/// 仅供 MacBook 本地可见截图使用的确定性界面状态，绝不连接真实 Relay 或读取本机安全存储。
enum LocalVisualScenario {
  none,
  ownerReady,
  pairingPending,
  sessionList,
  sessionDetail,
  sessionReadOnly,
}

LocalVisualScenario localVisualScenarioFromEnvironment(String value) =>
    switch (value) {
      'owner-ready' => LocalVisualScenario.ownerReady,
      'pairing-pending' => LocalVisualScenario.pairingPending,
      'session-list' => LocalVisualScenario.sessionList,
      'session-detail' => LocalVisualScenario.sessionDetail,
      'session-readonly' => LocalVisualScenario.sessionReadOnly,
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
    this.sessionId,
  });

  final LocalVisualScenario scenario;
  final FixtureRelayRepository relay;
  final InMemorySecureTokenStore tokens;
  final InMemoryDeviceIdentityStore identities;
  final InMemoryEncryptedCacheStore cache;
  final String? pairingRequestId;
  final String? sessionId;

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
    final isReadOnlySession = scenario == LocalVisualScenario.sessionReadOnly;
    if (isReadOnlySession) {
      // 只读场景必须使用未绑定 token，不能通过内存 owner 身份绕过 Relay 写边界。
      await tokens.write(
        await relay.login(
          const LoginCredentials(
            email: 'visual-readonly@fixture.test',
            password: 'fixture-password',
          ),
        ),
      );
    } else {
      await tokens.write(ownerTokens);
      await identities.bindDeviceId(ownerDeviceId);
      await identities.createOrRead();
      await identities.markOwnerBootstrapComplete(true);
    }

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

    final sessionId = await _seedSessionScenario(
      relay: relay,
      ownerDeviceId: ownerDeviceId,
      scenario: scenario,
    );

    return LocalVisualFixture(
      scenario: scenario,
      relay: relay,
      tokens: tokens,
      identities: identities,
      cache: cache,
      pairingRequestId: pairingRequestId,
      sessionId: sessionId,
    );
  }

  /// 会话视觉场景只使用固定、无敏感的 fixture 事件；真实 Relay 不会在截图前写入正文。
  static Future<String?> _seedSessionScenario({
    required FixtureRelayRepository relay,
    required String ownerDeviceId,
    required LocalVisualScenario scenario,
  }) async {
    final needsSession = switch (scenario) {
      LocalVisualScenario.sessionList ||
      LocalVisualScenario.sessionDetail ||
      LocalVisualScenario.sessionReadOnly => true,
      _ => false,
    };
    if (!needsSession) return null;

    final primary = await relay.createSession(
      CreateMobileSessionInput(
        workspaceId: 'fixture-mobile-workspace',
        provider: 'codex',
        deviceId: ownerDeviceId,
      ),
    );
    final lease = await relay.acquireSessionLease(primary.id);
    await relay.submitSessionCommand(
      primary.id,
      SessionCommandInput(
        kind: SessionCommandKind.send,
        idempotencyKey: 'visual-${scenario.name}-primary-message',
        leaseEpoch: lease.epoch,
        deviceId: ownerDeviceId,
        ciphertext: const {
          'fixture_payload': {'message': '请展示本地 fixture 会话的控制状态。'},
        },
      ),
    );

    if (scenario == LocalVisualScenario.sessionList) {
      await relay.createSession(
        CreateMobileSessionInput(
          workspaceId: 'fixture-review-workspace',
          provider: 'claude',
          deviceId: ownerDeviceId,
        ),
      );
    }
    return primary.id;
  }
}
