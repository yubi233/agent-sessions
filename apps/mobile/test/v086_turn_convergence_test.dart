// v0.8.6 A 组回合收敛 controller/widget 回归（V086-11/12/13）：
// 1) 轮询窗口（前台+后台）耗尽仍无终态 → v0.9.0 C1 收敛：锚点 2 分钟 deadline
//    切 UX 超时（isTurnTimedOut 置位、乐观回显清账），同步不停止（L1 降频续轮），
//    活动回合事实保持（中断仍可用）；
// 2) 迟到终态事实事件到达 → L1 零干预自动翻正：按事件校正清除超时标记并收敛回合；
// 3) 上一回合未终态时的同文本重发被防抖拦截（幂等去重会吞掉第二次事件，
//    双重置的乐观回显永远等不到清账——实机双气泡根因）；
// 4) SessionChatView 在 turnTimedOut 时显示超时横幅替代"处理中"状态条，
//    并提供「查看结果」出口与新鲜度次级行（v0.9.0 C3）。
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
    // 测试窗口：前台 2×10ms + 后台 2×10ms，窗口耗尽后交接 L1 降频续轮。
    controller.foregroundPollAttempts = 2;
    controller.backgroundPollAttempts = 2;
    controller.pollInterval = const Duration(milliseconds: 10);
    controller.l1PollInterval = const Duration(milliseconds: 5);
    // v0.9.0 C1：超时由锚点 deadline 驱动（可注入单调时钟），不再由
    // attempts×interval 推导——窗口耗尽只决定"何时交接 L1"。
    var monotonicMs = 0;
    controller.monotonicElapsed = () => Duration(milliseconds: monotonicMs);
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
    // v0.9.0 C1：窗口耗尽只交接 L1；超时在锚点 2 分钟 deadline 处置位——
    // 前推单调时钟跨过 deadline，等待 L1 下一拍评估。
    monotonicMs = 2 * 60 * 1000 + 1;
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (!controller.isTurnTimedOut(sessionId) &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    // ignore: avoid_print
    expect(controller.isTurnTimedOut(sessionId), isTrue);
    // v0.9.0 C1：超时只切 UX 表达——活动回合事实保持（中断仍可用），
    // 乐观回显清账，L1 降频续轮继续（10 秒档，测试 5ms）。
    expect(controller.isTurnInFlight, isTrue);
    expect(controller.pendingOutgoingMessage, isNull);

    // 迟到的终态事实事件到达（daemon 看门狗/Provider 收敛）→ 按事件校正。
    relay.completeTurn = true;
    // v0.9.0 根因回归：无需用户任何操作（不重进会话），L1 下一拍增量快照
    // 合并 idle 投影，终态事实自动清除超时标记并收敛回合。
    final corrected = DateTime.now().add(const Duration(seconds: 3));
    while ((controller.isTurnTimedOut(sessionId) ||
                controller.isTurnInFlight) &&
            DateTime.now().isBefore(corrected)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(controller.isTurnTimedOut(sessionId), isFalse);
    expect(controller.isTurnInFlight, isFalse);
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
    // v0.9.0 C1：横幅文案改为「等待结果已超时，仍在同步」。
    expect(find.text('等待结果已超时，仍在同步。'), findsOneWidget);

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

/// R17 回归：deadline 节拍器与传输解耦。C6 起 SSE live 时在途轮询与 L1 都跳过
/// 拉取——若执行侧对受理回合静默无事件（无 turn.phase、无终态），旧实现没有
/// 任何 deadline 评估调用点，UI 永远停留在"生成中"（真机 6 分钟实测）。
/// 202 锚定即武装节拍器，节拍一次即收敛 UX 表达，与是否有轮询无关。
test('R17：deadline 节拍器武装、驱动收敛且只切 UX 表达', () async {
  final relay = _NeverCompletingRelay(clock: () => DateTime.now());
  final owner = await bootstrapFixtureOwner(relay);
  final controller = SessionController(
    relay: relay,
    modelEffortMemory: InMemoryModelEffortPreferenceStore(),
  );
  controller.turnDeadlineTickInterval = const Duration(milliseconds: 10);
  // 窗口压到最小：本测试只验证节拍器路径，轮询窗口不参与收敛。
  controller.foregroundPollAttempts = 1;
  controller.backgroundPollAttempts = 1;
  controller.pollInterval = const Duration(milliseconds: 5);
  controller.l1PollInterval = const Duration(milliseconds: 5);
  var monotonicMs = 0;
  controller.monotonicElapsed = () => Duration(milliseconds: monotonicMs);
  await controller.initialize();
  await controller.createSession(
    workspaceId: 'fixture-workspace',
    provider: 'codex',
    deviceId: owner.deviceId,
    canWrite: true,
    autoStart: true,
  );
  final sessionId = controller.selectedSessionId!;
  expect(controller.turnDeadlineTickArmed, isFalse,
      reason: '无活跃回合时节拍器不应武装');

  await controller.sendMessage(
    message: '看看天德华府的最新情况',
    deviceId: owner.deviceId,
    canWrite: true,
  );
  expect(controller.turnDeadlineTickArmed, isTrue,
      reason: '202 锚定即武装 deadline 节拍器');

  // 推进单调时钟跨过 2 分钟 UX deadline，节拍一次即收敛。
  monotonicMs = 2 * 60 * 1000 + 1;
  controller.evaluateTurnDeadlineTick();
  expect(controller.isTurnTimedOut(sessionId), isTrue);
  // v0.9.0 C1 语义保持：超时只切 UX 表达，活动回合事实与中断能力保持。
  expect(controller.isTurnInFlight, isTrue);
  expect(controller.turnDeadlineTickArmed, isTrue,
      reason: '活跃回合仍在时节拍器保持武装（迟到终态仍可按事件校正）');
});
}
