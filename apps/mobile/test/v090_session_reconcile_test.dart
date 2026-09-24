import 'dart:async';

import 'package:agent_sessions_mobile/app/providers.dart';
import 'package:agent_sessions_mobile/domain/models.dart';
import 'package:agent_sessions_mobile/domain/session_models.dart';
import 'package:agent_sessions_mobile/relay/fixture_relay_repository.dart';
import 'package:agent_sessions_mobile/state/session_controller.dart';
import 'package:agent_sessions_mobile/ui/recent_sessions_screens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fixture_owner.dart';

/// V090-06/07：L3 quiet reconcile 与非当前完成角标回归（C4/T7）。
/// 覆盖：quiet 路径不闪 loading、listSessions 共享 single-flight、
/// 差异检测（status 翻转优先于仅序号前进）、每拍 4 个/并发 2 预算、
/// 后台零请求、角标只在快照确认真实 idle 终态后置位并在打开/移出/认证边界清除。
void main() {
  test('V090-07: quiet tick 不改变列表 loading/error 相位（不闪 loading）', () async {
    final relay = _V090ReconcileRelay();
    final owner = await bootstrapFixtureOwner(relay);
    final controller = SessionController(relay: relay, clock: () => DateTime.now());
    await controller.initialize();
    await _createSession(controller, relay, owner);
    controller.setQuietReconcileActive(true);
    expect(controller.phase, SessionListPhase.ready);

    await controller.quietReconcileTick();

    // quiet 路径绝不把列表切进 loading/error，也不清空已有列表。
    expect(controller.phase, SessionListPhase.ready);
    expect(controller.sessions, isNotEmpty);
    expect(controller.errorMessage, isNull);
    controller.dispose();
  });

  test('V090-07: 手动刷新与 quiet tick 共享 listSessions single-flight', () async {
    final relay = _V090ReconcileRelay();
    final owner = await bootstrapFixtureOwner(relay);
    final controller = SessionController(relay: relay, clock: () => DateTime.now());
    await controller.initialize();
    await _createSession(controller, relay, owner);
    controller.setQuietReconcileActive(true);
    relay.holdListRequests = true;
    final requestsBefore = relay.listCalls;

    // 手动刷新与周期拍并发：两者必须共享同一在途 list 请求。
    final manual = controller.refreshSessions();
    final tick = controller.quietReconcileTick();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(relay.listCalls, requestsBefore + 1, reason: '并发只发一次 list 请求');
    relay.releaseListRequests();
    await Future.wait([manual, tick]);
    expect(relay.listCalls, requestsBefore + 1);
    controller.dispose();
  });

  test('V090-07: 差异检测——仅 status 翻转或 last_seq 前进才拉快照，翻转优先', () async {
    final relay = _V090ReconcileRelay();
    final owner = await bootstrapFixtureOwner(relay);
    final controller = SessionController(relay: relay, clock: () => DateTime.now());
    await controller.initialize();
    final a = await _createSession(controller, relay, owner);
    // 本地观察为 streaming（角标资格 + L3 运行条件）。
    relay.snapshotOverrides[a.id] = _snapshot(a.id, MobileSessionStatus.streaming, 10);
    await controller.selectSession(a.id);
    // 远端列表：A 状态翻转（idle），B 仅有 last_seq 前进，C 完全无差异。
    final b = await _createSession(controller, relay, owner);
    await controller.selectSession(b.id);
    relay.remoteSessionsOverride = [
      _remote(a.id, MobileSessionStatus.idle, 10),
      _remote(b.id, MobileSessionStatus.idle, 99),
    ];
    controller.setQuietReconcileActive(true);
    controller.quietReconcileBatchSize = 4;
    final snapshotCallsBefore = relay.snapshotCalls;

    await controller.quietReconcileTick();

    // A（翻转）与 B（仅序号前进）进入队列；快照请求数只覆盖差异会话。
    expect(relay.snapshotCalls - snapshotCallsBefore, 2);
    controller.dispose();
  });

  test('V090-07: 每拍最多 4 个快照、并发最多 2，剩余项留到后续拍', () async {
    final relay = _V090ReconcileRelay();
    final owner = await bootstrapFixtureOwner(relay);
    final controller = SessionController(relay: relay, clock: () => DateTime.now());
    await controller.initialize();
    // 构造 6 个本地 streaming 会话：全部与远端 status 翻转（优先级相同）。
    final ids = <String>[];
    for (var i = 0; i < 6; i++) {
      final session = await _createSession(controller, relay, owner);
      ids.add(session.id);
      relay.snapshotOverrides[session.id] =
          _snapshot(session.id, MobileSessionStatus.streaming, 10);
    }
    // 逐个 select 以合并 streaming 投影（最后一个停在选中态也无妨，角标按非选中判定）。
    for (final id in ids) {
      await controller.selectSession(id);
    }
    relay.remoteSessionsOverride = [
      for (final id in ids) _remote(id, MobileSessionStatus.idle, 10),
    ];
    controller.setQuietReconcileActive(true);
    controller.quietReconcileBatchSize = 4;
    controller.quietReconcileConcurrency = 2;
    relay.snapshotDelay = const Duration(milliseconds: 30);
    final snapshotCallsBefore = relay.snapshotCalls;

    await controller.quietReconcileTick();

    expect(relay.snapshotCalls - snapshotCallsBefore, 4, reason: '每拍最多 4 个');
    expect(relay.maxConcurrentSnapshots, 2, reason: '并发上限 2');
    controller.dispose();
  });

  test('V090-07: 后台停拍零请求；active 才消费 tick', () async {
    final relay = _V090ReconcileRelay();
    final owner = await bootstrapFixtureOwner(relay);
    final controller = SessionController(relay: relay, clock: () => DateTime.now());
    await controller.initialize();
    final session = await _createSession(controller, relay, owner);
    relay.snapshotOverrides[session.id] =
        _snapshot(session.id, MobileSessionStatus.streaming, 10);
    await controller.selectSession(session.id);
    // inactive（后台/离线）：tick 直接 no-op，零新请求。
    final listCallsBeforeInactive = relay.listCalls;
    await controller.quietReconcileTick();
    expect(relay.listCalls, listCallsBeforeInactive);

    controller.setQuietReconcileActive(true);
    await controller.quietReconcileTick();
    expect(relay.listCalls, listCallsBeforeInactive + 1);
    controller.setQuietReconcileActive(false);
    final listCalls = relay.listCalls;
    await controller.quietReconcileTick();
    expect(relay.listCalls, listCalls, reason: '停拍后不再发请求');
    controller.dispose();
  });

  test('V090-06: 快照确认真实 idle 终态后置「有新完成结果」角标，打开后清除', () async {
    final relay = _V090ReconcileRelay();
    final owner = await bootstrapFixtureOwner(relay);
    final controller = SessionController(relay: relay, clock: () => DateTime.now());
    await controller.initialize();
    final a = await _createSession(controller, relay, owner);
    relay.snapshotOverrides[a.id] = _snapshot(a.id, MobileSessionStatus.streaming, 10);
    await controller.selectSession(a.id);
    final b = await _createSession(controller, relay, owner);
    await controller.selectSession(b.id);
    // 远端：A 由 streaming 翻转为 idle（真实完成）。
    relay.remoteSessionsOverride = [
      _remote(a.id, MobileSessionStatus.idle, 10),
    ];
    relay.snapshotOverrides[a.id] =
        _completedSnapshot(a.id, lastSeq: 11, status: MobileSessionStatus.idle);
    controller.setQuietReconcileActive(true);

    await controller.quietReconcileTick();

    // A 非当前选中：角标置位。
    expect(controller.hasUnseenCompletion(a.id), isTrue);
    expect(controller.unseenCompletedSessionIds, contains(a.id));

    // 打开 A 并成功合并快照：角标清除。
    await controller.selectSession(a.id);
    expect(controller.hasUnseenCompletion(a.id), isFalse);
    controller.dispose();
  });

  test('V090-06: stopped 投影/仅序号前进/拉取失败都不伪装完成', () async {
    final relay = _V090ReconcileRelay();
    final owner = await bootstrapFixtureOwner(relay);
    final controller = SessionController(relay: relay, clock: () => DateTime.now());
    await controller.initialize();
    final a = await _createSession(controller, relay, owner);
    relay.snapshotOverrides[a.id] = _snapshot(a.id, MobileSessionStatus.streaming, 10);
    await controller.selectSession(a.id);
    final b = await _createSession(controller, relay, owner);
    await controller.selectSession(b.id);
    controller.setQuietReconcileActive(true);

    // ① stopped 投影：不算完成结果。
    relay.remoteSessionsOverride = [_remote(a.id, MobileSessionStatus.stopped, 10)];
    relay.snapshotOverrides[a.id] =
        _completedSnapshot(a.id, lastSeq: 11, status: MobileSessionStatus.stopped);
    await controller.quietReconcileTick();
    expect(controller.hasUnseenCompletion(a.id), isFalse);

    // ② 仅 last_seq 前进、状态仍 streaming：快照确认仍在活动，不置角标。
    relay.remoteSessionsOverride = [_remote(a.id, MobileSessionStatus.streaming, 12)];
    relay.snapshotOverrides[a.id] = _snapshot(a.id, MobileSessionStatus.streaming, 12);
    await controller.quietReconcileTick();
    expect(controller.hasUnseenCompletion(a.id), isFalse);

    // ③ 拉取失败：不置角标、不进错误态。
    relay.remoteSessionsOverride = [_remote(a.id, MobileSessionStatus.idle, 12)];
    relay.snapshotOverrides[a.id] = null;
    relay.failSnapshots = true;
    await controller.quietReconcileTick();
    expect(controller.hasUnseenCompletion(a.id), isFalse);
    expect(controller.errorMessage, isNull);
    controller.dispose();
  });

  test('V090-06: 会话移出列表或认证代际结束时清除角标', () async {
    final relay = _V090ReconcileRelay();
    final owner = await bootstrapFixtureOwner(relay);
    final controller = SessionController(relay: relay, clock: () => DateTime.now());
    await controller.initialize();
    final a = await _createSession(controller, relay, owner);
    relay.snapshotOverrides[a.id] = _snapshot(a.id, MobileSessionStatus.streaming, 10);
    await controller.selectSession(a.id);
    final b = await _createSession(controller, relay, owner);
    await controller.selectSession(b.id);
    relay.remoteSessionsOverride = [_remote(a.id, MobileSessionStatus.idle, 10)];
    relay.snapshotOverrides[a.id] =
        _completedSnapshot(a.id, lastSeq: 11, status: MobileSessionStatus.idle);
    controller.setQuietReconcileActive(true);
    await controller.quietReconcileTick();
    expect(controller.hasUnseenCompletion(a.id), isTrue);

    // 会话移出列表（远端不再返回 A）→ 手动刷新清除角标。
    relay.remoteSessionsOverride = [_remote(b.id, MobileSessionStatus.idle, 1)];
    await controller.refreshSessions();
    expect(controller.hasUnseenCompletion(a.id), isFalse);
    controller.dispose();

    // 认证边界：集合整体清空（新 controller 演练）。
    final relay2 = _V090ReconcileRelay();
    final owner2 = await bootstrapFixtureOwner(relay2);
    final controller2 = SessionController(relay: relay2, clock: () => DateTime.now());
    await controller2.initialize();
    final c = await _createSession(controller2, relay2, owner2);
    relay2.snapshotOverrides[c.id] = _snapshot(c.id, MobileSessionStatus.streaming, 10);
    await controller2.selectSession(c.id);
    final d = await _createSession(controller2, relay2, owner2);
    await controller2.selectSession(d.id);
    relay2.remoteSessionsOverride = [_remote(c.id, MobileSessionStatus.idle, 10)];
    relay2.snapshotOverrides[c.id] =
        _completedSnapshot(c.id, lastSeq: 11, status: MobileSessionStatus.idle);
    controller2.setQuietReconcileActive(true);
    await controller2.quietReconcileTick();
    expect(controller2.hasUnseenCompletion(c.id), isTrue);
    controller2.resetForAuthBoundary();
    expect(controller2.unseenCompletedSessionIds, isEmpty);
    controller2.dispose();
  });

  testWidgets('V090-06: 列表角标 widget——稳定 Key 与「有新完成结果」Semantics，打开后清除', (
    tester,
  ) async {
    final relay = _V090ReconcileRelay();
    final owner = await bootstrapFixtureOwner(relay);
    final controller = SessionController(relay: relay, clock: () => DateTime.now());
    await controller.initialize();
    final a = await _createSession(controller, relay, owner);
    relay.snapshotOverrides[a.id] = _snapshot(a.id, MobileSessionStatus.streaming, 10);
    await controller.selectSession(a.id);
    final b = await _createSession(controller, relay, owner);
    await controller.selectSession(b.id);
    relay.remoteSessionsOverride = [_remote(a.id, MobileSessionStatus.idle, 10)];
    relay.snapshotOverrides[a.id] =
        _completedSnapshot(a.id, lastSeq: 11, status: MobileSessionStatus.idle);
    controller.setQuietReconcileActive(true);
    await controller.quietReconcileTick();
    expect(controller.hasUnseenCompletion(a.id), isTrue);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          relayRepositoryProvider.overrideWithValue(relay),
          sessionControllerProvider.overrideWith((ref) => controller),
        ],
        child: const MaterialApp(home: RecentSessionsScreen()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    // 角标可见：稳定 Key + Semantics label「有新完成结果」。
    expect(
      find.byKey(Key('session-completion-badge-${a.id}')),
      findsOneWidget,
    );
    final semantics = tester.getSemantics(
      find.byKey(Key('session-completion-badge-${a.id}')),
    );
    expect(semantics.label, contains('有新完成结果'));

    // 打开会话（成功合并快照）后角标清除。
    await controller.selectSession(a.id);
    await tester.pump(const Duration(milliseconds: 50));
    expect(
      find.byKey(Key('session-completion-badge-${a.id}')),
      findsNothing,
    );
    // 控制器由 ProviderScope 拥有并在拆卸时释放，这里不得手动 dispose。
  });
}

