import '../domain/session_models.dart';
import 'session_send_transaction.dart';

/// V094（计划 §2.1）：会话单一展示状态投影。
///
/// 设计约束（冻结）：
/// - 由 controller 已有事实**派生**的纯展示投影；header、状态槽、消息状态和
///   composer 同源消费，widget 不得各自再写一套恢复/可发送判断。
/// - 底层事实仍分维度保存（连接/角色/会话/操作），本投影只挑出**当前时刻
///   最该让用户知道的一件事**作为主状态，不把权限或网络错误写成 canonical
///   状态，不伪造底层事实。
/// - 展示优先级：硬阻断（只读/服务不可用/断网）→ 需要回答/审批 → 自动恢复/
///   重发 → 结果待确认/已知失败 → 执行中 → 可开始/待发送。


/// 主状态的视觉语义档位；只决定色调，不承载事实。
enum SessionPresentationTone { neutral, busy, success, attention, error }

/// 会话各维度的脱敏事实快照（投影输入）。
class SessionPresentationFacts {
  const SessionPresentationFacts({
    required this.status,
    required this.canWrite,
    required this.hasLease,
    required this.providerAvailable,
    required this.providerReason,
    this.transportLive = false,
    this.networkAvailable = true,
    this.turnInFlight = false,
    this.streaming = false,
    this.timedOut = false,
    this.recoveryStage,
    this.transactionPhase,
    this.transactionDetail,
    this.hasPendingQuestion = false,
    this.hasPendingPermission = false,
    this.errorMessage,
  });

  final MobileSessionStatus status;
  final bool canWrite;
  final bool hasLease;

  /// Provider 能力可用性（探测结果）；不代表实时连接。
  final bool providerAvailable;
  final String? providerReason;

  /// 会话事件通道（SSE）真实连接状态。
  final bool transportLive;

  /// 本机网络可用性（恢复控制器 offline 门控的事实来源）。
  final bool networkAvailable;

  final bool turnInFlight;
  final bool streaming;

  /// 客户端回合超时标记（V086-11）。
  final bool timedOut;

  /// 恢复链结构化阶段（V094-05）；非空时主状态让位给恢复。
  final SessionRecoveryStep? recoveryStage;

  /// 当前发送事务阶段（V094-06）；恢复/重发/待确认驱动主状态。
  final SessionSendPhase? transactionPhase;
  final String? transactionDetail;

  final bool hasPendingQuestion;
  final bool hasPendingPermission;

  /// 会话级硬错误（授权/环境失败等）；不与单条消息失败混同。
  final String? errorMessage;
}

/// 单一主状态 + 分维度事实标签的展示投影（纯函数输出，无行为）。
class SessionPresentationState {
  const SessionPresentationState({
    required this.primaryLabel,
    required this.tone,
    required this.roleLabel,
    required this.capabilityLabel,
    required this.connectionLabel,
    this.primaryDetail,
    this.actionHint,
  });

  /// 当前时刻唯一的主状态词。
  final String primaryLabel;
  final SessionPresentationTone tone;

  /// 角色层事实（V094-02）：设备可控制/只读；不承诺"可发送"。
  final String roleLabel;

  /// 能力层事实（V094-02）：执行服务可用/不可用；provider.available 不写成
  /// "已连接"。
  final String capabilityLabel;

  /// 连接层事实：事件通道真实连接状态，与能力可用性分开表达。
  final String connectionLabel;

  /// 主状态的补充说明（可展开的详情入口用）。
  final String? primaryDetail;

  /// 独立的行动提示（如 stopped 可写时的"发送时将恢复"）；
  /// 不与主状态拼成复合词，便于语义化单独渲染。
  final String? actionHint;

