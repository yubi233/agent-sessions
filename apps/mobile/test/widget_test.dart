// Android mock 控制壳 widget 测试（MOBILE-02 的 widget 层级）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:agent_sessions_mobile/main.dart';

void main() {
  testWidgets('MOBILE-02：登录后新建 mock 会话并流式显示', (tester) async {
    await tester.pumpWidget(const AgentSessionsApp());

    // 初始未连接。
    expect(find.textContaining('未连接'), findsOneWidget);

    // 登录（mock）。
    await tester.tap(find.byKey(const Key('login-button')));
    await tester.pump();
    expect(find.textContaining('已登录'), findsOneWidget);

    // 新建会话 → 显示运行中与流式消息。
    await tester.tap(find.byKey(const Key('start-button')));
    await tester.pump();
    expect(find.textContaining('正在启动'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.textContaining('运行中'), findsOneWidget);
    expect(find.text('hello from mock'), findsOneWidget);

    // 中止后回到空闲。
    await tester.tap(find.byKey(const Key('abort-button')));
    await tester.pump();
    expect(find.textContaining('已中止'), findsOneWidget);
  });

  testWidgets('MOBILE-02：未启动会话时 abort 禁用', (tester) async {
    await tester.pumpWidget(const AgentSessionsApp());
    await tester.tap(find.byKey(const Key('login-button')));
    await tester.pump();
    final abort = tester.widget<OutlinedButton>(find.byKey(const Key('abort-button')));
    expect(abort.onPressed, isNull);
  });
}
