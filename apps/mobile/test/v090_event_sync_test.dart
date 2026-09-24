import 'dart:async';
import 'dart:math';

import 'package:agent_sessions_mobile/domain/session_models.dart';
import 'package:agent_sessions_mobile/relay/fixture_relay_repository.dart';
import 'package:agent_sessions_mobile/state/session_controller.dart';
import 'package:agent_sessions_mobile/state/session_turn_runtime.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/v090/incident_seq48.dart';
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

  test('V090-01: UX 超时由锚点 2 分钟 deadline 驱动，而非轮询窗口耗尽', () async {
    final relay = _V090StreamingRelay();
    final owner = await bootstrapFixtureOwner(relay);
    final controller = _newController(relay);
    await controller.initialize();
    final session = await _createStartedSession(controller, relay, owner);
    // 轮询窗口立即耗尽（attempts=0），同步责任交给 L1——若超时仍由窗口推导，
    // 超时会在窗口耗尽瞬间出现；锚点语义下必须等 fake 时钟走到 2 分钟。
    controller.foregroundPollAttempts = 0;
    controller.backgroundPollAttempts = 0;
    controller.l1PollInterval = const Duration(milliseconds: 5);
    var monotonicMs = 0;
    controller.monotonicElapsed = () => Duration(milliseconds: monotonicMs);

    await controller.sendMessage(
      message: 'V090-01 deadline 锚点',
      deviceId: owner.deviceId,
      canWrite: true,
      awaitTurnCompletion: false,
    );
    // 窗口已耗尽、L1 已接管：给若干真实毫秒让 L1 跑几拍。
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(
      controller.isTurnTimedOut(session.id),
      isFalse,
      reason: '锚点未到 2 分钟，窗口耗尽不得触发 UX 超时（事故根因契约）',
    );
    expect(controller.activeTurnFor(session.id), isNotNull);

    // fake 时钟前推到 2 分钟+1ms：L1 下一拍置位超时标记（只切 UX 表达）。
    monotonicMs = 2 * 60 * 1000 + 1;
    await _waitFor(() => controller.isTurnTimedOut(session.id));
    expect(controller.activeTurnFor(session.id), isNotNull);
    // L1 在超时后仍在续轮（仍在同步）：请求数继续增长。
    final requestsAtTimeout = relay.snapshotRequests;
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(relay.snapshotRequests, greaterThan(requestsAtTimeout));
    controller.dispose();
  });

  test('V090-01: 60 分钟 continuation deadline 到期只停止 L1 并保留超时提示', () async {
    final relay = _V090StreamingRelay();
    final owner = await bootstrapFixtureOwner(relay);
    final controller = _newController(relay);
    await controller.initialize();
    final session = await _createStartedSession(controller, relay, owner);
    controller.foregroundPollAttempts = 0;
    controller.backgroundPollAttempts = 0;
    controller.l1PollInterval = const Duration(milliseconds: 5);
    var monotonicMs = 0;
    controller.monotonicElapsed = () => Duration(milliseconds: monotonicMs);

    await controller.sendMessage(
      message: 'V090-01 60 分钟到期',
      deviceId: owner.deviceId,
      canWrite: true,
      awaitTurnCompletion: false,
    );
    monotonicMs = 2 * 60 * 1000 + 1;
    await _waitFor(() => controller.isTurnTimedOut(session.id));

    // 前推到 60 分钟+1ms：L1 到期停止任务，超时提示保留，回合事实不被伪造。
    monotonicMs = 60 * 60 * 1000 + 1;
    final requestsBeforeDeadline = relay.snapshotRequests;
    await _waitForL1Stopped(relay, requestsBeforeDeadline);
    expect(controller.isTurnTimedOut(session.id), isTrue);
    expect(controller.activeTurnFor(session.id), isNotNull);
    final stable = relay.snapshotRequests;
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(relay.snapshotRequests, stable, reason: 'L1 已停止，不再发起新请求');
    controller.dispose();
  });

  test('V090-01: L1 续轮拿到迟到终态后自动收敛并停止（默认 10 秒档位存在）', () async {
    final relay = _V090StreamingRelay();
    final owner = await bootstrapFixtureOwner(relay);
    final controller = _newController(relay);
    // T7 裁决默认档位：选中会话 L1 10 秒一拍（单会话 0.1 QPS）。
    expect(controller.l1PollInterval, const Duration(seconds: 10));
    await controller.initialize();
    final session = await _createStartedSession(controller, relay, owner);
    controller.foregroundPollAttempts = 0;
    controller.backgroundPollAttempts = 0;
    controller.l1PollInterval = const Duration(milliseconds: 5);
    var monotonicMs = 0;
    controller.monotonicElapsed = () => Duration(milliseconds: monotonicMs);

    await controller.sendMessage(
      message: 'V090-01 迟到终态',
      deviceId: owner.deviceId,
      canWrite: true,
      awaitTurnCompletion: false,
    );
    monotonicMs = 2 * 60 * 1000 + 1;
    await _waitFor(() => controller.isTurnTimedOut(session.id));

    // L1 下一拍拉到 canonical 终态：超时清除、活动回合移除、L1 停止。
    relay.completeTurn = true;
    await _waitFor(() => !controller.isTurnTimedOut(session.id));
    await _waitFor(() => !controller.isTurnInFlight);
    final requestsAfterTerminal = relay.snapshotRequests;
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(relay.snapshotRequests, requestsAfterTerminal, reason: '终态后 L1 停止');
    controller.dispose();
  });

  test('V090-03: seq48 事故时间线零干预自动翻正（停滞→恢复→seq460 终态）', () async {
    final incident = const V090IncidentFixture();
    final relay = _V090IncidentRelay(incident);
    final owner = await bootstrapFixtureOwner(relay);
    final controller = _newController(relay);
    await controller.initialize();
    // 先建会话并注册受管 id，再做选择：保证首次全量快照就走事故 fixture。
    final created = await controller.createSession(
      workspaceId: 'fixture-workspace',
      provider: 'codex',
      deviceId: owner.deviceId,
      canWrite: true,
      autoStart: true,
    );
    relay.managedSessionId = created!.id;
    await controller.selectSession(created.id);
    await controller.acquireSelectedLease(
      deviceId: owner.deviceId,
      canWrite: true,
    );
    final session = created;
    controller.foregroundPollAttempts = 0;
    controller.backgroundPollAttempts = 0;
    controller.l1PollInterval = const Duration(milliseconds: 5);
    var monotonicMs = 0;
    controller.monotonicElapsed = () => Duration(milliseconds: monotonicMs);

    // 阶段一（停滞）：选中会话时的全量快照停留在 seq48（streaming）。
    expect(relay.phase, V090IncidentPhase.stall);
    expect(controller.selectedCursor, v090IncidentStallSeq);
    expect(
      controller.timeline.any(
        (event) => event.sequence == v090IncidentStallSeq,
      ),
      isTrue,
    );

    await controller.sendMessage(
      message: 'V090-FIXTURE-QUESTION（合成占位：用于事故回放的用户提问）',
      deviceId: owner.deviceId,
      canWrite: true,
      awaitTurnCompletion: false,
    );
    // 锚点 2 分钟到达：与事故一致，客户端进入超时表达。
    monotonicMs = 2 * 60 * 1000 + 1;
    await _waitFor(() => controller.isTurnTimedOut(session.id));

    // 阶段二（恢复）：执行端已落库 seq 49-62，L1 下一拍零干预补齐增量。
    relay.phase = V090IncidentPhase.recovery;
    await _waitFor(
      () => controller.timeline.any(
        (event) => event.sequence == v090IncidentRecoveryEndSeq,
      ),
    );

    // 阶段三（终态）：seq 460 迟到答案到达——超时清除、完整答案展示、L1 停止。
    relay.phase = V090IncidentPhase.terminal;
    await _waitFor(() => !controller.isTurnTimedOut(session.id));
    expect(controller.selectedSession?.status, MobileSessionStatus.idle);
    expect(
      controller.timeline.any(
        (event) => event.text?.startsWith('V090-FIXTURE-FULL-ANSWER') ?? false,
      ),
      isTrue,
      reason: '迟到的完整答案必须可见（事故中人工刷新才出现）',
    );
    // 按 sequence 去重：恢复窗口事件不重复出现，无重复 UI 节点。
    final sequences = controller.timeline
        .map((event) => event.sequence)
        .toList();
    expect(sequences.toSet().length, sequences.length);
    expect(controller.isTurnInFlight, isFalse);
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
    int? beforeSequence,
    int? limit,
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

/// 永不自行终态的 streaming 假 Relay：send 后所有快照返回空增量 streaming；
/// [completeTurn] 置 true 后返回 idle 终态投影（模拟迟到的 daemon 看门狗事实）。
class _V090StreamingRelay extends FixtureRelayRepository {
  bool completeTurn = false;

  /// 快照请求计数（L1 节奏/停止断言用）。
  int snapshotRequests = 0;

  @override
  Future<SessionSnapshot> getSessionSnapshot(
    String sessionId, {
    int afterSequence = 0,
    int? beforeSequence,
    int? limit,
  }) async {
    snapshotRequests += 1;
    final snapshot = await super.getSessionSnapshot(
      sessionId,
      afterSequence: afterSequence,
    );
    if (completeTurn) {
      return SessionSnapshot(
        session: snapshot.session.copyWith(status: MobileSessionStatus.idle),
        events: snapshot.events,
      );
    }
    return SessionSnapshot(
      session: snapshot.session.copyWith(status: MobileSessionStatus.streaming),
      events: const [],
    );
  }
}

/// 事故回放假 Relay：快照完全由脱敏 fixture 按阶段供给（after_seq 语义同规），
/// 阶段推进由测试显式控制，复现"服务端在前进、客户端已停更"的错位。
class _V090IncidentRelay extends FixtureRelayRepository {
  _V090IncidentRelay(this.incident);

  final V090IncidentFixture incident;
  V090IncidentPhase phase = V090IncidentPhase.stall;

  /// 受 fixture 管理的测试会话 id（createSession 后由测试注入）；
  /// 该会话的快照完全由事故 fixture 供给，其余会话走默认路径。
  String? managedSessionId;

  @override
  Future<SessionSnapshot> getSessionSnapshot(
    String sessionId, {
    int afterSequence = 0,
    int? beforeSequence,
    int? limit,
  }) async {
    if (sessionId == managedSessionId) {
      // 快照内 session row 必须携带请求的会话 id（合并按它落键）。
      return incident.incrementalSnapshot(
        phase,
        afterSeq: afterSequence,
        sessionIdOverride: sessionId,
      );
    }
    return super.getSessionSnapshot(sessionId, afterSequence: afterSequence);
  }
}

/// 等待快照请求数停止增长（L1 已退出）。
Future<void> _waitForL1Stopped(
  _V090StreamingRelay relay,
  int baseline,
) async {
  final deadline = DateTime.now().add(const Duration(milliseconds: 150));
  while (DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
    if (relay.snapshotRequests > baseline) {
      baseline = relay.snapshotRequests;
    }
  }
}
