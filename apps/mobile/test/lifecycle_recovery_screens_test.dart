import 'package:agent_sessions_mobile/app/providers.dart';
import 'package:agent_sessions_mobile/state/lifecycle_recovery_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/app_harness.dart';

void main() {
  testWidgets('MOBILE-06：恢复横幅显示应用内通知、失效 lease 与窄屏布局', (tester) async {
    await tester.binding.setSurfaceSize(const Size(480, 960));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final harness = MobileAppHarness();
    await tester.pumpWidget(harness.build());
    await _waitForVisible(
      tester,
      find.byKey(const Key('device-connect-submit')),
    );
    await _registerOwner(tester, 'lifecycle-ui-owner@fixture.test');
    await _tapVisible(tester, find.byKey(const Key('session-new-button')));
    await _waitForVisible(
      tester,
      find.byKey(const Key('new-session-create-button')),
    );
    await _tapVisible(
      tester,
      find.byKey(const Key('new-session-create-button')),
    );
    await _waitForVisible(
      tester,
      find.byKey(const Key('session-detail-screen')),
    );
    await _tapVisible(
      tester,
      find.byKey(const Key('session-acquire-lease-button')),
    );
    await _waitForVisible(tester, find.text('已获得控制权'));

    final container = ProviderScope.containerOf(
      tester.element(find.byKey(const Key('session-detail-screen'))),
    );
    final sessions = container.read(sessionControllerProvider);
    final recovery = container.read(sessionRecoveryControllerProvider);
    final sessionId = sessions.selectedSessionId!;
    await recovery.reportAppVisibility(MobileAppVisibility.background);
    await recovery.reportNetworkAvailability(MobileNetworkAvailability.offline);
    harness.relay.setNetworkAvailable(false);
    await harness.relay.appendOfflineRecoveryEvent(sessionId);
    harness.relay.repeatCursorEventOnNextSnapshot();
    harness.relay.setNetworkAvailable(true);
    await recovery.reportNetworkAvailability(MobileNetworkAvailability.online);
    await recovery.reportAppVisibility(MobileAppVisibility.foreground);
    await tester.pump();

    expect(sessions.hasSelectedLease, isFalse);
    expect(find.byKey(const Key('session-recovery-banner')), findsOneWidget);
    expect(find.byKey(const Key('session-recovery-notice')), findsOneWidget);
    expect(find.textContaining('本会话新增 1 条事件'), findsOneWidget);
    // 路由 test surface 可能把整个 480px 内容轨道居中平移；直接约束组件自身宽度，
    // 才能准确验证恢复条不会超出移动端逻辑画布。
    expect(
      tester.getSize(find.byKey(const Key('session-recovery-banner'))).width,
      lessThanOrEqualTo(480),
    );
    expect(
      find.byKey(const Key('session-composer-blocked-reason')),
      findsOneWidget,
    );

    await _tapVisible(
      tester,
      find.byKey(const Key('session-recovery-notice-dismiss')),
    );
    await tester.pump();
    expect(find.byKey(const Key('session-recovery-notice')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _registerOwner(WidgetTester tester, String _) async {
  await _tapVisible(tester, find.byKey(const Key('device-connect-submit')));
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
