import '../domain/control_models.dart';
import '../domain/session_models.dart';
import '../domain/session_projection_models.dart';

/// v0.5 会话展示投影构建器。
///
/// 该类是纯转换层：读取已经解密/裁剪后的本地 timeline 和 control snapshot，
/// 输出 UI 可消费的 display-safe 快照。它不订阅 Relay，不缓存密文，也不发送命令。
class SessionProjectionController {
  const SessionProjectionController();

  SessionProjectionSnapshot buildSnapshot({
    required List<SessionTimelineEvent> timeline,
    required SessionControlState controls,
  }) {
    final nodes = <ConversationNode>[];
    final waits = <ComposerPendingWait>[];
    final trajectory = <TrajectoryRecord>[];

    for (final event in timeline) {
      final nodeKind = _nodeKindFor(event);
      trajectory.add(
        TrajectoryRecord(
          key: 'trajectory:${event.sequence}',
          sequence: event.sequence,
          kind: nodeKind,
          label: event.label,
          status: event.isStreaming
              ? 'streaming'
              : event.toolStatus ?? _resolvedStatus(event),
          summary: event.text,
        ),
      );

      // pending interaction 是 composer chain 的唯一交互面，不能再渲染成 Chat 操作卡。
      final wait = _pendingWaitFor(event);
      if (wait != null) {
        waits.add(wait);
        continue;
      }

      nodes.add(
        ConversationNode(
          key: 'node:${event.sequence}:${nodeKind.name}',
          kind: nodeKind,
          sequence: event.sequence,
          label: event.label,
          text: _displayTextFor(event),
          isStreaming: event.isStreaming,
          toolStatus: event.toolStatus,
          safeReasoningSummary: _safeReasoningSummary(event),
        ),
      );
    }

    return SessionProjectionSnapshot(
      chatNodes: List.unmodifiable(nodes),
      pendingWaits: List.unmodifiable(waits),
      trajectoryRecords: List.unmodifiable(trajectory),
      stats: SessionStatsLineProjection.fromUsage(controls.usage),
      context: SessionContextMeterProjection.fromUsage(controls.usage),
    );
  }

  ConversationNodeKind _nodeKindFor(SessionTimelineEvent event) =>
      switch (event.kind) {
        SessionTimelineKind.userMessage => ConversationNodeKind.user,
        SessionTimelineKind.assistantMessage =>
          _looksLikeReasoning(event)
              ? ConversationNodeKind.reasoning
              : ConversationNodeKind.assistant,
        SessionTimelineKind.toolActivity => ConversationNodeKind.tool,
        SessionTimelineKind.permissionRequest => ConversationNodeKind.notice,
        SessionTimelineKind.questionRequest => ConversationNodeKind.notice,
        SessionTimelineKind.systemNotice =>
          _looksLikeCommand(event)
              ? ConversationNodeKind.command
              : ConversationNodeKind.notice,
        SessionTimelineKind.encryptedPlaceholder =>
          ConversationNodeKind.encrypted,
      };

  ComposerPendingWait? _pendingWaitFor(SessionTimelineEvent event) {
    final permission = event.permission;
    if (permission != null && permission.resolved != true) {
      return ComposerPendingWait.approval(
        requestId: permission.requestId,
        title: permission.title,
        summary: permission.summary,
      );
    }

    final question = event.question;
    if (question != null && question.resolved != true) {
      return ComposerPendingWait.question(
        requestId: question.requestId,
        prompt: question.prompt,
        options: question.options,
        allowsFreeform: question.allowsFreeform,
      );
    }
    return null;
  }

  String? _displayTextFor(SessionTimelineEvent event) {
    if (_looksLikeReasoning(event)) {
      // reasoning 只展示安全摘要；没有摘要时交给 UI 显示运行元数据。
      return _safeReasoningSummary(event);
    }
    return event.text;
  }

  String? _safeReasoningSummary(SessionTimelineEvent event) {
    final text = event.text?.trim();
    if (text == null || text.isEmpty) return null;
    final lower = event.label.toLowerCase();
    if (lower.contains('reasoning') ||
        lower.contains('thinking') ||
        event.label.contains('思考')) {
      return text;
    }
    return null;
  }

  bool _looksLikeReasoning(SessionTimelineEvent event) =>
      event.kind == SessionTimelineKind.assistantMessage &&
      _safeReasoningSummary(event) != null;

  bool _looksLikeCommand(SessionTimelineEvent event) =>
      event.text?.trimLeft().startsWith('/') == true ||
      event.label.toLowerCase().contains('command');

  String? _resolvedStatus(SessionTimelineEvent event) {
    if (event.permission?.resolved == true ||
        event.question?.resolved == true) {
      return 'resolved';
    }
    return null;
  }
}
