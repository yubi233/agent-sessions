import 'package:agent_sessions_mobile/app/local_visual_fixture.dart';
import 'package:agent_sessions_mobile/domain/control_models.dart';
import 'package:agent_sessions_mobile/domain/daemon_observation_models.dart';
import 'package:agent_sessions_mobile/domain/delegation_models.dart';
import 'package:agent_sessions_mobile/domain/session_models.dart';
import 'package:agent_sessions_mobile/domain/terminal_models.dart';
import 'package:agent_sessions_mobile/git/git_diff_repository.dart';
import 'package:agent_sessions_mobile/state/lifecycle_recovery_controller.dart';
import 'package:agent_sessions_mobile/state/session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('V081-10：DSH 工作区视觉场景只预置安全元数据和空工作区', () async {
    final fixture = await LocalVisualFixture.create('dsh-workspace-home');

    expect(fixture, isNotNull);
    expect(fixture!.scenario, LocalVisualScenario.dshWorkspaceHome);
    final workspaces = await fixture.relay.listWorkspaces();
    expect(workspaces.where((workspace) => workspace.isDsh), hasLength(2));
    expect(
      workspaces.map((workspace) => workspace.displayName),
      containsAll(<String>['agent-sessions', '网游风格小说']),
    );
    final sessions = await fixture.relay.listSessions();
    expect(sessions.single.provider, 'dsh');
    expect(sessions.single.workspaceId, 'ws-dsh-visual-alpha');
  });

  test('V082-P3：DSH 工具时间线视觉场景预置可渲染时间线（含工具活动）', () async {
    final fixture = await LocalVisualFixture.create('dsh-session-tool-timeline');

    expect(fixture, isNotNull);
    expect(fixture!.scenario, LocalVisualScenario.dshSessionToolTimeline);
    expect(fixture.sessionId, isNotNull);
    final sessions = await fixture.relay.listSessions();
    final dsh = sessions.single;
    expect(dsh.provider, 'dsh');
    expect(dsh.workspaceId, 'ws-dsh-visual-alpha');
    // 会话快照时间线必须含工具活动条目（fixture relay 发送生成的本地时间线词汇）。
    final snapshot = await fixture.relay.getSessionSnapshot(dsh.id);
    final timeline = snapshot.events
        .map(SessionTimelineEvent.fromRelayEvent)
        .toList(growable: false);
    expect(
      timeline.any((event) => event.kind == SessionTimelineKind.toolActivity),
      isTrue,
      reason: 'DSH 工具时间线场景必须在快照内预置 tool_activity 条目',
    );
  });

  test('V087-04：打字机流式视觉场景武装时间释放脚本并预置 DSH 会话', () async {
    final fixture = await LocalVisualFixture.create(
      'dsh-v087-typewriter-streaming',
    );

    expect(fixture, isNotNull);
    expect(fixture!.scenario, LocalVisualScenario.dshV087TypewriterStreaming);
    expect(fixture.sessionId, isNotNull);
    expect(fixture.ownerDeviceId, isNotEmpty);
    // 时间释放脚本必须已武装（40 帧 × 400ms 的 gate 默认脚本）：App 场景
    // 协调器经 controller 发送 'v087 timed' 后，回合按真实时钟逐步到达。
    final relay = fixture.relay;
    expect(relay.timedStreamSchedule, isNotNull);
    expect(relay.timedStreamSchedule!.offsets, hasLength(40));
    final sessions = await relay.listSessions();
    final dsh = sessions.single;
    expect(dsh.provider, 'dsh');
    // 脚本武装但尚未发送：此刻不产生任何流式帧。
    final snapshot = await relay.getSessionSnapshot(dsh.id);
    expect(
      snapshot.events
          .map(SessionTimelineEvent.fromRelayEvent)
          .where(
            (event) =>
                event.kind == SessionTimelineKind.assistantMessage &&
                event.isStreaming,
          ),
      isEmpty,
    );
  });

  test('V085-23：中止轨迹视觉场景预置“已中止 · 时间”并投影 stopped', () async {
    final fixture = await LocalVisualFixture.create('dsh-abort-trajectory');

    expect(fixture, isNotNull);
    expect(fixture!.scenario, LocalVisualScenario.dshAbortTrajectory);
    expect(fixture.sessionId, isNotNull);
    final sessions = await fixture.relay.listSessions();
    final dsh = sessions.single;
    expect(dsh.provider, 'dsh');
    expect(dsh.status, MobileSessionStatus.stopped);
    // 快照时间线必须包含唯一的“已中止”系统通知，且携带 created_at 时间
    //（可见窗口的“已中止 · HH:mm:ss”由轨迹行渲染，时间断言见轨迹 widget 测试）。
    final snapshot = await fixture.relay.getSessionSnapshot(dsh.id);
    final timeline = snapshot.events
        .map(SessionTimelineEvent.fromRelayEvent)
        .toList(growable: false);
    final aborted = timeline.where((event) => event.label == '已中止');
    expect(aborted, hasLength(1), reason: '中止场景必须且只能产生一条“已中止”轨迹');
    expect(aborted.single.createdAt, isNotNull);
  });

  group('MOBILE-02 本地可见 fixture', () {
    test('会话列表场景预置分组会话、当前选择所需的流式事件和无敏感展示数据', () async {
      final fixture = await LocalVisualFixture.create('session-list');

      expect(fixture, isNotNull);
      expect(fixture!.scenario, LocalVisualScenario.sessionList);
      expect(fixture.sessionId, isNotNull);
      final sessions = await fixture.relay.listSessions();
      expect(sessions, hasLength(3));
      expect(
        sessions.any(
          (session) => session.status == MobileSessionStatus.streaming,
        ),
        isTrue,
      );
      // 列表按最后活动时间排序：刚刚活跃的流式主会话在最前，两个 idle 会话按
      // 陈旧度（2 小时前、3 天前）依次沉底；陈旧不会改变 Relay 上报的状态。
      expect(sessions.first.status, MobileSessionStatus.streaming);
      expect(sessions[1].status, MobileSessionStatus.idle);
      expect(sessions[2].status, MobileSessionStatus.idle);
      expect(
        sessions[1].lastActivityAt!.isAfter(sessions[2].lastActivityAt!),
        isTrue,
      );
      expect(
        sessions.every((session) => session.projectName == 'Fixture Project'),
        isTrue,
      );
    });

    test('会话详情场景预置用户、流式、工具、确认和问题卡事件', () async {
      final fixture = await LocalVisualFixture.create('session-detail');

      expect(fixture, isNotNull);
      final snapshot = await fixture!.relay.getSessionSnapshot(
        fixture.sessionId!,
      );
      final timeline = snapshot.events
          .map(SessionTimelineEvent.fromRelayEvent)
          .toList(growable: false);
      expect(
        timeline.any((event) => event.kind == SessionTimelineKind.userMessage),
        isTrue,
      );
      expect(
        timeline.any(
          (event) =>
              event.kind == SessionTimelineKind.assistantMessage &&
              event.isStreaming,
        ),
        isTrue,
      );
      expect(
        timeline.any((event) => event.kind == SessionTimelineKind.toolActivity),
        isTrue,
      );
      expect(timeline.any((event) => event.permission != null), isTrue);
      expect(timeline.any((event) => event.question != null), isTrue);
      expect(
        snapshot.events.any((event) => event.eventType == 'session.started'),
        isTrue,
      );
    });

    test('会话 fixture 可以通过同一 lease 提交 kill 并追加结束事件', () async {
      final fixture = await LocalVisualFixture.create('session-detail');
      final sessionId = fixture!.sessionId!;
      final lease = await fixture.relay.acquireSessionLease(sessionId);
      await fixture.relay.submitSessionCommand(
        sessionId,
        SessionCommandInput(
          kind: SessionCommandKind.kill,
          idempotencyKey: 'local-visual-kill',
          leaseEpoch: lease.epoch,
          deviceId: 'android-owner-fixture',
        ),
      );
      final snapshot = await fixture.relay.getSessionSnapshot(sessionId);
      expect(snapshot.session.status, MobileSessionStatus.stopped);
      expect(
        snapshot.events.any((event) => event.eventType == 'session.killed'),
        isTrue,
      );
    });

    test('只读会话场景保留可读时间线，但不写入 owner 设备绑定', () async {
      final fixture = await LocalVisualFixture.create('session-readonly');

      expect(fixture, isNotNull);
      expect(fixture!.scenario, LocalVisualScenario.sessionReadOnly);
      expect((await fixture.tokens.read())!.deviceId, isNull);
      final snapshot = await fixture.relay.getSessionSnapshot(
        fixture.sessionId!,
      );
      expect(snapshot.events, isNotEmpty);
      expect(snapshot.session.status, MobileSessionStatus.streaming);
    });

    test('P3 能力场景使用同一会话链路，并固定覆盖 native/emulated/unsupported', () async {
      final fixture = await LocalVisualFixture.create('session-capability');

      expect(fixture, isNotNull);
      expect(fixture!.scenario, LocalVisualScenario.sessionCapability);
      final matrix = await fixture.relay.getCapabilities();
      final provider = matrix.provider('claude');
      expect(
        provider.capability('model_select').availability,
        CapabilityAvailability.native,
      );
      expect(
        provider.capability('plan').availability,
        CapabilityAvailability.emulated,
      );
      expect(
        provider.capability('attachments').availability,
        CapabilityAvailability.unsupported,
      );
    });

    test('P3 Skill 与附件场景预置的显示内容均为 deterministic fixture', () async {
      final skill = await LocalVisualFixture.create(
        'session-skill-confirmation',
      );
      final attachment = await LocalVisualFixture.create('session-attachments');
      final drafts = LocalVisualFixture.attachmentDrafts();

      expect(skill!.scenario, LocalVisualScenario.sessionSkillConfirmation);
      expect(attachment!.scenario, LocalVisualScenario.sessionAttachments);
      expect(
        drafts.take(2).every((draft) {
          draft.validate();
          return true;
        }),
        isTrue,
      );
      expect(() => drafts.last.validate(), throwsA(isA<Exception>()));
    });

    test('P4 DiffView 场景只使用固定 Git fixture，并覆盖主路径和 snapshot stale', () async {
      final main = await LocalVisualFixture.create('session-git-main');
      final restricted = await LocalVisualFixture.create(
        'session-git-restricted',
      );

      expect(main!.scenario, LocalVisualScenario.sessionGitMain);
      expect(restricted!.scenario, LocalVisualScenario.sessionGitRestricted);
      expect(main.sessionId, isNotNull);
      expect(
        (await main.gitDiff.loadSnapshot()).repositoryLabel,
        'fixture-agent-sessions',
      );
      expect(
        (await restricted.gitDiff.loadSnapshot()).repositoryLabel,
        'fixture-security-review',
      );
      expect(restricted.gitDiff.scenario, GitFixtureScenario.restricted);
    });

    test('P5 Delegation 场景只提供安全摘要、已批准 child 图和 unsupported 降级', () async {
      final proposed = await LocalVisualFixture.create(
        'session-delegation-proposed',
      );
      final approved = await LocalVisualFixture.create(
        'session-delegation-approved',
      );
      final restricted = await LocalVisualFixture.create(
        'session-delegation-restricted',
      );

      final proposedNode = (await proposed!.relay.listSessionDelegations(
        proposed.sessionId!,
      )).single;
      final approvedNode = (await approved!.relay.listSessionDelegations(
        approved.sessionId!,
      )).single;
      final restrictedNode = (await restricted!.relay.listSessionDelegations(
        restricted.sessionId!,
      )).single;

      expect(proposedNode.status, DelegationStatus.proposed);
      expect(proposedNode.summaryEnvelope.containsKey('plaintext'), isFalse);
      expect(approvedNode.status, DelegationStatus.running);
      expect(approvedNode.childSessionId, isNotNull);
      expect(restrictedNode.targetProvider, 'claude');
      expect(
        (await restricted.relay.getCapabilities())
            .provider('claude')
            .capability('delegate_cross_provider')
            .isSupported,
        isFalse,
      );
    });

    test('P6 生命周期场景通过真实 fixture cursor 恢复产生脱敏应用内通知', () async {
      final fixture = await LocalVisualFixture.create(
        'session-lifecycle-recovery',
      );

      expect(fixture, isNotNull);
      final sessions = SessionController(relay: fixture!.relay);
      await sessions.initialize();
      await sessions.selectSession(fixture.sessionId!);
      final cursorBefore = sessions.selectedCursor;
      final recovery = SessionRecoveryController(sessions: sessions);

      await fixture.stageLifecycleRecovery(recovery);

      expect(sessions.selectedCursor, cursorBefore + 1);
      expect(recovery.latestNotice?.eventCount, 1);
      expect(
        fixture.relay.snapshotAfterSequencesFor(fixture.sessionId!).last,
        cursorBefore,
      );
    });

    test('v0.2 P2 快捷菜单场景预置持有 lease 的 codex 会话（resume 可用）', () async {
      final fixture = await LocalVisualFixture.create('session-quick-menu');

      expect(fixture, isNotNull);
      expect(fixture!.scenario, LocalVisualScenario.sessionQuickMenu);
      final sessions = SessionController(relay: fixture.relay);
      await sessions.initialize();
      await sessions.selectSession(fixture.sessionId!);
      // 预置 lease：真实 controller 链路下 resume 入口应可用。
      expect(sessions.hasSelectedLease, isFalse);
      final capabilities = await fixture.relay.getCapabilities();
      expect(
        capabilities.provider('codex').capability('resume').availability,
        CapabilityAvailability.native,
      );
    });

    test('v0.2 P2 文件浏览场景预置会话与确定性文件树（无真实路径）', () async {
      final fixture = await LocalVisualFixture.create('session-files-browse');

      expect(fixture, isNotNull);
      expect(fixture!.scenario, LocalVisualScenario.sessionFilesBrowse);
      expect(fixture.sessionId, isNotNull);
      final snapshot = await fixture.relay.getSessionSnapshot(
        fixture.sessionId!,
      );
      expect(snapshot.events, isNotEmpty);
    });

    test('v0.2 P3 composer 控制面场景预置模型/effort 目录与脱敏 usage', () async {
      final fixture = await LocalVisualFixture.create(
        'session-composer-controls',
      );

      expect(fixture, isNotNull);
      expect(fixture!.scenario, LocalVisualScenario.sessionComposerControls);
      final controls = await fixture.relay.getSessionControls(
        fixture.sessionId!,
      );
      expect(controls.models, isNotEmpty);
      expect(controls.efforts, isNotEmpty);
      expect(controls.usage, isNotNull);
      expect(
        controls.models.contains(controls.model),
        isTrue,
        reason: '当前模型必须属于目录，否则 composer 下拉断言失败',
      );
    });

    test('v0.3 P3 goal 编辑场景预置 goal 与 lease 链路', () async {
      final fixture = await LocalVisualFixture.create('session-goal-edit');

      expect(fixture, isNotNull);
      expect(fixture!.scenario, LocalVisualScenario.sessionGoalEdit);
      final controls = await fixture.relay.getSessionControls(
        fixture.sessionId!,
      );
      expect(controls.goal, isNotNull);
    });

    test('v0.3 P3 Provider 探测失败场景全部能力 unavailable', () async {
      final fixture = await LocalVisualFixture.create(
        'session-provider-unavailable',
      );

      expect(fixture, isNotNull);
      expect(fixture!.scenario, LocalVisualScenario.sessionProviderUnavailable);
      final matrix = await fixture.relay.getCapabilities();
      for (final provider in matrix.providers) {
        expect(provider.available, isFalse);
        expect(provider.version, isEmpty);
        expect(
          provider.capability('start').availability,
          CapabilityAvailability.unsupported,
        );
      }
    });

    test('v0.4 P3 终端状态场景只预置白名单元数据', () async {
      final fixture = await LocalVisualFixture.create('terminal-status');

      expect(fixture, isNotNull);
      expect(fixture!.scenario, LocalVisualScenario.terminalStatus);
      expect(fixture.sessionId, isNull);
      final terminals = await fixture.relay.listTerminals();
      expect(terminals, hasLength(2));
      expect(terminals.first.hostname, 'MacBook Fixture');
      // v0.9.1：availability 只消费 Relay 投影（旧 Relay 降级为 status/protocol 派生）。
      expect(terminals.first.availability, TerminalAvailability.online);
    });

    test('v0.4 P2-F Daemon 观察场景只预置安全投影，不模拟执行或密钥交付', () async {
      final fixture = await LocalVisualFixture.create(
        'session-daemon-observation',
      );

      expect(fixture, isNotNull);
      expect(fixture!.scenario, LocalVisualScenario.sessionDaemonObservation);
      expect(fixture.sessionId, isNotNull);
      final observation = await fixture.relay.getSessionDaemonObservation(
        fixture.sessionId!,
      );
      expect(observation.commands, isNotEmpty);
      expect(
        observation.commands.every(
          (command) => command.deliveryState == DaemonDeliveryState.queued,
        ),
        isTrue,
      );
      expect(observation.events, isNotEmpty);
      expect(
        observation.events.every(
          (event) => event.envelope.state == CipherEnvelopeState.opaque,
        ),
        isTrue,
      );
    });

    test('v0.4 P3 设置中心场景预置设备、能力矩阵与终端白名单', () async {
      final fixture = await LocalVisualFixture.create('settings-index');

      expect(fixture, isNotNull);
      expect(fixture!.scenario, LocalVisualScenario.settingsIndex);
      final devices = await fixture.relay.listDevices();
      expect(devices, hasLength(1));
      expect(devices.first.isOwner, isTrue);
      final terminals = await fixture.relay.listTerminals();
      expect(terminals, hasLength(2));
      final capabilities = await fixture.relay.getCapabilities();
      expect(capabilities.providers, isNotEmpty);
      // 设置中心场景不预置会话，避免与账户/连接分区数据纠缠。
      expect(fixture.sessionId, isNull);
    });

    test('v0.4 P3 会话 info 场景预置会话与终端白名单，但不预置正文', () async {
      final fixture = await LocalVisualFixture.create('session-info');

      expect(fixture, isNotNull);
      expect(fixture!.scenario, LocalVisualScenario.sessionInfo);
      expect(fixture.sessionId, isNotNull);
      final terminals = await fixture.relay.listTerminals();
      expect(terminals, hasLength(2));
      // info 场景的会话只经过 send 链路，不写入消息正文明文。
      final snapshot = await fixture.relay.getSessionSnapshot(
        fixture.sessionId!,
      );
      expect(snapshot.events, isNotEmpty);
      for (final event in snapshot.events) {
        expect(event.envelope, isNotEmpty);
      }
    });
  });
}