Future<MobileSession> _createSession(
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
  return session!;
}

MobileSession _remote(String id, MobileSessionStatus status, int lastSeq) =>
    MobileSession(
      id: id,
      workspaceId: 'fixture-workspace',
      status: status,
      provider: 'codex',
      lastSequence: lastSeq,
    );

SessionSnapshot _snapshot(
  String id,
  MobileSessionStatus status,
  int lastSeq,
) => SessionSnapshot(
  session: MobileSession(
    id: id,
    workspaceId: 'fixture-workspace',
    status: status,
    provider: 'codex',
    lastSequence: lastSeq,
  ),
  events: const [],
);

/// 携带 completed_turn 终态事件的快照（真实完成事实）。
SessionSnapshot _completedSnapshot(
  String id, {
  required int lastSeq,
  required MobileSessionStatus status,
}) => SessionSnapshot(
  session: MobileSession(
    id: id,
    workspaceId: 'fixture-workspace',
    status: status,
    provider: 'codex',
    lastSequence: lastSeq,
  ),
  events: [
    RelaySessionEvent(
      sequence: lastSeq,
      eventType: 'turn.completed',
      envelope: const {
        'fixture_payload': {
          'kind': 'assistant_message',
          'text': 'V090-FIXTURE-完成',
          'completed_turn': true,
        },
      },
    ),
  ],
);

