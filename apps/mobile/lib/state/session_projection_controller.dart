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
    // v0.8.4（ADR-015 §3）：按 revision 单调折叠 phase 投影；乱序/回退帧丢弃。
    TurnPhase? turnPhase;
    var phaseRevision = 0;

    // v0.5/P6-B：用 user 事件作为 turn 分组锚点；无 user 时统一归到 turn-0。
    // 该 turnId 只是展示层分组标识，不写回 Relay / Chat projection。
    var currentTurn = 'turn-0';
    DateTime? previousCreatedAt;

    for (final event in timeline) {
      if (event.kind == SessionTimelineKind.userMessage) {
        currentTurn = 'turn-${event.sequence}';
      }
      final nodeKind = _nodeKindFor(event);
      final createdAt = event.createdAt;
      final duration = (createdAt != null && previousCreatedAt != null)
          ? createdAt.difference(previousCreatedAt)
          : null;
      if (createdAt != null) previousCreatedAt = createdAt;
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
          createdAt: createdAt,
          duration: duration,
          turnId: currentTurn,
          isStreaming: event.isStreaming,
          inspectTarget: event.inspectTarget,
        ),
      );

      // v0.8.4：turn_phase 只驱动状态行（快照上的 turnPhase 字段），不渲染
      // 聊天气泡，也不进入轨迹记录（避免高频 phase 帧刷屏）。
      if (event.kind == SessionTimelineKind.turnPhase) {
        if (event.phase != null && event.phaseRevision >= phaseRevision) {
          turnPhase = event.phase;
          phaseRevision = event.phaseRevision;
        }
        continue;
      }

      // pending interaction 是 composer chain 的唯一交互面，不能再渲染成 Chat 操作卡。
      final wait = _pendingWaitFor(event);
      if (wait != null) {
        waits.add(wait);
        continue;
      }

      // v0.9.2 R17：同回合 assistant 帧收敛——delta（streaming=true）帧与
      // completed（streaming=false）帧描述**同一条**回复，必须渲染为一条气泡；
      // 否则用户看到「运行中」+「已完成」两条重复回复（真机录屏实测）。
      if (nodeKind == ConversationNodeKind.assistant) {
        // ① 新流式帧取代仍在 streaming 的前帧（同回合只有一条在途气泡）。
        final prevStreaming = nodes.lastIndexWhere(
          (n) => n.kind == ConversationNodeKind.assistant && n.isStreaming,
        );
        if (prevStreaming >= 0) {
          nodes.removeAt(prevStreaming);
        }
        // ② turn.completed 终态帧（completed_turn=true、无正文）并入最后一条
        //    assistant 气泡并置「已完成」，自身不新增气泡。
        if (event.completedTurn && event.text?.trim().isNotEmpty != true) {
          final idx = nodes.lastIndexWhere(
            (n) => n.kind == ConversationNodeKind.assistant,
          );
          if (idx >= 0) {
            nodes[idx] = _nodeWithCompletedTail(nodes[idx]);
          }
          continue;
        }
      }

      if (nodeKind == ConversationNodeKind.assistant &&
          event.text?.trim().isNotEmpty != true &&
          !event.isStreaming) {
        continue;
      }
      // v0.9.5 P1（预览/回放合一）：导入预览（messageId 带 `imported` 前缀）与
      // resume 回放的 canonical 事件描述同一段 DSH 历史；canonical 节点到达时
      // 折叠更早的同文 imported 预览节点，避免回放后出现双气泡。只作用于本次
      // 投影的 chatNodes（原始事件不删除）；仅精确匹配 imported 前缀，绝不折叠
      // 无前缀的真实历史（两次同文发送是合法历史）。
      if (nodeKind == ConversationNodeKind.user ||
          nodeKind == ConversationNodeKind.assistant) {
        _collapseImportedPreview(nodes, nodeKind, event.text);
      }
      nodes.add(
        ConversationNode(
          // v0.8.7（V087-06）：assistant/reasoning 节点优先用上游 messageId 作
          // 稳定 key——流式期间同身份帧每批整体替换节点（sequence 随帧变化），
          // 稳定 key 让打字机释放动画的元素状态跨帧存活（completed 帧同身份
          // 替换时也平滑收敛）；无 messageId 回退 sequence（现状形态）。
          // tool/command 等 key 消费方（轨迹/检查器）不受影响，维持 sequence。
          key: 'node:${_stableNodeKey(event, nodeKind)}:${nodeKind.name}',
          kind: nodeKind,
          sequence: event.sequence,
          label: event.label,
          text: _displayTextFor(event),
          errorCode: event.errorCode,
          httpStatus: event.httpStatus,
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
          feedbackAvailable: _feedbackAvailable(event, nodeKind),
          completedTurn: event.completedTurn,
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
      turnPhase: turnPhase,
    );
  }

  /// v0.9.5 P1（预览/回放合一）：移除与 incoming 同 kind、同文本的 imported
  /// 预览节点。折叠的唯一依据是被移除节点自身的 `imported` messageId 前缀——
  /// 导入侧（daemon relay.go）为预览 assistant 写 `imported-<seq>`、为预览
  /// user 写 `imported-u-<seq>`；无前缀的真实历史永不参与折叠。
  void _collapseImportedPreview(
    List<ConversationNode> nodes,
    ConversationNodeKind kind,
    String? incomingText,
  ) {
    final text = incomingText?.trim();
    if (text == null || text.isEmpty) return;
    for (var i = nodes.length - 1; i >= 0; i--) {
      final node = nodes[i];
      final id = node.messageId;
      if (node.kind != kind || id == null || !id.startsWith('imported')) {
        continue;
      }
      if (node.text?.trim() == text) {
        nodes.removeAt(i);
      }
    }
  }

  /// R17：把 turn.completed 终态标记并入最后一条 assistant 气泡
  /// （isStreaming=false + completedTurn=true），保留原文与全部展示字段。
  ConversationNode _nodeWithCompletedTail(ConversationNode node) =>
      ConversationNode(
        key: node.key,
        kind: node.kind,
        sequence: node.sequence,
        label: node.label,
        text: node.text,
        errorCode: node.errorCode,
        httpStatus: node.httpStatus,
        isStreaming: false,
        toolStatus: node.toolStatus,
        safeReasoningSummary: node.safeReasoningSummary,
        messageId: node.messageId,
        createdAt: node.createdAt,
        copyText: node.copyText,
        canCopy: node.canCopy,
        showTimestamp: node.showTimestamp,
        canFork: node.canFork,
        forkUnavailable: node.forkUnavailable,
        pendingSteering: node.pendingSteering,
        references: node.references,
        filePath: node.filePath,
        toolDetails: node.toolDetails,
        producedFiles: node.producedFiles,
        feedbackAvailable: node.feedbackAvailable,
        completedTurn: true,
      );

  ConversationNodeKind _nodeKindFor(SessionTimelineEvent event) =>
      switch (event.kind) {
        SessionTimelineKind.userMessage => ConversationNodeKind.user,
        SessionTimelineKind.assistantMessage =>
          _looksLikeReasoning(event)
              ? ConversationNodeKind.reasoning
              : ConversationNodeKind.assistant,
        // v0.8.4（ADR-015 §5）：raw thought 是一等 reasoning 节点，文本直接
        // 展示（终端所有者本地授权内容），不再依赖 label 启发式。
        SessionTimelineKind.assistantThought => ConversationNodeKind.reasoning,
        // turn_phase 事件在主循环中提前跳过（只驱动状态行），此分支仅为穷尽性。
        SessionTimelineKind.turnPhase => ConversationNodeKind.notice,
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
        command: permission.command,
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
    // v0.8.4：thought 通道的 raw 文本直接展示（独立通道已保证不混入回答）。
    if (event.kind == SessionTimelineKind.assistantThought) {
      return event.text;
    }
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
      subcalls: event.toolSubcalls.map(_subcallFor).toList(growable: false),
    );
    return details.hasContent ? details : null;
  }

  ConversationToolSubcall _subcallFor(SessionToolSubcall call) =>
      ConversationToolSubcall(
        callId: call.callId,
        label: call.label,
        status: call.status,
        input: call.input,
        output: call.output,
        subcalls: call.subcalls.map(_subcallFor).toList(growable: false),
      );

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
    var copyText = event.copyText ?? _displayTextFor(event);
    if (!_canCopy(event, nodeKind)) return null;
    if (copyText == null || copyText.trim().isEmpty) return null;
    if (copyText.length > _maxCopyTextLength) {
      copyText =
          '${copyText.substring(0, _maxCopyTextLength)}…（内容过长，已截断）';
    }
    return copyText;
  }

  // v0.8.6 E（G11）：复制上限 64K 字符。tool 输出等可能极长，超限截断并
  // 标注，避免一次复制把整段日志拖进剪贴板。
  static const int _maxCopyTextLength = 64 * 1024;

  /// v0.8.6 E（G11，复制全覆盖）：门控从"按节点类型 + completedTurn"改为
  /// "有可复制文本即出按钮"——流式中/未终态回合的 assistant 已产出文本、
  /// tool 命令与输出、思考摘要、通知与错误都必须可复制（实机 A① 事故中
  /// 卡死回合的回复完全无法复制是核心痛点）。pendingSteering 乐观回显仍仅
  /// user 可复制（assistant 尚无内容可复制）。
  bool _canCopy(SessionTimelineEvent event, ConversationNodeKind nodeKind) {
    final text = event.copyText ?? _displayTextFor(event);
    if (text?.trim().isNotEmpty != true) return false;
    if (event.pendingSteering) return nodeKind == ConversationNodeKind.user;
    return switch (nodeKind) {
      ConversationNodeKind.user ||
      ConversationNodeKind.assistant ||
      ConversationNodeKind.reasoning ||
      ConversationNodeKind.tool ||
      ConversationNodeKind.notice ||
      ConversationNodeKind.error => true,
      // command/compaction/turnTail/retry/encrypted 是生命周期或投影内部
      // 节点，不提供复制。
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

  bool _feedbackAvailable(
    SessionTimelineEvent event,
    ConversationNodeKind nodeKind,
  ) =>
      nodeKind == ConversationNodeKind.assistant &&
      event.completedTurn &&
      event.messageId?.trim().isNotEmpty == true;

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

/// v0.8.7（V087-06）：assistant/reasoning 节点在携带上游 messageId 时用它作
/// 稳定 key 基座——流式期间同身份帧每批整体替换节点（sequence 随帧变化），
/// 稳定 key 让打字机释放动画的元素状态跨帧存活；其余节点维持 sequence 基
/// key（轨迹/检查器等消费方契约不变）。
String _stableNodeKey(SessionTimelineEvent event, ConversationNodeKind kind) {
  final messageId = event.messageId?.trim() ?? '';
  if (messageId.isNotEmpty &&
      (kind == ConversationNodeKind.assistant ||
          kind == ConversationNodeKind.reasoning)) {
    return messageId;
  }
  return '${event.sequence}';
}
