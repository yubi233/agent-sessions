import 'package:flutter/foundation.dart';

/// V094（计划 §2.2）：消息发送事务的阶段。
///
/// 展示语义冻结（§2.2 状态表）：
/// - submitting  正在提交：本地已创建事务，尚无服务受理回执；
/// - accepted    已受理，等待执行：Relay 202，不能据此称 Provider 已收到；
/// - recovering  恢复中：明确可恢复错误触发 resume/start 链，事务尚未终结；
/// - resending   正在重发（自动重试 1/1）：恢复成功后换幂等键重发同一逻辑消息；
/// - processing  已开始处理：关联执行事件或可信进展到达；
/// - verifying   结果待确认：回执超时/查询失败且没有权威执行结果；
/// - completed   已完成：明确成功终态；
/// - failed      执行失败：关联失败回执（含结构化错误分类）；
/// - cancelled   已取消：仅取消尚未提交的自动后续步骤；已提交命令不伪报取消。
enum SessionSendPhase {
  submitting,
  accepted,
  recovering,
  resending,
  processing,
  verifying,
  completed,
  failed,
  cancelled;

  /// 面向用户的状态词（V094-06：气泡出现 ≠ 已送达）。
  /// "已送达"不是必用词：只有链路能证明其含义时才允许使用。
  String get userLabel => switch (this) {
    submitting => '正在提交',
    accepted => '已受理，等待执行',
    recovering => '恢复中',
    resending => '正在重发',
    processing => '处理中',
    verifying => '结果待确认',
    completed => '已完成',
    failed => '发送失败',
    cancelled => '已取消',
  };
}

/// V094（计划 §2.3）：恢复链的结构化阶段。
/// 阶段从执行路径写入，不根据计时器伪造完成度或倒计时。
@immutable
class SessionRecoveryStep {
  const SessionRecoveryStep({
    required this.step,
    required this.attempt,
    required this.maxAttempts,
    this.detail,
    this.cancelable = false,
  });

  /// resume / start / resend / verify。
  final String step;
  final int attempt;

  /// 自动重试上限冻结为 1（保留 v0.9.3 契约）。
  final int maxAttempts;

  /// 面向用户的一句话说明；cause 无确证时用"正在恢复会话"，
  /// 不一律断言"检测到终端已重启"。
  final String? detail;

  /// 是否提供"取消自动恢复"入口：只取消尚未提交的后续自动步骤。
  final bool cancelable;

  String get label => '自动重试 $attempt/$maxAttempts';
}

/// V094（计划 §2.2）：一次显式发送的唯一逻辑事务。
///
/// 身份契约：
/// - [clientMessageId] 在同一次显式发送内稳定；同一自动恢复重发复用该 ID，
///   但按既有 `#recovered` 规则更换失败命令的幂等键；两次用户主动发送相同
///   文本必须获得不同 ID。
/// - [submissionId] 是本地账本主键，与 Relay 命令 ID、Provider messageId 均不同。
/// - 事务不复制正文到遥测或关联索引；fixture 链路并非生产保密证明。
///
/// 事务是有状态的账本对象（阶段/回执/重试计数随链路推进），因此不是
/// immutable 值对象；对外只暴露只读视图时由 controller 复制所需字段。
class SessionSendTransaction {
  SessionSendTransaction({
    required this.submissionId,
    required this.sessionId,
    required this.clientMessageId,
    required this.text,
    required this.draftRevision,
    required this.baseOperation,
    required this.createdAt,
    required this.deviceId,
    this.canWrite = true,
    this.phase = SessionSendPhase.submitting,
    this.currentCommandId,
    this.errorCode,
    this.errorDetail,
    this.resendCount = 0,
    this.maxResends = 1,
    this.cancelRequested = false,
    this.hasTrustedProgress = false,
    this.recoveryStep,
  });

  /// 本地账本主键（每会话单调递增）。
  final String submissionId;
  final String sessionId;

  /// 一次显式发送的稳定逻辑消息 ID；重发复用，不进 messageId/fork 通道。
  final String clientMessageId;

  /// 提交快照正文（接管后草稿可释放；失败内容保留在本事务）。
  final String text;

  /// 提交时的草稿 revision（结算用：旧响应不得清掉新草稿）。
  final int draftRevision;

  /// 提交上下文：观察器/恢复链跨会话切换执行时使用提交时的设备身份，
  /// 不依赖“当前选中会话”。
  final String deviceId;

  /// 提交时的可写判定；恢复链不得越权。
  final bool canWrite;

  /// 初次命令的幂等操作键；自动重发使用 `$baseOperation#recovered`。
  final String baseOperation;
  final DateTime createdAt;

  SessionSendPhase phase;

  /// 当前在途（或最后一条）Relay 命令 ID。
  String? currentCommandId;

  /// 结构化错误分类（如 LOCAL_STATE_MISSING）；恢复判定优先用它，
  /// 旧文本匹配仅作兼容回退（计划 §2.3）。
  String? errorCode;
  String? errorDetail;

  /// 已用自动重试次数；上限 [maxResends] 冻结为 1。
  int resendCount;
  final int maxResends;

  /// "取消自动恢复"标记：只阻止尚未提交的后续自动步骤。
  bool cancelRequested = false;

  /// 30s 回执窗口内已观察到可信执行进展（流式/回合事件）。
  bool hasTrustedProgress = false;

  /// 恢复链当前步骤（recovering/resending 期间非空）。
  SessionRecoveryStep? recoveryStep;

  bool get isTerminal =>
      phase == SessionSendPhase.completed ||
      phase == SessionSendPhase.failed ||
      phase == SessionSendPhase.cancelled;

  /// 事务是否允许提交下一条显式消息：同一事务禁止重复提交，
  /// 但不阻塞用户写新草稿（是否可发按真实运行态决定）。
  bool get blocksNewSubmission =>
      phase == SessionSendPhase.submitting ||
      phase == SessionSendPhase.recovering ||
      phase == SessionSendPhase.resending;
}

/// V094-24（计划 §2.5）：配置控制域的确认状态。
/// requested/effective 分离：202 只表示"切换中"；查询 null/超时不假报成功；
/// 命令成功且权威投影一致才标已生效；失败保留原值并说明原因。
enum ControlConfirmState {
  /// 无在途确认，effective 即当前值。
  idle,

  /// 已受理，等待执行端确认（切换中）。
  confirming,

  /// 命令成功且权威投影一致：已生效。
  applied,

  /// 命令成功但权威投影尚未一致，继续确认（投影滞后）。
  verifying,

  /// 回执超时/查询失败且无权威结果：结果待确认（保留原值 + 候选值）。
  unknown,

  /// 明确失败：保留原 effective 并说明原因。
  failed,
}

/// 单个控制域（model / effort / permission）的确认记录。
@immutable
class ControlDomainConfirmation {
  const ControlDomainConfirmation({
    required this.domain,
    required this.state,
    this.requested,
    this.detail,
  });

  /// model / effort / permission。
  final String domain;
  final ControlConfirmState state;

  /// 本次显式操作请求的目标值（候选生效值）。
  final String? requested;

  /// 面向用户的补充说明（失败原因/待确认提示）。
  final String? detail;
}