/// V090 reconcile 假 Relay：
/// - [remoteSessionsOverride]：listSessions 的受控远端投影；
/// - [snapshotOverrides]：按会话 id 注入受控快照（null 时模拟失败）；
/// - [holdListRequests]/[releaseListRequests]：扣住 list 请求验证 single-flight；
/// - [snapshotDelay]/[maxConcurrentSnapshots]：并发预算断言。
class _V090ReconcileRelay extends FixtureRelayRepository {
  List<MobileSession>? remoteSessionsOverride;
  final Map<String, SessionSnapshot?> snapshotOverrides = {};
  bool holdListRequests = false;
  final List<Completer<List<MobileSession>>> _listHoldGate = [];
  bool failSnapshots = false;
  Duration? snapshotDelay;
  int maxConcurrentSnapshots = 0;
  int _inFlightSnapshots = 0;
  int listCalls = 0;
  int snapshotCalls = 0;

  void releaseListRequests() {
    for (final completer in _listHoldGate) {
      completer.complete(_remoteOrReal());
    }
    _listHoldGate.clear();
  }

  List<MobileSession> _remoteOrReal() =>
      remoteSessionsOverride ?? superSessions();

  List<MobileSession> superSessions() => const [];

  @override
  Future<List<MobileSession>> listSessions() async {
    listCalls += 1;
    if (holdListRequests) {
      final completer = Completer<List<MobileSession>>();
      _listHoldGate.add(completer);
      return completer.future;
    }
    return remoteSessionsOverride ?? super.listSessions();
  }

  @override
  Future<SessionSnapshot> getSessionSnapshot(
    String sessionId, {
    int afterSequence = 0,
    int? beforeSequence,
    int? limit,
  }) async {
    snapshotCalls += 1;
    if (snapshotOverrides.containsKey(sessionId) || failSnapshots) {
      _inFlightSnapshots += 1;
      maxConcurrentSnapshots =
          maxConcurrentSnapshots > _inFlightSnapshots
          ? maxConcurrentSnapshots
          : _inFlightSnapshots;
      try {
        if (snapshotDelay != null) {
          await Future<void>.delayed(snapshotDelay!);
        }
        if (failSnapshots) {
          throw const RelayFailure(
            RelayFailureKind.unavailable,
            'V090-模拟 Relay 不可用',
          );
        }
        return snapshotOverrides[sessionId]!;
      } finally {
        _inFlightSnapshots -= 1;
      }
    }
    return super.getSessionSnapshot(sessionId, afterSequence: afterSequence);
  }
}
