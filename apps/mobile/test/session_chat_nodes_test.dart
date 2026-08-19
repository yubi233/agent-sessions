import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:agent_sessions_mobile/domain/session_projection_models.dart';
import 'package:agent_sessions_mobile/ui/session/chat/session_chat_view.dart';

void main() {
  group('MOBILE-V05-10/P2 SessionChatView', () {
    testWidgets('keyed Chat nodes 渲染投影节点并排除 pending 文案', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 520,
              child: SessionChatView(
                running: true,
                nodes: const [
                  ConversationNode(
                    key: 'u1',
                    kind: ConversationNodeKind.user,
                    sequence: 1,
                    label: 'User',
                    text: '请检查计划',
                  ),
                  ConversationNode(
                    key: 'r2',
                    kind: ConversationNodeKind.reasoning,
                    sequence: 2,
                    label: 'Reasoning',
                    safeReasoningSummary: '安全摘要：正在整理步骤',
                    text: '安全摘要：正在整理步骤',
                  ),
                  ConversationNode(
                    key: 't3',
                    kind: ConversationNodeKind.tool,
                    sequence: 3,
                    label: 'tool.run',
                    toolStatus: 'completed',
                  ),
                  ConversationNode(
                    key: 'a4',
                    kind: ConversationNodeKind.assistant,
                    sequence: 4,
                    label: 'Assistant',
                    text: '计划已更新',
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 220));

      expect(find.byKey(const Key('session-chat-view')), findsOneWidget);
      expect(find.byKey(const Key('session-chat-node-u1')), findsOneWidget);
      expect(find.byKey(const Key('session-chat-node-r2')), findsOneWidget);
      expect(find.byKey(const Key('session-chat-node-t3')), findsOneWidget);
      expect(find.byKey(const Key('session-reasoning-row-2')), findsOneWidget);
      expect(
        find.byKey(const Key('session-compact-node-3-tool')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('session-turn-status-row')), findsOneWidget);
      expect(find.textContaining('permission'), findsNothing);
      expect(find.textContaining('question'), findsNothing);
    });

    testWidgets('reader 离开底部后显示回到底部入口', (tester) async {
      final nodes = List<ConversationNode>.generate(
        32,
        (index) => ConversationNode(
          key: 'node-$index',
          kind: index.isEven
              ? ConversationNodeKind.user
              : ConversationNodeKind.assistant,
          sequence: index + 1,
          label: index.isEven ? 'User' : 'Assistant',
          text: '第 $index 条消息用于制造可滚动高度。',
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 360,
              child: SessionChatView(nodes: nodes, running: false),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 220));

      await tester.drag(
        find.byKey(const Key('session-chat-view')),
        const Offset(0, 260),
      );
      await tester.pump();

      expect(
        find.byKey(const Key('session-chat-to-bottom-button')),
        findsOneWidget,
      );
    });
  });
}
