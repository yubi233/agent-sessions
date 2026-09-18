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
  // v0.8.2：DSH 会话工具时间线可见场景（会话详情打开即含工具活动条目）。
  dshSessionToolTimeline,
  // v0.8.3：DSH 能力门控可见场景（无 lease 只读态；unsupported 能力不渲染写入口）。
  dshCapabilityGates,
  // v0.8.4（ADR-015 §3/§5）：流式投影可见场景（phase 状态行 + thought 通道 + 打字机）。
  dshStreamingTurnPhase,
  // v0.8.5：中止与轨迹时间可见场景（发送后中止：唯一“已中止 · HH:mm:ss”轨迹，
  // 缺失时间条目显示“时间未知”，与实施记录 23 收口条件一致）。
  dshAbortTrajectory,
  // v0.8.5 主计划可见场景：工作区显示名（无写死兜底）+ Agent 预设只读 label +
  // usage timing chips（首字/解码）+ 权限 mode 目录可点（实施记录 24 收口条件）。
  dshV085ReadonlyProjections,
  // v0.8.7：打字机式流式传输可见场景（时间释放脚本真实时钟驱动，气泡文本
  // 逐步生长；双门禁证据由场景宿主采样写入 streaming-gate 文件）。
  dshV087TypewriterStreaming,
  // v0.9.1（V091-14）：Terminal presence 四态可见场景（online/offline/unknown/
  // unsupported 来自 Relay availability 投影；headed gate 专用，见 run-macos-v091.mjs）。
  terminalPresenceV091,
  // v0.9.2（V092，录屏内容先定 2026-09-16）：DSH 发送闭环与能力事实源可见场景。
  // 画面序列：① 执行侧上报不可用 → DSH 会话 composer 展示真实原因（不是笼统
  // "Provider 当前不可用"）；② 执行侧恢复可用（等同修好 node/桥路径）→ composer
  // 恢复可发送；③ 会话时间线出现发送后的用户消息与终态。全部数据来自确定性
  // fixture，不连接真实 Relay、不调用模型。
  dshV092SendLoop,
  // v0.9.4（V094，计划 P0 fixture 冻结 2026-09-19）：会话 UI 全面优化三场景。
  // baseline：富 Markdown 历史（表格/代码/列表）；recovery：结构化错误 +
  // 自动恢复历史；config：长模型名 + 完全访问权限目录（紧凑徽标 gate）。
  // 录制环境基线：360×800 逻辑尺寸、textScale 1.0、亮/暗双主题、revision 见
  // e2e-verify 报告 manifest；全部为公开 fixture 文本，不连接真实 Relay。
  v094SessionUiBaseline,
  v094SessionUiRecovery,
  v094SessionUiConfig,
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
  'terminal-presence-v091' => LocalVisualScenario.terminalPresenceV091,
  'dsh-v092-send-loop' => LocalVisualScenario.dshV092SendLoop,
  'v094-session-ui-baseline' => LocalVisualScenario.v094SessionUiBaseline,
  'v094-session-ui-recovery' => LocalVisualScenario.v094SessionUiRecovery,
  'v094-session-ui-config' => LocalVisualScenario.v094SessionUiConfig,
  'dsh-session-tool-timeline' => LocalVisualScenario.dshSessionToolTimeline,
  'dsh-capability-gates' => LocalVisualScenario.dshCapabilityGates,
  'dsh-streaming-turn-phase' =>
    LocalVisualScenario.dshStreamingTurnPhase,
  'dsh-abort-trajectory' => LocalVisualScenario.dshAbortTrajectory,
  'dsh-v085-readonly-projections' =>
    LocalVisualScenario.dshV085ReadonlyProjections,
  'dsh-v087-typewriter-streaming' =>
    LocalVisualScenario.dshV087TypewriterStreaming,
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
    required this.ownerDeviceId,
    this.pairingRequestId,
    this.sessionId,
  });

  final LocalVisualScenario scenario;

  /// fixture owner 设备绑定（v0.8.7 场景协调器经 controller 发送回合时使用）。
  final String ownerDeviceId;
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
      // v0.8.7 打字机流式场景必须用真实时钟：时间释放脚本按墙上时间到期
      // （40×400ms ≈ 16.4s，落在可见 gate 60s 采集窗内）；其余场景保持
      // 冻结时钟以稳定截图内容。
      clock: scenario == LocalVisualScenario.dshV087TypewriterStreaming
          ? null
          : () => DateTime.utc(2026, 8, 14, 12),
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

    // v0.9.2 场景预置见下方 dshSessionId 声明之后（需要 ownerDeviceId 与会话 id 变量）。
    if (scenario == LocalVisualScenario.terminalPresenceV091) {
      // v0.9.1（V091-14）：四态 presence 投影 fixture。availability /
      // presence_revision 是 Relay additive 权威字段；fixtures 不含真实
      // Terminal ID、路径或正文（脱敏口径与 docs/test/29 环境声明一致）。
      TerminalSummary v091Terminal(
        String id,
        String availability, {
        int revision = 1,
        List<String> capabilities = const ['dsh_workspace_sync', 'start'],
      }) => TerminalSummary.fromRelayJson({
        'id': 'term-v091-$id',
        'hostname': 'V091 $id',
        'platform': 'macos',
        'status': availability == 'offline' ? 'offline' : 'online',
        'protocol_version': availability == 'unsupported' ? 2 : 1,
        'availability': availability,
        'presence_revision': revision,
        'last_heartbeat_unix_ms':
            DateTime.utc(2026, 9, 8, 12).millisecondsSinceEpoch,
        'capabilities': capabilities,
      });
      relay.replaceTerminals([
        v091Terminal('online', 'online'),
        v091Terminal('offline', 'offline'),
        v091Terminal('unknown', 'unknown'),
        v091Terminal('unsupported', 'unsupported'),
      ]);
      relay.replaceWorkspaces(const [
        MobileWorkspace(
          id: 'ws-v091-online',
          projectId: 'v091-online',
          terminalId: 'term-v091-online',
          origin: MobileWorkspaceOrigin.dsh,
          displayName: 'agent-sessions',
          status: 'active',
        ),
        MobileWorkspace(
          id: 'ws-v091-offline',
          projectId: 'v091-offline',
          terminalId: 'term-v091-offline',
          origin: MobileWorkspaceOrigin.dsh,
          displayName: '离线终端工作区',
          status: 'active',
        ),
      ]);
    }
    final isDshScenario = scenario == LocalVisualScenario.dshWorkspaceHome ||
        scenario == LocalVisualScenario.dshSessionToolTimeline ||
        scenario == LocalVisualScenario.dshCapabilityGates ||
        scenario == LocalVisualScenario.dshStreamingTurnPhase ||
        scenario == LocalVisualScenario.dshAbortTrajectory ||
        scenario == LocalVisualScenario.dshV085ReadonlyProjections ||
        scenario == LocalVisualScenario.dshV087TypewriterStreaming ||
        scenario == LocalVisualScenario.v094SessionUiBaseline ||
        scenario == LocalVisualScenario.v094SessionUiRecovery ||
        scenario == LocalVisualScenario.v094SessionUiConfig;
    String? dshSessionId;
    if (scenario == LocalVisualScenario.dshV092SendLoop) {
      // v0.9.2（V092）：DSH 发送闭环可见场景（录屏内容先定 2026-09-16）。
      // 预置一套安全投影（工作区只含 display name 与 opaque 元数据），把 dsh 的
      // 能力事实来源标注为执行侧上报，并保留“执行侧当前不可用”的初始态。
      relay.executionSideDshUnavailable = true;
      relay.replaceTerminals([
        TerminalSummary.fromRelayJson({
          'id': 'term-v092-dsh',
          'hostname': 'V092 执行侧',
          'platform': 'macos',
          'status': 'online',
          'protocol_version': 1,
          'availability': 'online',
          'presence_revision': 1,
          'last_heartbeat_unix_ms':
              DateTime.utc(2026, 9, 16, 12).millisecondsSinceEpoch,
          'capabilities': const ['dsh_workspace_sync', 'start', 'send', 'resume'],
        }),
      ]);
      relay.replaceWorkspaces(const [
        MobileWorkspace(
          id: 'ws-v092-dsh',
          projectId: 'v092-dsh',
          terminalId: 'term-v092-dsh',
          origin: MobileWorkspaceOrigin.dsh,
          displayName: 'agent-sessions',
          status: 'active',
        ),
      ]);
      // 会话必须先存在：只有会话详情页的 composer/模型入口才会把执行侧给出的
      // 不可用原因渲染成可见文案（G4 的断言面）。
      final v092Session = await relay.createSession(
        CreateMobileSessionInput(
          workspaceId: 'ws-v092-dsh',
          provider: 'dsh',
          deviceId: ownerDeviceId,
        ),
      );
      dshSessionId = v092Session.id;
    }
    if (isDshScenario) {
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
      final dshSession = await relay.createSession(
        CreateMobileSessionInput(
          workspaceId: 'ws-dsh-visual-alpha',
          provider: 'dsh',
          deviceId: ownerDeviceId,
        ),
      );
      dshSessionId = dshSession.id;
      if (scenario == LocalVisualScenario.dshStreamingTurnPhase) {
        // v0.8.4 流式场景：消息带 'v084 stream' 标记，fixture relay 生成
        // turn_phase + assistant_thought + 打字机增量的本地开发时间线（ADR-015）。
        final lease = await relay.acquireSessionLease(dshSession.id);
        await relay.submitSessionCommand(
          dshSession.id,
          SessionCommandInput(
            kind: SessionCommandKind.send,
            idempotencyKey: 'visual-dsh-streaming-turn-phase-send',
            leaseEpoch: lease.epoch,
            deviceId: ownerDeviceId,
            ciphertext: const {
              'fixture_payload': {
                'message': 'v084 stream 演示：展示相位状态行与思考通道。',
              },
            },
          ),
        );
      }
      if (scenario == LocalVisualScenario.dshV087TypewriterStreaming) {
        // v0.8.7：武装时间释放脚本（gateDefault：40 帧 × 400ms ≈ 16s）。
        // 发送由 main.dart 场景协调器经 session controller 触发（'v087 timed'），
        // 在途轮询（250ms 收紧档）驱动气泡文本逐步生长并写入双门禁证据。
        relay.timedStreamSchedule = TimedStreamSchedule.gateDefault();
      }
      // V094（计划 P0 fixture 冻结）：会话 UI 三场景共用 DSH 基础设施，
      // 经固定 marker 触发确定性时间线（见 _appendSendConversation 的
      // v094 markdown / v094 recovery 分支），config 场景额外切长模型名。
      if (scenario == LocalVisualScenario.v094SessionUiBaseline ||
          scenario == LocalVisualScenario.v094SessionUiRecovery) {
        final lease = await relay.acquireSessionLease(dshSession.id);
        final marker = scenario == LocalVisualScenario.v094SessionUiBaseline
            ? 'v094 markdown 演示：表格、代码块与行内代码。'
            : 'v094 recovery 演示：发送失败后自动恢复。';
        await relay.submitSessionCommand(
          dshSession.id,
          SessionCommandInput(
            kind: SessionCommandKind.send,
            idempotencyKey: scenario == LocalVisualScenario.v094SessionUiBaseline
                ? 'visual-v094-baseline-send'
                : 'visual-v094-recovery-send',
            leaseEpoch: lease.epoch,
            deviceId: ownerDeviceId,
            ciphertext: {
              'fixture_payload': {'message': marker},
            },
          ),
        );
      }
      if (scenario == LocalVisualScenario.v094SessionUiConfig) {
        // config 场景：长模型名 + 完全访问徽标的确定性投影（UI-15/16 gate）。
        // 通过 fixture 的 controls 覆盖钩子注入目录外长名称，权限目录沿用
        // 默认 controls（含展示目录说明）；不伪造切换命令回执。
        final controls = await relay.getSessionControls(dshSession.id);
        relay.applyVisualControlsOverride(
          dshSession.id,
          controls.copyWith(
            model: 'deepseek-v4.1-flash-128k-context-preview',
            permissionMode: 'danger-full-access',
          ),
        );
      }
      if (scenario == LocalVisualScenario.dshSessionToolTimeline) {
        // 时间线场景：fixture 发送一条消息，触发 fixture relay 生成完整的
        // 本地开发时间线（user_message → tool_activity → assistant_message），
        // 与 LocalDevEventEncoder 投影词汇一致（不注入真实命令/正文）。
        final lease = await relay.acquireSessionLease(dshSession.id);
        await relay.submitSessionCommand(
          dshSession.id,
          SessionCommandInput(
            kind: SessionCommandKind.send,
            idempotencyKey: 'visual-dsh-tool-timeline-send',
            leaseEpoch: lease.epoch,
            deviceId: ownerDeviceId,
            ciphertext: const {
              'fixture_payload': {'message': '请展示 DSH fixture 的工具活动时间线。'},
            },
          ),
        );
      }
      if (scenario == LocalVisualScenario.dshAbortTrajectory) {
        // v0.8.5 中止场景：先发送一条进入生成中的消息，再提交 abort，fixture
        // 产生唯一的“已中止 · HH:mm:ss”轨迹并投影 stopped；展示发送时间与
        // 中止时间都真实可见（实施记录 23 收口条件）。
        final lease = await relay.acquireSessionLease(dshSession.id);
        await relay.submitSessionCommand(
          dshSession.id,
          SessionCommandInput(
            kind: SessionCommandKind.send,
            idempotencyKey: 'visual-dsh-abort-send',
            leaseEpoch: lease.epoch,
            deviceId: ownerDeviceId,
            ciphertext: const {
              'fixture_payload': {'message': '你好'},
            },
          ),
        );
        await relay.submitSessionCommand(
          dshSession.id,
          SessionCommandInput(
            kind: SessionCommandKind.abort,
            idempotencyKey: 'visual-dsh-abort-stop',
            leaseEpoch: lease.epoch,
            deviceId: ownerDeviceId,
          ),
        );
      }
      if (scenario == LocalVisualScenario.dshV085ReadonlyProjections) {
        // v0.8.5 主计划可见场景（实施记录 24）：以用户案例中的 money 工作区建独立
        // 会话——副标题显示工作区显示名（无写死兜底）、Agent preset 只读 label、
        // usage timing chips（fixture controls 已带 ttft/decode）、权限 mode 目录
        // 可点（default/plan/acceptEdits/danger-full-access，均来自 controls）。
        relay.replaceWorkspaces(const [
          MobileWorkspace(
            id: 'ws-dsh-visual-money',
            projectId: 'dsh-visual-money',
            terminalId: 'term-dsh-visual',
            origin: MobileWorkspaceOrigin.dsh,
            displayName: 'money',
            status: 'active',
          ),
        ]);
        final moneySession = await relay.createSession(
          CreateMobileSessionInput(
            workspaceId: 'ws-dsh-visual-money',
            provider: 'dsh',
            deviceId: ownerDeviceId,
            // v0.8.5 §3.8：会话实际 joined 的预设（standard）经 sessionView 只读投影，
            // fixture 与真实 Relay 同构注入——生产链路选择器不渲染，label 只读展示。
            agentPresetId: 'standard',
          ),
        );
        dshSessionId = moneySession.id;
        final lease = await relay.acquireSessionLease(moneySession.id);
        await relay.submitSessionCommand(
          moneySession.id,
          SessionCommandInput(
            kind: SessionCommandKind.send,
            idempotencyKey: 'visual-dsh-v085-readonly-send',
            leaseEpoch: lease.epoch,
            deviceId: ownerDeviceId,
            ciphertext: const {
              'fixture_payload': {'message': '展示 v0.8.5 只读投影与权限目录。'},
            },
          ),
        );
      }
    }

    final sessionId = dshSessionId ?? await _seedSessionScenario(
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
      ownerDeviceId: ownerDeviceId,
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
