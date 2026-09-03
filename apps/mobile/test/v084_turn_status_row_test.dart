import 'package:agent_sessions_mobile/domain/session_models.dart';
import 'package:agent_sessions_mobile/domain/session_projection_models.dart';
import 'package:agent_sessions_mobile/ui/session/chat/session_chat_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// v0.8.4（V084-10 状态行，ADR-015 §3）：
/// phase-aware 状态行文案映射与无投影回退。
void main() {
  Widget host(TurnPhase? phase) => MaterialApp(
    home: Scaffold(
      body: SessionChatView(
        nodes: const <ConversationNode>[],
        running: true,
        turnPhase: phase,
      ),
    ),
  );

  Future<String> statusText(WidgetTester tester, TurnPhase? phase) async {
    await tester.pumpWidget(host(phase));
    await tester.pump();
    final row = find.byKey(const Key('session-turn-status-row'));
    expect(row, findsOneWidget);
    return tester.widget<Text>(find.descendant(of: row, matching: find.byType(Text))).data ??
        tester
            .widget<Text>(find.descendant(of: row, matching: find.byType(Text).first))
            .data!;
  }

  testWidgets('thinking 相位显示思考中', (tester) async {
    await tester.pumpWidget(host(TurnPhase.thinking));
    await tester.pump();
    expect(find.text('思考中...'), findsOneWidget);
  });

  testWidgets('streaming 相位显示生成中', (tester) async {
    await tester.pumpWidget(host(TurnPhase.streaming));
    await tester.pump();
    expect(find.text('生成中...'), findsOneWidget);
  });

  testWidgets('toolRunning 相位显示工具执行中，waitingQuestion 显示等待回答', (tester) async {
    await tester.pumpWidget(host(TurnPhase.toolRunning));
    await tester.pump();
    expect(find.text('工具执行中...'), findsOneWidget);

    await tester.pumpWidget(host(TurnPhase.waitingQuestion));
    await tester.pump();
    expect(find.text('等待你的回答...'), findsOneWidget);
  });

  testWidgets('无 phase 投影回退通用文案（旧会话/旧桥行为不变）', (tester) async {
    await tester.pumpWidget(host(null));
    await tester.pump();
    expect(find.text('模型仍在处理当前轮次...'), findsOneWidget);
  });

  testWidgets('running=false 时状态行整体消失（终态收敛）', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SessionChatView(
            nodes: const <ConversationNode>[],
            running: false,
            turnPhase: TurnPhase.completed,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const Key('session-turn-status-row')), findsNothing);
  });
}
