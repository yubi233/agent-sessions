import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/app_harness.dart';

void main() {
  testWidgets('MOBILE-05 DELEG-06：批准后 parent 只显示摘要并可切入独立 child 会话', (
    tester,
  ) async {
    final harness = MobileAppHarness();
    await tester.pumpWidget(harness.build());
    await _registerOwner(tester, 'delegation-ui-owner@fixture.test');
    await _createAndAcquireParent(tester);

    final parentId = (await harness.relay.listSessions()).single.id;
    final proposal = await harness.relay.seedDelegationProposal(
      parentSessionId: parentId,
    );
    await _tapVisible(tester, find.byKey(const Key('session-refresh-button')));
    await _waitForVisible(
      tester,
      find.byKey(Key('delegation-node-${proposal.id}')),
    );
    // 会话刷新会安全清空旧 epoch；确认派发前必须重新获取 parent lease。
    await _tapVisible(
      tester,
      find.byKey(const Key('session-acquire-lease-button')),
    );
    await _waitForVisible(tester, find.text('已获得控制权'));
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
    expect(find.text('子会话使用独立控制权'), findsOneWidget);
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
    expect(find.text('等待获取会话控制权'), findsOneWidget);
  });

  testWidgets('DELEG-04/06：拒绝无 child，unsupported target 显示禁用原因', (
    tester,
  ) async {
    final harness = MobileAppHarness();
    await tester.pumpWidget(harness.build());
    await _registerOwner(tester, 'delegation-reject-owner@fixture.test');
    await _createAndAcquireParent(tester);
    final parentId = (await harness.relay.listSessions()).single.id;

    final rejected = await harness.relay.seedDelegationProposal(
      parentSessionId: parentId,
    );
    await _tapVisible(tester, find.byKey(const Key('session-refresh-button')));
    await _waitForVisible(
      tester,
      find.byKey(Key('delegation-reject-${rejected.id}')),
    );
    await _tapVisible(
      tester,
      find.byKey(const Key('session-acquire-lease-button')),
    );
    await _waitForVisible(tester, find.text('已获得控制权'));
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
    await _tapVisible(tester, find.byKey(const Key('session-refresh-button')));
    await _waitForVisible(
      tester,
      find.byKey(Key('delegation-approve-${unsupported.id}')),
    );
    await _tapVisible(
      tester,
      find.byKey(const Key('session-acquire-lease-button')),
    );
    await _waitForVisible(tester, find.text('已获得控制权'));
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
}

Future<void> _createAndAcquireParent(WidgetTester tester) async {
  await _tapVisible(tester, find.byKey(const Key('session-new-button')));
  await _waitForVisible(
    tester,
    find.byKey(const Key('new-session-create-button')),
  );
  await _tapVisible(tester, find.byKey(const Key('new-session-create-button')));
  await _waitForVisible(tester, find.byKey(const Key('session-detail-screen')));
  await _tapVisible(
    tester,
    find.byKey(const Key('session-acquire-lease-button')),
  );
  await _waitForVisible(tester, find.text('已获得控制权'));
}

Future<void> _registerOwner(WidgetTester tester, String email) async {
  await _tapVisible(tester, find.byKey(const Key('register-link')));
  await _waitForVisible(tester, find.byKey(const Key('register-email')));
  await _enterVisible(tester, find.byKey(const Key('register-email')), email);
  await _enterVisible(
    tester,
    find.byKey(const Key('register-password')),
    'fixture-password',
  );
  await _tapVisible(tester, find.byKey(const Key('register-submit')));
  await _waitForVisible(tester, find.byKey(const Key('owner-ready-state')));
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
  await tester.pump();
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
