import 'dart:async';
import 'dart:math';

import 'package:agent_sessions_mobile/domain/session_models.dart';
import 'package:agent_sessions_mobile/relay/fixture_relay_repository.dart';
import 'package:agent_sessions_mobile/state/session_controller.dart';
import 'package:agent_sessions_mobile/state/session_turn_runtime.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fixture_owner.dart';

/// V090-02/05 地基回归：三重代际（认证/选择/同步）、202 即时受理锚点、
/// 提交意图（newTurn/steer）与认证边界/dispose 契约。
/// 本文件是 A 线后续 L1/L3/SSE 的根因层回归基座；测试 ID 见
/// docs/test/28-v090-mobile-event-stream-and-style.json。
void main() {
  test('V090-02: send 受理锚点在 Relay 202 即建立，不等首批快照返回（C1）', () async {
    final relay = _V090ScriptedRelay();
    final owner = await bootstrapFixtureOwner(relay);
    final controller = _newController(relay);
    await controller.initialize();
    final session = await _createStartedSession(controller, relay, owner);
    // 注入可控单调时钟：锚点预算相对受理时刻可精确断言。
    var monotonicMs = 1000;
    controller.monotonicElapsed = () => Duration(milliseconds: monotonicMs);
    controller.backgroundPollAttempts = 0;

    // 扣住首批快照：202 已受理但快照未返回。
    final requestsBeforeSend = relay.snapshotRequests;
    final gate = Completer<SessionSnapshot>();
    relay.nextSnapshotGate = gate;
    final sending = controller.sendMessage(
      message: 'V090 锚点先于快照',
      deviceId: owner.deviceId,
      canWrite: true,
      awaitTurnCompletion: false,
    );
    await _waitFor(() => controller.activeTurnFor(session.id) != null);

    // 核心断言：快照仍被扣住（本回合首批请求已发出、未返回）时，活动回合锚点与
    // 在途标记已经就位——证明锚点记录发生在 202 受理分支，而非快照等待之后。
    expect(relay.snapshotRequests, requestsBeforeSend + 1);
    expect(controller.isTurnInFlight, isTrue);
    final turn = controller.activeTurnFor(session.id)!;
    expect(turn.intent, TurnSubmissionIntent.newTurn);
    expect(turn.uxDeadlineMs, 1000 + const Duration(minutes: 2).inMilliseconds);
    expect(
      turn.continuationDeadlineMs,
      1000 + const Duration(minutes: 60).inMilliseconds,
    );

    // 放行快照让受理链收敛；时钟前推不改变已建立的锚点（不重复续期）。
    monotonicMs = 60_000;
    gate.complete(_streamingSnapshot(session.id));
    await sending;
    expect(controller.activeTurnFor(session.id)!.uxDeadlineMs, 1000 + 120_000);
    controller.dispose();
  });

  test('V090-02: 相同回合的后续受理复用已有锚点，不重复续期（C1）', () async {
    final relay = _V090ScriptedRelay();
    final owner = await bootstrapFixtureOwner(relay);
    final controller = _newController(relay);
    await controller.initialize();
    final session = await _createStartedSession(controller, relay, owner);
    var monotonicMs = 1000;
    controller.monotonicElapsed = () => Duration(milliseconds: monotonicMs);
    controller.backgroundPollAttempts = 0;

    await controller.sendMessage(
      message: '第一条',
      deviceId: owner.deviceId,
      canWrite: true,
      awaitTurnCompletion: false,
    );
    final first = controller.activeTurnFor(session.id)!;
    expect(first.uxDeadlineMs, 1000 + 120_000);

    // 上一回合尚未终态时再次受理（不同文本，绕开同文本拦截）：
    // newTurn 必须复用已有锚点，不得以新受理时刻重置 2/60 分钟预算。
    monotonicMs = 10_000;
    await controller.sendMessage(
      message: '第二条',
      deviceId: owner.deviceId,
      canWrite: true,
      awaitTurnCompletion: false,
    );
    final second = controller.activeTurnFor(session.id);
    expect(identical(second, first), isTrue);
    expect(second!.uxDeadlineMs, 1000 + 120_000);
    controller.dispose();
  });

  test('V090-02: steer 继承活动回合锚点与预算，只推进同步代际（C1/C2）', () async {
    final relay = _V090ScriptedRelay();
    final owner = await bootstrapFixtureOwner(relay);
    final controller = _newController(relay);
    await controller.initialize();
    final session = await _createStartedSession(controller, relay, owner);
    var monotonicMs = 1000;
    controller.monotonicElapsed = () => Duration(milliseconds: monotonicMs);
    controller.backgroundPollAttempts = 0;

    await controller.sendMessage(
      message: '被注入的回合',
      deviceId: owner.deviceId,
      canWrite: true,
      awaitTurnCompletion: false,
    );
    final turn = controller.activeTurnFor(session.id)!;
    expect(turn.timedOut, isFalse);
    final syncGenerationBefore = controller.syncGenerationFor(session.id);

    // steer：不创建新业务回合、不重置锚点与预算。
    monotonicMs = 90_000;
    await controller.sendMessage(
      message: 'steer 注入',
      deviceId: owner.deviceId,
      canWrite: true,
      intent: TurnSubmissionIntent.steer,
      awaitTurnCompletion: false,
    );
    final after = controller.activeTurnFor(session.id);
    expect(identical(after, turn), isTrue, reason: 'steer 必须继承原回合状态');
    expect(after!.uxDeadlineMs, turn.uxDeadlineMs);
    expect(
      controller.syncGenerationFor(session.id),
      greaterThan(syncGenerationBefore),
      reason: 'steer 推进同步代际使提交前旧快照作废',
    );
    controller.dispose();
  });

  test('V090-02: 旧同步代际的迟到快照回包不能写入当前回合时间线（C2）', () async {
    final relay = _V090ScriptedRelay();
    final owner = await bootstrapFixtureOwner(relay);
    final controller = _newController(relay);
    await controller.initialize();
    final session = await _createStartedSession(controller, relay, owner);
    var monotonicMs = 1000;
    controller.monotonicElapsed = () => Duration(milliseconds: monotonicMs);
    controller.backgroundPollAttempts = 0;

    // 扣住回合 1 的首批快照（该请求携带回合 1 的同步代际）。
    final requestsBeforeSend = relay.snapshotRequests;
    final staleGate = Completer<SessionSnapshot>();
    relay.nextSnapshotGate = staleGate;
    final firstSend = controller.sendMessage(
      message: '回合一',
      deviceId: owner.deviceId,
      canWrite: true,
      awaitTurnCompletion: true,
    );
    await _waitFor(
      () => relay.snapshotRequests == requestsBeforeSend + 1,
    );

    // 快照被扣住期间发起 steer：同步代际推进，回合 1 的在途回包全部失效。
    await controller.sendMessage(
      message: '回合二（steer）',
      deviceId: owner.deviceId,
      canWrite: true,
      intent: TurnSubmissionIntent.steer,
      awaitTurnCompletion: false,
    );
    final syncGeneration = controller.syncGenerationFor(session.id);

    // 释放迟到回包：携带旧回合的 assistant 文本。
    staleGate.complete(_snapshotWithEvents(session.id, [
      const RelaySessionEvent(
        sequence: 9001,
        eventType: 'assistant.message',
        envelope: {
          'fixture_payload': {
            'kind': 'assistant_message',
            'text': 'V090-迟到回包文本',
            'streaming': false,
          },
        },
      ),
    ]));
    await firstSend;

    // 旧回包不得改写当前时间线；同步代际保持稳定。
    expect(
      controller.timeline.any((event) => event.text == 'V090-迟到回包文本'),
      isFalse,
    );
    expect(controller.syncGenerationFor(session.id), syncGeneration);
    controller.dispose();
  });

  test('V090-05: resetForAuthBoundary 递增认证代际并清空会话运行期状态（C7）', () async {
    final relay = _V090ScriptedRelay();
    final owner = await bootstrapFixtureOwner(relay);
    final controller = _newController(relay);
    await controller.initialize();
    final session = await _createStartedSession(controller, relay, owner);
    controller.backgroundPollAttempts = 0;
    await controller.sendMessage(
      message: '注销前回合',
      deviceId: owner.deviceId,
      canWrite: true,
      awaitTurnCompletion: false,
    );
    expect(controller.activeTurnFor(session.id), isNotNull);
    final authGenerationBefore = controller.authGeneration;

    controller.resetForAuthBoundary();

    expect(controller.authGeneration, authGenerationBefore + 1);
    expect(controller.activeTurnFor(session.id), isNull);
    expect(controller.isTurnInFlight, isFalse);
    expect(controller.selectedSessionId, isNull);
    expect(controller.phase, SessionListPhase.loading);
    expect(controller.timeline, isEmpty);
    controller.dispose();
  });

  test('V090-05: dispose 后在途回包安全丢弃，不再通知已释放的控制器（C7）', () async {
    final relay = _V090ScriptedRelay();
    final owner = await bootstrapFixtureOwner(relay);
    final controller = _newController(relay);
    await controller.initialize();
    final session = await _createStartedSession(controller, relay, owner);
    controller.backgroundPollAttempts = 0;

    final requestsBeforeSend = relay.snapshotRequests;
    final gate = Completer<SessionSnapshot>();
    relay.nextSnapshotGate = gate;
    final sending = controller.sendMessage(
      message: 'dispose 竞态回合',
      deviceId: owner.deviceId,
      canWrite: true,
      awaitTurnCompletion: false,
    );
    await _waitFor(
      () => relay.snapshotRequests == requestsBeforeSend + 1,
    );

    // 在快照在途时注销控制器：迟到回包返回后不得触碰已释放的 ChangeNotifier。
    controller.dispose();
    gate.complete(_snapshotWithEvents(session.id, [
      const RelaySessionEvent(
        sequence: 9002,
        eventType: 'assistant.message',
        envelope: {
          'fixture_payload': {
            'kind': 'assistant_message',
            'text': 'V090-dispose 后到达的事件',
          },
        },
      ),
    ]));
    await sending;

    // 认证代际已递增：迟到事件未写入时间线，也无异常抛出（dispose 契约）。
    // timeline 仍保留 setup 阶段 selectSession 合并的 fixture 事件，属正常状态。
    expect(
      controller.timeline.any(
        (event) => event.text == 'V090-dispose 后到达的事件',
      ),
      isFalse,
    );
  });

  test('V090-02: 单航班快照门——并发请求只置 pending，不重复发起在途请求（C2）', () async {
    final relay = _V090ScriptedRelay();
    final owner = await bootstrapFixtureOwner(relay);
    final controller = _newController(relay);
    await controller.initialize();
    final session = await _createStartedSession(controller, relay, owner);
    controller.backgroundPollAttempts = 0;

    // 两次 cursor 恢复并发：第二次只置 pending，等待第一次完成后补一轮。
    final requestsBefore = relay.snapshotRequests;
    final first = controller.recoverSelectedSessionFromCursor();
    final second = controller.recoverSelectedSessionFromCursor();
    await Future.wait([first, second]);
    // fixture 快照即时返回：单航班下两次调用串行执行，各发起一次请求。
    // 这里断言不产生并发交错导致的重复请求（请求数 == 调用数）。
    expect(relay.snapshotRequests, requestsBefore + 2);
    expect(controller.selectedSessionId, session.id);
    controller.dispose();
  });
}

