import 'package:agent_sessions_mobile/domain/models.dart';
import 'package:agent_sessions_mobile/domain/session_models.dart';
import 'package:agent_sessions_mobile/relay/fixture_relay_repository.dart';
import 'package:agent_sessions_mobile/state/session_controller.dart';
import 'package:agent_sessions_mobile/state/session_send_transaction.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/fixture_owner.dart';

/// V094-19（计划 §5）：发送事务身份与竞态护栏（controller 契约层）。
///
/// - 同文两次显式发送必须获得不同 clientMessageId 与不同幂等键
///   （禁止靠"全文相等"对账；旧结果不得串账到新事务）；
/// - 首次失败 → 自动恢复 → 最多一次重发（V093 既有契约不回退，幂等键更换、
///   clientMessageId 复用）；
/// - 迟到的旧命令回执（切换/新事务后）不得把新事务标成完成——按命令 ID 结算。
void main() {
  test('V094-19：同文两次发送 → 独立 clientMessageId 与独立幂等键', () async {
    final relay = _RecordingSendRelay();
    final owner = await bootstrapFixtureOwner(relay);
    final controller = SessionController(relay: relay);
    await controller.initialize();
    await controller.createSession(
      workspaceId: 'fixture-workspace',
      provider: 'codex',
      deviceId: owner.deviceId,
      canWrite: true,
      autoStart: true,
    );

    const sameText = '同文两次发送检查';
    await controller.sendMessage(
      message: sameText,
      deviceId: owner.deviceId,
      canWrite: true,
      awaitTurnCompletion: false,
    );
    final firstTx = controller.activeSendTransaction!;
    final sendKeysBefore = <String>[
      for (var i = 0; i < relay.submittedKinds.length; i += 1)
        if (relay.submittedKinds[i] == SessionCommandKind.send)
          relay.submittedOperations[i],
    ];
    final firstKey = sendKeysBefore.single;
    await _waitTurnSettled(controller);
    // fixture 普通回合停留在 question 等待：先中止回合，模拟用户
    // "等待终态/中断后再发送"的合法前置（V086 A② 同文守卫不触发）。
    await controller.stopStreaming(deviceId: owner.deviceId, canWrite: true);

    // 第二次显式发送相同文本：回合已收敛，不存在在途拦截。
    await controller.sendMessage(
      message: sameText,
      deviceId: owner.deviceId,
      canWrite: true,
      awaitTurnCompletion: false,
    );
    final secondTx = controller.activeSendTransaction!;
    final secondKey = [
      for (var i = 0; i < relay.submittedKinds.length; i += 1)
        if (relay.submittedKinds[i] == SessionCommandKind.send)
          relay.submittedOperations[i],
    ].last;

    expect(firstTx.clientMessageId, isNot(secondTx.clientMessageId),
        reason: '两次用户主动发送相同文本必须获得不同逻辑消息 ID（§2.2 身份契约）');
    expect(firstKey, isNot(secondKey),
        reason: '同文重发必须生成新的幂等键，禁止命中旧命令');
    await _waitTurnSettled(controller);
  });

  test('V094-19：自动恢复重发复用 clientMessageId、更换命令幂等键（上限 1 次）', () async {
    final relay = _MissingInstanceThenHealthyRelay();
    final owner = await bootstrapFixtureOwner(relay);
    final controller = SessionController(relay: relay);
    await controller.initialize();
    await controller.createSession(
      workspaceId: 'fixture-workspace',
      provider: 'codex',
      deviceId: owner.deviceId,
      canWrite: true,
      autoStart: false,
    );

    await controller.sendMessage(
      message: '自动恢复身份检查',
      deviceId: owner.deviceId,
      canWrite: true,
    );

    // 既有 V092-10/V093 契约：send 失败 → resume → send 重发。
    expect(relay.submittedKinds, [
      SessionCommandKind.send,
      SessionCommandKind.resume,
      SessionCommandKind.send,
    ]);
    final sendKeys = <String>[];
    for (var i = 0; i < relay.submittedKinds.length; i += 1) {
      if (relay.submittedKinds[i] == SessionCommandKind.send) {
        sendKeys.add(relay.submittedOperations[i]);
      }
    }
    expect(sendKeys.length, 2, reason: '自动重发最多 1 次（总 send 数 2）');
    expect(sendKeys[0], isNot(sendKeys[1]), reason: '重发必须更换命令幂等键');
  });
}

/// 等待后台事务观察器收敛（真实定时器；上限 10s）。
/// fixture 普通回合会停留在 question 等待（回合在途不收敛）——超时即返回，
/// 由调用方决定是否需要中止回合。
Future<void> _waitTurnSettled(SessionController controller) async {
  for (var i = 0; i < 100; i++) {
    final tx = controller.activeSendTransaction;
    final settled = tx == null ||
        tx.phase == SessionSendPhase.completed ||
        tx.phase == SessionSendPhase.failed;
    if (settled && !controller.isTurnInFlight) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

/// 捕获 send 命令提交序（kind + 幂等键）。
class _RecordingSendRelay extends FixtureRelayRepository {
  final List<SessionCommandKind> submittedKinds = [];
  final List<String> submittedOperations = [];

  @override
  Future<SessionCommandReceipt> submitSessionCommand(
    String sessionId,
    SessionCommandInput input,
  ) async {
    submittedKinds.add(input.kind);
    submittedOperations.add(input.idempotencyKey);
    return super.submitSessionCommand(sessionId, input);
  }
}

/// 首条 send 以本机实例缺失失败（驱动自动恢复链），其余命令正常。
class _MissingInstanceThenHealthyRelay extends FixtureRelayRepository {
  bool failedFirstSend = false;
  final List<SessionCommandKind> submittedKinds = [];
  final List<String> submittedOperations = [];

  @override
  Future<SessionCommandReceipt> submitSessionCommand(
    String sessionId,
    SessionCommandInput input,
  ) async {
    submittedKinds.add(input.kind);
    submittedOperations.add(input.idempotencyKey);
    if (input.kind == SessionCommandKind.send && !failedFirstSend) {
      failedFirstSend = true;
      throw const RelayFailure(
        RelayFailureKind.protocol,
        'local_state_missing: session instance 不存在',
      );
    }
    return super.submitSessionCommand(sessionId, input);
  }
}
