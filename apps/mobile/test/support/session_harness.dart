// v0.5 会话 UI 测试公共 harness：全屏 FixtureRelayRepository 驱动的可写会话入口
// 与稳定的交互 helper。供 session_takeover_test / session_accessibility_focus_test
// 等专项测试复用；与 session_screens_test.dart 的私有 helper 行为保持一致。
import 'package:agent_sessions_mobile/app/router.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'app_harness.dart';

export 'app_harness.dart' show MobileAppHarness;

/// v0.8.1+：预置 owner 与会话后，经「最近会话」入口打开会话详情。
/// 返回 harness（调用方可用 relay 断言事件）。
Future<MobileAppHarness> openWritableSession(
  WidgetTester tester,
  String ownerEmail,
) async {
  final harness = MobileAppHarness();
  await harness.launchAsOwner();
  final sessionId = await harness.seedSession();
  await tester.pumpWidget(harness.build());
  await waitForVisible(tester, find.byKey(const Key('session-home-screen')));
  await openSessionDetailFromRecent(tester, harness, sessionId);
  await waitForVisible(tester, find.text('可操作'));
  return harness;
}

/// v0.8.1+ owner 引导已由 bootstrapLocalOwner 预置完成，无需再点击连接。
Future<void> registerOwner(WidgetTester tester, String _) async {
  await waitForVisible(tester, find.byKey(const Key('session-home-screen')));
}

/// v0.8.1+：进入「新建会话」页（首页无旧式新建按钮，经 router 直达）。
Future<void> openNewSessionScreen(WidgetTester tester) async {
  // 从 home 页元素向上找 ProviderScope（containerOf 不接受 scope 自身 element）。
  final container = ProviderScope.containerOf(
    tester.element(find.byKey(const Key('session-home-screen'))),
  );
  container.read(appRouterProvider).go('/sessions/new');
  await waitForVisible(
    tester,
    find.byKey(const Key('new-session-workspace-input')),
  );
}

/// 从首页「最近会话」入口打开指定会话详情。
Future<void> openSessionDetailFromRecent(
  WidgetTester tester,
  MobileAppHarness harness,
  String sessionId,
) async {
  await tapVisible(tester, find.byKey(const Key('session-recent-button')));
  await waitForVisible(tester, find.byKey(Key('recent-session-$sessionId')));
  await tapVisible(tester, find.byKey(Key('recent-session-$sessionId')));
  await waitForVisible(tester, find.byKey(const Key('session-detail-screen')));
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
