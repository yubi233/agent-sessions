import 'dart:typed_data';

import '../domain/control_models.dart';
import '../domain/delegation_models.dart';
import '../domain/models.dart';
import '../domain/session_models.dart';
import '../git/git_diff_repository.dart';
import '../relay/fixture_relay_repository.dart';
import '../state/lifecycle_recovery_controller.dart';
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
  sessionCapability,
  sessionSkillConfirmation,
  sessionAttachments,
  sessionGitMain,
  sessionGitRestricted,
  sessionDelegationProposed,
  sessionDelegationApproved,
  sessionDelegationRestricted,
  sessionLifecycleRecovery,
  // v0.2/P2 视觉场景：快捷菜单/Resume 与只读文件浏览。
  sessionQuickMenu,
  sessionFilesBrowse,
  // v0.2/P3 视觉场景：composer 模型/effort/usage 控制面。
  sessionComposerControls,
}

LocalVisualScenario localVisualScenarioFromEnvironment(
  String value,
) => switch (value) {
  'owner-ready' => LocalVisualScenario.ownerReady,
  'pairing-pending' => LocalVisualScenario.pairingPending,
  'session-list' => LocalVisualScenario.sessionList,
  'session-detail' => LocalVisualScenario.sessionDetail,
  'session-readonly' => LocalVisualScenario.sessionReadOnly,
  'session-capability' => LocalVisualScenario.sessionCapability,
  'session-skill-confirmation' => LocalVisualScenario.sessionSkillConfirmation,
  'session-attachments' => LocalVisualScenario.sessionAttachments,
  'session-git-main' => LocalVisualScenario.sessionGitMain,
  'session-git-restricted' => LocalVisualScenario.sessionGitRestricted,
  'session-delegation-proposed' =>
    LocalVisualScenario.sessionDelegationProposed,
  'session-delegation-approved' =>
    LocalVisualScenario.sessionDelegationApproved,
  'session-delegation-restricted' =>
    LocalVisualScenario.sessionDelegationRestricted,
  'session-lifecycle-recovery' => LocalVisualScenario.sessionLifecycleRecovery,
  'session-quick-menu' => LocalVisualScenario.sessionQuickMenu,
  'session-files-browse' => LocalVisualScenario.sessionFilesBrowse,
  'session-composer-controls' => LocalVisualScenario.sessionComposerControls,
  _ => LocalVisualScenario.none,
};

class LocalVisualFixture {
  const LocalVisualFixture({
    required this.scenario,
    required this.relay,
    required this.gitDiff,
    required this.tokens,
    required this.identities,
    required this.cache,
    this.pairingRequestId,
    this.sessionId,
  });

  final LocalVisualScenario scenario;
  final FixtureRelayRepository relay;
  final FixtureGitDiffRepository gitDiff;
  final InMemorySecureTokenStore tokens;
  final InMemoryDeviceIdentityStore identities;
  final InMemoryEncryptedCacheStore cache;
  final String? pairingRequestId;
  final String? sessionId;

