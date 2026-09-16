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

  test('V092-10：status 非 stopped 但执行侧实例缺失时，自动 resume 并用新幂等键重试发送', () async {
    // v0.9.2 P2 修正（R14 真机暴露）：Daemon 重启会丢失本机实例映射，但 Relay 的
    // session 投影不会因此改写——客户端看到的 status 仍是 idle。此时旧的"status 不是
    // stopped 就直接放行"短路不会触发恢复，发送直达执行侧后必然以
    // local_state_missing 失败，用户看到的是"显示空闲却发不出去"。
    final now = baseNow;
    final relay = _RecordingCommandRelay(clock: () => now);
    // 关键：**不**把投影改成 stopped——模拟真实的重启后形态。
    relay.failFirstSendWithMissingInstance = true;
    final owner = await bootstrapFixtureOwner(relay);
    final controller = SessionController(relay: relay, clock: () => now);
    await controller.initialize();
    final created = await controller.createSession(
      workspaceId: 'fixture-workspace',
      provider: 'codex',
      deviceId: owner.deviceId,
      canWrite: true,
      autoStart: true,
    );
    expect(created, isNotNull);
    relay.submittedKinds.clear();
    relay.submittedOperations.clear();

    await controller.sendMessage(
      message: '你好',
      deviceId: owner.deviceId,
      canWrite: true,
    );

    // 断言 1：首次 send 失败后必须自动恢复（resume 优先，符合 T3 裁决）。
    expect(
      relay.submittedKinds,
      [
        SessionCommandKind.send,
        SessionCommandKind.resume,
        SessionCommandKind.send,
      ],
      reason: '必须是 send 失败 → resume → 重试 send 的顺序',
    );
    // 断言 2：重试必须换幂等键；沿用旧键会被 Relay 去重成"返回上一次失败命令"，
    // 重试形同虚设。
    final sendKeys = <String>[];
    for (var i = 0; i < relay.submittedKinds.length; i += 1) {
      if (relay.submittedKinds[i] == SessionCommandKind.send) {
        sendKeys.add(relay.submittedOperations[i]);
      }
    }
    expect(sendKeys.length, 2);
    expect(sendKeys[0], isNot(sendKeys[1]));
    // 断言 3：重试成功后不再残留上一轮的错误面。
    expect(controller.errorMessage, isNull);
  });
  test('R17：resume 自报成功但状态投影不翻转时回退 start（不再死锁）', () async {
    // R17 实测：daemon 持久映射仍在时 resume 恒成功，但只恢复句柄、不注册
    // 实例也不写状态事件——投影保持 stopped。旧实现在健康门失败后直接放弃，
    // 用户被"会话恢复未成功，请先手动恢复会话再发送"死锁（无手动入口）。
    // 修复后：resume 成功但不健康 → 回退 start → 消息真正发出。
    var now = baseNow;
    final relay = _RecordingCommandRelay(clock: () => now);
    relay.projectSelectedSessionAsStopped = true;
    relay.keepStoppedAfterResume = true;
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

    await controller.sendMessage(
      message: 'R17 回归',
      deviceId: owner.deviceId,
      canWrite: true,
    );

    expect(relay.submittedKinds, contains(SessionCommandKind.resume),
        reason: '恢复链仍先走 resume（保留上下文的优先语义）');
    expect(relay.submittedKinds, contains(SessionCommandKind.start),
        reason: 'resume 成功但不健康时必须回退 start（死锁修复）');
    expect(relay.submittedKinds, contains(SessionCommandKind.send),
        reason: '恢复成功后消息必须真正发出');
    expect(controller.errorMessage, isNull, reason: '恢复链完成后不得残留错误面');
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
  // 提交顺序对应的幂等键：重试必须换键（Relay 按 operation 去重），
  // 否则断言只能看到"命令数变了"而看不出重试是否真的会生效。
  final List<String> submittedOperations = <String>[];
  bool projectSelectedSessionAsStopped = false;

  /// 首次 send 以"本机没有该会话实例"失败（local_state_missing 语义），
  /// 用于覆盖 v0.9.2 P2 修正：status 非 stopped 时也要能触发恢复重试。
  bool failFirstSendWithMissingInstance = false;
  int _sendAttempts = 0;

  /// 让 resume 以"本机没有实例映射"失败（local_state_missing 语义），
  /// 用于覆盖"新会话必须回退 start"的分支。
  bool failResumeWithMissingInstance = false;

  /// R17 实测形态：resume 自报成功（持久映射仍在），但 daemon 只恢复句柄、
  /// 不注册实例也不写状态事件——投影**永远**保持 stopped。用于覆盖
  /// "resume 成功但不健康 → 必须回退 start"的死锁修复。
  bool keepStoppedAfterResume = false;

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
    final stop = projectSelectedSessionAsStopped &&
        (keepStoppedAfterResume || submittedKinds.isEmpty);
    if (!stop) {
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
    submittedOperations.add(input.idempotencyKey);
    if (input.kind == SessionCommandKind.send) {
      _sendAttempts += 1;
      if (failFirstSendWithMissingInstance && _sendAttempts == 1) {
        throw RelayFailure(
          RelayFailureKind.protocol,
          'local_state_missing: session instance 不存在: session=fixture',
        );
      }
    }
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
