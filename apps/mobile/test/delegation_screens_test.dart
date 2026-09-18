import 'package:agent_sessions_mobile/domain/delegation_models.dart';
import 'package:agent_sessions_mobile/domain/models.dart';
import 'package:agent_sessions_mobile/domain/session_models.dart';
import 'package:agent_sessions_mobile/relay/fixture_relay_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/app_harness.dart';

/// 模拟「自动获取租约被 Relay 拒绝」的 fail-closed 场景。
/// 打开会话后仍保持未持有控制权，派发入口显示中文原因且不创建节点。
class _AcquireLeaseBlockingRelay extends FixtureRelayRepository {
  bool blockAcquire = true;

  @override
  Future<SessionLease> acquireSessionLease(String sessionId) async {
    if (blockAcquire) {
      throw const RelayFailure(
        RelayFailureKind.forbidden,
        '测试 Relay 拒绝授予会话可操作状态。',
      );
    }
    return super.acquireSessionLease(sessionId);
  }
}
void main() {
  testWidgets('MOBILE-05 DELEG-06：批准后 parent 只显示摘要并可切入独立 child 会话', (
    tester,
  ) async {
    final harness = MobileAppHarness();
    _activeHarness = harness;
    await harness.launchAsOwner();
    await harness.seedSession();
    await tester.pumpWidget(harness.build());
    await _waitForVisible(tester, find.byKey(const Key('session-home-screen')));
    await _createAndAcquireParent(tester);

    final parentId = (await harness.relay.listSessions()).single.id;
    final proposal = await harness.relay.seedDelegationProposal(
      parentSessionId: parentId,
    );
    await _refreshSession(tester);
    await _waitForVisible(
      tester,
      find.byKey(Key('delegation-node-${proposal.id}')),
    );
    // 会话刷新会安全清空旧 epoch；确认派发前必须重新获取 parent lease。
    await _tapVisible(
      tester,
      find.byKey(const Key('session-acquire-lease-button')).first,
    );
    await _waitForVisible(tester, find.text('可控制'));
    expect(
      find.byKey(const Key('delegation-security-boundary')),
      findsOneWidget,
    );
    expect(find.textContaining('fixture-opaque'), findsNothing);
    expect(find.textContaining('ciphertext'), findsNothing);

    await _tapVisible(
      tester,
      find.byKey(Key('delegation-approve-${proposal.id}')),
    );
    await _waitForVisible(
      tester,
      find.byKey(Key('delegation-open-child-${proposal.id}')),
    );
    expect(find.text('子会话使用独立可操作状态'), findsOneWidget);
    // child 标题和正文均不回流到 parent detail；父页只呈现图节点投影。
    expect(find.text('新的会话 2'), findsNothing);

    await _tapVisible(
      tester,
      find.byKey(Key('delegation-open-child-${proposal.id}')),
    );
    await _waitForVisible(
      tester,
      find.byKey(const Key('session-detail-screen')),
    );
    expect(
      find.byKey(const Key('session-composer-blocked-reason')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('session-subagent-readonly')), findsOneWidget);
    expect(find.text('一次性子会话'), findsOneWidget);
    expect(find.byKey(const Key('session-model-seat')), findsNothing);
  });

  testWidgets('DELEG-04/06：拒绝无 child，unsupported target 显示禁用原因', (
    tester,
  ) async {
    final harness = MobileAppHarness();
    _activeHarness = harness;
    await harness.launchAsOwner();
    await harness.seedSession();
    await tester.pumpWidget(harness.build());
    await _waitForVisible(tester, find.byKey(const Key('session-home-screen')));
    await _createAndAcquireParent(tester);
    final parentId = (await harness.relay.listSessions()).single.id;

    final rejected = await harness.relay.seedDelegationProposal(
      parentSessionId: parentId,
    );
    await _refreshSession(tester);
    await _waitForVisible(
      tester,
      find.byKey(Key('delegation-reject-${rejected.id}')),
    );
    await _tapVisible(
      tester,
      find.byKey(const Key('session-acquire-lease-button')).first,
    );
    await _waitForVisible(tester, find.text('可控制'));
    await _tapVisible(
      tester,
      find.byKey(Key('delegation-reject-${rejected.id}')),
    );
    await _waitForVisible(tester, find.text('已拒绝'));
    expect(await harness.relay.listSessions(), hasLength(1));
    expect(
      find.byKey(Key('delegation-open-child-${rejected.id}')),
      findsNothing,
    );

    final unsupported = await harness.relay.seedDelegationProposal(
      parentSessionId: parentId,
      targetProvider: 'claude',
    );
    await _refreshSession(tester);
    await _waitForVisible(
      tester,
      find.byKey(Key('delegation-approve-${unsupported.id}')),
    );
    await _tapVisible(
      tester,
      find.byKey(const Key('session-acquire-lease-button')).first,
    );
    await _waitForVisible(tester, find.text('可控制'));
    final approve = tester.widget<IconButton>(
      find.byKey(Key('delegation-approve-${unsupported.id}')),
    );
    expect(approve.onPressed, isNull);
    final disabledIconColor = approve.style?.foregroundColor?.resolve({
      WidgetState.disabled,
    });
    final enabledIconColor = approve.style?.foregroundColor?.resolve({});
    expect(disabledIconColor, isNot(equals(enabledIconColor)));
    expect(
      find.byKey(Key('delegation-blocked-${unsupported.id}')),
      findsOneWidget,
    );
    expect(await harness.relay.listSessions(), hasLength(1));
  });

  testWidgets('MOBILE-07：父会话内可见派发入口创建 proposed 子会话节点', (tester) async {
    final harness = MobileAppHarness();
    _activeHarness = harness;
    await harness.launchAsOwner();
    await harness.seedSession();
    await tester.pumpWidget(harness.build());
    await _waitForVisible(tester, find.byKey(const Key('session-home-screen')));
    await _createAndAcquireParent(tester);

    // 打开“新建子会话”底表并提交：只提交密文 envelope 与目标 Provider。
    await _tapVisible(
      tester,
      find.byKey(const Key('delegation-propose-button')),
    );
    await _waitForVisible(
      tester,
      find.byKey(const Key('delegation-proposal-sheet')),
    );
    await _enterVisible(
      tester,
      find.byKey(const Key('delegation-task-summary-input')),
      '生成一份只读的迁移方案',
    );
    await _tapVisible(
      tester,
      find.byKey(const Key('delegation-propose-submit')),
    );
    await _waitForVisible(
      tester,
      find.byKey(Key('delegation-node-delegation-fixture-001')),
    );
    // 底表退场后再断言摘要不可见，避免动画中的输入框残留被误判。
    for (var frame = 0; frame < 10; frame += 1) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    // 任务摘要正文绝不能变成 Relay 可见内容：列表只展示 opaque 摘要指纹。
    expect(find.textContaining('迁移方案'), findsNothing);
    final nodes = await harness.relay.listSessionDelegations(
      (await harness.relay.listSessions()).single.id,
    );
    expect(nodes.single.status, DelegationStatus.proposed);
    expect(nodes.single.summaryEnvelope.containsKey('plaintext'), isFalse);
    expect(nodes.single.summaryEnvelope.containsKey('text'), isFalse);
  });

  testWidgets('MOBILE-V05-20：subagent catalog 展开子树、Escape 关闭并恢复焦点', (
    tester,
  ) async {
    final harness = MobileAppHarness();
    _activeHarness = harness;
    await harness.launchAsOwner();
    await harness.seedSession();
    await tester.pumpWidget(harness.build());
    await _waitForVisible(tester, find.byKey(const Key('session-home-screen')));
    await _createAndAcquireParent(tester);
    final parentId = (await harness.relay.listSessions()).single.id;
    final proposal = await harness.relay.seedDelegationProposal(
      parentSessionId: parentId,
    );
    await _refreshSession(tester);
    await _tapVisible(
      tester,
      find.byKey(const Key('session-acquire-lease-button')).first,
    );
    await _waitForVisible(tester, find.text('可控制'));
    await _tapVisible(
      tester,
      find.byKey(Key('delegation-approve-${proposal.id}')),
    );
    await _waitForVisible(
      tester,
      find.byKey(Key('delegation-open-child-${proposal.id}')),
    );

    await _tapVisible(
      tester,
      find.byKey(const Key('session-subagent-catalog')),
    );
    await _waitForVisible(
      tester,
      find.byKey(const Key('session-subagent-catalog-sheet')),
    );
    await _waitForVisible(
      tester,
      find.byKey(Key('session-subagent-entry-${proposal.id}')),
    );
    await _tapVisible(
      tester,
      find.byKey(Key('session-subagent-toggle-${proposal.id}')),
    );
    final child = (await harness.relay.listSessionDelegations(
      parentId,
    )).single.childSessionId!;
    await _waitForVisible(
      tester,
      find.byKey(Key('session-subagent-branch-empty-$child')),
    );
    expect(find.textContaining('token/时长不可用'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('session-subagent-catalog-sheet')),
      findsNothing,
    );
    final trigger = tester.widget<IconButton>(
      find.byKey(const Key('session-subagent-catalog')),
    );
    expect(trigger.focusNode?.hasFocus, isTrue);
  });

  testWidgets('MOBILE-07：无 parent lease 时派发入口给出中文原因且不创建节点', (tester) async {
    // v0.8.1+：blocking relay 使打开会话时的自动 lease 获取被拒（保持无 lease）。
    final relay = _AcquireLeaseBlockingRelay();
    final harness = MobileAppHarness(relay: relay);
    _activeHarness = harness;
    await harness.launchAsOwner();
    await harness.seedSession();
    await tester.pumpWidget(harness.build());
    final parentId = (await harness.relay.listSessions()).single.id;
    await _waitForVisible(tester, find.byKey(const Key('session-home-screen')));
    await _tapVisible(tester, find.byKey(const Key('session-recent-button')));
    await _waitForVisible(
      tester,
      find.byKey(Key('recent-session-$parentId')),
    );
    await _tapVisible(tester, find.byKey(Key('recent-session-$parentId')));
    await _waitForVisible(tester, find.byKey(const Key('session-detail-screen')));

    await _tapVisible(
      tester,
      find.byKey(const Key('delegation-propose-button')),
    );
    await _waitForVisible(
      tester,
      find.byKey(const Key('delegation-proposal-sheet')),
    );
    await _waitForVisible(
      tester,
      find.byKey(const Key('delegation-propose-blocked')),
    );
    expect(find.textContaining('可控制'), findsWidgets);
    expect(
      await harness.relay.listSessionDelegations(parentId),
      isEmpty,
      reason: '无 lease 时必须 fail-closed，不得创建 proposed 节点',
    );
  });
}

