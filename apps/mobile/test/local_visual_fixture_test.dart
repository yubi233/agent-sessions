import 'package:agent_sessions_mobile/app/local_visual_fixture.dart';
import 'package:agent_sessions_mobile/domain/session_models.dart';
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
  });
}
