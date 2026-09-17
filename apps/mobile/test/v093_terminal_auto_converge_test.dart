// v0.9.3 V093-02 移动端消费侧回归（F2：终态自动收敛）：
// R18 云端实测中，出箱积压把 turn.completed 排到队列尾部，手机 UI 在回合
// 实际结束后数分钟仍显示「生成中」，需要一次视图切换才收敛。传输层批量修复
// （daemon→Relay 批量上传）解决积压本身；本文件把 F2 的用户可见结果钉在
// controller 层：**大批 delta 追平后终态事件经主动轮询到达时，无需任何用户
// 操作（不重进会话、不切换视图），状态行与活动回合标记自动收敛到终态。**
import 'package:agent_sessions_mobile/domain/session_models.dart';
import 'package:agent_sessions_mobile/relay/fixture_relay_repository.dart';
import 'package:agent_sessions_mobile/state/session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fixture_owner.dart';

/// 先保持「生成中」（过滤 turn.completed 与挂起 question/permission——完成判定
/// 会把"停在交互等待"视为完成，必须排除；见 v086_turn_convergence_test 同口径），
/// 置 complete 后一次性放行终态投影（对应积压被批量上传快速追平后的到达形态）。
class _BacklogThenCompleteRelay extends FixtureRelayRepository {
  _BacklogThenCompleteRelay({required super.clock});

  int pollCount = 0;
  bool complete = false;

  @override
  Future<SessionSnapshot> getSessionSnapshot(
    String sessionId, {
    int afterSequence = 0,
  }) async {
    final snapshot = await super.getSessionSnapshot(
      sessionId,
      afterSequence: afterSequence,
    );
    pollCount += 1;
    if (!complete) {
      final events = snapshot.events.where((event) {
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
        session: snapshot.session.copyWith(status: MobileSessionStatus.streaming),
        events: events,
      );
    }
    return SessionSnapshot(
      session: snapshot.session.copyWith(status: MobileSessionStatus.idle),
      events: snapshot.events,
    );
  }
}

void main() {
  test('V093-02：大批 delta 追平后终态到达，零操作自动收敛（F2 回归）', () async {
    final relay = _BacklogThenCompleteRelay(clock: () => DateTime.now());
    final owner = await bootstrapFixtureOwner(relay);
    final controller = SessionController(relay: relay);
    // 测试窗口：主动/后台/续轮各档收紧到 5ms，对应生产 250ms 主动档的角色。
    controller.foregroundPollAttempts = 3;
    controller.backgroundPollAttempts = 3;
    controller.pollInterval = const Duration(milliseconds: 5);
    controller.activePollInterval = const Duration(milliseconds: 5);
    controller.l1PollInterval = const Duration(milliseconds: 5);
    await controller.initialize();
    await controller.createSession(
      workspaceId: 'fixture-workspace',
      provider: 'codex',
      deviceId: owner.deviceId,
      canWrite: true,
      autoStart: true,
    );

    await controller.sendMessage(
      message: 'V093-02 吞吐回归',
      deviceId: owner.deviceId,
      canWrite: true,
    );
    expect(controller.isTurnInFlight, isTrue, reason: '发送后回合应在途');

    // 模拟积压追平：终态在下一拍快照可见；不做任何用户操作。
    relay.complete = true;
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (controller.isTurnInFlight && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    // F2 断言：无需任何用户操作（无重进、无视图切换），主动轮询的增量快照
    // 合并把回合收敛到终态；状态行恢复空闲、超时横幅不出现。
    expect(controller.isTurnInFlight, isFalse,
        reason: '终态事件到达后必须零操作收敛（R18 F2 回归）');
    expect(controller.isTurnTimedOut(controller.selectedSessionId!), isFalse,
        reason: '批量修复后终态应远早于 2 分钟 deadline 到达');
    expect(controller.selectedSession?.status, MobileSessionStatus.idle,
        reason: '会话投影必须跟随 turn.completed(idle) 恢复空闲');
  });
}
