import 'package:agent_sessions_mobile/main.dart' show macBookPhoneLogicalSize;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/support/app_harness.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('VISUAL-MOBILE-02：owner 控制端状态截图', (tester) async {
    await binding.setSurfaceSize(macBookPhoneLogicalSize);
    addTearDown(() => binding.setSurfaceSize(null));

    final harness = MobileAppHarness();
    await tester.pumpWidget(harness.build());
    await _waitForVisible(
      tester,
      find.byKey(const Key('device-connect-submit')),
    );
    expect(find.byKey(const Key('login-email')), findsNothing);
    expect(find.byKey(const Key('register-email')), findsNothing);
    await _tapVisible(tester, find.byKey(const Key('device-connect-submit')));
    // v0.8.1 起认证成功后 router 重定向到 /home（DSH 主页），W1 中间页不再停留
    // （与 w1_auth_pairing_flow 同一归因，2026-09-28 真机 gate）。
    await _waitForVisible(tester, find.byKey(const Key('session-home-screen')));

    // 只推进已知路由动画时长；可见截图由独立 flutter run fixture 负责，避免干扰测试宿主退出。
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const Key('session-home-screen')), findsOneWidget);
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
