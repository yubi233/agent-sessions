import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:agent_sessions_mobile/domain/session_projection_models.dart';
import 'package:agent_sessions_mobile/state/session_message_feedback_controller.dart';
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

    testWidgets('assistant 完成态尾标不再显示运行中', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 320,
              child: SessionChatView(
                running: false,
                nodes: [
                  ConversationNode(
                    key: 'assistant-completed',
                    kind: ConversationNodeKind.assistant,
                    sequence: 5,
                    label: 'Assistant',
                    text: '回复已经完成',
                    completedTurn: true,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 220));

      expect(find.text('已完成'), findsOneWidget);
      expect(find.text('运行中'), findsNothing);
    });

    testWidgets('notice 节点展示上游结构化错误码徽标', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 300,
              child: SessionChatView(
                running: true,
                nodes: const [
                  ConversationNode(
                    key: 'n5',
                    kind: ConversationNodeKind.notice,
                    sequence: 5,
                    label: 'Provider 错误',
                    text: '模型回合失败：quota',
                    errorCode: 'RATE_LIMIT',
                    httpStatus: 429,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 220));
      expect(find.text('Provider 错误'), findsOneWidget);
      expect(find.text('模型回合失败：quota'), findsOneWidget);
      // 徽标展示 错误码 · HTTP 状态。
      expect(find.text('RATE_LIMIT · 429'), findsOneWidget);
      expect(
        find.byKey(const Key('session-error-code-5')),
        findsOneWidget,
      );
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

    testWidgets('消息 actions 限制 copy/time/fork 并展示已发送引用', (tester) async {
      final clipboardValues = <String>[];
      final openedPaths = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              clipboardValues.add((call.arguments as Map)['text'] as String);
            }
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 520,
              child: SessionChatView(
                running: false,
                openFile: (path) async => openedPaths.add(path),
                nodes: [
                  ConversationNode(
                    key: 'u-actions',
                    kind: ConversationNodeKind.user,
                    sequence: 11,
                    label: '你',
                    text: '请让 @worker 执行 /goal',
                    copyText: '请让 @worker 执行 /goal',
                    canCopy: true,
                    showTimestamp: true,
                    createdAt: DateTime.utc(2026, 8, 20, 12, 5),
                    references: const [
                      ConversationReferenceChip(
                        label: 'worker',
                        kind: ConversationReferenceKind.session,
                      ),
                      ConversationReferenceChip(
                        label: '/goal',
                        kind: ConversationReferenceKind.command,
                      ),
                      ConversationReferenceChip(
                        label: 'README.md',
                        kind: ConversationReferenceKind.file,
                        target: 'README.md',
                      ),
                    ],
                  ),
                  const ConversationNode(
                    key: 'steering-actions',
                    kind: ConversationNodeKind.user,
                    sequence: 12,
                    label: '插话',
                    text: '追加一个插话',
                    copyText: '追加一个插话',
                    canCopy: true,
                    pendingSteering: true,
                  ),
                  ConversationNode(
                    key: 'a-actions',
                    kind: ConversationNodeKind.assistant,
                    sequence: 13,
                    label: 'Assistant',
                    text: '处理完成',
                    copyText: '处理完成',
                    canCopy: true,
                    showTimestamp: true,
                    createdAt: DateTime.utc(2026, 8, 20, 12, 6),
                    forkUnavailable: true,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 220));

      expect(
        find.byKey(const Key('session-reference-chip-11-0')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('session-reference-chip-11-1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('session-reference-chip-11-2')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('session-message-time-11')), findsOneWidget);
      expect(
        find.byKey(const Key('session-pending-steering-badge')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('session-message-time-12')), findsNothing);
      expect(
        find.byKey(const Key('session-message-fork-unavailable-12')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('session-message-fork-unavailable-13')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('session-message-copy-12')));
      await tester.pump();

      expect(clipboardValues, ['追加一个插话']);
      expect(
        find.byKey(const Key('session-message-action-feedback-12')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('session-reference-chip-11-2')));
      await tester.pump();
      expect(openedPaths, ['README.md']);
    });

    testWidgets('completed assistant fork action 调用上层分支 handler', (
      tester,
    ) async {
      final forkedMessages = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 420,
              child: SessionChatView(
                running: false,
                onFork: (messageId) async => forkedMessages.add(messageId),
                nodes: const [
                  ConversationNode(
                    key: 'assistant-fork-node',
                    kind: ConversationNodeKind.assistant,
                    sequence: 14,
                    label: 'Assistant',
                    messageId: 'assistant-fork-message',
                    text: '这一步可以分支。',
                    canFork: true,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 220));

      await tester.tap(find.byKey(const Key('session-message-fork-14')));
      await tester.pump();

      expect(forkedMessages, ['assistant-fork-message']);
    });

    testWidgets('文件打开旧请求迟到失败不会覆盖新路径错误面', (tester) async {
      final first = Completer<void>();
      final second = Completer<void>();
      final openedPaths = <String>[];

      Future<void> openFile(String path) {
        openedPaths.add(path);
        return openedPaths.length == 1 ? first.future : second.future;
      }

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 420,
              child: SessionChatView(
                running: false,
                openFile: openFile,
                nodes: const [
                  ConversationNode(
                    key: 'tool-one',
                    kind: ConversationNodeKind.tool,
                    sequence: 21,
                    label: '读取文件',
                    text: '准备打开第一个路径',
                    filePath: 'one.dart',
                  ),
                  ConversationNode(
                    key: 'tool-two',
                    kind: ConversationNodeKind.tool,
                    sequence: 22,
                    label: '读取文件',
                    text: '准备打开第二个路径',
                    filePath: 'two.dart',
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 220));

      await tester.tap(find.byKey(const Key('session-tool-open-path-21')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('session-tool-open-path-22')));
      await tester.pump();

      first.completeError(StateError('旧路径拒绝'));
      await tester.pump();
      expect(
        find.byKey(const Key('session-file-open-error-dialog')),
        findsNothing,
      );

      second.completeError(StateError('新路径拒绝'));
      await tester.pump();

      expect(openedPaths, ['one.dart', 'two.dart']);
      expect(
        find.byKey(const Key('session-file-open-error-dialog')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('session-file-open-error-dialog')),
          matching: find.byKey(const Key('session-file-open-error-path')),
        ),
        findsOneWidget,
      );
      expect(find.textContaining('新路径拒绝'), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('session-file-open-error-path')))
            .data,
        'two.dart',
      );
    });

    testWidgets('P2-C 工具详情可展开并通过 inspect 回调交给 Trajectory', (tester) async {
      final inspected = <String>[];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 520,
              child: SessionChatView(
                running: false,
                onInspectTarget: inspected.add,
                nodes: const [
                  ConversationNode(
                    key: 'tool-details',
                    kind: ConversationNodeKind.tool,
                    sequence: 31,
                    label: '读取工作区状态',
                    text: '检查完成',
                    toolStatus: 'completed',
                    toolDetails: ConversationToolDetails(
                      input: '{"kind":"workspace.status","path":"."}',
                      output: 'fixture: workspace status ready',
                      inspectTarget: 'tool-31',
                      subcalls: [
                        ConversationToolSubcall(
                          callId: 'sub-31-a',
                          label: '读取子目录',
                          status: 'ok',
                          subcalls: [
                            ConversationToolSubcall(
                              callId: 'sub-31-a-1',
                              label: '统计文件',
                              status: 'running',
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 220));

      await tester.tap(find.byKey(const Key('session-tool-details-31')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('session-tool-input-31')), findsOneWidget);
      expect(find.byKey(const Key('session-tool-output-31')), findsOneWidget);
      expect(find.text('IN'), findsOneWidget);
      expect(find.text('OUT'), findsOneWidget);
      expect(find.byKey(const ValueKey('sub-31-a')), findsOneWidget);
      expect(find.byKey(const ValueKey('sub-31-a-1')), findsOneWidget);

      await tester.tap(find.byKey(const Key('session-tool-inspect-31')));
      await tester.pump();

      expect(inspected, ['tool-31']);
    });

    testWidgets('P2-C produced files 独立 turn-tail，chips 复用 openFile opener', (
      tester,
    ) async {
      final opened = <String>[];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 520,
              child: SessionChatView(
                running: false,
                openFile: (path) async => opened.add(path),
                nodes: const [
                  ConversationNode(
                    key: 'produced-files',
                    kind: ConversationNodeKind.turnTail,
                    sequence: 32,
                    label: '产物文件',
                    producedFiles: [
                      ConversationProducedFile(
                        path: 'reports/fixture-summary.md',
                        label: 'fixture-summary.md',
                      ),
                      ConversationProducedFile(
                        path: 'logs/fixture.log',
                        label: 'fixture.log',
                      ),
                      ConversationProducedFile(
                        path: 'reports/raw.json',
                        label: 'raw.json',
                      ),
                      ConversationProducedFile(
                        path: 'reports/fourth.txt',
                        label: 'fourth.txt',
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 220));

      expect(
        find.byKey(const Key('session-produced-files-row-32')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('session-produced-file-32-0')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('session-produced-file-32-2')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('session-produced-files-more-32')),
        findsOneWidget,
      );
      expect(find.text('+1'), findsOneWidget);

      await tester.tap(find.byKey(const Key('session-produced-file-32-0')));
      await tester.pump();
      await tester.tap(
        find.byKey(const Key('session-produced-files-open-folder-32')),
      );
      await tester.pump();

      expect(opened, ['reports/fixture-summary.md', '.']);
    });

    testWidgets(
      'assistant feedback 支持 lazy ensure、toggle/retract、备注 popover 与焦点恢复',
      (tester) async {
        final writes = <String>[];
        ConversationFeedbackItem? committed = const ConversationFeedbackItem(
          rating: ConversationFeedbackRating.positive,
          version: 1,
        );
        final feedback = SessionMessageFeedbackController(
          reader: (_) async => committed,
          writer:
              ({
                required messageId,
                required rating,
                required note,
                required version,
              }) async {
                writes.add('$messageId:$rating:$note:$version');
                if (rating == null) {
                  committed = null;
                  return const ConversationFeedbackResult.success();
                }
                committed = ConversationFeedbackItem(
                  rating: rating,
                  note: note,
                  version: version == null ? 2 : 3,
                );
                return ConversationFeedbackResult.success(committed);
              },
        );
        await feedback.ensure('assistant-feedback');

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                height: 520,
                child: SessionChatView(
                  running: false,
                  feedbackController: feedback,
                  nodes: const [
                    ConversationNode(
                      key: 'assistant-feedback-node',
                      kind: ConversationNodeKind.assistant,
                      sequence: 21,
                      label: 'Assistant',
                      messageId: 'assistant-feedback',
                      text: '已完成',
                      canCopy: true,
                      feedbackAvailable: true,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 220));

        expect(
          find.byKey(const Key('session-message-like-21')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('session-message-dislike-21')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('session-message-note-21')),
          findsOneWidget,
        );

        await tester.tap(find.byKey(const Key('session-message-like-21')));
        await tester.pump();
        expect(writes.last, 'assistant-feedback:null:null:1');

        await tester.tap(find.byKey(const Key('session-message-dislike-21')));
        await tester.pump();
        expect(
          writes.last,
          'assistant-feedback:ConversationFeedbackRating.negative:null:null',
        );

        await tester.tap(find.byKey(const Key('session-message-note-21')));
        await tester.pump();
        expect(
          find.byKey(const Key('session-message-note-input-21')),
          findsOneWidget,
        );
        await tester.enterText(
          find.byKey(const Key('session-message-note-input-21')),
          '需要保留这个结果',
        );
        await tester.tap(find.byKey(const Key('session-message-note-save-21')));
        await tester.pump();
        expect(
          find.byKey(const Key('session-message-note-input-21')),
          findsNothing,
        );
        expect(
          writes.last,
          'assistant-feedback:ConversationFeedbackRating.negative:需要保留这个结果:2',
        );

        await tester.tap(find.byKey(const Key('session-message-note-21')));
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        expect(
          find.byKey(const Key('session-message-note-input-21')),
          findsNothing,
        );
        expect(tester.binding.focusManager.primaryFocus, isNotNull);
      },
    );

    testWidgets('assistant feedback version-conflict 保留 note 草稿并显示 panel 错误', (
      tester,
    ) async {
      final feedback = SessionMessageFeedbackController(
        reader: (_) async => const ConversationFeedbackItem(
          rating: ConversationFeedbackRating.positive,
          version: 7,
        ),
        writer:
            ({
              required messageId,
              required rating,
              required note,
              required version,
            }) async =>
                const ConversationFeedbackResult.failure('version-conflict'),
      );
      await feedback.ensure('assistant-conflict');

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 520,
              child: SessionChatView(
                running: false,
                feedbackController: feedback,
                nodes: const [
                  ConversationNode(
                    key: 'assistant-conflict-node',
                    kind: ConversationNodeKind.assistant,
                    sequence: 22,
                    label: 'Assistant',
                    messageId: 'assistant-conflict',
                    text: '已完成',
                    feedbackAvailable: true,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 220));
      await tester.tap(find.byKey(const Key('session-message-note-22')));
      await tester.pump();
      await tester.enterText(
        find.byKey(const Key('session-message-note-input-22')),
        '冲突时不能丢失',
      );
      await tester.tap(find.byKey(const Key('session-message-note-save-22')));
      await tester.pump();

      expect(
        find.byKey(const Key('session-message-note-input-22')),
        findsOneWidget,
      );
      expect(find.text('反馈已被其他设备修改，请重试。'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(
              find.byKey(const Key('session-message-note-input-22')),
            )
            .controller!
            .text,
        '冲突时不能丢失',
      );
    });
  });
}
