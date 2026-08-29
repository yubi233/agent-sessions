import 'package:agent_sessions_mobile/relay/fixture_relay_repository.dart';
import 'package:agent_sessions_mobile/state/lifecycle_recovery_controller.dart';
import 'package:agent_sessions_mobile/state/session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fixture_owner.dart';

void main() {
  group('MOBILE-06 生命周期、cursor 与应用内通知', () {
    test(
      'background -> offline -> event -> foreground -> online 只补齐增量且不重放写命令',
      () async {
        final relay = FixtureRelayRepository(clock: () => _now);
        await _prepareOwner(relay);
        final sessions = SessionController(relay: relay, clock: () => _now);
        await sessions.initialize();
        final created = await sessions.createSession(
          workspaceId: 'lifecycle-workspace',
          provider: 'codex',
          deviceId: _ownerDeviceId,
          canWrite: true,
        );
        expect(created, isNotNull);
        await sessions.acquireSelectedLease(
          deviceId: _ownerDeviceId,
          canWrite: true,
        );
        final recovery = SessionRecoveryController(
          sessions: sessions,
          clock: () => _now,
        );
        final cursorBefore = sessions.selectedCursor;
        final timelineCountBefore = sessions.timeline.length;
        final commandCountBefore = relay.submittedCommandCount;
        final snapshotCountBefore = relay
            .snapshotAfterSequencesFor(created!.id)
            .length;

        await recovery.reportAppVisibility(MobileAppVisibility.background);
        await recovery.reportNetworkAvailability(
          MobileNetworkAvailability.offline,
        );
        expect(sessions.selectedLease, isNull);
        expect(
          relay.snapshotAfterSequencesFor(created.id).length,
          snapshotCountBefore,
        );

        relay.setNetworkAvailable(false);
        await relay.appendOfflineRecoveryEvent(created.id);
        // fixture 重放 cursor 边界事件，验证客户端不会把该事件重复插入时间线。
        relay.repeatCursorEventOnNextSnapshot();
        relay.setNetworkAvailable(true);
        await recovery.reportNetworkAvailability(
          MobileNetworkAvailability.online,
        );
        expect(
          relay.snapshotAfterSequencesFor(created.id).length,
          snapshotCountBefore,
        );

        await recovery.reportAppVisibility(MobileAppVisibility.foreground);

        expect(recovery.phase, SessionRecoveryPhase.recovered);
        expect(sessions.selectedCursor, cursorBefore + 1);
        expect(sessions.timeline, hasLength(timelineCountBefore + 1));
        expect(
          sessions.timeline.where((event) => event.label == '离线期间有新事件').length,
          1,
        );
        expect(relay.snapshotAfterSequencesFor(created.id).last, cursorBefore);
        expect(relay.submittedCommandCount, commandCountBefore);
        expect(recovery.latestNotice?.eventCount, 1);
        expect(recovery.latestNotice?.sessionId, created.id);

        // 重复前台事件只会从已推进 cursor 读取空增量，不能隐式调用任何写命令。
        await recovery.reportAppVisibility(MobileAppVisibility.foreground);
        expect(relay.submittedCommandCount, commandCountBefore);
        expect(sessions.timeline, hasLength(timelineCountBefore + 1));
      },
    );

    test('后台后本地 lease 失效，恢复逻辑不会把待写输入自动发送', () async {
      final relay = FixtureRelayRepository(clock: () => _now);
      await _prepareOwner(relay);
      final sessions = SessionController(relay: relay, clock: () => _now);
      await sessions.initialize();
      final created = await sessions.createSession(
        workspaceId: 'lifecycle-write-boundary',
        provider: 'codex',
        deviceId: _ownerDeviceId,
        canWrite: true,
      );
      await sessions.acquireSelectedLease(
        deviceId: _ownerDeviceId,
        canWrite: true,
      );
      final recovery = SessionRecoveryController(sessions: sessions);
      final commandCountBefore = relay.submittedCommandCount;

      await recovery.reportAppVisibility(MobileAppVisibility.background);
      await sessions.sendMessage(
        message: '这条消息需要用户重新可操作后显式发送',
        deviceId: _ownerDeviceId,
        canWrite: true,
      );

      expect(created, isNotNull);
      expect(sessions.selectedLease, isNull);
      expect(sessions.errorMessage, '会话暂不可操作，请稍后重试。');
      expect(relay.submittedCommandCount, commandCountBefore);
    });

    test('首次 online 只记录链路可用，不把新会话误标为恢复完成', () async {
      final relay = FixtureRelayRepository(clock: () => _now);
      await _prepareOwner(relay);
      final sessions = SessionController(relay: relay, clock: () => _now);
      await sessions.initialize();
      final created = await sessions.createSession(
        workspaceId: 'lifecycle-initial-online',
        provider: 'codex',
        deviceId: _ownerDeviceId,
        canWrite: true,
      );
      expect(created, isNotNull);
      final snapshotCountBefore = relay
          .snapshotAfterSequencesFor(created!.id)
          .length;
      final recovery = SessionRecoveryController(sessions: sessions);

      await recovery.reportNetworkAvailability(
        MobileNetworkAvailability.online,
      );

      expect(recovery.phase, SessionRecoveryPhase.idle);
      expect(recovery.latestNotice, isNull);
      expect(
        relay.snapshotAfterSequencesFor(created.id).length,
        snapshotCountBefore,
      );
    });

    test('应用内通知队列达到上限时保留最新十个会话恢复结果', () async {
      final relay = FixtureRelayRepository(clock: () => _now);
      await _prepareOwner(relay);
      final sessions = SessionController(relay: relay, clock: () => _now);
      await sessions.initialize();
      final recovery = SessionRecoveryController(
        sessions: sessions,
        clock: () => _now,
      );
      final sessionIds = <String>[];

      for (var index = 0; index < 11; index += 1) {
        final created = await sessions.createSession(
          workspaceId: 'lifecycle-notice-$index',
          provider: 'codex',
          deviceId: _ownerDeviceId,
          canWrite: true,
        );
        expect(created, isNotNull);
        final sessionId = created!.id;
        sessionIds.add(sessionId);

        await recovery.reportAppVisibility(MobileAppVisibility.background);
        await recovery.reportNetworkAvailability(
          MobileNetworkAvailability.offline,
        );
        relay.setNetworkAvailable(false);
        await relay.appendOfflineRecoveryEvent(sessionId);
        relay.setNetworkAvailable(true);
        await recovery.reportNetworkAvailability(
          MobileNetworkAvailability.online,
        );
        await recovery.reportAppVisibility(MobileAppVisibility.foreground);
      }

      expect(recovery.notices, hasLength(10));
      expect(recovery.notices.first.sessionId, sessionIds[1]);
      expect(recovery.notices.last.sessionId, sessionIds.last);
    });
  });
}

const _ownerDeviceId = 'android-owner-fixture';
final _now = DateTime.utc(2026, 8, 14, 23, 0);

Future<void> _prepareOwner(FixtureRelayRepository relay) async {
  await bootstrapFixtureOwner(relay);
}
