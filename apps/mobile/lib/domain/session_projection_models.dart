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

enum ConversationReferenceKind { command, session, file, folder }

/// 已发送消息中的只读引用展示。
///
/// 这些 chip 来自投影层已经确认的引用或保守文本扫描，只是 UI 装饰，
/// 不会重新 claim command、打开文件或改写 composer 状态。
class ConversationReferenceChip {
  const ConversationReferenceChip({
    required this.label,
    required this.kind,
    this.target,
  });

  final String label;
  final ConversationReferenceKind kind;
  final String? target;
}

/// 工具详情的只读 display payload。
///
/// 这里保存的是已经裁剪/脱敏后的展示文本；真实工具参数、文件正文或隐藏输出
/// 不得从 Relay envelope 猜测生成。
class ConversationToolDetails {
  const ConversationToolDetails({this.input, this.output, this.inspectTarget});

  final String? input;
  final String? output;
  final String? inspectTarget;

  bool get hasContent =>
      input?.trim().isNotEmpty == true ||
      output?.trim().isNotEmpty == true ||
      inspectTarget?.trim().isNotEmpty == true;
}

/// assistant turn-tail 的产物文件 chip。
///
/// 路径必须来自工具 follow-along 或显式 projection，不能从 assistant prose 猜测。
class ConversationProducedFile {
  const ConversationProducedFile({required this.path, String? label})
    : label = label ?? path;

  final String path;
  final String label;
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
    this.messageId,
    this.createdAt,
    this.copyText,
    this.canCopy = false,
    this.showTimestamp = false,
    this.canFork = false,
    this.forkUnavailable = false,
    this.pendingSteering = false,
    this.references = const [],
    this.filePath,
    this.toolDetails,
    this.producedFiles = const [],
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

  /// 消息动作只认 display-only 身份；没有身份时仍可复制文本，但不能 fork。
  final String? messageId;

  /// 时间标签来自 fixture/上游投影；没有时间就不展示，不能用本地 now 补假时间。
  final DateTime? createdAt;

  /// 复制动作写入的纯文本。未提供时 UI 可使用 [text] 的展示副本。
  final String? copyText;

  final bool canCopy;
  final bool showTimestamp;
  final bool canFork;
  final bool forkUnavailable;

  /// Host 权威的 pre-admission steering 投影：只允许 copy，不显示时间或 fork。
  final bool pendingSteering;

  final List<ConversationReferenceChip> references;

  /// 工具行或 produced file chip 的可打开路径；由 Host opener 解析，不在 UI 猜绝对路径。
  final String? filePath;

  final ConversationToolDetails? toolDetails;
  final List<ConversationProducedFile> producedFiles;
}

enum ComposerPendingKind { approval, question }

/// Composer takeover 的待处理交互。
class ComposerPendingWait {
  const ComposerPendingWait.approval({
    required this.requestId,
    required this.title,
    required this.summary,
    this.command,
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
       summary = null,
       command = null;

  final ComposerPendingKind kind;
  final String requestId;
  final String title;
  final String? summary;
  final String? command;
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
    this.ttftMs,
    this.decodeThroughput,
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

  /// v0.5/P7-B：首 token 延迟（毫秒）与解码吞吐（token/s）。
  /// 真实 Relay/Provider 未提供时保持 null，UI 不显示假值。
  final int? ttftMs;
  final double? decodeThroughput;

  bool get isUnavailable =>
      inputTokens == null &&
      outputTokens == null &&
      cacheTokens == null &&
      turnCount == null &&
      stepCount == null &&
      ttftMs == null &&
      decodeThroughput == null;
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
    this.createdAt,
    this.duration,
    this.turnId,
    this.isStreaming = false,
    this.inspectTarget,
  });

  final String key;
  final int sequence;
  final ConversationNodeKind kind;
  final String label;
  final String? status;
  final String? summary;

  /// 仅来自上游/fixture 的时间字段；缺失时 timeline 回退到等宽布局，不伪造时长。
  final DateTime? createdAt;
  final Duration? duration;

  /// 用于 turn 分组的 display-only 标识；不写回 Relay。
  final String? turnId;

  /// streaming partial 也要进入 Trajectory 搜索/timeline 结构。
  final bool isStreaming;

  /// 从 Chat 一次性 inspect handoff 带来的目标；展示后由 view store 清空。
  final String? inspectTarget;
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
