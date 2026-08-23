import 'package:agent_sessions_mobile/domain/session_projection_models.dart';
import 'package:agent_sessions_mobile/ui/session/composer/session_context_meter.dart';
import 'package:agent_sessions_mobile/ui/session/composer/session_stats_line.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// v0.5/P7：StatsLine / ContextMeter 只读投影回归。
void main() {
  testWidgets('MOBILE-V05-12/P7：StatsLine 显示可用字段，缺字段显示不可用', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SessionStatsLine(
            stats: SessionStatsLineProjection(
              inputTokens: 12480,
              outputTokens: 3840,
              cacheTokens: 61800,
              turnCount: 3,
              stepCount: 12,
              ttftMs: 1200,
              decodeThroughput: 12.5,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const Key('session-stats-line')), findsOneWidget);
    expect(find.byKey(const Key('session-stats-input')), findsOneWidget);
    expect(find.byKey(const Key('session-stats-output')), findsOneWidget);
    expect(find.byKey(const Key('session-stats-cache')), findsOneWidget);
    expect(find.byKey(const Key('session-stats-turns')), findsOneWidget);
    expect(find.byKey(const Key('session-stats-steps')), findsOneWidget);
    expect(find.byKey(const Key('session-stats-ttft')), findsOneWidget);
    expect(find.byKey(const Key('session-stats-throughput')), findsOneWidget);
    expect(find.textContaining('输入 12.5k'), findsOneWidget);
    expect(find.textContaining('首字 1.2s'), findsOneWidget);
    expect(find.textContaining('解码 12.5 tok/s'), findsOneWidget);
    expect(find.textContaining('上下文'), findsNothing);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SessionStatsLine(stats: SessionStatsLineProjection()),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('统计不可用'), findsOneWidget);
  });

  testWidgets('MOBILE-V05-12/P7：ContextMeter 显示比例并可打开 breakdown 对话框', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SessionContextMeter(
            meter: SessionContextMeterProjection(
              usedTokens: 92000,
              windowTokens: 100000,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const Key('session-context-meter')), findsOneWidget);
    expect(find.textContaining('上下文 92%'), findsOneWidget);

    await tester.tap(find.byKey(const Key('session-context-meter-open')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('session-context-meter-dialog')),
      findsOneWidget,
    );
    expect(find.textContaining('92%'), findsWidgets);

    await tester.tap(
      find.byKey(const Key('session-context-meter-dialog-close')),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('session-context-meter-dialog')), findsNothing);
    expect(
      tester
          .widget<InkWell>(find.byKey(const Key('session-context-meter-open')))
          .focusNode
          ?.hasFocus,
      isTrue,
    );
  });

  testWidgets('MOBILE-V05-12/P7：Context capacity 消失时关闭 breakdown 且不自动重开', (
    tester,
  ) async {
    final meter = ValueNotifier(
      const SessionContextMeterProjection(usedTokens: 200, windowTokens: 1000),
    );
    addTearDown(meter.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<SessionContextMeterProjection>(
            valueListenable: meter,
            builder: (context, value, _) => SessionContextMeter(meter: value),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('session-context-meter-open')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('session-context-meter-dialog')),
      findsOneWidget,
    );

    meter.value = const SessionContextMeterProjection(usedTokens: 200);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('session-context-meter-dialog')), findsNothing);
    expect(find.text('上下文不可用'), findsOneWidget);

    meter.value = const SessionContextMeterProjection(
      usedTokens: 200,
      windowTokens: 1000,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('session-context-meter-dialog')), findsNothing);
  });

  testWidgets('MOBILE-V05-12/P7：ContextMeter 缺窗口时显示不可用且不画伪占用', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SessionContextMeter(
            meter: SessionContextMeterProjection(usedTokens: 1),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('上下文不可用'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });
}
