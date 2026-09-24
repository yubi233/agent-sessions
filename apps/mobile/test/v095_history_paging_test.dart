import 'dart:math' as math;

import 'package:agent_sessions_mobile/domain/session_models.dart';
import 'package:agent_sessions_mobile/relay/fixture_relay_repository.dart';
import 'package:agent_sessions_mobile/state/session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fixture_owner.dart';

/// v0.9.5 P2（历史向前翻页）回归：服务端首屏窗口（最新 200 条 + has_more）下，
/// 「加载更早」先展开本地窗口、耗尽后以 before_seq 向服务端续拉，直到头部；
/// canLoadOlder 在全部历史加载完后收敛为 false。
class _PagedHistoryRelay extends FixtureRelayRepository {
  _PagedHistoryRelay({required super.clock});

  static const totalEvents = 320;
  int serverPageCalls = 0;

  RelaySessionEvent _event(int seq) => RelaySessionEvent(
        sequence: seq,
        eventType: 'user.message',
        envelope: {
          'fixture_payload': {
            'kind': 'user_message',
            'label': '你',
            'text': 'm$seq',
            'streaming': false,
            'copy_text': 'm$seq',
          },
        },
      );

  List<RelaySessionEvent> _range(int startInclusive, int endInclusive) => [
        for (var seq = startInclusive; seq <= endInclusive; seq++) _event(seq),
      ];

  @override
  Future<SessionSnapshot> getSessionSnapshot(
    String sessionId, {
    int afterSequence = 0,
    int? beforeSequence,
    int? limit,
  }) async {
    final base = await super.getSessionSnapshot(
      sessionId,
      afterSequence: afterSequence,
    );
    if (beforeSequence != null && beforeSequence >= 0) {
      // 向前翻页：返回 (beforeSequence-25, beforeSequence] 且不早于 1。
      serverPageCalls += 1;
      final end = beforeSequence - 1;
      final start = (end - 24).clamp(1, end);
      final page = start <= end ? _range(start, end) : const <RelaySessionEvent>[];
      return SessionSnapshot(
        session: base.session,
        events: page,
        hasMore: start > 1,
        oldestEventSeq: page.isEmpty ? 0 : page.first.sequence,
      );
    }
    if (afterSequence > 0) {
      // 增量：固定会话无新事件。
      return SessionSnapshot(session: base.session, events: const []);
    }
    // 首屏窗口：最新 200 条（event_seq 121..320），has_more=true。
    return SessionSnapshot(
      session: base.session.copyWith(lastSequence: totalEvents),
      events: _range(totalEvents - 199, totalEvents),
      hasMore: true,
      oldestEventSeq: totalEvents - 199,
    );
  }
}

class _DeterministicRandom implements math.Random {
  var _value = 0;

  @override
  bool nextBool() => nextInt(2) == 1;

  @override
  double nextDouble() => nextInt(1 << 20) / (1 << 20);

  @override
  int nextInt(int max) {
    _value += 1;
    return _value % max;
  }
}

final DateTime _now = DateTime.utc(2026, 9, 25, 9, 30);

void main() {
  test('V095-P2：首屏窗口 + 本地展开耗尽后经 before_seq 续拉到头部', () async {
    final relay = _PagedHistoryRelay(clock: () => _now);
    final owner = await bootstrapFixtureOwner(relay);
    final controller = SessionController(
      relay: relay,
      clock: () => _now,
      random: _DeterministicRandom(),
    );
    await controller.initialize();

    final created = await controller.createSession(
      workspaceId: 'fixture-workspace',
      provider: 'codex',
      deviceId: owner.deviceId,
      canWrite: true,
    );
    expect(created, isNotNull);
    await controller.selectSession(created!.id);

    // 首屏：服务端窗口 200 条，可见切片 50 条，可继续加载。
    expect(controller.hasMoreServerHistory(created.id), isTrue);
    expect(controller.canLoadOlder, isTrue);
    expect(controller.timeline, isNotEmpty);

    var guard = 0;
    while (controller.canLoadOlder && guard < 60) {
      guard += 1;
      await controller.loadOlderHistory();
    }
    expect(guard, lessThan(60), reason: '加载更早必须在有限步内收敛到头部');
    expect(controller.timeline, hasLength(_PagedHistoryRelay.totalEvents));
    expect(controller.timeline.first.sequence, 1);
    expect(controller.timeline.last.sequence, _PagedHistoryRelay.totalEvents);
    expect(controller.hasMoreServerHistory(created.id), isFalse,
        reason: '翻页到头部后 must 清除 hasMore 标记');
    expect(relay.serverPageCalls, greaterThanOrEqualTo(4),
        reason: '本地窗口（200）之外必须经服务端翻页补齐（320-200=120，25/页 ≥ 5 页）');
  });
}