  /// 从事实投影出单一主状态（纯函数，可单测）。
  factory SessionPresentationState.fromFacts(SessionPresentationFacts f) {
    // ── 1. 硬阻断（保留在途状态附注）───────────────────────────────────
    if (!f.networkAvailable) {
      return _state('网络不可用', SessionPresentationTone.error,
          detail: f.txLabel() ?? '恢复联机后继续同步', f: f);
    }
    // ── 2. 需要回答/审批（takeover 高优先级，P2 也不收进设置）──────────
    if (f.hasPendingQuestion) {
      return _state('等待你的回答', SessionPresentationTone.attention, f: f);
    }
    if (f.hasPendingPermission) {
      return _state('等待权限确认', SessionPresentationTone.attention, f: f);
    }
    // ── 3. 自动恢复/重发（事务链的结构化阶段）──────────────────────────
    final recovery = f.recoveryStage;
    final txPhase = f.transactionPhase;
    if (recovery != null) {
      return _state(
        '正在恢复会话',
        SessionPresentationTone.busy,
        detail: recovery.label,
        f: f,
      );
    }
    if (txPhase == SessionSendPhase.recovering ||
        txPhase == SessionSendPhase.resending) {
      return _state(
        txPhase!.userLabel,
        SessionPresentationTone.busy,
        detail: f.transactionDetail,
        f: f,
      );
    }
    // ── 4. 结果待确认 / 已知失败（消息事务事实优先于会话状态）──────────
    if (txPhase == SessionSendPhase.verifying) {
      return _state(
        '结果待确认',
        SessionPresentationTone.attention,
        detail: '回执等待超时且暂无执行进展，请核验后再试',
        f: f,
      );
    }
    // ── 5. 执行中（真实活动回合/流式/处理中事务）───────────────────────
    if (f.timedOut) {
      return _state('等待结果超时', SessionPresentationTone.attention,
          detail: '执行端仍可能完成，可查看结果或重试', f: f);
    }
    if (f.streaming ||
        f.turnInFlight ||
        txPhase == SessionSendPhase.processing) {
      return _state('执行中', SessionPresentationTone.busy, f: f);
    }
    // ── 6. 会话级错误（授权/环境失败等硬事实）──────────────────────────
    if (f.errorMessage != null && f.errorMessage!.trim().isNotEmpty) {
      return _state('需要处理', SessionPresentationTone.error,
          detail: f.errorMessage, f: f);
    }
    // ── 7. 会话 canonical 状态（stopped 不一定不可发送：可自动恢复时
    //      显示"发送时将恢复会话"，不错误禁用恢复入口）───────────────────
    final base = switch (f.status) {
      MobileSessionStatus.streaming => (
        '执行中',
        SessionPresentationTone.busy,
      ),
      MobileSessionStatus.waitingPermission => (
        '等待权限确认',
        SessionPresentationTone.attention,
      ),
      MobileSessionStatus.waitingQuestion => (
        '等待你的回答',
        SessionPresentationTone.attention,
      ),
      MobileSessionStatus.idle => ('可发送', SessionPresentationTone.success),
      // V094 §2.1：stopped ≠ 不可发送。主状态保持"已停止"（不与恢复提示
      // 拼接成复合词），"发送时将恢复"走 actionHint 独立展示。
      MobileSessionStatus.stopped => ('已停止', SessionPresentationTone.neutral),
      MobileSessionStatus.errored => (
        '会话出错',
        SessionPresentationTone.error,
      ),
      MobileSessionStatus.offline => (
        '离线',
        SessionPresentationTone.error,
      ),
      MobileSessionStatus.unknown => (
        '状态未知',
        SessionPresentationTone.neutral,
      ),
    };
    final state = _compose(base.$1, base.$2, detail: null, f: f);
    // stopped 且可写：提供"发送时将恢复"的行动提示（不错误禁用恢复入口）。
    if (f.status == MobileSessionStatus.stopped && f.canWrite) {
      return SessionPresentationState(
        primaryLabel: state.primaryLabel,
        tone: state.tone,
        roleLabel: state.roleLabel,
        capabilityLabel: state.capabilityLabel,
        connectionLabel: state.connectionLabel,
        primaryDetail: state.primaryDetail,
        actionHint: '发送时将恢复',
      );
    }
    return state;
  }

  /// 组装分维度事实标签：角色/能力/连接各自来自真实事实源（V094-02）。
  static SessionPresentationState _compose(
    String label,
    SessionPresentationTone tone, {
    required String? detail,
    required SessionPresentationFacts f,
  }) => SessionPresentationState(
    primaryLabel: label,
    tone: tone,
    roleLabel: f.canWrite ? '可控制' : '只读',
    capabilityLabel: f.providerAvailable
        ? '执行服务可用'
        : (f.providerReason?.trim().isNotEmpty == true
              ? '执行服务不可用 · ${f.providerReason!.trim()}'
              : '执行服务不可用'),
    connectionLabel: f.transportLive
        ? '已连接'
        : (f.networkAvailable ? '未连接' : '未连接 · 网络不可用'),
    primaryDetail: detail,
  );

  static SessionPresentationState _state(
    String label,
    SessionPresentationTone tone, {
    String? detail,
    required SessionPresentationFacts f,
  }) => _compose(label, tone, detail: detail, f: f);
}

extension on SessionPresentationFacts {
  String? txLabel() => transactionPhase == null
      ? null
      : '${transactionPhase!.userLabel}${transactionDetail == null ? '' : ' · $transactionDetail'}';
}
