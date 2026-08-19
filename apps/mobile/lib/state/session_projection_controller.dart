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
          messageId: event.messageId,
          createdAt: event.createdAt,
          copyText: _copyTextFor(event, nodeKind),
          canCopy: _canCopy(event, nodeKind),
          showTimestamp: _showTimestamp(event, nodeKind),
          canFork: _canFork(event, nodeKind),
          forkUnavailable: _forkUnavailable(event, nodeKind),
          pendingSteering: event.pendingSteering,
          references: _referenceChipsFor(event),
          filePath: event.filePath,
          toolDetails: _toolDetailsFor(event),
        ),
      );
      final producedFiles = _producedFilesFor(event);
      if (producedFiles.isNotEmpty) {
        nodes.add(
          ConversationNode(
            key: 'node:${event.sequence}:turnTail:producedFiles',
            kind: ConversationNodeKind.turnTail,
            sequence: event.sequence,
            label: '产物文件',
            producedFiles: producedFiles,
          ),
        );
      }
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

  ConversationToolDetails? _toolDetailsFor(SessionTimelineEvent event) {
    if (event.kind != SessionTimelineKind.toolActivity) return null;
    final details = ConversationToolDetails(
      input: event.toolInput,
      output: event.toolOutput,
      inspectTarget: event.inspectTarget,
    );
    return details.hasContent ? details : null;
  }

  List<ConversationProducedFile> _producedFilesFor(
    SessionTimelineEvent event,
  ) => event.producedFilePaths
      .where((path) => path.trim().isNotEmpty)
      .map(
        (path) => ConversationProducedFile(path: path, label: _basename(path)),
      )
      .toList(growable: false);

  String _basename(String path) {
    final normalized = path.trim();
    final parts = normalized.split('/').where((part) => part.isNotEmpty);
    return parts.isEmpty ? normalized : parts.last;
  }

  String? _copyTextFor(
    SessionTimelineEvent event,
    ConversationNodeKind nodeKind,
  ) {
    final copyText = event.copyText ?? _displayTextFor(event);
    if (!_canCopy(event, nodeKind)) return null;
    return copyText?.trim().isNotEmpty == true ? copyText : null;
  }

  bool _canCopy(SessionTimelineEvent event, ConversationNodeKind nodeKind) {
    final text = event.copyText ?? _displayTextFor(event);
    if (text?.trim().isNotEmpty != true) return false;
    if (event.pendingSteering) return nodeKind == ConversationNodeKind.user;
    return switch (nodeKind) {
      ConversationNodeKind.user => true,
      ConversationNodeKind.assistant => event.completedTurn,
      _ => false,
    };
  }

  bool _showTimestamp(
    SessionTimelineEvent event,
    ConversationNodeKind nodeKind,
  ) {
    if (event.createdAt == null || event.pendingSteering) return false;
    return switch (nodeKind) {
      ConversationNodeKind.user => true,
      ConversationNodeKind.assistant => event.completedTurn,
      _ => false,
    };
  }

  bool _canFork(SessionTimelineEvent event, ConversationNodeKind nodeKind) =>
      nodeKind == ConversationNodeKind.assistant &&
      event.completedTurn &&
      event.forkAvailable &&
      event.messageId?.trim().isNotEmpty == true;

  bool _forkUnavailable(
    SessionTimelineEvent event,
    ConversationNodeKind nodeKind,
  ) =>
      nodeKind == ConversationNodeKind.assistant &&
      event.completedTurn &&
      !event.forkAvailable;

  List<ConversationReferenceChip> _referenceChipsFor(
    SessionTimelineEvent event,
  ) => event.referenceLabels
      .map(_referenceChipFor)
      .whereType<ConversationReferenceChip>()
      .toList(growable: false);

  ConversationReferenceChip? _referenceChipFor(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return null;
    // fixture 可以用 kind:target 精确声明引用类型；UI 只展示，不重新解析为输入 claim。
    final separator = value.indexOf(':');
    if (separator > 0) {
      final prefix = value.substring(0, separator).toLowerCase();
      final target = value.substring(separator + 1).trim();
      if (target.isEmpty) return null;
      final kind = switch (prefix) {
        'command' => ConversationReferenceKind.command,
        'session' => ConversationReferenceKind.session,
        'folder' => ConversationReferenceKind.folder,
        'file' => ConversationReferenceKind.file,
        _ => null,
      };
      if (kind != null) {
        return ConversationReferenceChip(
          label: target,
          kind: kind,
          target: target,
        );
      }
    }

    if (value.startsWith('/')) {
      return ConversationReferenceChip(
        label: value,
        kind: ConversationReferenceKind.command,
      );
    }
    if (value.startsWith('@"') && value.endsWith('"')) {
      final target = value.substring(2, value.length - 1);
      final parts = target.split('/').where((part) => part.isNotEmpty).toList();
      return ConversationReferenceChip(
        label: parts.isEmpty ? target : parts.last,
        kind: ConversationReferenceKind.file,
        target: target,
      );
    }
    if (value.startsWith('@')) {
      final target = value.substring(1);
      return ConversationReferenceChip(
        label: target,
        kind: target.endsWith('/')
            ? ConversationReferenceKind.folder
            : ConversationReferenceKind.file,
        target: target,
      );
    }
    return ConversationReferenceChip(
      label: value,
      kind: ConversationReferenceKind.file,
      target: value,
    );
  }

  String? _resolvedStatus(SessionTimelineEvent event) {
    if (event.permission?.resolved == true ||
        event.question?.resolved == true) {
      return 'resolved';
    }
    return null;
  }
}
