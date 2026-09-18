import 'package:agent_sessions_mobile/domain/session_models.dart';
import 'package:agent_sessions_mobile/relay/fixture_relay_repository.dart';
import 'package:agent_sessions_mobile/state/session_controller.dart';
import 'package:agent_sessions_mobile/state/session_send_transaction.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/fixture_owner.dart';

/// V094 发送事务与回执观察回归（计划 §2.2/§2.5，V094-06/07/23）。
///
/// 这些用例在 P0 是先红骨架（widget 版在旧实现上可复现失败，见实施记录 34
/// §1.3）；P1 事务化落地后固化为 controller 级回归：
/// - V094-23：202 受理即释放全局 busy（提交/观察解耦），回执窗口转后台；
/// - V094-06：受理即有事务账本阶段（"已受理，等待执行"），乐观回显同源；
/// - V094-07：观察期间的新草稿不被旧事务的迟到结算清空（按身份结算）。
///
/// 受控回执：`_ReceiptGateRelay` 把首条 send 的终态回执延后 N 拍
/// （真实定时器，V093-04 同款竞争形态），其余行为与默认 fixture 一致。
void main() {
  test('V094-23：202 受理后全局 busy 立即释放，回执观察在后台继续', () async {
    final relay = _ReceiptGateRelay(pendingPolls: 4);
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

    // UI 路径语义：awaitTurnCompletion=false（composer 实际调用形态）。
    final future = controller.sendMessage(
      message: 'V094-23 停止门控检查',
      deviceId: owner.deviceId,
      canWrite: true,
      awaitTurnCompletion: false,
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    // 202 已受理（事务在账本、回合在途），但全局 busy 必须已释放——
    // 旧实现在 30s 回执窗口内持有 busy，停止与提交都被禁用。
    expect(controller.activeSendTransaction?.phase, SessionSendPhase.accepted);
    expect(controller.isTurnInFlight, isTrue);
    expect(controller.isBusy, isFalse);

    await future;
    await _waitForTransactionTerminal(controller);
    // 回执最终收敛为完成，事务按成功结算。
    expect(
      controller.activeSendTransaction?.phase ?? SessionSendPhase.completed,
      SessionSendPhase.completed,
    );
  });

  test('V094-06：受理即产生消息事务阶段与乐观回显（气泡出现 ≠ 已送达）', () async {
    final relay = _ReceiptGateRelay(pendingPolls: 3);
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

    await controller.sendMessage(
      message: 'V094-06 消息状态检查',
      deviceId: owner.deviceId,
      canWrite: true,
      awaitTurnCompletion: false,
    );

    final tx = controller.activeSendTransaction;
    expect(tx, isNotNull);
    expect(tx!.phase, SessionSendPhase.accepted);
    // 乐观回显与事务同一事实源：气泡挂出即有状态，不伪装成已送达。
    expect(controller.pendingOutgoingMessage, 'V094-06 消息状态检查');
    expect(tx.phase.userLabel, '已受理，等待执行');
    // 同一次显式发送的 clientMessageId 稳定；重试复用、两次发送必不同。
    expect(tx.clientMessageId, startsWith('cmsg-'));

    await _waitForTransactionTerminal(controller);
  });

  test('V094-07：观察期间保存的新草稿不被旧事务结算清空', () async {
    final relay = _ReceiptGateRelay(pendingPolls: 4);
    final owner = await bootstrapFixtureOwner(relay);
    final controller = SessionController(relay: relay);
    await controller.initialize();
    final created = await controller.createSession(
      workspaceId: 'fixture-workspace',
      provider: 'codex',
      deviceId: owner.deviceId,
      canWrite: true,
      autoStart: true,
    );
    final sessionId = created!.id;

    await controller.sendMessage(
      message: 'V094-07 草稿归属检查',
      deviceId: owner.deviceId,
      canWrite: true,
      awaitTurnCompletion: false,
    );
    // 回执窗口期内用户写下的新草稿（composer 本地状态由 controller 持久化）。
    controller.saveComposerState(
      sessionId,
      controller.composerStateFor(sessionId).copyWith(draft: '回执等待期的新草稿'),
    );

    await _waitForTransactionTerminal(controller);
    // 旧事务结算只允许清空"仍是本次提交正文"的草稿（按内容身份结算），
    // 观察期间的新草稿必须原样保留。
    expect(controller.composerDraftFor(sessionId), '回执等待期的新草稿');
  });

  test('V094-06：失败回执优先收敛为失败事务，正文保留可重试（V093-04b 不回退）', () async {
    final relay = _ReceiptGateRelay(pendingPolls: 2, failOnRelease: true);
    final owner = await bootstrapFixtureOwner(relay);
    final controller = SessionController(relay: relay);
    controller.sendReceiptPollAttempts = 8;
    await controller.initialize();
    await controller.createSession(
      workspaceId: 'fixture-workspace',
      provider: 'codex',
      deviceId: owner.deviceId,
      canWrite: true,
      autoStart: true,
    );

    await controller.sendMessage(
      message: 'V094-06 失败收敛检查',
      deviceId: owner.deviceId,
      canWrite: true,
      awaitTurnCompletion: false,
    );
    expect(controller.activeSendTransaction, isNotNull);

    await _waitForTransactionTerminal(controller);
    final tx = controller.lastInterruptedSendTransaction;
    expect(tx, isNotNull, reason: '失败事务必须保留为消息待处理项');
    expect(tx!.phase, SessionSendPhase.failed);
    expect(tx.errorCode, 'LOCAL_STATE_MISSING');
    // 失败正文保留在事务中（不回填草稿、不删除记录），供编辑后重试。
    // （规范 user.message 合并后乐观回显按既有语义清账；失败事实在事务里。）
    expect(tx.text, 'V094-06 失败收敛检查');
    expect(controller.lastInterruptedSendTransaction!.clientMessageId,
        startsWith('cmsg-'));
  });
}

/// 等待后台事务观察器收敛（真实定时器；上限 10s 防悬挂）。
Future<void> _waitForTransactionTerminal(SessionController controller) async {
  for (var i = 0; i < 100; i++) {
    final tx = controller.activeSendTransaction;
    if (tx == null || tx.isTerminal) {
      // 失败/待确认事务保留在槽内（isTerminal），再等一拍让收尾通知完成。
      await Future<void>.delayed(const Duration(milliseconds: 30));
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  fail('发送事务未在窗口内收敛：phase=${controller.activeSendTransaction?.phase}');
}

/// 受控回执 fixture：首条 send 的终态回执延后 [pendingPolls] 拍；
/// [failOnRelease] 为 true 时释放后返回 failed(LOCAL_STATE_MISSING)，
/// 驱动失败收敛路径（V093-04b 的失败回执优先语义）。
class _ReceiptGateRelay extends FixtureRelayRepository {
  _ReceiptGateRelay({this.pendingPolls = 2, this.failOnRelease = false});

  final int pendingPolls;

  /// true：释放后所有受控 send 回执一律 failed(LOCAL_STATE_MISSING)——
  /// 自动恢复重试也失败，驱动「失败事务保留」终态（重试上限 1 次）。
  final bool failOnRelease;
  final Set<String> gatedCommandIds = {};
  final Map<String, int> _pollCounts = {};

  @override
  Future<SessionCommandReceipt> submitSessionCommand(
    String sessionId,
    SessionCommandInput input,
  ) async {
    final receipt = await super.submitSessionCommand(sessionId, input);
    if (input.kind == SessionCommandKind.send) {
      gatedCommandIds.add(receipt.id);
    }
    return receipt;
  }

  @override
  Future<SessionCommandReceipt> getSessionCommand(String commandId) async {
    if (!gatedCommandIds.contains(commandId)) {
      return super.getSessionCommand(commandId);
    }
    final polls = (_pollCounts[commandId] ?? 0) + 1;
    _pollCounts[commandId] = polls;
    if (polls <= pendingPolls) {
      return SessionCommandReceipt(
        id: commandId,
        kind: 'session.send',
        status: 'running',
        idempotencyKey: 'fixture-$commandId',
      );
    }
    if (failOnRelease) {
      return SessionCommandReceipt(
        id: commandId,
        kind: 'session.send',
        status: 'failed',
        idempotencyKey: 'fixture-$commandId',
        errorCode: 'LOCAL_STATE_MISSING',
      );
    }
    return super.getSessionCommand(commandId);
  }
}
