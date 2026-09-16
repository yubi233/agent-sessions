import 'package:agent_sessions_mobile/domain/models.dart';
import 'package:agent_sessions_mobile/domain/session_models.dart';
import 'package:agent_sessions_mobile/relay/fixture_relay_repository.dart';
import 'package:agent_sessions_mobile/state/session_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/fixture_owner.dart';

/// v0.9.2 P2（V092-06 / C3 / T3 裁决）回归：发送前自动恢复的语义修正。
///
/// 背景：daemon 重启后 store 里的 instance 映射仍在、内存句柄已释放，移动端
/// 看到 stopped 投影。旧实现在发送前无条件补 `session.start`，而 daemon 的
/// start 走 `session/new` **新建** Provider 实例并覆盖映射——会话"恢复"了但
/// 上下文断链（P0 实测 b5 对照分支）。修正后：**存在映射时必须走 resume**，
/// 只有确实没有本机实例时才回退 start。
void main() {
  final baseNow = DateTime.utc(2026, 9, 4, 11, 0);

  test('V092-06：stopped 会话发送前自动恢复走 resume（不再 start）', () async {
    var now = baseNow;
    final relay = _RecordingCommandRelay(clock: () => now);
    // 会话从未被本机执行过（fixture 内部保持 idle），但客户端看到 stopped 投影，
    // 等价于"daemon 重启后有映射无句柄"。
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

    expect(
      relay.submittedKinds,
      contains(SessionCommandKind.resume),
      reason: '存在实例映射时必须走 resume（续接原实例，不新建）',
    );
    expect(
      relay.submittedKinds.contains(SessionCommandKind.start),
      isFalse,
      reason: 'resume 可用时不得回退 start：start 会新建实例造成历史断链',
    );
    expect(
      relay.submittedKinds.indexOf(SessionCommandKind.resume),
      lessThan(relay.submittedKinds.indexOf(SessionCommandKind.send)),
      reason: 'resume 必须先于 send',
    );
    expect(controller.errorMessage, isNull);
  });

  test('V092-06：resume 报告本机无实例时才回退 start（新会话语义）', () async {
    var now = baseNow;
    final relay = _RecordingCommandRelay(clock: () => now);
    // 该 fixture 让 resume 立即失败并给出 local_state_missing 语义错误面，
    // 等价于"会话从未在 daemon 侧建立过映射"。
    relay.failResumeWithMissingInstance = true;
    relay.projectSelectedSessionAsStopped = true;
    final owner = await bootstrapFixtureOwner(relay);
    final controller = SessionController(relay: relay, clock: () => now);
    await controller.initialize();
    await controller.createSession(
      workspaceId: 'fixture-workspace',
      provider: 'codex',
      deviceId: owner.deviceId,
      canWrite: true,
      autoStart: false,
    );

    await controller.sendMessage(
      message: '首次发送',
      deviceId: owner.deviceId,
      canWrite: true,
    );

    expect(
      relay.submittedKinds,
      contains(SessionCommandKind.resume),
      reason: '先尝试 resume（有映射时的正确语义）',
    );
    expect(
      relay.submittedKinds,
      contains(SessionCommandKind.start),
      reason: '只有"确实没有本机实例"才允许回退 start',
    );
  });

  test('非 stopped 会话发送不触发额外恢复命令', () async {
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
      reason: '运行中/空闲会话不应重复注入 resume/start',
    );
  });
}

/// 把选中会话投影为 stopped，并记录客户端提交的命令序列。
class _RecordingCommandRelay extends FixtureRelayRepository {
  _RecordingCommandRelay({required super.clock});

  final List<SessionCommandKind> submittedKinds = <SessionCommandKind>[];
  bool projectSelectedSessionAsStopped = false;

  /// 让 resume 以"本机没有实例映射"失败（local_state_missing 语义），
  /// 用于覆盖"新会话必须回退 start"的分支。
  bool failResumeWithMissingInstance = false;

  @override
  Future<SessionSnapshot> getSessionSnapshot(
    String sessionId, {
    int afterSequence = 0,
  }) async {
    final snapshot = await super.getSessionSnapshot(
      sessionId,
      afterSequence: afterSequence,
    );
    // 恢复命令提交后，真实 daemon 会把会话投影推进为 idle；fixture 也必须跟随，
    // 否则停止投影会永久生效，恢复永远"看起来失败"而掩盖真实的恢复路径。
    if (!projectSelectedSessionAsStopped || submittedKinds.isNotEmpty) {
      return snapshot;
    }
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
    if (input.kind == SessionCommandKind.resume &&
        failResumeWithMissingInstance) {
      throw RelayFailure(
        RelayFailureKind.protocol,
        '本机实例不存在（local_state_missing），请先启动会话。',
      );
    }
    return super.submitSessionCommand(sessionId, input);
  }
}