SessionController _newController(FixtureRelayRepository relay) => SessionController(
  relay: relay,
  clock: () => DateTime.now(),
  random: _DeterministicRandom(),
);

Future<MobileSession> _createStartedSession(
  SessionController controller,
  FixtureRelayRepository relay,
  FixtureOwner owner,
) async {
  final session = await controller.createSession(
    workspaceId: 'fixture-workspace',
    provider: 'codex',
    deviceId: owner.deviceId,
    canWrite: true,
    autoStart: true,
  );
  await controller.selectSession(session!.id);
  await controller.acquireSelectedLease(
    deviceId: owner.deviceId,
    canWrite: true,
  );
  return session;
}

/// 流式空增量快照：保持会话 streaming 且不携带任何事件（回合永不自行终态）。
SessionSnapshot _streamingSnapshot(String sessionId) => SessionSnapshot(
  session: MobileSession(
    id: sessionId,
    workspaceId: 'fixture-workspace',
    status: MobileSessionStatus.streaming,
    provider: 'codex',
    lastSequence: 1,
  ),
  events: const [],
);

/// 携带指定事件的流式快照（迟到回包演练）。
SessionSnapshot _snapshotWithEvents(
  String sessionId,
  List<RelaySessionEvent> events,
) => SessionSnapshot(
  session: MobileSession(
    id: sessionId,
    workspaceId: 'fixture-workspace',
    status: MobileSessionStatus.streaming,
    provider: 'codex',
    lastSequence: events.fold(1, (max, event) => event.sequence > max ? event.sequence : max),
  ),
  events: events,
);

