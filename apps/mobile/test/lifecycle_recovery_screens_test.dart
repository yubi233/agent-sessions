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
    await harness.launchAsOwner();
    final sessionId = await harness.seedSession();
    await tester.pumpWidget(harness.build());
    await _waitForVisible(tester, find.byKey(const Key('session-home-screen')));
    // 经「最近会话」入口打开详情并等待自动获取写权。
    await _tapVisible(tester, find.byKey(const Key('session-recent-button')));
    await _waitForVisible(
      tester,
      find.byKey(Key('recent-session-$sessionId')),
    );
    await _tapVisible(tester, find.byKey(Key('recent-session-$sessionId')));
    await _waitForVisible(
      tester,
      find.byKey(const Key('session-detail-screen')),
    );
    await _waitForVisible(tester, find.text('可操作'));

    final container = ProviderScope.containerOf(
      tester.element(find.byKey(const Key('session-detail-screen'))),
    );
    final sessions = container.read(sessionControllerProvider);
    final recovery = container.read(sessionRecoveryControllerProvider);
    await recovery.reportAppVisibility(MobileAppVisibility.background);
    await recovery.reportNetworkAvailability(MobileNetworkAvailability.offline);
    harness.relay.setNetworkAvailable(false);
    await harness.relay.appendOfflineRecoveryEvent(sessionId);
    harness.relay.repeatCursorEventOnNextSnapshot();
    harness.relay.setNetworkAvailable(true);
    await recovery.reportNetworkAvailability(MobileNetworkAvailability.online);
    await recovery.reportAppVisibility(MobileAppVisibility.foreground);
    await tester.pump();
    // v0.9：恢复完成后自动重取会话写权（沿用最近成功授权参数），用户无需手动点按。
    for (var i = 0; i < 40 && !sessions.hasSelectedLease; i += 1) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(sessions.hasSelectedLease, isTrue);
    expect(find.byKey(const Key('session-recovery-banner')), findsOneWidget);
    expect(find.byKey(const Key('session-recovery-notice')), findsOneWidget);
    expect(find.textContaining('本会话新增 1 条事件'), findsOneWidget);
    // 路由 test surface 可能把整个 480px 内容轨道居中平移；直接约束组件自身宽度，
    // 才能准确验证恢复条不会超出移动端逻辑画布。
    expect(
      tester.getSize(find.byKey(const Key('session-recovery-banner'))).width,
      lessThanOrEqualTo(480),
    );
    // v0.9：lease 已自动重取，composer 不再显示阻断原因，可直接输入。
    expect(
      find.byKey(const Key('session-composer-blocked-reason')),
      findsNothing,
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
