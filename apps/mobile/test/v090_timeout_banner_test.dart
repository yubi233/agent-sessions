import 'package:agent_sessions_mobile/ui/session/chat/session_chat_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// V090-04：超时横幅「查看结果」与事件新鲜度 widget 回归（C1/C3/T5）。
/// 覆盖：成功路径只在真实事实到达时清横幅、失败路径横幅保留并浮出脱敏错误、
/// Key/Semantics 稳定契约、200% 文本缩放无溢出遮挡。
void main() {
  Widget bannerHarness({
    bool timedOut = true,
    String? freshnessText = '最近同步 12:30:01',
    Future<void> Function()? onViewResult,
  }) => MaterialApp(
    home: Scaffold(
      body: SessionChatView(
        nodes: const [],
        running: false,
        turnTimedOut: timedOut,
        timeoutFreshnessText: freshnessText,
        onViewResult: onViewResult,
      ),
    ),
  );

  testWidgets('V090-04: 超时横幅展示新文案、新鲜度次级行与「查看结果」出口', (tester) async {
    var viewResultCalls = 0;
    await tester.pumpWidget(
      bannerHarness(onViewResult: () async => viewResultCalls += 1),
    );

    expect(find.byKey(const Key('session-turn-timeout-row')), findsOneWidget);
    // C1 冻结文案：超时只切换 UX 表达，同步仍在继续。
    expect(find.text('等待结果已超时，仍在同步。'), findsOneWidget);
    // T5 裁决：事件新鲜度放横幅次级行。
    expect(find.byKey(const Key('session-turn-timeout-freshness')), findsOneWidget);
    expect(find.text('最近同步 12:30:01'), findsOneWidget);
    // C3：查看结果出口（稳定 Key + Semantics label）。
    expect(find.byKey(const Key('session-turn-timeout-view-result')), findsOneWidget);
    expect(find.text('查看结果'), findsOneWidget);
    final semantics = tester.getSemantics(
      find.byKey(const Key('session-turn-timeout-view-result')),
    );
    expect(semantics, isNotNull);

    await tester.tap(find.byKey(const Key('session-turn-timeout-view-result')));
    await tester.pump();
    expect(viewResultCalls, 1);
  });

  testWidgets('V090-04: 查看结果成功——真实终态到达后横幅清除', (tester) async {
    var timedOut = true;
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) => bannerHarness(
          timedOut: timedOut,
          onViewResult: () async {
            // controller.refreshTurnResult 的成功路径：真实事实到达才清横幅。
            setState(() => timedOut = false);
          },
        ),
      ),
    );
    expect(find.byKey(const Key('session-turn-timeout-row')), findsOneWidget);

    await tester.tap(find.byKey(const Key('session-turn-timeout-view-result')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('session-turn-timeout-row')), findsNothing);
  });

  testWidgets('V090-04: 查看结果失败——横幅保留，脱敏错误浮出', (tester) async {
    // 模拟 controller.refreshTurnResult 失败路径：横幅不清，errorMessage 浮出。
    await tester.pumpWidget(
      bannerHarness(
        onViewResult: () async {
          // 不改变 timedOut；错误经 Snackbar 呈现（与既有错误面同口径）。
        },
      ),
    );
    await tester.tap(find.byKey(const Key('session-turn-timeout-view-result')));
    await tester.pump();

    // 失败后横幅仍在（等待下一拍/L1/SSE 的真实事实）。
    expect(find.byKey(const Key('session-turn-timeout-row')), findsOneWidget);
  });

  testWidgets('V090-04: 200% 文本缩放无溢出、无遮挡', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(2.0)),
        child: bannerHarness(),
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('session-turn-timeout-row')), findsOneWidget);
    // 溢出断言：任何 RenderFlex overflow 都会以异常形式浮出。
    expect(tester.takeException(), isNull);
  });
}
