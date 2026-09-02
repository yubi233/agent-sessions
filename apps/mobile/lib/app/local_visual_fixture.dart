import 'dart:typed_data';

import '../domain/control_models.dart';
import '../domain/delegation_models.dart';
import '../domain/models.dart';
import '../domain/session_models.dart';
import '../domain/terminal_models.dart';
import '../domain/usage_models.dart';
import '../git/git_diff_repository.dart';
import '../relay/fixture_relay_repository.dart';
import '../state/lifecycle_recovery_controller.dart';
import '../storage/encrypted_cache.dart';
import '../storage/secure_token_store.dart';

/// 仅供 MacBook 本地可见截图使用的确定性界面状态，绝不连接真实 Relay 或读取本机安全存储。
enum LocalVisualScenario {
  none,
  ownerReady,
  // v0.8.1：DSH 工作区主模式，只注入安全 display name 与会话元数据。
  dshWorkspaceHome,
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
  // v0.3/P3 视觉场景：goal 编辑入口与 Provider 探测失败提示。
  sessionGoalEdit,
  sessionProviderUnavailable,
  // v0.4/P3 视觉场景：只读 Relay Terminal 状态，不模拟 Daemon 命令。
  terminalStatus,
  // v0.4/P2-F：只读 Daemon 安全投影，不模拟命令执行、回执或密钥交付。
  sessionDaemonObservation,
  // v0.4/P3-A 视觉场景：设置中心与会话 info 只读白名单展示。
  settingsIndex,
  sessionInfo,
  // v0.4/P3-B 视觉场景：代码查看器与最近会话。
  codeViewer,
  recentSessions,
  // v0.4/P3-C 视觉场景：用量统计、命令面板与单消息深链。
  usageScreen,
  commandPalette,
  messageDeepLink,
}

