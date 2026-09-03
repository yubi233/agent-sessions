import 'package:agent_sessions_mobile/domain/session_models.dart';
import 'package:agent_sessions_mobile/relay/fixture_relay_repository.dart';
import 'package:agent_sessions_mobile/state/session_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/fixture_owner.dart';

/// 回归：daemon 重启后原空闲会话呈"已停止"，直接发消息会被执行端以
/// local_state_missing 拒绝（时间线浮出"请先启动会话"）。修复后客户端在
/// 发送前对 stopped 会话自动补一次 session.start（resume 重建本机实例），
/// 与"写权自动获取"同一体验方向。
void main() {
  final baseNow = DateTime.utc(2026, 9, 4, 11, 0);

  test('发送前对已停止会话自动补 start（resume）再发送', () async {
    var now = baseNow;
    final relay = _RecordingCommandRelay(clock: () => now);
    // fixture 简化：已停止会话不允许二次 start（真实 daemon 走 resume 重建）。
    // 因此被测会话保持 fixture 内部 idle，仅让客户端"看到" stopped 投影，
    // 以驱动自动恢复路径并断言 start → send 的命令顺序。
    relay.projectSelectedSessionAsStopped = true;
    final owner = await bootstrapFixtureOwner(relay);
    final controller = SessionController(relay: relay, clock: () => now);
    await controller.initialize();
    final created = await controller.createSession(
      workspaceId: 'fixture-workspace',
      provider: 'codex',
      deviceId: owner.deviceId,
      canWrite: true,
      autoStart: false,
    );
    expect(created, isNotNull);
    expect(controller.selectedSession?.status, MobileSessionStatus.stopped);

    await controller.sendMessage(
      message: '你好',
      deviceId: owner.deviceId,
      canWrite: true,
    );

    // 自动恢复确实发生：start 命令先于 send 提交。
    expect(
      relay.submittedKinds,
      contains(SessionCommandKind.start),
      reason: '发送前应自动对 stopped 会话补发 session.start',
    );
    expect(
      relay.submittedKinds.indexOf(SessionCommandKind.start),
      lessThan(relay.submittedKinds.indexOf(SessionCommandKind.send)),
      reason: 'start 必须先于 send',
    );
    // 发送完成且无错误浮出：用户不再被"请先启动会话"阻断。
    expect(controller.errorMessage, isNull);
    expect(
      controller.timeline.any((event) => event.label == '会话已启动'),
      isTrue,
    );
  });

  test('非 stopped 会话发送不触发额外 start', () async {
    var now = baseNow;
    final relay = _RecordingCommandRelay(clock: () => now);
    final owner = await bootstrapFixtureOwner(relay);
    final controller = SessionController(relay: relay, clock: () => now);
    await controller.initialize();
    await controller.createSession(
      workspaceId: 'fixture-workspace',
      provider: 'codex',
      deviceId: owner.deviceId,
      canWrite: true,
      autoStart: true,
    );
    final kindsBefore = List.of(relay.submittedKinds);

    await controller.sendMessage(
      message: '普通消息',
      deviceId: owner.deviceId,
      canWrite: true,
    );

    expect(
      relay.submittedKinds.skip(kindsBefore.length),
      [SessionCommandKind.send],
      reason: '运行中/空闲会话不应重复注入 start',
    );
  });
}

/// 把选中会话投影为 stopped，并记录客户端提交的命令序列。
class _RecordingCommandRelay extends FixtureRelayRepository {
  _RecordingCommandRelay({required super.clock});

  final List<SessionCommandKind> submittedKinds = <SessionCommandKind>[];
  bool projectSelectedSessionAsStopped = false;

  @override
  Future<SessionSnapshot> getSessionSnapshot(
    String sessionId, {
    int afterSequence = 0,
  }) async {
    final snapshot = await super.getSessionSnapshot(
      sessionId,
      afterSequence: afterSequence,
    );
    if (!projectSelectedSessionAsStopped) return snapshot;
    // 只改客户端可见投影；fixture 内部状态保持原样（与真实 daemon 重启后
    // "本地实例已失、投影呈 stopped"的形态一致）。
    return SessionSnapshot(
      session: snapshot.session.copyWith(status: MobileSessionStatus.stopped),
      events: snapshot.events,
    );
  }

  @override
  Future<SessionCommandReceipt> submitSessionCommand(
    String sessionId,
    SessionCommandInput input,
  ) {
    submittedKinds.add(input.kind);
    return super.submitSessionCommand(sessionId, input);
  }
}
