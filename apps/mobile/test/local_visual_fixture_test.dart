import 'package:agent_sessions_mobile/app/local_visual_fixture.dart';
import 'package:agent_sessions_mobile/domain/control_models.dart';
import 'package:agent_sessions_mobile/domain/delegation_models.dart';
import 'package:agent_sessions_mobile/domain/session_models.dart';
import 'package:agent_sessions_mobile/git/git_diff_repository.dart';
import 'package:agent_sessions_mobile/state/lifecycle_recovery_controller.dart';
import 'package:agent_sessions_mobile/state/session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MOBILE-02 本地可见 fixture', () {
    test('会话列表场景预置分组会话、当前选择所需的流式事件和无敏感展示数据', () async {
      final fixture = await LocalVisualFixture.create('session-list');

      expect(fixture, isNotNull);
      expect(fixture!.scenario, LocalVisualScenario.sessionList);
      expect(fixture.sessionId, isNotNull);
      final sessions = await fixture.relay.listSessions();
      expect(sessions, hasLength(2));
      expect(
        sessions.any(
          (session) => session.status == MobileSessionStatus.streaming,
        ),
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
  });
}