  /// P6 仅在 deterministic fixture 下模拟前后台与网络变化。
  /// 生产运行由 RuntimeRecoveryBinding 提供平台信号，绝不能把此 helper 接入真实 Relay。
  Future<void> stageLifecycleRecovery(
    SessionRecoveryController recovery,
  ) async {
    final currentSessionId = sessionId;
    if (scenario != LocalVisualScenario.sessionLifecycleRecovery ||
        currentSessionId == null) {
      return;
    }
    await recovery.reportAppVisibility(MobileAppVisibility.background);
    await recovery.reportNetworkAvailability(MobileNetworkAvailability.offline);
    relay.setNetworkAvailable(false);
    await relay.appendOfflineRecoveryEvent(currentSessionId);
    // 下一次 snapshot 故意包含 cursor 边界事件，验证客户端按 sequence 去重。
    relay.repeatCursorEventOnNextSnapshot();
    relay.setNetworkAvailable(true);
    await recovery.reportNetworkAvailability(MobileNetworkAvailability.online);
    await recovery.reportAppVisibility(MobileAppVisibility.foreground);
  }

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
    final gitDiff = FixtureGitDiffRepository(
      scenario: scenario == LocalVisualScenario.sessionGitRestricted
          ? GitFixtureScenario.restricted
          : GitFixtureScenario.main,
    );
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
      gitDiff: gitDiff,
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
      LocalVisualScenario.sessionReadOnly ||
      LocalVisualScenario.sessionCapability ||
      LocalVisualScenario.sessionSkillConfirmation ||
      LocalVisualScenario.sessionAttachments ||
      LocalVisualScenario.sessionGitMain ||
      LocalVisualScenario.sessionGitRestricted ||
      LocalVisualScenario.sessionDelegationProposed ||
      LocalVisualScenario.sessionDelegationApproved ||
      LocalVisualScenario.sessionDelegationRestricted ||
      LocalVisualScenario.sessionLifecycleRecovery ||
      LocalVisualScenario.sessionQuickMenu ||
      LocalVisualScenario.sessionFilesBrowse ||
      LocalVisualScenario.sessionComposerControls => true,
      _ => false,
    };
    if (!needsSession) return null;

    final primary = await relay.createSession(
      CreateMobileSessionInput(
        workspaceId: 'fixture-mobile-workspace',
        // 能力场景故意使用 mixed profile，确保画面同时覆盖 native/emulated/unsupported 三态。
        provider: scenario == LocalVisualScenario.sessionCapability
            ? 'claude'
            : 'codex',
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
    // 三个 P5 场景都复用真实 fixture repository 的 parent lease 与决策链路，
    // 而不是由页面静态拼出 child 节点。摘要始终保持 opaque envelope。
    if (scenario == LocalVisualScenario.sessionDelegationProposed ||
        scenario == LocalVisualScenario.sessionDelegationApproved ||
        scenario == LocalVisualScenario.sessionDelegationRestricted) {
      final proposal = await relay.seedDelegationProposal(
        parentSessionId: primary.id,
        targetProvider:
            scenario == LocalVisualScenario.sessionDelegationRestricted
            ? 'claude'
            : 'codex',
      );
      if (scenario == LocalVisualScenario.sessionDelegationApproved) {
        await relay.decideDelegation(
          proposal.id,
          DelegationDecisionInput(
            decision: DelegationDecision.approve,
            idempotencyKey: 'visual-delegation-approved',
            parentLeaseEpoch: lease.epoch,
            deviceId: ownerDeviceId,
          ),
        );
      }
    }
    return primary.id;
  }

  /// P3 附件视觉场景仅生成已加密的固定 bytes。localName 只留在内存 chip，不会进入 Relay 请求。
  static List<AttachmentDraft> attachmentDrafts() => [
    AttachmentDraft(
      id: 'visual-image-attachment',
      localName: 'fixture-image.png',
      mimeType: 'image/png',
      byteSize: 480,
      compression: 'none',
      metadataCiphertext: Uint8List.fromList([11, 12, 13]),
      ciphertextChunks: [
        Uint8List.fromList([21, 22]),
        Uint8List.fromList([23, 24]),
      ],
    ),
    AttachmentDraft(
      id: 'visual-text-attachment',
      localName: 'fixture-note.md',
      mimeType: 'text/markdown',
      byteSize: 96,
      compression: 'none',
      metadataCiphertext: Uint8List.fromList([31, 32, 33]),
      ciphertextChunks: [
        Uint8List.fromList([41, 42]),
      ],
    ),
    // 这项仅用于预检拒绝状态，绝不会上传或持久化。
    AttachmentDraft(
      id: 'visual-rejected-attachment',
      localName: 'fixture-unsupported.bin',
      mimeType: 'application/octet-stream',
      byteSize: 64,
      compression: 'none',
      metadataCiphertext: Uint8List.fromList([51, 52, 53]),
      ciphertextChunks: [
        Uint8List.fromList([61, 62]),
      ],
    ),
  ];
}