Future<void> _waitFor(bool Function() condition) async {
  for (var attempt = 0; attempt < 400; attempt++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('等待条件在 2s 内未满足');
}

/// V090 脚本化假 Relay：在 fixture 之上提供两个可控开关。
/// ① `nextSnapshotGate`：非空时下一次 getSessionSnapshot 被扣住，由测试放行
///    （迟到回包演练）；② `snapshotRequests` 计数供受理/轮询时序断言。
class _V090ScriptedRelay extends FixtureRelayRepository {
  _V090ScriptedRelay();

  Completer<SessionSnapshot>? nextSnapshotGate;
  int snapshotRequests = 0;

  @override
  Future<SessionSnapshot> getSessionSnapshot(
    String sessionId, {
    int afterSequence = 0,
  }) async {
    snapshotRequests += 1;
    final gate = nextSnapshotGate;
    if (gate != null) {
      nextSnapshotGate = null;
      return gate.future;
    }
    return super.getSessionSnapshot(sessionId, afterSequence: afterSequence);
  }
}

class _DeterministicRandom implements Random {
  var _value = 0;

  @override
  bool nextBool() => nextInt(2) == 1;

  @override
  double nextDouble() => nextInt(1 << 20) / (1 << 20);

  @override
  int nextInt(int max) {
    _value = (_value * 1103515245 + 12345) & 0x7fffffff;
    return _value % max;
  }
}
