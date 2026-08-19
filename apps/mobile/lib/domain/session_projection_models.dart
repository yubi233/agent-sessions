import 'control_models.dart';

/// v0.5 会话 UI 的展示节点类型。
///
/// 这些节点只描述客户端可见投影，不是 Relay canonical event，也不会反向写回会话日志。
enum ConversationNodeKind {
  user,
  assistant,
  reasoning,
  tool,
  command,
  compaction,
  turnTail,
  retry,
  error,
  encrypted,
  notice,
}

/// 会话 Chat 视图的单个 display-safe 节点。
class ConversationNode {
  const ConversationNode({
    required this.key,
    required this.kind,
    required this.sequence,
    required this.label,
    this.text,
    this.isStreaming = false,
    this.toolStatus,
    this.safeReasoningSummary,
  });

  /// 稳定 key 由投影层生成，后续 UI keyed renderer 只能依赖该 key。
  final String key;
  final ConversationNodeKind kind;
  final int sequence;
  final String label;
  final String? text;
  final bool isStreaming;
  final String? toolStatus;

  /// 只允许展示上游明确给出的 display-safe summary；隐藏 CoT 永远不进入该字段。
  final String? safeReasoningSummary;
}

enum ComposerPendingKind { approval, question }

/// Composer takeover 的待处理交互。
class ComposerPendingWait {
  const ComposerPendingWait.approval({
    required this.requestId,
    required this.title,
    required this.summary,
  }) : kind = ComposerPendingKind.approval,
       prompt = null,
       options = const [],
       allowsFreeform = false;

  const ComposerPendingWait.question({
    required this.requestId,
    required this.prompt,
    required this.options,
    required this.allowsFreeform,
  }) : kind = ComposerPendingKind.question,
       title = '需要回答',
       summary = null;

  final ComposerPendingKind kind;
  final String requestId;
  final String title;
  final String? summary;
  final String? prompt;
  final List<String> options;
  final bool allowsFreeform;
}

/// Composer 下方 StatsLine 的投影。
class SessionStatsLineProjection {
  const SessionStatsLineProjection({
    this.inputTokens,
    this.outputTokens,
    this.cacheTokens,
    this.turnCount,
    this.stepCount,
  });

  factory SessionStatsLineProjection.fromUsage(SessionUsageSummary? usage) {
    if (usage == null) return const SessionStatsLineProjection();
    return SessionStatsLineProjection(
      inputTokens: usage.inputTokens,
      outputTokens: usage.outputTokens,
      cacheTokens: usage.cacheReadTokens + usage.cacheCreationTokens,
    );
  }

  final int? inputTokens;
  final int? outputTokens;
  final int? cacheTokens;
  final int? turnCount;
  final int? stepCount;

  bool get isUnavailable =>
      inputTokens == null &&
      outputTokens == null &&
      cacheTokens == null &&
      turnCount == null &&
      stepCount == null;
}

/// ContextMeter 是窗口压力近似值，不能和真实 usage 混为一谈。
class SessionContextMeterProjection {
  const SessionContextMeterProjection({this.usedTokens, this.windowTokens});

  factory SessionContextMeterProjection.fromUsage(SessionUsageSummary? usage) {
    if (usage == null || usage.contextWindowTokens <= 0) {
      return const SessionContextMeterProjection();
    }
    return SessionContextMeterProjection(
      usedTokens: usage.contextTokens,
      windowTokens: usage.contextWindowTokens,
    );
  }

  final int? usedTokens;
  final int? windowTokens;

  double? get ratio {
    final used = usedTokens;
    final window = windowTokens;
    if (used == null || window == null || window <= 0) return null;
    return used / window;
  }
}

/// Trajectory ledger 的只读记录。
class TrajectoryRecord {
  const TrajectoryRecord({
    required this.key,
    required this.sequence,
    required this.kind,
    required this.label,
    this.status,
    this.summary,
  });

  final String key;
  final int sequence;
  final ConversationNodeKind kind;
  final String label;
  final String? status;
  final String? summary;
}

/// 会话详情页共享的展示投影快照。
class SessionProjectionSnapshot {
  const SessionProjectionSnapshot({
    required this.chatNodes,
    required this.pendingWaits,
    required this.trajectoryRecords,
    required this.stats,
    required this.context,
  });

  final List<ConversationNode> chatNodes;
  final List<ComposerPendingWait> pendingWaits;
  final List<TrajectoryRecord> trajectoryRecords;
  final SessionStatsLineProjection stats;
  final SessionContextMeterProjection context;
}
