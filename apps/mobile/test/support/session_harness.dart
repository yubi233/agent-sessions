// v0.5 会话 UI 测试公共 harness：全屏 FixtureRelayRepository 驱动的可写会话入口
// 与稳定的交互 helper。供 session_takeover_test / session_accessibility_focus_test
// 等专项测试复用；与 session_screens_test.dart 的私有 helper 行为保持一致。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'app_harness.dart';

export 'app_harness.dart' show MobileAppHarness;

/// 打开一个 owner 可写的 fixture 会话详情页。
Future<MobileAppHarness> openWritableSession(
  WidgetTester tester,
  String ownerEmail,
) async {
  final harness = MobileAppHarness();
  await tester.pumpWidget(harness.build());
  await waitForVisible(tester, find.byKey(const Key('device-connect-submit')));
  await registerOwner(tester, ownerEmail);

  await tapVisible(tester, find.byKey(const Key('session-new-button')));
  await waitForVisible(
    tester,
    find.byKey(const Key('new-session-workspace-input')),
  );
  await enterVisible(
    tester,
    find.byKey(const Key('new-session-workspace-input')),
    'fixture-workspace',
  );
  await tapVisible(tester, find.byKey(const Key('new-session-create-button')));
  await waitForVisible(tester, find.byKey(const Key('session-detail-screen')));
  await tapVisible(
    tester,
    find.byKey(const Key('session-acquire-lease-button')),
  );
  await waitForVisible(tester, find.text('已获得控制权'));
  return harness;
}

Future<void> registerOwner(WidgetTester tester, String _) async {
  await tapVisible(tester, find.byKey(const Key('device-connect-submit')));
  await waitForVisible(tester, find.byKey(const Key('owner-ready-state')));
}

String composerText(WidgetTester tester) {
  return tester
      .widget<TextField>(find.byKey(const Key('session-composer-input')))
      .controller!
      .text;
}

Future<void> pressEnter(WidgetTester tester, {bool shift = false}) async {
  if (shift) {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  }
  await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
  if (shift) {
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  }
  await tester.pump(const Duration(milliseconds: 50));
}

/// TextField 光标会让 macOS/live binding 持续产帧；回归只等待下一项用户可见契约。
Future<void> waitForVisible(
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

Future<void> waitForGone(
  WidgetTester tester,
  Finder finder, {
  int maxFrames = 80,
}) async {
  for (var frame = 0; frame < maxFrames; frame += 1) {
    await tester.pump(const Duration(milliseconds: 50));
    if (finder.evaluate().isEmpty) return;
  }
  expect(finder, findsNothing);
}

Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  await waitForVisible(tester, finder);
  await tester.ensureVisible(finder);
  // ensureVisible 可能触发滚动/布局；多 pump 几帧让 RenderBox 完成布局与绘制，
  // 否则 hit test 使用陈旧偏移会被遮罩或滚动区吞掉。
  for (var frame = 0; frame < 3; frame += 1) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.tap(finder);
}

Future<void> enterVisible(
  WidgetTester tester,
  Finder finder,
  String text,
) async {
  await waitForVisible(tester, finder);
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.enterText(finder, text);
}