MobileAppHarness? _activeHarness;

/// v0.8.1+：打开预置会话详情并获取写权。
Future<void> _createAndAcquireParent(WidgetTester tester) async {
  final harness = _activeHarness;
  if (harness == null) return;
  final sessionId = (await harness.relay.listSessions()).single.id;
  await _tapVisible(tester, find.byKey(const Key('session-recent-button')));
  await _waitForVisible(
    tester,
    find.byKey(Key('recent-session-$sessionId')),
  );
  await _tapVisible(tester, find.byKey(Key('recent-session-$sessionId')));
  await _waitForVisible(tester, find.byKey(const Key('session-detail-screen')));
  await _waitForVisible(tester, find.text('可控制'));
}

Future<void> _refreshSession(WidgetTester tester) async {
  await _tapVisible(tester, find.byKey(const Key('session-quick-menu-button')));
  await _tapVisible(tester, find.byKey(const Key('session-refresh-button')));
}

Future<void> _waitForVisible(
  WidgetTester tester,
  Finder finder, {
  int maxFrames = 80,
}) async {
  for (var frame = 0; frame < maxFrames; frame += 1) {
    await tester.pump(const Duration(milliseconds: 50));
    if (finder.evaluate().isNotEmpty) return;
  }
  expect(finder, findsOneWidget);
}

Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  await _waitForVisible(tester, finder);
  await tester.ensureVisible(finder);
  // ensureVisible 可能触发滚动/布局；多 pump 几帧让 RenderBox 完成布局，避免陈旧偏移被吞。
  for (var frame = 0; frame < 3; frame += 1) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.tap(finder);
}

Future<void> _enterVisible(
  WidgetTester tester,
  Finder finder,
  String value,
) async {
  await _waitForVisible(tester, finder);
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.enterText(finder, value);
}
