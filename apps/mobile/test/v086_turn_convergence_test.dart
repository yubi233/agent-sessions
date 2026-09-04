// v0.8.6 A 组回合收敛 controller/widget 回归（V086-11/12/13）：
// 1) 轮询窗口（前台+后台）耗尽仍无终态 → 显式超时收敛：turnInFlight 复位、
//    乐观回显清账、isTurnTimedOut 置位；
// 2) 迟到终态事实事件到达 → 按事件校正清除超时标记；
// 3) 上一回合未终态时的同文本重发被防抖拦截（幂等去重会吞掉第二次事件，
//    双重置的乐观回显永远等不到清账——实机双气泡根因）；
// 4) SessionChatView 在 turnTimedOut 时显示超时横幅替代"处理中"状态条。
import 'package:agent_sessions_mobile/domain/session_models.dart';
import 'package:agent_sessions_mobile/relay/fixture_relay_repository.dart';
import 'package:agent_sessions_mobile/state/session_controller.dart';
import 'package:agent_sessions_mobile/storage/model_effort_preference_store.dart';
import 'package:agent_sessions_mobile/ui/session/chat/session_chat_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fixture_owner.dart';

/// send 命令成功受理，但快照永远不出现 completed_turn / 非 streaming——
/// 复现执行端静默失联（实机 A① 事故形态）。
class _NeverCompletingRelay extends FixtureRelayRepository {
  _NeverCompletingRelay({required super.clock});

  final List<SessionCommandInput> submitted = [];

  /// 置 true 后恢复正常的 completed 终态投影，模拟"迟到的看门狗事实事件"。
  bool completeTurn = false;

  @override
  Future<SessionCommandReceipt> submitSessionCommand(
    String sessionId,
    SessionCommandInput input,
  ) {
    submitted.add(input);
    return super.submitSessionCommand(sessionId, input);
  }

  @override
  Future<SessionCommandReceipt> getSessionCommand(String commandId) async {
    return SessionCommandReceipt(
      id: commandId,
      kind: '',
      status: 'succeeded',
      idempotencyKey: 'fixture-$commandId',
    );
  }

  @override
  Future<SessionSnapshot> getSessionSnapshot(
    String sessionId, {
    int afterSequence = 0,
  }) async {
    final snapshot = await super.getSessionSnapshot(
      sessionId,
      afterSequence: afterSequence,
    );
    // 未终态投影：过滤 turn.completed 与挂起的 question/permission 交互
    // （fixture 的标准 send 以挂起 question 结尾，而完成判定会把
    // "停在交互等待"视为完成——A① 场景必须排除这一切）。
    final events = completeTurn
        ? snapshot.events
        : snapshot.events.where((event) {
            if (event.eventType == 'turn.completed') return false;
            final parsed = SessionTimelineEvent.fromRelayEvent(event);
            if (parsed.question != null && parsed.question!.resolved != true) {
              return false;
            }
            if (parsed.permission != null && parsed.permission!.resolved != true) {
              return false;
            }
            return true;
          }).toList(growable: false);
    return SessionSnapshot(
      session: completeTurn
          ? snapshot.session.copyWith(status: MobileSessionStatus.idle)
          : snapshot.session.copyWith(status: MobileSessionStatus.streaming),
      events: events,
    );
  }
}

void main() {
  test('V086-11：轮询窗口耗尽显式超时收敛，迟到终态按事件校正', () async {
    final relay = _NeverCompletingRelay(clock: () => DateTime.now());
    final owner = await bootstrapFixtureOwner(relay);
    final store = InMemoryModelEffortPreferenceStore();
    final controller = SessionController(
      relay: relay,
      modelEffortMemory: store,
    );
    // 测试窗口：前台 2×10ms + 后台 2×10ms，总约 40ms 后应显式超时。
    controller.foregroundPollAttempts = 2;
    controller.backgroundPollAttempts = 2;
    controller.pollInterval = const Duration(milliseconds: 10);
    await controller.initialize();
    await controller.createSession(
      workspaceId: 'fixture-workspace',
      provider: 'codex',
      deviceId: owner.deviceId,
      canWrite: true,
      autoStart: true,
    );
    final sessionId = controller.selectedSessionId!;

    await controller.sendMessage(
      message: '看看天德华府的最新情况',
      deviceId: owner.deviceId,
      canWrite: true,
    );

    // ignore: avoid_print
    // 前台窗口耗尽：sendMessage 已返回，后台轮询继续；轮询到超时标记置位。
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (!controller.isTurnTimedOut(sessionId) &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    // ignore: avoid_print
    expect(controller.isTurnTimedOut(sessionId), isTrue);
    // 显式收敛：在途标记复位（composer 恢复发送）、乐观回显清账。
    expect(controller.isTurnInFlight, isFalse);
    expect(controller.pendingOutgoingMessage, isNull);

    // 迟到的终态事实事件到达（daemon 看门狗/Provider 收敛）→ 按事件校正。
    relay.completeTurn = true;
    // 重进会话：走全量快照合并路径，终态事实按事件校正清除超时标记。
    await controller.selectSession(sessionId);
    final corrected = DateTime.now().add(const Duration(seconds: 3));
    while (controller.isTurnTimedOut(sessionId) &&
        DateTime.now().isBefore(corrected)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(controller.isTurnTimedOut(sessionId), isFalse);
  });

  test('V086-12：上一回合未终态时的同文本重发被防抖拦截', () async {
    final relay = _NeverCompletingRelay(clock: () => DateTime.now());
    final owner = await bootstrapFixtureOwner(relay);
    final controller = SessionController(
      relay: relay,
      modelEffortMemory: InMemoryModelEffortPreferenceStore(),
    );
    await controller.initialize();
    await controller.createSession(
      workspaceId: 'fixture-workspace',
      provider: 'codex',
      deviceId: owner.deviceId,
      canWrite: true,
      autoStart: true,
    );

    // 首次发送受理即返回（UI 口径）：turnInFlight=true，首批快照含 canonical
    // user_message；此后快照被强制 streaming 且无终态，回合保持未终态。
    await controller.sendMessage(
      message: '看看天德华府的最新情况',
      deviceId: owner.deviceId,
      canWrite: true,
      awaitTurnCompletion: false,
    );
    expect(controller.isTurnInFlight, isTrue);

    // 同文本重发：必须拦截且不再提交第二条 send 命令。
    await controller.sendMessage(
      message: '看看天德华府的最新情况',
      deviceId: owner.deviceId,
      canWrite: true,
      awaitTurnCompletion: false,
    );
    expect(controller.errorMessage, contains('相同消息仍在处理中'));
    expect(
      relay.submitted.where((command) => command.kind == SessionCommandKind.send),
      hasLength(1),
    );
  });

  testWidgets('V086-11：turnTimedOut 时显示超时横幅替代"处理中"状态条', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SessionChatView(
            nodes: const [],
            running: false,
            turnTimedOut: true,
          ),
        ),
      ),
    );
    expect(find.byKey(const Key('session-turn-timeout-row')), findsOneWidget);
    expect(find.textContaining('回合超时'), findsOneWidget);

    // 未超时的常规在途：仍显示原状态条，不显示超时横幅。
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SessionChatView(nodes: const [], running: true),
        ),
      ),
    );
    expect(find.byKey(const Key('session-turn-timeout-row')), findsNothing);
    expect(find.byKey(const Key('session-turn-status-row')), findsOneWidget);
  });
}
