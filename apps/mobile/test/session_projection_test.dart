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
  });
}
