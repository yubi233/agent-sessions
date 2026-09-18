import 'package:agent_sessions_mobile/domain/session_models.dart';
import 'package:agent_sessions_mobile/relay/fixture_relay_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/session_harness.dart';

/// V094 定向回归骨架（P0 登记，计划 §4-P0 / §2.2/§2.5）：发送事务与回执观察。
///
/// 这些用例是**先红骨架**：在旧实现上可复现地失败，P1 事务化落地后转绿：
/// - V094-23：回执观察期间停止不被全局 busy 禁用（发送与停止门控解耦）；
/// - V094-07：结算不得清空回执等待期间用户新写的草稿（事务归属结算）；
/// - V094-06：受理后用户气泡呈现消息级状态（"已受理"），不是裸节点。
///
/// 受控回执：fixture 前 2 次回执轮询返回 running，模拟 daemon 迟迟不出终态的
/// 真实窗口（V093-04 同款竞争形态）。使用 'v084 stream' 标记保持回合稳定流式，
/// 避免终态时序抖动。
void main() {
  testWidgets('V094-23 骨架：回执等待期间停止入口保持可用（不被全局 busy 禁用）', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final relay = _ReceiptGateRelay();
    final harness = MobileAppHarness(relay: relay);
    await harness.launchAsOwner();
    final sessionId = await harness.seedSession();
    await tester.pumpWidget(harness.build());
    await waitForVisible(tester, find.byKey(const Key('session-home-screen')));
    await openSessionDetailFromRecent(tester, harness, sessionId);
    await waitForVisible(tester, find.byKey(const Key('session-composer-input')));

    await enterVisible(
      tester,
      find.byKey(const Key('session-composer-input')),
      'v084 stream 演示：停止门控检查',
    );    await tapVisible(
      tester,
      find.byKey(const Key('session-composer-primary-action')),
    );
    // 等 send 被受理（streaming 指示器出现），此刻回执窗口仍被 fixture 扣住。
    await waitForVisible(
      tester,
      find.byKey(const Key('assistant-streaming-indicator')),
    );
    await tester.pump(const Duration(milliseconds: 60));

    final primary = tester.widget<IconButton>(
      find.byKey(const Key('session-composer-primary-action')),
    );
    expect(
      primary.onPressed,
      isNotNull,
      reason:
          '回执等待期间停止入口必须可用（V094-23：提交/观察/停止门控解耦，'
          '不能仅因 send 在等终态而禁用停止；DSH send 等待回合结束，'
          '若停止必须等它才能中断等于没有中断能力）',
    );

    // 释放回执并让回合收敛，避免悬挂计时器污染后续用例。
    await _drainToSettled(tester);
    expect(relay.gatedCommandId, isNotNull);
    expect(sessionId, isNotNull);
  });

  testWidgets('V094-07 骨架：回执等待期间的新草稿不被旧事务结算清空', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final relay = _ReceiptGateRelay();
    final harness = MobileAppHarness(relay: relay);
    await harness.launchAsOwner();
    final sessionId = await harness.seedSession();
    await tester.pumpWidget(harness.build());
    await waitForVisible(tester, find.byKey(const Key('session-home-screen')));
    await openSessionDetailFromRecent(tester, harness, sessionId);
    await waitForVisible(tester, find.byKey(const Key('session-composer-input')));

    await enterVisible(
      tester,
      find.byKey(const Key('session-composer-input')),
      'v084 stream 演示：草稿归属检查',
    );
    await tapVisible(
      tester,
      find.byKey(const Key('session-composer-primary-action')),
    );
    await waitForVisible(
      tester,
      find.byKey(const Key('assistant-streaming-indicator')),
    );
    // 回执窗口期内写下一条草稿：提交快照与后续草稿分离（§2.4）。
    await tester.enterText(
      find.byKey(const Key('session-composer-input')),
      '回执等待期的新草稿',
    );
    await tester.pump(const Duration(milliseconds: 60));

    await _drainToSettled(tester);

    expect(
      composerText(tester),
      '回执等待期的新草稿',
      reason:
          '旧事务结算不得清空回执等待期间的新草稿（V094-07：'
          '末尾无条件清 draft 必须改为按事务身份结算）',
    );
  });

  testWidgets('V094-06 骨架：受理后用户气泡呈现消息级状态而非裸节点', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final relay = _ReceiptGateRelay();
    final harness = MobileAppHarness(relay: relay);
    await harness.launchAsOwner();
    final sessionId = await harness.seedSession();
    await tester.pumpWidget(harness.build());
    await waitForVisible(tester, find.byKey(const Key('session-home-screen')));
    await openSessionDetailFromRecent(tester, harness, sessionId);
    await waitForVisible(tester, find.byKey(const Key('session-composer-input')));

    await enterVisible(
      tester,
      find.byKey(const Key('session-composer-input')),
      'v084 stream 演示：消息状态检查',
    );
    await tapVisible(
      tester,
      find.byKey(const Key('session-composer-primary-action')),
    );
    await waitForVisible(
      tester,
      find.byKey(const Key('assistant-streaming-indicator')),
    );
    await tester.pump(const Duration(milliseconds: 60));

    expect(
      find.textContaining('已受理'),
      findsOneWidget,
      reason:
          'Relay 202 后用户气泡必须呈现消息级状态（已受理），'
          '让"气泡出现"与"送达/执行"可区分（V094-06）',
    );

    await _drainToSettled(tester);
  });
}

/// 回执等待期排空：推进假时钟直至 send 事务收敛（含回执轮询与回合收敛）。
Future<void> _drainToSettled(WidgetTester tester) async {
  for (var frame = 0; frame < 120; frame += 1) {
    await tester.pump(const Duration(milliseconds: 250));
  }
}

/// 受控回执 fixture：第一条 send 的回执前 N 次轮询保持 running，
/// 模拟 daemon 迟迟不出终态；其余行为与默认 fixture 一致。
class _ReceiptGateRelay extends FixtureRelayRepository {
  int pendingReceiptPollsForFirstSend = 2;
  String? gatedCommandId;
  int _polls = 0;

  @override
  Future<SessionCommandReceipt> submitSessionCommand(
    String sessionId,
    SessionCommandInput input,
  ) async {
    final receipt = await super.submitSessionCommand(sessionId, input);
    if (input.kind == SessionCommandKind.send && gatedCommandId == null) {
      gatedCommandId = receipt.id;
    }
    return receipt;
  }

  @override
  Future<SessionCommandReceipt> getSessionCommand(String commandId) async {
    if (commandId == gatedCommandId &&
        _polls < pendingReceiptPollsForFirstSend) {
      _polls += 1;
      return SessionCommandReceipt(
        id: commandId,
        kind: 'session.send',
        status: 'running',
        idempotencyKey: 'fixture-$commandId',
      );
    }
    return super.getSessionCommand(commandId);
  }
}
