import 'package:agent_sessions_mobile/domain/control_models.dart';
import 'package:agent_sessions_mobile/domain/session_models.dart';
import 'package:agent_sessions_mobile/domain/session_projection_models.dart';
import 'package:agent_sessions_mobile/state/session_projection_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MOBILE-V05-03 display-safe 会话投影', () {
    test('pending waits 进入 composer chain，不进入 Chat nodes', () {
      const projection = SessionProjectionController();
      final snapshot = projection.buildSnapshot(
        timeline: const [
          SessionTimelineEvent(
            sequence: 1,
            kind: SessionTimelineKind.userMessage,
            label: '你',
            text: '请执行检查',
          ),
          SessionTimelineEvent(
            sequence: 2,
            kind: SessionTimelineKind.permissionRequest,
            label: '需要确认',
            permission: TimelinePermissionRequest(
              requestId: 'perm-1',
              title: '运行命令',
              summary: '需要执行只读检查。',
            ),
          ),
          SessionTimelineEvent(
            sequence: 3,
            kind: SessionTimelineKind.questionRequest,
            label: '需要回答',
            question: TimelineQuestionRequest(
              requestId: 'question-1',
              prompt: '选择环境',
              options: ['本地', '远端'],
              allowsFreeform: true,
            ),
          ),
          SessionTimelineEvent(
            sequence: 4,
            kind: SessionTimelineKind.assistantMessage,
            label: 'Assistant',
            text: '收到。',
          ),
        ],
        controls: const SessionControlState.empty(),
      );

      expect(snapshot.chatNodes.map((node) => node.sequence), [1, 4]);
      expect(snapshot.pendingWaits, hasLength(2));
      expect(snapshot.pendingWaits.first.kind, ComposerPendingKind.approval);
      expect(snapshot.pendingWaits.last.kind, ComposerPendingKind.question);
      expect(snapshot.trajectoryRecords.map((row) => row.sequence), [
        1,
        2,
        3,
        4,
      ]);
    });

    test('StatsLine 和 ContextMeter 缺字段时保持 unavailable，不填假 0', () {
      const projection = SessionProjectionController();
      final snapshot = projection.buildSnapshot(
        timeline: const [],
        controls: const SessionControlState.empty(),
      );

      expect(snapshot.stats.isUnavailable, isTrue);
      expect(snapshot.stats.inputTokens, isNull);
      expect(snapshot.context.ratio, isNull);
    });

    test('usage 与 context pressure 分层，reasoning 只使用安全摘要', () {
      const projection = SessionProjectionController();
      final snapshot = projection.buildSnapshot(
        timeline: const [
          SessionTimelineEvent(
            sequence: 9,
            kind: SessionTimelineKind.assistantMessage,
            label: 'Thinking summary',
            text: '已完成安全摘要。',
          ),
        ],
        controls: const SessionControlState.empty().copyWith(
          usage: SessionUsageSummary(
            inputTokens: 1200,
            outputTokens: 300,
            contextTokens: 6000,
            cacheReadTokens: 400,
            cacheCreationTokens: 20,
            contextWindowTokens: 12000,
          ),
        ),
      );

      expect(snapshot.chatNodes.single.kind, ConversationNodeKind.reasoning);
      expect(snapshot.chatNodes.single.text, '已完成安全摘要。');
      expect(snapshot.stats.inputTokens, 1200);
      expect(snapshot.stats.outputTokens, 300);
      expect(snapshot.stats.cacheTokens, 420);
      expect(snapshot.context.ratio, 0.5);
    });

    test('消息动作与引用 chip 只从 display-safe 字段投影', () {
      const projection = SessionProjectionController();
      final snapshot = projection.buildSnapshot(
        timeline: [
          SessionTimelineEvent(
            sequence: 1,
            kind: SessionTimelineKind.userMessage,
            label: '你',
            text: '请继续 @worker 处理 /goal',
            copyText: '请继续 @worker 处理 /goal',
            createdAt: DateTime.utc(2026, 8, 20, 12, 5),
            referenceLabels: const ['session:worker', 'command:/goal'],
          ),
          const SessionTimelineEvent(
            sequence: 2,
            kind: SessionTimelineKind.userMessage,
            label: '插话',
            text: '排队中的插话',
            pendingSteering: true,
          ),
          SessionTimelineEvent(
            sequence: 3,
            kind: SessionTimelineKind.assistantMessage,
            label: 'Assistant',
            text: '处理完成',
            messageId: 'msg-3',
            createdAt: DateTime.utc(2026, 8, 20, 12, 6),
            completedTurn: true,
            forkAvailable: true,
          ),
          SessionTimelineEvent(
            sequence: 4,
            kind: SessionTimelineKind.toolActivity,
            label: '读取文件',
            text: '读取 pubspec.yaml',
            filePath: 'pubspec.yaml',
          ),
        ],
        controls: const SessionControlState.empty(),
      );

      final user = snapshot.chatNodes[0];
      expect(user.canCopy, isTrue);
      expect(user.showTimestamp, isTrue);
      expect(user.references.map((chip) => chip.kind), [
        ConversationReferenceKind.session,
        ConversationReferenceKind.command,
      ]);

      final steering = snapshot.chatNodes[1];
      expect(steering.pendingSteering, isTrue);
      expect(steering.canCopy, isTrue);
      expect(steering.showTimestamp, isFalse);
      expect(steering.canFork, isFalse);

      final assistant = snapshot.chatNodes[2];
      expect(assistant.canCopy, isTrue);
      expect(assistant.showTimestamp, isTrue);
      expect(assistant.canFork, isTrue);

      final tool = snapshot.chatNodes[3];
      expect(tool.canCopy, isFalse);
      expect(tool.filePath, 'pubspec.yaml');
    });

    test('P2-C 工具详情留在 tool node，产物文件生成独立 turn-tail', () {
      const projection = SessionProjectionController();
      final snapshot = projection.buildSnapshot(
        timeline: const [
          SessionTimelineEvent(
            sequence: 31,
            kind: SessionTimelineKind.toolActivity,
            label: '读取工作区状态',
            text: '检查完成',
            toolStatus: 'completed',
            toolInput: '{"kind":"workspace.status","path":"."}',
            toolOutput: 'fixture: workspace status ready',
            inspectTarget: 'tool-31',
            producedFilePaths: [
              'reports/fixture-summary.md',
              'logs/fixture.log',
            ],
          ),
          SessionTimelineEvent(
            sequence: 32,
            kind: SessionTimelineKind.assistantMessage,
            label: 'Assistant',
            text: '我写好了 reports/from-prose.md。',
            completedTurn: true,
          ),
        ],
        controls: const SessionControlState.empty(),
      );

      expect(snapshot.chatNodes, hasLength(3));
      final tool = snapshot.chatNodes[0];
      expect(tool.kind, ConversationNodeKind.tool);
      expect(tool.toolDetails?.input, '{"kind":"workspace.status","path":"."}');
      expect(tool.toolDetails?.output, 'fixture: workspace status ready');
      expect(tool.toolDetails?.inspectTarget, 'tool-31');
      expect(tool.producedFiles, isEmpty);

      final produced = snapshot.chatNodes[1];
      expect(produced.kind, ConversationNodeKind.turnTail);
      expect(produced.key, 'node:31:turnTail:producedFiles');
      expect(produced.producedFiles.map((file) => file.path), [
        'reports/fixture-summary.md',
        'logs/fixture.log',
      ]);
      expect(produced.producedFiles.map((file) => file.label), [
        'fixture-summary.md',
        'fixture.log',
      ]);

      final assistant = snapshot.chatNodes[2];
      expect(assistant.kind, ConversationNodeKind.assistant);
      expect(assistant.producedFiles, isEmpty);
    });
  });
}
