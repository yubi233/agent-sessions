import 'package:agent_sessions_mobile/domain/session_projection_models.dart';
import 'package:agent_sessions_mobile/state/session_view_controller.dart';
import 'package:agent_sessions_mobile/ui/session/chat/session_chat_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('MOBILE-V05-10 history prepend 保持 reader anchor', (tester) async {
    final key = GlobalKey<_ScrollHarnessState>();
    await tester.binding.setSurfaceSize(const Size(420, 620));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_ScrollHarness(key: key));
    await tester.pump(const Duration(milliseconds: 240));

    final initial = _position(tester);
    initial.jumpTo(initial.maxScrollExtent / 2);
    await tester.pump();
    final before = _position(tester);
    final beforePixels = before.pixels;
    final beforeMax = before.maxScrollExtent;
    expect(beforePixels, lessThan(beforeMax));

    key.currentState!.prependHistory();
    await tester.pump();
    await tester.pump();
    final after = _position(tester);
    final addedExtent = after.maxScrollExtent - beforeMax;

    expect(addedExtent, greaterThan(0));
    expect(after.pixels - beforePixels, closeTo(addedExtent, 1.5));
  });

  testWidgets('MOBILE-V05-10 tab/remount 从逐会话 store 恢复 scroll', (tester) async {
    final key = GlobalKey<_ScrollHarnessState>();
    await tester.binding.setSurfaceSize(const Size(420, 620));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_ScrollHarness(key: key));
    await tester.pump(const Duration(milliseconds: 240));

    final initial = _position(tester);
    initial.jumpTo(initial.maxScrollExtent / 2);
    await tester.pump();
    final before = _position(tester).pixels;
    expect(before, greaterThan(0));

    key.currentState!.setChatVisible(false);
    await tester.pump();
    key.currentState!.setChatVisible(true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    expect(_position(tester).pixels, closeTo(before, 1.5));
  });

  testWidgets('MOBILE-V05-10 history loading/error/retry/load older 可见', (
    tester,
  ) async {
    var retries = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SessionChatView(
            nodes: const [],
            running: false,
            historyError: '历史窗口暂时不可用',
            onLoadOlder: () async => retries += 1,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('session-chat-history-error')), findsOneWidget);
    await tester.tap(find.byKey(const Key('session-chat-history-retry')));
    await tester.pump();
    expect(retries, 1);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SessionChatView(
            nodes: const [],
            running: false,
            canLoadOlder: true,
            onLoadOlder: () async => retries += 1,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const Key('session-chat-load-older')), findsOneWidget);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SessionChatView(
            nodes: [],
            running: false,
            historyLoading: true,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(
      find.byKey(const Key('session-chat-history-loading')),
      findsOneWidget,
    );
  });
}

class _ScrollHarness extends StatefulWidget {
  const _ScrollHarness({super.key});

  @override
  State<_ScrollHarness> createState() => _ScrollHarnessState();
}

class _ScrollHarnessState extends State<_ScrollHarness> {
  final view = SessionViewController();
  var visible = true;
  var nodes = _nodes(20, 40);

  void prependHistory() => setState(() {
    nodes = [..._nodes(10, 20), ...nodes];
  });

  void setChatVisible(bool next) => setState(() => visible = next);

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: visible
          ? SessionChatView(
              nodes: nodes,
              running: false,
              initialScrollOffset: view.chatScrollOffsetFor('session-1'),
              onScrollOffsetChanged: (offset) =>
                  view.setChatScrollOffset('session-1', offset),
            )
          : const Center(child: Text('Trajectory placeholder')),
    ),
  );
}

List<ConversationNode> _nodes(int start, int end) => [
  for (var sequence = start; sequence < end; sequence++)
    ConversationNode(
      key: 'history-$sequence',
      kind: ConversationNodeKind.notice,
      sequence: sequence,
      label: '历史事件 $sequence',
      text: '用于稳定测量滚动锚点的展示文本 $sequence',
    ),
];

ScrollPosition _position(WidgetTester tester) => tester
    .state<ScrollableState>(
      find.descendant(
        of: find.byKey(const Key('session-chat-view')),
        matching: find.byType(Scrollable),
      ),
    )
    .position;