LocalVisualScenario localVisualScenarioFromEnvironment(
  String value,
) => switch (value) {
  'owner-ready' => LocalVisualScenario.ownerReady,
  'dsh-workspace-home' => LocalVisualScenario.dshWorkspaceHome,
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
  'session-goal-edit' => LocalVisualScenario.sessionGoalEdit,
  'session-provider-unavailable' =>
    LocalVisualScenario.sessionProviderUnavailable,
  'terminal-status' => LocalVisualScenario.terminalStatus,
  'session-daemon-observation' => LocalVisualScenario.sessionDaemonObservation,
  'settings-index' => LocalVisualScenario.settingsIndex,
  'session-info' => LocalVisualScenario.sessionInfo,
  'code-viewer' => LocalVisualScenario.codeViewer,
  'recent-sessions' => LocalVisualScenario.recentSessions,
  'usage-screen' => LocalVisualScenario.usageScreen,
  'command-palette' => LocalVisualScenario.commandPalette,
  'message-deeplink' => LocalVisualScenario.messageDeepLink,
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
    if (scenario == LocalVisualScenario.sessionProviderUnavailable) {
      // 探测失败场景：能力矩阵全部 unavailable，状态条展示 fail-closed 原因。
      relay.providersUnavailable = true;
    }
    if (scenario == LocalVisualScenario.terminalStatus ||
        scenario == LocalVisualScenario.settingsIndex ||
        scenario == LocalVisualScenario.sessionInfo ||
        scenario == LocalVisualScenario.codeViewer ||
        scenario == LocalVisualScenario.commandPalette) {
      relay.replaceTerminals([
        TerminalSummary(
          id: 'term_visual_online',
          hostname: 'MacBook Fixture',
          platform: 'macos',
          status: TerminalConnectionStatus.online,
          protocolVersion: 1,
          daemonVersion: '0.4.0-fixture',
          lastSeen: DateTime.utc(2026, 8, 14, 11, 59, 30),
        ),
        TerminalSummary(
          id: 'term_visual_stale',
          hostname: 'Linux Fixture',
          platform: 'linux',
          status: TerminalConnectionStatus.online,
          protocolVersion: 1,
          daemonVersion: '0.3.9-fixture',
          lastSeen: DateTime.utc(2026, 8, 14, 11, 54),
        ),
      ]);
    }
    if (scenario == LocalVisualScenario.usageScreen) {
      // 用量场景预置 30 天窗口的白名单整数计数（ADR-010），覆盖多 Provider 分解。
      relay.replaceUsageSummary(
        UsageSummary(
          days: 30,
          utcToday: '2026-08-14',
          providers: [
            UsageDayAggregate(
              provider: 'codex',
              utcDay: '2026-08-14',
              inputTokens: 12000,
              outputTokens: 3000,
              cacheReadTokens: 500,
              cacheWriteTokens: 200,
            ),
            UsageDayAggregate(
              provider: 'claude',
              utcDay: '2026-08-14',
              inputTokens: 8000,
              outputTokens: 2500,
              cacheReadTokens: 300,
              cacheWriteTokens: 100,
            ),
            UsageDayAggregate(
              provider: 'codex',
              utcDay: '2026-08-07',
              inputTokens: 20000,
              outputTokens: 6000,
              cacheReadTokens: 800,
              cacheWriteTokens: 400,
            ),
          ],
        ),
      );
    }
    final tokens = InMemorySecureTokenStore();
    final identities = InMemoryDeviceIdentityStore();
    final cache = InMemoryEncryptedCacheStore();
    final gitDiff = FixtureGitDiffRepository(
      scenario: scenario == LocalVisualScenario.sessionGitRestricted
          ? GitFixtureScenario.restricted
          : GitFixtureScenario.main,
    );
    final identity = await identities.createOrRead();
    final ownerBootstrap = await relay.bootstrapDevice(
      BootstrapOwnerInput(
        displayName: '本地视觉 Android 控制端',
        platform: 'android',
        keys: identity,
      ),
    );
    final ownerTokens = ownerBootstrap.tokens;
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

    if (scenario == LocalVisualScenario.dshWorkspaceHome) {
      relay.replaceTerminals([
        TerminalSummary(
          id: 'term-dsh-visual',
          hostname: 'DSH Mac Fixture',
          platform: 'macos',
          status: TerminalConnectionStatus.online,
          protocolVersion: 1,
          daemonVersion: 'v081-fixture',
          lastSeen: relay.fixtureNow(),
          capabilities: const [
            'dsh_workspace_sync',
            'dsh_session_import',
            'start',
          ],
        ),
      ]);
      relay.replaceWorkspaces(const [
        MobileWorkspace(
          id: 'ws-dsh-visual-alpha',
          projectId: 'dsh-visual-alpha',
          terminalId: 'term-dsh-visual',
          origin: MobileWorkspaceOrigin.dsh,
          displayName: 'agent-sessions',
          status: 'active',
        ),
        MobileWorkspace(
          id: 'ws-dsh-visual-empty',
          projectId: 'dsh-visual-empty',
          terminalId: 'term-dsh-visual',
          origin: MobileWorkspaceOrigin.dsh,
          displayName: '网游风格小说',
          status: 'active',
        ),
      ]);
      await relay.createSession(
        CreateMobileSessionInput(
          workspaceId: 'ws-dsh-visual-alpha',
          provider: 'dsh',
          deviceId: ownerDeviceId,
        ),
      );
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
      LocalVisualScenario.sessionComposerControls ||
      LocalVisualScenario.sessionGoalEdit ||
      LocalVisualScenario.sessionProviderUnavailable ||
      LocalVisualScenario.sessionDaemonObservation ||
      LocalVisualScenario.sessionInfo ||
      LocalVisualScenario.recentSessions ||
      LocalVisualScenario.messageDeepLink => true,
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
        kind: SessionCommandKind.start,
        idempotencyKey: 'visual-${scenario.name}-primary-start',
        leaseEpoch: lease.epoch,
        deviceId: ownerDeviceId,
        ciphertext: {
          'fixture_payload': {
            'session_id': primary.id,
            'provider': primary.provider,
          },
        },
      ),
    );
    // Composer 控件场景必须保持在 idle：fixture send 会故意生成 Question/Approval
    // 接管面板，导致目标控制条被遮挡，无法提供有效的可见验收证据。
    if (scenario != LocalVisualScenario.sessionComposerControls) {
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
    }

    if (scenario == LocalVisualScenario.sessionList) {
      // 列表场景覆盖不同最后活动时间，同时验证列表按该时间排序——新活动在前、
      // 陈旧沉底。状态仍完全由 Relay 事件提供，不随时间改写。
      final oldHours = await relay.createSession(
        CreateMobileSessionInput(
          workspaceId: 'fixture-review-workspace',
          provider: 'claude',
          deviceId: ownerDeviceId,
        ),
      );
      final oldDays = await relay.createSession(
        CreateMobileSessionInput(
          workspaceId: 'fixture-archive-workspace',
          provider: 'dsh',
          deviceId: ownerDeviceId,
        ),
      );
      // 视觉 fixture 的时钟是固定的（保证帧确定性）；时间排序基准必须用同一时钟，
      // 否则注入的活动时间会与主会话的固定时间线排序错乱。
      final now = relay.fixtureNow();
      relay.seedSessionActivity(
        sessionId: oldHours.id,
        lastActivityAt: now.subtract(const Duration(hours: 2)),
      );
      relay.seedSessionActivity(
        sessionId: oldDays.id,
        lastActivityAt: now.subtract(const Duration(days: 3)),
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
