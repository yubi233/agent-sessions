import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../attachments/attachment_picker.dart';
import '../diagnostics/streaming_telemetry.dart';
import '../domain/control_models.dart';
import '../domain/models.dart';
import '../domain/model_effort_preferences.dart';
import '../domain/session_models.dart';
import '../relay/relay_repository.dart';
import '../relay/session_event_transport.dart';
import '../relay/session_sse.dart';
import 'session_send_transaction.dart';
import 'session_presentation_state.dart';
import '../storage/model_effort_preference_store.dart';
import 'session_composer_controller.dart';
import 'session_turn_runtime.dart';

/// v0.9.0 C7：App 传输构建开关（默认 auto）。
/// `SESSION_EVENT_TRANSPORT=poll_only` 构建时永不建立 session SSE，
/// L1/L3/手动刷新完整工作——回滚只切换传输，不回滚任何事件 schema。
const String kSessionEventTransportMode = String.fromEnvironment(
  'SESSION_EVENT_TRANSPORT',
  defaultValue: 'auto',
);

enum SessionListPhase { loading, ready, error }

enum WorkspaceListPhase { loading, ready, error }

/// 会话状态与认证状态分离：认证控制器只负责设备身份，本文控制器只负责用户可见的会话旅程。
class SessionController extends ChangeNotifier {
  /// 保持公开依赖参数为 relay，避免私有字段名成为外部调用契约。
  factory SessionController({
    required RelayRepository relay,
    DateTime Function()? clock,
    Random? random,
    AttachmentPicker? picker,
    ModelEffortPreferenceStore? modelEffortMemory,
    StreamingTelemetry? streamingTelemetry,
    DioSessionEventStreamSource? Function()? sessionEventSourceFactory,
    Future<bool> Function()? sessionAuthRefresh,
  }) => SessionController._(
    relay,
    clock: clock,
    random: random,
    picker: picker,
    modelEffortMemory: modelEffortMemory,
    streamingTelemetry:
        streamingTelemetry ?? StreamingTelemetry(now: clock),
    sessionEventSourceFactory: sessionEventSourceFactory,
    sessionAuthRefresh: sessionAuthRefresh,
  );

  SessionController._(
    this._relay, {
    DateTime Function()? clock,
    Random? random,
    this._picker,
    this._modelEffortMemory,
    StreamingTelemetry? streamingTelemetry,
    // 私有字段无法作为命名参数（this._x 不可用于命名参数），显式初始化是唯一形式。
    DioSessionEventStreamSource? Function()? sessionEventSourceFactory,
    Future<bool> Function()? sessionAuthRefresh,
  }) : _sessionEventSourceFactory = sessionEventSourceFactory, // ignore: prefer_initializing_formals
       _sessionAuthRefresh = sessionAuthRefresh, // ignore: prefer_initializing_formals
       _clock = clock ?? DateTime.now,
       _random = random ?? Random.secure(),
       streamingTelemetry = streamingTelemetry ?? StreamingTelemetry() {
    // v0.9.0 C1：默认单调时钟用进程内 Stopwatch（不受系统时间回拨影响）；
    // 测试可注入步进函数（monotonicElapsed）锁定 2/60 分钟边界。
    _monotonicWatch.start();
    monotonicElapsed = () => _monotonicWatch.elapsed;
  }
  final RelayRepository _relay;

  /// v0.9.0 C6：session SSE 传输（仅当前选中+surface 可见+auto 模式时存在）。
  final DioSessionEventStreamSource? Function()? _sessionEventSourceFactory;
  final Future<bool> Function()? _sessionAuthRefresh;
  SessionEventTransport? _sessionEventTransport;
  final DateTime Function() _clock;
  final Random _random;
  final AttachmentPicker? _picker;

  /// v0.9.0 C1：运行期单调时钟锚点的基准表（进程内，不跨进程持久化）。
  final Stopwatch _monotonicWatch = Stopwatch();

  /// v0.9.0 C1：单调时钟读取函数。测试注入可控步进函数；
  /// 超时锚点与等待时长的唯一来源，禁止用 attempts×interval 或服务端时间推导。
  @visibleForTesting
  late Duration Function() monotonicElapsed;

  /// v0.8.7 门禁 2：流式埋点 sink（打字机流式的唯一证据源）。只记录元数据
  /// （seq/kind/message_id/长度/时间差），正文永不入 sink（审计红线 V087-03）。
  /// 默认随控制器创建；测试注入步进时钟的实例以断言时间单调性。
  final StreamingTelemetry streamingTelemetry;

  /// 「模型 → 上次选中推理等级」本地记忆（v0.8.6）。store 为 null 时仍在本进程
  /// 内存内生效（同一 App 生命周期内避免重复选择），只是不持久化。
  final ModelEffortPreferenceStore? _modelEffortMemory;
  Map<String, String> _effortsByModel = {};

  SessionListPhase _phase = SessionListPhase.loading;
  List<MobileSession> _sessions = const [];
  WorkspaceListPhase _workspacePhase = WorkspaceListPhase.loading;
  List<MobileWorkspace> _workspaces = const [];
  String? _workspaceErrorMessage;
  String? _pendingWorkspaceId;
  String? _pendingWorkspaceCommandId;
  bool _workspaceSettling = false;
  WorkspaceSyncState? _workspaceSyncState;
  bool _workspaceSyncWaiting = false;
  WorkspaceImportState? _workspaceImportState;
  bool _workspaceImportWaiting = false;
  String? _workspaceImportWorkspaceId;
  String? _selectedSessionId;
  List<SessionTimelineEvent> _timeline = const [];
  final Map<String, List<SessionTimelineEvent>> _timelineWindows = {};
  bool _historyLoading = false;
  String? _historyErrorMessage;
  SessionLease? _selectedLease;
  CapabilityMatrix _capabilities = CapabilityMatrix.empty;
  // 能力快照的最近一次成功拉取时间。启动瞬间 daemon 的 Provider
  // 探测可能尚未完成，若只在 initialize 拉一次，陈旧的"未连接"会话状态行会
  // 缓存整个 App 生命周期；打开会话时按节流窗口刷新（见 refreshCapabilities）。
  DateTime? _capabilitiesFetchedAt;
  SessionControlState _controls = const SessionControlState.empty();

  /// 已提交但 canonical user.message 事件尚未回传的出站文本，按会话隔离。
  /// 非空时该会话的 Chat 时间线尾部渲染乐观回显气泡；规范化事件合并后立即清账，
  /// 会话切换互不泄漏。
  final Map<String, String> _pendingOutgoingBySession = <String, String>{};

  // ── V094（计划 §2.2/§2.4）：消息发送事务账本 ────────────────────────────
  /// 每会话最新发送事务（一次显式发送一个逻辑事务）。
  /// 失败/待确认事务保留在槽内作为"消息待处理项"（失败内容不回填草稿、
  /// 不删除记录），新一次显式发送或"编辑后重试"会将其取代。
  final Map<String, SessionSendTransaction> _sendTxBySession =
      <String, SessionSendTransaction>{};
  int _sendTxCounter = 0;

  /// 草稿 revision 计数：输入内容变化即推进（V094 §2.4 结算身份之一）。
  final Map<String, int> _draftRevisionsBySession = <String, int>{};

  /// 当前会话的活动发送事务；无事务时为 null。
  SessionSendTransaction? get activeSendTransaction => _selectedSessionId == null
      ? null
      : _sendTxBySession[_selectedSessionId!];

  /// 当前会话最近一个失败/待确认的事务（手动重试与"编辑后重试"入口的事实来源）。
  SessionSendTransaction? get lastInterruptedSendTransaction {
    final tx = activeSendTransaction;
    if (tx == null) return null;
    if (tx.phase == SessionSendPhase.failed ||
        tx.phase == SessionSendPhase.verifying) {
      return tx;
    }
    return null;
  }

  /// "编辑后重试"：把失败事务正文转回草稿。仅当当前草稿为空时允许
  /// （禁止覆盖新草稿，§2.4）；成功后失败事务记录让位。
  /// 返回 null 表示不允许（当前草稿非空）；返回正文表示已接管。
  String? consumeFailedSendForEdit() {
    final sessionId = _selectedSessionId;
    final tx = lastInterruptedSendTransaction;
    if (sessionId == null || tx == null) return null;
    final current = _composerDrafts[sessionId];
    if (current != null && current.trim().isNotEmpty) {
      return null;
    }
    _sendTxBySession.remove(sessionId);
    if (_pendingOutgoingBySession[sessionId] == tx.text) {
      _pendingOutgoingBySession.remove(sessionId);
    }
    _notifyListeners();
    return tx.text;
  }
  // v0.8.6 A①：会话级"回合超时"标记。客户端轮询窗口（前台+后台约 2 分钟）
  // 耗尽仍无终态时置位，UI 据此把"处理中"收敛为显式超时文案；迟到的
  // daemon 看门狗 / Provider 终态事件到达后按事件校正清除。
  final Set<String> _turnTimedOut = <String>{};

  /// 回合轮询窗口（v0.8.6 A① 参数化以便测试）：前台 120×500ms=60s，后台再
  /// 120×500ms=60s，总约 2 分钟后显式超时。生产保持既有口径不变。
  @visibleForTesting
  int foregroundPollAttempts = 120;
  @visibleForTesting
  int backgroundPollAttempts = 120;
  @visibleForTesting
  Duration pollInterval = const Duration(milliseconds: 500);

  /// v0.8.7（§3.3 裁决）：发送受理后的前台在途轮询收紧档（默认 250ms）。
  /// 仅作用于 send 在途前台窗口——这是打字机渲染的数据到达粒度；后台续轮
  /// 与一般刷新维持 [pollInterval]=500ms，单会话在途 QPS 增量有界（P0 裁决）。
  @visibleForTesting
  Duration activePollInterval = const Duration(milliseconds: 250);

  /// v0.9.3 P2 / V093-04（T4 裁决）：命令收据轮询窗口参数化。
  ///
  /// 为什么 send 需要比其它命令更长的窗口：R18 云端实测（F4）显示，daemon
  /// 重启后的首条 send 在「提交 → 执行 → 回执」链路上可能远超 6 秒——命令先在
  /// Relay 排队等 daemon 重连（SSE 重连 + hello + 启动清扫），失败回执到达时
  /// 客户端早已放弃轮询并按"受理即确认"放行，LOCAL_STATE_MISSING 自动恢复
  /// （R14/R17 路径）因此从未触发，用户被迫手动重发。
  ///
  /// - [sendReceiptPollAttempts]：send 终态回执专用窗口，默认 120×250ms=30s，
  ///   覆盖一次 daemon 重启的投递+执行时延；超时仍按"受理即确认"回退。
  /// - [receiptPollAttempts]：abort / onAccepted 等需要快速反馈的路径，
  ///   维持 24×250ms=6s 不变。
  @visibleForTesting
  int sendReceiptPollAttempts = 120;
  @visibleForTesting
  int receiptPollAttempts = 24;

  /// v0.9.3 P2（T4 裁决）：会话自动恢复过程的可见状态。检测到执行侧实例丢失
  /// （LOCAL_STATE_MISSING）并触发自动恢复期间非空，UI 在 Chat 视图展示提示行，
  /// 避免"点了发送却毫无反馈"的静默窗口；恢复结束（成功或失败）即清除，
  /// 绝不自动重试第二轮（重试上限 1 次，见 _ensureSessionRunnableForSend）。
  String? _recoveryNotice;

  /// 当前自动恢复提示；非空时 Chat 视图渲染恢复提示行。
  String? get recoveryNotice => _recoveryNotice;

  // ── V094（计划 §2.3）：结构化恢复阶段 ──────────────────────────────────
  /// 恢复链当前步骤（resume → 必要时 start → send#recovered → 结果核验）。
  /// 从执行路径写入，不在 resume 返回时提前清除；无确证 cause 时用
  /// "正在恢复会话"，不断言"检测到终端已重启"。
  SessionRecoveryStep? _recoveryStage;

  /// 当前会话的结构化恢复阶段；null 表示无恢复活动。
  SessionRecoveryStep? get recoveryStage => _selectedSessionId == null
      ? _recoveryStage
      : (_sendTxBySession[_selectedSessionId!]?.recoveryStep ?? _recoveryStage);

  // ── V094-24/25：配置确认状态与操作幂等身份 ──────────────────────────
  /// 每控制域（model/effort/permission）当前确认记录。
  final Map<String, ControlDomainConfirmation> _configConfirmations =
      <String, ControlDomainConfirmation>{};

  /// 每控制域的串行锁：确认期间后续显式选择排队串行（§2.5）。
  final Map<String, Future<void>> _configDomainLocks =
      <String, Future<void>>{};

  int _configActionCounter = 0;

  /// 读取控制域确认状态（UI 摘要行显示"切换中/待确认/失败"的事实来源）。
  ControlDomainConfirmation? configConfirmationFor(String domain) =>
      _configConfirmations[domain];

  /// 在指定控制域串行执行 [action]：前序确认未结束时等待其完成。
  Future<T> _serializedConfigAction<T>(
    String domain,
    Future<T> Function() action,
  ) {
    final previous = _configDomainLocks[domain];
    Future<T> run() async {
      if (previous != null) {
        try {
          await previous;
        } catch (_) {
          // 前序失败不阻塞本次显式选择（失败已有独立错误面）。
        }
      }
      return action();
    }
    final future = run();
    _configDomainLocks[domain] = future.then(
      (_) {},
      onError: (_) {},
    );
    return future;
  }

  /// 记录确认状态并通知。
  void _setConfigConfirmation(ControlDomainConfirmation confirmation) {
    _configConfirmations[confirmation.domain] = confirmation;
    _notifyListeners();
  }

  /// 命令成功后的权威投影核验：controls 值与请求值一致才标"已生效"；
  /// 投影滞后时有界重查（3 拍），仍不一致进入"结果待确认"。
  Future<void> _verifyConfigConfirmation(
    String domain,
    String requested,
    String Function(SessionControlState controls) effectiveValueOf,
  ) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final controls = await _relay.getSessionControls(_selectedSessionId!);
        if (effectiveValueOf(controls) == requested) {
          // 权威投影一致：刷新本地 controls 并标"已生效"。
          if (_selectedSessionId != null) {
            _controls = controls;
          }
          _setConfigConfirmation(
            ControlDomainConfirmation(
              domain: domain,
              state: ControlConfirmState.applied,
              requested: requested,
            ),
          );
          return;
        }
      } catch (_) {
        // 投影拉取失败按滞后处理，走重查。
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    _setConfigConfirmation(
      ControlDomainConfirmation(
        domain: domain,
        state: ControlConfirmState.unknown,
        requested: requested,
        detail: '执行端已确认，但权威投影尚未一致，请稍后核验',
      ),
    );
  }

  /// V094：展示投影使用的网络事实。由应用层（恢复绑定/连接性事件）回报；
  /// 默认 true 表示"无离线事实"，不伪造离线状态。
  bool presentationNetworkAvailable = true;

  /// V094-01/02：会话单一展示状态投影的唯一派生入口。
  /// header 状态条、状态槽与 composer 门控都消费同一份投影，
  /// widget 不得各自再写恢复/可发送判断（§2.1 冻结）。
  SessionPresentationState buildPresentationState({
    required bool canWrite,
    required bool hasLease,
  }) {
    final sessionId = _selectedSessionId;
    final tx = sessionId == null ? null : _sendTxBySession[sessionId];
    return SessionPresentationState.fromFacts(
      SessionPresentationFacts(
        status: selectedSession?.status ?? MobileSessionStatus.unknown,
        canWrite: canWrite,
        hasLease: hasLease,
        providerAvailable: selectedProviderCapabilities.available,
        providerReason: selectedProviderCapabilities.capabilities
            .where((entry) => entry.name == 'start')
            .map((entry) => entry.reason)
            .whereType<String>()
            .firstOrNull,
        transportLive:
            sessionId != null &&
            _sessionEventTransport != null &&
            _sessionEventTransport!.sessionId == sessionId &&
            _sessionEventTransport!.state == SessionEventTransportState.live,
        networkAvailable: presentationNetworkAvailable,
        turnInFlight: isTurnInFlight,
        streaming: isStreaming,
        timedOut: isTurnTimedOut(sessionId),
        recoveryStage: recoveryStage,
        transactionPhase: tx?.phase,
        transactionDetail: tx?.errorDetail,
        errorMessage: errorMessage,
      ),
    );
  }

  /// V094-05：取消尚未提交的自动后续步骤。
  /// 已提交的命令不能被虚假标为已取消——它们按既有 abort 能力处理；
  /// 本入口只设置事务取消 token，阻止 resume/start/resend 等未提交步骤。
  bool cancelAutoRecovery() {
    final sessionId = _selectedSessionId;
    if (sessionId == null) return false;
    final tx = _sendTxBySession[sessionId];
    if (tx == null || tx.isTerminal) return false;
    tx.cancelRequested = true;
    _notifyListeners();
    return true;
  }

  /// 当前选中会话尚未被规范化事件确认的本机回显文本；null 表示无待确认出站消息。
  /// 该会话的回合是否已被客户端判定超时（V086-11）：UI 据此把"处理中"
  /// 状态条替换为显式超时文案，并停止无限转圈。
  bool isTurnTimedOut(String? sessionId) =>
      sessionId != null && _turnTimedOut.contains(sessionId);

  /// v0.8.6 B：权限目录为空时的禁用原因（capability 支持但目录未同步）。
  /// capability 不支持或只读等其它阻断由 controlBlockedReason 负责。
  ///
  /// v0.8.7 追加缺陷修复（V087-13 真实栈发现）：目录空有两种不同事实——
  /// ① 会话未启动（stopped/未运行）：目录确实等启动后获取，维持 v0.8.6 文案；
  /// ② 会话已启动甚至完成过回合而目录仍空：说明终端桥未上报模式目录（或上行
  /// 失败），"启动后自动获取"与事实矛盾（误导用户反复重启）。按状态区分文案，
  /// 事实性描述当前阻塞，不做任何能力伪造。
  String? get permissionDirectoryHint {
    final capability = selectedProviderCapabilities.capability('permission_mode');
    if (!capability.isSupported) return null;
    if (_controls.availablePermissionModes.isNotEmpty) return null;
    final status = selectedSession?.status;
    final started =
        status == MobileSessionStatus.idle || status == MobileSessionStatus.streaming;
    if (started) {
      return '权限目录未同步——该会话的终端桥未上报模式目录。';
    }
    return '权限目录未同步——启动会话后自动获取。';
  }

  String? get pendingOutgoingMessage => _selectedSessionId == null
      ? null
      : _pendingOutgoingBySession[_selectedSessionId!];
  SkillConfirmation? _skillConfirmation;
  List<AttachmentTransfer> _attachments = const [];
  List<AttachmentRejection> _attachmentRejections = const [];
  bool _isDetailLoading = false;
  bool _isCapabilitiesLoading = false;
  final Set<String> _pendingActionKeys = {};
  final Set<String> _resolvedRequestKeys = {};
  final Map<String, String> _idempotencyKeys = {};
  // cursor 只在内存保存为会话序号；生命周期恢复不接触消息正文、密文或待发送内容。
  final Map<String, int> _sessionCursors = {};
  // v0.9.0 C1：回合在途不再用可分布尔表达，改为从活动回合表派生
  // （见 isTurnInFlight）——"服务端仍有活动回合 / UX 已超时 / 同步任务在执行"
  // 三件事彻底拆开：超时不清除活动回合，活动回合只在 canonical 终态、
  // 用户 abort/kill 或认证边界清除。
  // v0.2/P2：composer 草稿只保存在内存（不落明文盘）；按会话隔离，切换页面/会话后仍可恢复。
  final Map<String, String> _composerDrafts = {};
  // v0.5：reference occurrences 与 transient queue 也按 session 隔离，不能随 widget 重建丢失。
  final Map<String, SessionComposerSessionState> _composerStates = {};
  // 附件句柄只在内存保存；切换会话时暂存，发送时才绑定目标 session。
  final Map<String, List<AttachmentTransfer>> _attachmentsBySession = {};
  // v0.2/P3：会话内容密钥（DEK）可用性；false 时附件选文件入口 fail-closed。
  bool _contentKeyAvailable = false;
  String? _errorMessage;
  int _idempotencyCounter = 0;
  int _selectionGeneration = 0;
  int _runtimeLeaseGeneration = 0;
  bool _initializing = false;

  // ─── v0.9.0 C2：三重代际与运行期取消契约 ───────────────────────────────
  /// 认证代际：登录态/设备绑定变化、认证失效、注销（resetForAuthBoundary）
  /// 与 dispose 时递增。旧代际的 Timer、轮询循环与 REST 回包全部按正常取消丢弃。
  int _authGeneration = 0;

  /// 会话同步代际（按会话）：send/steer/abort 实际提交前与 canonical 终态收口时
  /// 推进。它是取消旧异步任务的技术代际，不等同于 Provider turn id；steer 推进
  /// 该值但继承原业务回合起点、超时标记与 60 分钟期限。
  final Map<String, int> _syncGenerations = {};

  /// 会话页面 surface 可见性（前台且会话页面可见）。离开会话页面推进选择代际，
  /// 旧选择的 UI 状态写入（timeline/controls/续轮）随即失效。P3/P4 的 quiet
  /// reconcile 与 session SSE 以此决定是否运行。
  bool _sessionSurfaceVisible = true;

  /// dispose 后禁止新调度与通知：任何完成中的 Future 返回都不得再触碰
  /// 已释放的 ChangeNotifier（C7）。
  bool _disposed = false;

  /// v0.9.0 C1：会话级活动回合运行期状态（202 受理锚点 + 2/60 分钟预算）。
  final Map<String, SessionActiveTurn> _activeTurns = {};

  /// v0.9.0 C2：每会话快照刷新单航班——同会话同时最多一个 fetch+merge 在途，
  /// 其余请求只置 pending；当前请求结束后从已合并 cursor 再拉一轮。
  final Map<String, Future<void>> _snapshotTurnsInFlight = {};
  final Set<String> _snapshotTurnsPending = {};

  /// v0.9.0 C3：按会话记录最近一次成功合并事件的客户端时刻（内存，不持久化）。
  final Map<String, DateTime> _lastSnapshotMergedAt = {};

  // ─── v0.9.0 C4：L3 quiet reconcile 与非当前完成角标 ────────────────────
  /// quiet reconcile 启停（由 lifecycle recovery 驱动：前台+在线开启，
  /// 后台/离线关闭；关闭时零新请求）。
  bool _quietReconcileActive = false;
  Timer? _quietReconcileTimer;

  /// quiet reconcile 周期（T7：全局 25 秒一拍，0.04 list QPS）。
  @visibleForTesting
  Duration quietReconcileInterval = const Duration(seconds: 25);

  /// 每拍最多调度的差异会话快照数（C4：每拍最多 4 个）。
  @visibleForTesting
  int quietReconcileBatchSize = 4;

  /// 快照调度并发上限（C4：并发最多 2）。
  @visibleForTesting
  int quietReconcileConcurrency = 2;

  /// 「有新完成结果」角标：认证运行期内存集合，不持久化（C4）。
  final Set<String> _unseenCompletedSessionIds = {};

  /// 本机曾观察为活动回合的会话（角标置位前置条件）。
  final Set<String> _observedActiveSessionIds = {};

  /// 手动刷新与 quiet reconcile 共享的 listSessions single-flight。
  Future<List<MobileSession>>? _listSessionsInFlight;

  /// 指定会话最近一次成功合并事件的时刻；null 表示尚未合并过。
  DateTime? lastMergedAtFor(String? sessionId) =>
      sessionId == null ? null : _lastSnapshotMergedAt[sessionId];

  /// 只读暴露：认证代际（测试断言用）。
  @visibleForTesting
  int get authGeneration => _authGeneration;

  /// 只读暴露：指定会话的同步代际（测试断言用）。
  @visibleForTesting
  int syncGenerationFor(String sessionId) => _syncGenerations[sessionId] ?? 0;

  /// 只读暴露：会话页面 surface 可见性。
  bool get isSessionSurfaceVisible => _sessionSurfaceVisible;

  /// 当前会话的活动回合运行期状态（C1）；null 表示无已锚定的活动回合。
  SessionActiveTurn? activeTurnFor(String? sessionId) =>
      sessionId == null ? null : _activeTurns[sessionId];

  /// 该会话是否显示「有新完成结果」角标（C4：认证运行期内存集合）。
  bool hasUnseenCompletion(String? sessionId) =>
      sessionId != null && _unseenCompletedSessionIds.contains(sessionId);

  /// 角标集合只读快照（列表 UI 消费）。
  Set<String> get unseenCompletedSessionIds =>
      Set<String>.unmodifiable(_unseenCompletedSessionIds);

  /// 本地是否存在已确认活动回合的会话（L3 运行前置条件之一）。
  bool get _hasObservableActiveTurns =>
      _activeTurns.isNotEmpty ||
      _sessions.any(
        (session) =>
            session.status == MobileSessionStatus.streaming ||
            session.status == MobileSessionStatus.waitingPermission ||
            session.status == MobileSessionStatus.waitingQuestion,
      );

  /// v0.9.0 C2：离开/进入会话页面 surface 时由路由层调用。离开时推进选择代际，
  /// 旧选择的迟到写入不得落到当前页面。
  void setSessionSurfaceVisible(bool visible) {
    if (_sessionSurfaceVisible == visible) return;
    _sessionSurfaceVisible = visible;
    if (!visible) {
      _selectionGeneration += 1;
      // v0.9.0 C6：离开会话页面必须取消 stream/watchdog/退避。
      _stopSessionEventTransport();
    } else {
      final sessionId = _selectedSessionId;
      if (sessionId != null) _startSessionEventTransportIfNeeded(sessionId);
    }
    _notifyListeners();
  }

  // ─── v0.9.0 C6：session SSE 传输生命周期 ──────────────────────────────
  /// 是否应由当前传输抑制高频轮询（C6：live 时由 SSE wake 驱动增量快照，
  /// 不再同时运行 250/500ms 在途轮询；connecting/backoff/pollFallback 轮询托底）。
  bool _transportSuppressesPolling(String sessionId) =>
      kSessionEventTransportMode == 'auto' &&
      _sessionEventTransport != null &&
      _sessionEventTransport!.sessionId == sessionId &&
      _sessionEventTransport!.state == SessionEventTransportState.live;

  /// 按 C6 前置条件建立 session SSE：仅 auto 模式、surface 可见、运行期未暂停
  /// （前台+在线）、且存在专用 streaming source（真实 Relay）时。调用前必须已
  /// 成功合并一次该会话快照（_loadSelectedSession 保证），消除首次从 0 回放
  /// 全部历史的风险。
  void _startSessionEventTransportIfNeeded(String sessionId) {
    if (_disposed || kSessionEventTransportMode != 'auto') return;
    if (!_sessionSurfaceVisible || !_autoLeaseEnabled) return;
    final sourceFactory = _sessionEventSourceFactory;
    if (sourceFactory == null) return;
    _stopSessionEventTransport();
    final transport = SessionEventTransport(
      sessionId: sessionId,
      source: sourceFactory()!,
      pullSnapshot: ({required bool forceFull}) =>
          _pullSnapshotForTransport(sessionId, forceFull: forceFull),
      probeSnapshot: () => _probeSnapshotForTransport(sessionId),
      refreshAuth: () =>
          _sessionAuthRefresh?.call() ?? Future<bool>.value(false),
      onState: (_) => _notifyListeners(),
    )..start();
    _sessionEventTransport = transport;
  }

  void _stopSessionEventTransport() {
    _sessionEventTransport?.stop();
    _sessionEventTransport = null;
  }

  /// SSE wake 驱动的增量快照（C6）：经单航班门与 L1/L3/手动刷新合并；
  /// 成功合并才让 transport 提交 wake cursor。
  Future<bool> _pullSnapshotForTransport(String sessionId,
      {required bool forceFull}) async {
    final authGenerationAtStart = _authGeneration;
    var merged = false;
    await _runSnapshotTurn(sessionId, () async {
      try {
        final snapshot = await _relay.getSessionSnapshot(
          sessionId,
          afterSequence: forceFull ? 0 : _cursorFor(sessionId),
        );
        if (_disposed || _authGeneration != authGenerationAtStart) return;
        _mergeSnapshot(snapshot, appendTimeline: true);
        _evaluateTurnDeadlines(sessionId);
        merged = true;
        _notifyListeners();
      } catch (_) {
        merged = false;
      }
    });
    return merged;
  }

  /// 404 探测（C6）：snapshot 200 → 旧 Relay 无此路由（pollFallback）；
  /// 404/403 → 资源级失效；网络/429/5xx → 结论未知保持退避。
  Future<SessionSnapshotProbeResult> _probeSnapshotForTransport(
    String sessionId,
  ) async {
    try {
      await _relay.getSessionSnapshot(sessionId);
      return SessionSnapshotProbeResult.reachable;
    } on RelayFailure catch (failure) {
      switch (failure.kind) {
        case RelayFailureKind.validation:
          return SessionSnapshotProbeResult.missing;
        case RelayFailureKind.forbidden:
          return SessionSnapshotProbeResult.forbidden;
        default:
          return SessionSnapshotProbeResult.unknown;
      }
    } catch (_) {
      return SessionSnapshotProbeResult.unknown;
    }
  }

  int _bumpSyncGeneration(String sessionId) {
    final next = (_syncGenerations[sessionId] ?? 0) + 1;
    _syncGenerations[sessionId] = next;
    return next;
  }

  /// dispose 安全通知（C7）：dispose 后丢弃通知而不是让在途 Future 崩溃。
  void _notifyListeners() {
    if (_disposed) return;
    // ignore: invalid_use_of_protected_member
    notifyListeners();
  }
  // 最近一次成功获取 lease 所用的写授权参数；前台/网络恢复后用于无参重新获取，
  // 使“从后台回来直接可写”无需用户再次点按。
  String? _lastLeaseDeviceId;
  bool _lastLeaseCanWrite = false;
  bool _lastLeaseSet = false;
  // 自动获取 lease 的闸门：前台+在线时允许写命令静默补获取；
  // 后台或离线时由生命周期控制器关闭，避免把用户尚未看到的输入悄悄发出去。
  bool _autoLeaseEnabled = true;

  /// 生命周期控制器在前后台/网络切换时开关自动获取闸门。
  void setAutoLeaseEnabled(bool enabled) {
    if (_autoLeaseEnabled == enabled) return;
    _autoLeaseEnabled = enabled;
    // v0.9.0 C6：后台/离线（闸门关闭）必须取消 stream/watchdog/退避计时；
    // 前台+在线恢复后为当前选中会话重建传输。
    if (!enabled) {
      _stopSessionEventTransport();
    } else {
      final sessionId = _selectedSessionId;
      if (sessionId != null && _sessionSurfaceVisible) {
        _startSessionEventTransportIfNeeded(sessionId);
      }
    }
    _notifyListeners();
  }

  SessionListPhase get phase => _phase;
  List<MobileSession> get sessions =>
      List<MobileSession>.unmodifiable(_sessions.where((session) => session.isVisible));
  WorkspaceListPhase get workspacePhase => _workspacePhase;
  List<MobileWorkspace> get workspaces =>
      List<MobileWorkspace>.unmodifiable(_workspaces);
  String? get workspaceErrorMessage => _workspaceErrorMessage;
  String? get pendingWorkspaceId => _pendingWorkspaceId;
  String? get pendingWorkspaceCommandId => _pendingWorkspaceCommandId;
  bool get workspaceSettling => _workspaceSettling;
  WorkspaceSyncState? get workspaceSyncState => _workspaceSyncState;
  bool get workspaceSyncWaiting => _workspaceSyncWaiting;
  WorkspaceImportState? get workspaceImportState => _workspaceImportState;
  bool get workspaceImportWaiting => _workspaceImportWaiting;
  String? get workspaceImportWorkspaceId => _workspaceImportWorkspaceId;
  List<SessionTimelineEvent> get timeline =>
      List<SessionTimelineEvent>.unmodifiable(_timeline);

  /// 指定会话当前已拉取/合并的完整时间线窗口；用于“复制 Debug 信息”导出全部轨迹。
  List<SessionTimelineEvent> timelineWindowFor(String sessionId) =>
      List<SessionTimelineEvent>.unmodifiable(
        _timelineWindows[sessionId] ?? const [],
      );
  bool get historyLoading => _historyLoading;
  String? get historyErrorMessage => _historyErrorMessage;

  // v0.9.5 P2（历史向前翻页）：服务端首屏窗口截断标记。仅由「首屏/翻页」路径
  // 置位（快照 hasMore=true）与「翻页未满一页」（权威到头）清除；增量快照的
  // has_more=false 不清除，避免把还有更早历史的会话误判为已到底。
  final Set<String> _sessionsWithMoreHistory = <String>{};
  bool hasMoreServerHistory(String sessionId) =>
      _sessionsWithMoreHistory.contains(sessionId);
  bool get canLoadOlder {
    final sessionId = _selectedSessionId;
    if (sessionId == null) return false;
    return (_timelineWindows[sessionId]?.length ?? 0) > _timeline.length ||
        _sessionsWithMoreHistory.contains(sessionId);
  }

  String? get selectedSessionId => _selectedSessionId;
  MobileSession? get selectedSession => _sessionById(_selectedSessionId);
  SessionLease? get selectedLease => _selectedLease;
  CapabilityMatrix get capabilities => _capabilities;

  /// Delegation 等独立控制器消费同一份 Relay capability 快照，避免按 Provider 名称猜测可用性。
  CapabilityMatrix get capabilityMatrix => _capabilities;
  ProviderCapabilityProfile get selectedProviderCapabilities =>
      _capabilities.provider(selectedSession?.provider ?? 'unknown');
  SessionControlState get controls => _controls;
  SkillConfirmation? get skillConfirmation => _skillConfirmation;
  List<AttachmentTransfer> get attachments =>
      List<AttachmentTransfer>.unmodifiable(_attachments);
  List<AttachmentRejection> get attachmentRejections =>
      List<AttachmentRejection>.unmodifiable(_attachmentRejections);
  bool get isDetailLoading => _isDetailLoading;
  bool get isCapabilitiesLoading => _isCapabilitiesLoading;
  bool get isBusy => _pendingActionKeys.isNotEmpty;
  String? get errorMessage => _errorMessage;
  bool get hasSelectedLease =>
      _selectedLease != null && _selectedLease!.epoch > 0;
  bool get isStreaming =>
      selectedSession?.status == MobileSessionStatus.streaming;

  /// 回合在途：派生自当前选中会话的活动回合状态（v0.9.0 C1 状态拆分）。
  /// send 受理（202）即成立，直到 canonical 终态/abort/kill/认证边界才结束；
  /// UX 超时不清除它——超时后中断按钮仍可用（C1：空草稿仍允许用户中止），
  /// composer 的发送入口按既有 queue/steer 交互收敛。
  bool get isTurnInFlight =>
      _selectedSessionId != null && _activeTurns.containsKey(_selectedSessionId);
  bool get isEmpty => _phase == SessionListPhase.ready && _sessions.isEmpty;
  int get selectedCursor => _cursorFor(_selectedSessionId);

  /// 仅在首次消费 provider 时拉取列表，避免页面 rebuild 时重复请求 Relay。
  Future<void> initialize() async {
    if (_initializing || _phase == SessionListPhase.ready) return;
    _initializing = true;
    try {
      await Future.wait([
        refreshSessions(),
        refreshWorkspaces(),
        refreshCapabilities(),
        _loadModelEffortMemory(),
      ]);
    } finally {
      _initializing = false;
    }
  }

  /// 读取持久化的「模型 → 上次推理等级」记忆。失败按无记忆处理（方法自身吞错，
  /// 不能拖垮 initialize 的 Future.wait）。
  Future<void> _loadModelEffortMemory() async {
    final store = _modelEffortMemory;
    if (store == null) return;
    try {
      final preferences = await store.read();
      _effortsByModel = Map<String, String>.of(preferences.effortsByModel);
      _notifyListeners();
    } catch (_) {
      _effortsByModel = {};
    }
  }

  /// 该模型上次使用的推理等级（本地记忆快照）；无记忆返回 null。
  String? cachedEffortFor(String model) => _effortsByModel[model];

  /// 记忆快照（只读副本），供模型选择列表渲染"该模型将使用的等级"徽标。
  Map<String, String> get modelEffortsMemory =>
      Map<String, String>.unmodifiable(_effortsByModel);

  void _rememberModelEffort(String model, String effort) {
    if (model.isEmpty || _effortsByModel[model] == effort) return;
    _effortsByModel[model] = effort;
    unawaited(
      _modelEffortMemory?.write(
        ModelEffortPreferences(
          effortsByModel: Map<String, String>.of(_effortsByModel),
        ),
      ),
    );
  }

  /// capability 失败时采取 fail-closed：已有会话仍可读，但所有 P3 写入口保持禁用。
  ///
  /// 修复（空闲会话状态行误显示"未连接"）：启动瞬间的拉取可能早于 daemon
  /// 完成 Provider 探测，失败或空结果会被缓存到 App 生命周期结束。因此
  /// （1）带 15 秒节流窗口，允许在打开会话等时机安全重试；
  /// （2）拉取失败时保留最近一次成功快照（若存在），避免把好数据清成空矩阵。
  Future<void> refreshCapabilities({bool force = false}) async {
    if (!force) {
      final fetchedAt = _capabilitiesFetchedAt;
      if (fetchedAt != null &&
          _clock().difference(fetchedAt) < const Duration(seconds: 15)) {
        return;
      }
    }
    _isCapabilitiesLoading = true;
    _notifyListeners();
    try {
      _capabilities = await _relay.getCapabilities();
      _capabilitiesFetchedAt = _clock();
    } on RelayFailure catch (failure) {
      if (_capabilities.providers.isEmpty) {
        _capabilities = CapabilityMatrix.empty;
        _errorMessage = failure.message;
      }
    } catch (_) {
      if (_capabilities.providers.isEmpty) {
        _capabilities = CapabilityMatrix.empty;
        _errorMessage = '能力矩阵暂时不可用，控制入口已安全禁用。';
      }
    } finally {
      _isCapabilitiesLoading = false;
      _notifyListeners();
    }
  }

  Future<void> refreshSessions() async {
    _errorMessage = null;
    _phase = SessionListPhase.loading;
    _notifyListeners();
    try {
      final loaded = await _listSessionsShared();
      // 按最后活动时间稳定排序（服务端同样排序，这里兜底合并/刷新路径）。
      _sessions = [...loaded]..sort(MobileSession.compareByLastActivity);
      _phase = SessionListPhase.ready;
      if (_selectedSessionId != null &&
          _sessionById(_selectedSessionId) == null) {
        _clearSelection();
      }
      // v0.9.0 C4：会话被移出列表（含归档）时清除其完成角标。
      _unseenCompletedSessionIds.removeWhere(
        (id) => _sessionById(id) == null,
      );
    } on RelayFailure catch (failure) {
      _phase = SessionListPhase.error;
      _errorMessage = failure.message;
    } catch (_) {
      _phase = SessionListPhase.error;
      _errorMessage = '会话列表暂时不可用，请稍后重试。';
    }
    _notifyListeners();
  }

  /// v0.9.0 C4：listSessions 共享 single-flight——手动刷新与 quiet reconcile
  /// 并发时只发一次请求，双方消费同一结果。
  Future<List<MobileSession>> _listSessionsShared() {
    final existing = _listSessionsInFlight;
    if (existing != null) return existing;
    final task = _relay
        .listSessions()
        .then((items) => items.where((session) => session.isVisible).toList(growable: false))
        .whenComplete(() => _listSessionsInFlight = null);
    _listSessionsInFlight = task;
    return task;
  }

  Future<void> refreshWorkspaces() async {
    _workspaceErrorMessage = null;
    _workspacePhase = WorkspaceListPhase.loading;
    _notifyListeners();
    try {
      _workspaces = await _relay.listWorkspaces();
      _workspacePhase = WorkspaceListPhase.ready;
    } on RelayFailure catch (failure) {
      _workspacePhase = WorkspaceListPhase.error;
      _workspaceErrorMessage = failure.message;
    } catch (_) {
      _workspacePhase = WorkspaceListPhase.error;
      _workspaceErrorMessage = '工作区列表暂时不可用，请稍后重试。';
    }
    _notifyListeners();
  }

  /// 工作区操作错误只属于当前客户端提示，关闭后不影响已投递的 Daemon 命令。
  void clearWorkspaceError() {
    if (_workspaceErrorMessage == null) return;
    _workspaceErrorMessage = null;
    _notifyListeners();
  }

  /// 显式发起 DSH 同步并有限轮询；离开页面只停止等待，不撤销已提交命令。
  Future<WorkspaceSyncState?> syncDSHWorkspaces({
    String terminalId = '',
  }) async {
    if (_workspaceSyncWaiting) return _workspaceSyncState;
    _workspaceSyncWaiting = true;
    _workspaceSyncState = null;
    _workspaceErrorMessage = null;
    _notifyListeners();
    try {
      var state = await _relay.syncDSHWorkspaces(terminalId: terminalId);
      _workspaceSyncState = state;
      _notifyListeners();
      final commandId = state.commandId;
      for (
        var attempt = 0;
        state.isPending &&
            commandId != null &&
            attempt < 20 &&
            _workspaceSyncWaiting;
        attempt += 1
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        if (!_workspaceSyncWaiting) break;
        state = await _relay.getDSHWorkspaceSyncState(commandId);
        _workspaceSyncState = state;
        _notifyListeners();
      }
      if (state.isSucceeded && _workspaceSyncWaiting) {
        await refreshWorkspaces();
        await refreshSessions();
      } else if (state.isPending && _workspaceSyncWaiting) {
        _workspaceErrorMessage =
            '同步请求仍在等待终端响应。请确认本机 Daemon 在线且支持 DSH 工作区同步，再下拉刷新查看结果。';
      }
      return state;
    } on RelayFailure catch (failure) {
      _workspaceErrorMessage = failure.message;
      _workspaceSyncState = const WorkspaceSyncState(status: 'failed');
      return _workspaceSyncState;
    } catch (_) {
      _workspaceErrorMessage = 'DSH 工作区同步暂时不可用，请稍后重试。';
      _workspaceSyncState = const WorkspaceSyncState(status: 'failed');
      return _workspaceSyncState;
    } finally {
      _workspaceSyncWaiting = false;
      _notifyListeners();
    }
  }

  /// 停止本地状态等待；Relay/Daemon 命令继续按原幂等键收口。
  void stopWaitingForDSHWorkspaceSync() {
    if (!_workspaceSyncWaiting) return;
    _workspaceSyncWaiting = false;
    _notifyListeners();
  }

  /// 显式发现历史候选；只读候选列表与日常列表分开，只有选择后才调用 manage。
  Future<WorkspaceImportState?> importDSHSessions({
    required String workspaceId,
    required String? deviceId,
    required bool canWrite,
    String terminalId = '',
  }) async {
    if (!_ensureWriteAccess(canWrite: canWrite, deviceId: deviceId)) {
      return null;
    }
    return _runDSHImport(
      workspaceId: workspaceId,
      terminalId: terminalId,
      discover: true,
    );
  }

  Future<List<MobileSession>?> historyCandidatesForWorkspace(String workspaceId) async {
    try {
      final candidates = await _relay.listHistorySessions();
      return candidates.where((session) =>
        session.isHistoryCandidate &&
        session.workspaceId == workspaceId &&
        session.provider == 'dsh',
      ).toList(growable: false)..sort(MobileSession.compareByLastActivity);
    } on RelayFailure catch (failure) {
      _workspaceErrorMessage = failure.message;
    } catch (_) {
      _workspaceErrorMessage = '历史会话候选暂时不可用，请稍后重试。';
    }
    _notifyListeners();
    return null;
  }

  /// 仅显式选择的一条候选进入日常列表；不创建会话、不启动 Provider、不发 prompt。
  Future<MobileSession?> manageHistorySession({
    required MobileSession candidate,
    required String? deviceId,
    required bool canWrite,
  }) async {
    if (!_ensureWriteAccess(canWrite: canWrite, deviceId: deviceId)) return null;
    if (!candidate.isHistoryCandidate || candidate.provider != 'dsh' ||
        !_workspaces.any((workspace) => workspace.id == candidate.workspaceId && workspace.isDsh)) {
      _workspaceErrorMessage = '请选择当前 DSH 工作区的历史候选。';
      _notifyListeners();
      return null;
    }
    final managed = await _runAction<MobileSession?>(
      'manage-session:${candidate.id}',
      () async {
        final session = await _relay.manageSession(candidate.id);
        if (session.id != candidate.id || session.workspaceId != candidate.workspaceId ||
            session.provider != 'dsh' || !session.isVisible) {
          throw const RelayFailure(RelayFailureKind.protocol, '历史会话接续响应无效。');
        }
        _sessions = [session, ..._sessions.where((item) => item.id != session.id)]
          ..sort(MobileSession.compareByLastActivity);
        _phase = SessionListPhase.ready;
        return session;
      },
    );
    if (managed == null) {
      _workspaceErrorMessage = _errorMessage ?? '历史会话接续失败，请重试。';
      _notifyListeners();
    }
    return managed;
  }

  /// 进入详情只刷新已管理会话；空工作区不扫描，时间开关不影响此边界。
  Future<void> refreshDSHSessionsSilently({
    required String workspaceId,
    String terminalId = '',
  }) async {
    if (!sessions.any((session) => session.workspaceId == workspaceId && session.provider == 'dsh')) return;
    final last = _dshAutoRefreshAt[workspaceId];
    if (last != null && _clock().difference(last) < dshAutoRefreshThrottle) return;
    if (_workspaceImportWaiting) return;
    _dshAutoRefreshAt[workspaceId] = _clock();
    await _runDSHImport(
      workspaceId: workspaceId,
      terminalId: terminalId,
      silent: true,
      discover: false,
    );
  }

  static const dshAutoRefreshThrottle = Duration(seconds: 60);
  final Map<String, DateTime> _dshAutoRefreshAt = <String, DateTime>{};

  Future<WorkspaceImportState?> _runDSHImport({
    required String workspaceId,
    String terminalId = '',
    bool silent = false,
    // 只有用户显式浏览历史才 discover:true；自动刷新固定 false，不发现新历史。
    bool discover = false,
  }) async {
    if (_workspaceImportWaiting) return _workspaceImportState;
    final normalized = workspaceId.trim();
    final workspace = _workspaces
        .where((item) => item.id == normalized)
        .firstOrNull;
    if (workspace == null || !workspace.isDsh) {
      if (!silent) {
        _workspaceErrorMessage = '只能从已同步的 DSH 工作区导入历史会话。';
        _notifyListeners();
      }
      return null;
    }
    _workspaceImportWaiting = true;
    _workspaceImportWorkspaceId = normalized;
    _workspaceImportState = null;
    _workspaceErrorMessage = null;
    _notifyListeners();
    try {
      var state = await _relay.importDSHSessions(
        workspaceId: normalized,
        terminalId: terminalId,
        discover: discover,
      );
      _workspaceImportState = state;
      _notifyListeners();
      final commandId = state.commandId;
      for (
        var attempt = 0;
        state.isPending &&
            commandId != null &&
            attempt < 20 &&
            _workspaceImportWaiting;
        attempt += 1
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        if (!_workspaceImportWaiting) break;
        state = await _relay.getDSHImportState(commandId);
        _workspaceImportState = state;
        _notifyListeners();
      }
      if (state.isSucceeded && _workspaceImportWaiting) {
        await refreshSessions();
      }
      return state;
    } on RelayFailure catch (failure) {
      // 静默刷新不发布失败状态/错误文案（手动入口保留完整报错）。
      if (!silent) {
        _workspaceErrorMessage = failure.message;
        _workspaceImportState = const WorkspaceImportState(status: 'failed');
      }
      return _workspaceImportState;
    } catch (_) {
      if (!silent) {
        _workspaceErrorMessage = '历史 DSH 会话导入暂时不可用，请稍后重试。';
        _workspaceImportState = const WorkspaceImportState(status: 'failed');
      }
      return _workspaceImportState;
    } finally {
      _workspaceImportWaiting = false;
      _notifyListeners();
    }
  }

  /// 停止客户端等待而不取消已投递的 import 命令。
  void stopWaitingForDSHImport() {
    if (!_workspaceImportWaiting) return;
    _workspaceImportWaiting = false;
    _notifyListeners();
  }

  bool get selectedWorkspaceDeleted {
    final workspaceId = selectedSession?.workspaceId;
    if (workspaceId == null || _workspacePhase != WorkspaceListPhase.ready) {
      return false;
    }
    return !_workspaces.any((workspace) => workspace.id == workspaceId);
  }

  Future<MobileWorkspace?> createWorkspaceFromDirectory({
    required String canonicalRoot,
    required String? deviceId,
    required bool canWrite,
    String terminalId = '',
  }) async {
    if (!_ensureWriteAccess(canWrite: canWrite, deviceId: deviceId)) {
      return null;
    }
    final root = canonicalRoot.trim();
    if (root.isEmpty) {
      _workspaceErrorMessage = '没有选择工作区目录。';
      _notifyListeners();
      return null;
    }
    final projectId = _projectIdForRoot(root);
    final created = await _runAction<MobileWorkspace?>(
      'workspace-create:$projectId',
      () => _relay.createWorkspace(
        CreateMobileWorkspaceInput(
          projectId: projectId,
          canonicalRoot: root,
          terminalId: terminalId,
          deviceId: deviceId!,
        ),
      ),
    );
    if (created != null) {
      _workspaces = [
        created,
        ..._workspaces.where((workspace) => workspace.id != created.id),
      ];
      _workspacePhase = WorkspaceListPhase.ready;
      _workspaceErrorMessage = null;
      _notifyListeners();
    } else {
      _workspaceErrorMessage = _errorMessage ?? '工作区创建失败，请重新选择目录。';
      _notifyListeners();
    }
    return created;
  }

  /// 真实 Relay 工作区创建只接受名称，并等待 Terminal Daemon 的异步回执。
  /// 轮询期间保留 pending 状态；成功后把脱敏 Workspace 投影放入列表，绝不接触
  /// canonical root 或把移动端路径当成 Host 路径。
  Future<MobileWorkspace?> createWorkspaceWithName({
    required String name,
    required String? deviceId,
    required bool canWrite,
    String terminalId = '',
  }) async {
    if (!_ensureWriteAccess(canWrite: canWrite, deviceId: deviceId)) {
      return null;
    }
    final input = CreateMobileWorkspaceWithFolderInput(
      name: name,
      deviceId: deviceId!,
      terminalId: terminalId,
    );
    try {
      input.validate();
    } on RelayFailure catch (failure) {
      _workspaceErrorMessage = failure.message;
      _notifyListeners();
      return null;
    }
    final normalizedName = name.trim();
    // workspace.create 是异步 Terminal 命令；显式暴露 settling 状态让页面禁用
    // 重复点击，并让回归测试能区分 pending 与已完成投影。
    _workspaceSettling = true;
    _notifyListeners();
    try {
      final created = await _runAction<MobileWorkspace?>(
        'workspace-create-name:$normalizedName',
        () async {
          var state = await _relay.createWorkspaceWithFolder(input);
          if (state.isPending) {
            final commandID = state.commandId;
            if (commandID == null || commandID.trim().isEmpty) {
              throw const RelayFailure(
                RelayFailureKind.protocol,
                'Relay 未返回工作区创建命令标识。',
              );
            }
            _pendingWorkspaceCommandId = commandID;
            _pendingWorkspaceId = state.workspaceId;
            _notifyListeners();
            // Daemon 创建目录是异步的；有限次轮询避免网络异常时永久占住 UI。
            for (var attempt = 0; attempt < 40 && state.isPending; attempt++) {
              await Future<void>.delayed(const Duration(milliseconds: 250));
              state = await _relay.getWorkspaceCreateState(commandID);
              _notifyListeners();
            }
          }
          if (!state.isSucceeded) {
            throw RelayFailure(
              RelayFailureKind.unavailable,
              _workspaceCreateFailureMessage(state.errorCode),
            );
          }
          var workspace = state.workspace;
          if (workspace == null) {
            await refreshWorkspaces();
            workspace = _workspaces
                .where((item) => item.id == state.workspaceId)
                .firstOrNull;
          }
          if (workspace == null) {
            throw const RelayFailure(
              RelayFailureKind.protocol,
              'Relay 已完成工作区创建，但未返回工作区。',
            );
          }
          _workspaces = [
            workspace,
            ..._workspaces.where((item) => item.id != workspace!.id),
          ];
          _workspacePhase = WorkspaceListPhase.ready;
          _workspaceErrorMessage = null;
          return workspace;
        },
      );
      if (created == null && _errorMessage != null) {
        _workspaceErrorMessage = _errorMessage;
      }
      return created;
    } finally {
      _pendingWorkspaceCommandId = null;
      _pendingWorkspaceId = null;
      _workspaceSettling = false;
      _notifyListeners();
    }
  }

  String _workspaceCreateFailureMessage(String? errorCode) =>
      switch (errorCode) {
        'WORKSPACE_PATH_DENIED' => '工作区名称或授权路径不允许。',
        'WORKSPACE_MOVED' => '工作区授权根已移动，请重新连接 Terminal。',
        'TERMINAL_OFFLINE' => '没有在线且支持新建工作区的 Terminal。',
        'CAPABILITY_UNSUPPORTED' => '当前 Terminal 不支持新建工作区。',
        _ => '工作区创建失败，请稍后重试。',
      };

  /// Reuse an empty session for the workspace or create one. Session-scoped
  /// input and opaque attachment handles move only after the destination has
  /// opened; any failure leaves the source untouched.
  Future<MobileSession?> openWorkspace({
    required String workspaceId,
    required String provider,
    required String? deviceId,
    required bool canWrite,
    String? agentPresetId,
    bool autoStart = false,
  }) async {
    final normalized = workspaceId.trim();
    if (normalized.isEmpty) return null;
    final sourceSessionId = _selectedSessionId;
    final sourceState = sourceSessionId == null
        ? const SessionComposerSessionState.empty()
        : composerStateFor(sourceSessionId);
    final sourceAttachments = List<AttachmentTransfer>.of(_attachments);
    _pendingWorkspaceId = normalized;
    _workspaceSettling = true;
    _workspaceErrorMessage = null;
    _notifyListeners();
    try {
      MobileSession? target;
      for (final session in _sessions) {
        if (session.workspaceId == normalized &&
            session.status == MobileSessionStatus.idle &&
            session.lastSequence <= 1) {
          target = session;
          break;
        }
      }
      if (target != null) {
        await _loadSelectedSession(target.id);
        if (_selectedSessionId != target.id || _isDetailLoading) return null;
      } else {
        target = await createSession(
          workspaceId: normalized,
          provider: provider,
          deviceId: deviceId,
          canWrite: canWrite,
          agentPresetId: agentPresetId,
          autoStart: autoStart,
        );
      }
      if (target == null || _selectedSessionId != target.id) return null;
      if (sourceSessionId != null && sourceSessionId != target.id) {
        if (sourceAttachments.any((item) => item.draft.isImage) &&
            _controls.imageLimits == null) {
          _workspaceErrorMessage = '目标会话未声明图片接收能力，源草稿和图片已保留。';
          await _loadSelectedSession(sourceSessionId);
          return null;
        }
        if (sourceState.draft.isNotEmpty ||
            sourceState.references.isNotEmpty ||
            sourceState.queue.isNotEmpty) {
          saveComposerState(target.id, sourceState);
        }
        if (sourceAttachments.isNotEmpty) {
          _attachments = List.unmodifiable(sourceAttachments);
          _rememberSelectedAttachments();
        }
        _composerStates.remove(sourceSessionId);
        _composerDrafts.remove(sourceSessionId);
        _attachmentsBySession.remove(sourceSessionId);
        _notifyListeners();
      }
      return target;
    } finally {
      _pendingWorkspaceId = null;
      _workspaceSettling = false;
      _notifyListeners();
    }
  }

  /// 新会话尚未有可 fencing 的 session id，因此这里只校验 owner 身份；后续控制命令再要求 lease。
  Future<MobileSession?> createSession({
    required String workspaceId,
    required String provider,
    required String? deviceId,
    required bool canWrite,
    String? agentPresetId,
    bool autoStart = false,
  }) async {
    if (!_ensureWriteAccess(canWrite: canWrite, deviceId: deviceId)) {
      return null;
    }
    final normalizedWorkspaceId = workspaceId.trim();
    final normalizedProvider = provider.trim();
    if (normalizedWorkspaceId.isEmpty || normalizedProvider.isEmpty) {
      _workspaceErrorMessage = '工作区或 Provider 无效，无法创建会话。';
      _notifyListeners();
      return null;
    }
    if (normalizedProvider.toLowerCase() == 'dsh' &&
        !_workspaces.any(
          (workspace) =>
              workspace.id == normalizedWorkspaceId && workspace.isDsh,
        )) {
      // UI 只能在 DSH Workspace detail 调用此路径。客户端提前拒绝错误归属，
      // Relay 仍会以 origin/home Terminal/capability fence 作为最终授权判断。
      _workspaceErrorMessage = 'DSH 会话必须在已同步的 DSH 工作区内创建。';
      _notifyListeners();
      return null;
    }
    final actionKey = 'create:$normalizedWorkspaceId:$normalizedProvider';
    return _runAction<MobileSession?>(actionKey, () async {
      final created = await _relay.createSession(
        CreateMobileSessionInput(
          workspaceId: normalizedWorkspaceId,
          provider: normalizedProvider,
          deviceId: deviceId!,
          agentPresetId: agentPresetId,
        ),
      );
      _sessions = [
        created,
        ..._sessions.where((item) => item.id != created.id),
      ];
      _phase = SessionListPhase.ready;
      if (!_workspaces.any(
        (workspace) => workspace.id == created.workspaceId,
      )) {
        await refreshWorkspaces();
      }
      await _loadSelectedSession(created.id);
      if (autoStart) {
        await acquireSelectedLease(deviceId: deviceId, canWrite: canWrite);
        final started = await startSelectedSession(
          deviceId: deviceId,
          canWrite: canWrite,
        );
        if (!started) return null;
      }
      return created;
    });
  }

  String _projectIdForRoot(String root) {
    var hash = 0x811c9dc5;
    for (final unit in root.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return 'mobile-${hash.toRadixString(16).padLeft(8, '0')}';
  }

  Future<void> selectSession(String sessionId) =>
      _loadSelectedSession(sessionId);

  /// 归档当前会话：数据保留，仅从默认列表隐藏。
  Future<bool> archiveSelectedSession({
    required String? deviceId,
    required bool canWrite,
  }) async {
    final sessionId = _selectedSessionId;
    if (sessionId == null ||
        !_ensureWriteAccess(canWrite: canWrite, deviceId: deviceId)) {
      return false;
    }
    final archived = await _runAction<MobileSession?>(
      'archive-session:$sessionId',
      () => _relay.archiveSession(sessionId),
    );
    if (archived == null) return false;
    await refreshSessions();
    return _sessionById(sessionId) == null;
  }

  /// 取消归档当前会话；仅用于已归档会话列表的恢复入口。
  Future<bool> unarchiveSelectedSession({
    required String? deviceId,
    required bool canWrite,
  }) async {
    final sessionId = _selectedSessionId;
    if (sessionId == null ||
        !_ensureWriteAccess(canWrite: canWrite, deviceId: deviceId)) {
      return false;
    }
    final restored = await _runAction<MobileSession?>(
      'unarchive-session:$sessionId',
      () => _relay.unarchiveSession(sessionId),
    );
    if (restored == null) return false;
    await refreshSessions();
    return _sessionById(sessionId) != null;
  }

  Future<void> loadOlderHistory() async {
    final sessionId = _selectedSessionId;
    if (sessionId == null || _historyLoading) return;
    final window = _timelineWindows[sessionId] ?? const [];
    final hidden = window.length - _timeline.length;
    // 优先展开本地窗口（零网络）；本地已全部展示且服务端仍有更早历史时，
    // 以窗口最旧序号为 before_seq 向 Relay 续拉一页（v0.9.5 P2）。
    if (hidden <= 0) {
      if (!_sessionsWithMoreHistory.contains(sessionId)) return;
      _historyLoading = true;
      _historyErrorMessage = null;
      _notifyListeners();
      try {
        final oldest = window.isEmpty ? 0 : window.first.sequence;
        const pageSize = 25;
        final page = await _relay.getSessionSnapshot(
          sessionId,
          afterSequence: 0,
          beforeSequence: oldest,
          limit: pageSize,
        );
        if (_disposed) return;
        // 快照事件必须经 fromRelayEvent 转换为时间线事件（与 _mergeSnapshot 同规）。
        final older = page.events
            .map(SessionTimelineEvent.fromRelayEvent)
            .where(
              (event) => !window.any(
                (existing) => existing.sequence == event.sequence,
              ),
            )
            .toList(growable: false);
        if (older.isNotEmpty) {
          _timelineWindows[sessionId] = List.unmodifiable([
            ...older,
            ...window,
          ]..sort((left, right) => left.sequence.compareTo(right.sequence)));
          if (_selectedSessionId == sessionId) {
            _timeline = List.unmodifiable([...older, ..._timeline]);
          }
        }
        // 服务端权威：本页不足一页（或明确 has_more=false）即到头部。
        if (older.length < pageSize && !page.hasMore) {
          _sessionsWithMoreHistory.remove(sessionId);
        }
      } on RelayFailure {
        _historyErrorMessage = '更早的会话记录暂时不可用，请重试。';
      } catch (_) {
        _historyErrorMessage = '更早的会话记录暂时不可用，请重试。';
      } finally {
        _historyLoading = false;
        _notifyListeners();
      }
      return;
    }
    _historyLoading = true;
    _historyErrorMessage = null;
    _notifyListeners();
    try {
      final take = hidden > 25 ? 25 : hidden;
      final start = hidden - take;
      final older = window.sublist(start, hidden);
      _timeline = List.unmodifiable([...older, ..._timeline]);
    } catch (_) {
      _historyErrorMessage = '更早的会话记录暂时不可用，请重试。';
    } finally {
      _historyLoading = false;
      _notifyListeners();
    }
  }

  /// 获取 lease 是显式操作，UI 可以准确呈现“只读”与“等待控制权”而不伪造可发送状态。
  Future<void> acquireSelectedLease({
    required String? deviceId,
    required bool canWrite,
    bool reportFailure = true,
  }) async {
    final sessionId = _selectedSessionId;
    if (sessionId == null ||
        !_ensureWriteAccess(canWrite: canWrite, deviceId: deviceId)) {
      return;
    }
    final runtimeLeaseGeneration = _runtimeLeaseGeneration;
    await _runAction<void>(
      'lease:$sessionId',
      reportFailure: reportFailure,
      () async {
        final lease = await _relay.acquireSessionLease(sessionId);
        if (lease.sessionId != sessionId || lease.epoch <= 0) {
          throw const RelayFailure(
            RelayFailureKind.protocol,
            'Relay 返回了无效可操作状态。',
          );
        }
        // 后台/离线后才返回的旧 lease 不能重新解锁 composer；用户必须显式获取新的 fencing epoch。
        if (runtimeLeaseGeneration != _runtimeLeaseGeneration ||
            _selectedSessionId != sessionId) {
          return;
        }
        _selectedLease = lease;
        _lastLeaseDeviceId = deviceId;
        _lastLeaseCanWrite = canWrite;
        _lastLeaseSet = true;
      },
    );
  }

  /// 前台/网络恢复后的无参自动重取：沿用最近一次成功写授权的参数，
  /// 让恢复完成的会话立即可写，无需用户手动点按“重试”。
  /// 从未写过（_lastLeaseSet == false）或当前未选中会话时静默跳过。
  Future<bool> reacquireLeaseAfterRuntimePause() async {
    if (!_lastLeaseSet) return false;
    final sessionId = _selectedSessionId;
    if (sessionId == null) return false;
    if (!hasSelectedLease) {
      _selectedLease = null;
      await acquireSelectedLease(
        deviceId: _lastLeaseDeviceId,
        canWrite: _lastLeaseCanWrite,
        reportFailure: false,
      );
    }
    return hasSelectedLease;
  }

  /// 写操作统一前置：已持有当前会话有效 lease 时直接通过；否则自动静默获取一次。
  /// 返回是否可写。失败（Relay 不可达、被其它设备抢占等）返回 false 且不弹错误，
  /// 由调用方决定是否提示；真正的写提交仍带 lease_epoch，Relay fencing 兜底。
  /// 后台/离线时闸门关闭，不自动获取（返回 false），由调用方呈现原阻断原因。
  Future<bool> ensureSelectedLeaseAuto({
    required String? deviceId,
    required bool canWrite,
    bool silent = true,
  }) async {
    final sessionId = _selectedSessionId;
    if (sessionId == null) return false;
    final lease = _selectedLease;
    if (lease != null &&
        lease.sessionId == sessionId &&
        lease.epoch > 0) {
      return true;
    }
    if (!_autoLeaseEnabled) return false;
    if (!_ensureWriteAccess(canWrite: canWrite, deviceId: deviceId)) {
      return false;
    }
    await acquireSelectedLease(
      deviceId: deviceId,
      canWrite: canWrite,
      reportFailure: !silent,
    );
    return hasSelectedLease;
  }

  Future<bool> startSelectedSession({
    required String? deviceId,
    required bool canWrite,
  }) async {
    final sessionId = _selectedSessionId;
    final blocked = controlBlockedReason('start', canWrite: canWrite);
    if (sessionId == null || blocked != null) {
      if (blocked != null) _setError(blocked);
      return false;
    }
    final accepted = await _submitCommand(
      sessionId: sessionId,
      operation: 'start:$sessionId:${selectedSession?.lastSequence ?? 0}',
      kind: SessionCommandKind.start,
      deviceId: deviceId!,
      ciphertext: {
        'fixture_payload': {
          'session_id': sessionId,
          'provider': selectedSession?.provider ?? 'unknown',
          'model': selectedSession?.model ?? '',
        },
      },
    );
    // v0.8.6 B：start 受理后立即刷新 controls（mode 目录等事实秒级到达）。
    if (accepted) {
      unawaited(_refreshControlsAfterTurn(sessionId));
    }
    return accepted;
  }

  String? killBlockedReason({required bool canWrite}) =>
      controlBlockedReason('kill', canWrite: canWrite);

  Future<void> killSelectedSession({
    required String? deviceId,
    required bool canWrite,
  }) async {
    final sessionId = _selectedSessionId;
    final blocked = killBlockedReason(canWrite: canWrite);
    if (sessionId == null || blocked != null) {
      if (blocked != null) _setError(blocked);
      return;
    }
    // kill 与 abort 同口径：用户发起的强制终止，本地活动回合事实随命令受理移除。
    _activeTurns.remove(sessionId);
    _turnTimedOut.remove(sessionId);
    await _submitCommand(
      sessionId: sessionId,
      operation: 'kill:$sessionId:${selectedSession?.lastSequence ?? 0}',
      kind: SessionCommandKind.kill,
      deviceId: deviceId!,
      ciphertext: {
        'fixture_payload': {'session_id': sessionId},
      },
    );
  }

  /// 前后台或网络变化时本地 lease 立即失效。
  /// 已提交到 Relay 的写请求不会被这里重放；恢复阶段只会读取增量 snapshot。
  void invalidateSelectedLeaseForRuntimePause() {
    _runtimeLeaseGeneration += 1;
    if (_selectedLease == null && _skillConfirmation == null) return;
    _selectedLease = null;
    _skillConfirmation = null;
    _notifyListeners();
  }

  /// 以当前已确认 cursor 拉取选中会话的增量事件。
  /// 该方法绝不调用 create/send/abort/确认/附件等写接口，生命周期恢复只能走只读路径。
  /// v0.9.0 C2：经每会话单航班门执行，与 L1/L3/手动刷新共享同一合并节奏，
  /// 不会与在途快照刷新并发重复请求。
  Future<SessionCursorRecovery?> recoverSelectedSessionFromCursor() async {
    final sessionId = _selectedSessionId;
    if (sessionId == null) return null;
    SessionCursorRecovery? recovery;
    await _runSnapshotTurn(sessionId, () async {
      recovery = await _recoverSelectedSessionFromCursorTurn(sessionId);
    });
    return recovery;
  }

  /// v0.9.0 C3：超时横幅「查看结果」手动出口——对选中会话触发一次强制快照
  /// 同步（只读），服从单航班与代际守卫。成功只在真实状态/事件到达时清横幅
  /// （返回是否已不再超时）；失败保留横幅并经既有 errorMessage 呈现脱敏错误。
  Future<bool> refreshTurnResult() async {
    final sessionId = _selectedSessionId;
    if (sessionId == null) return false;
    await _runSnapshotTurn(sessionId, () async {
      try {
        final snapshot = await _relay.getSessionSnapshot(
          sessionId,
          afterSequence: _cursorFor(sessionId),
        );
        if (_selectedSessionId != sessionId) return;
        _mergeSnapshot(snapshot, appendTimeline: true);
      } on RelayFailure catch (failure) {
        // 脱敏错误浮出；横幅保留，等待下一拍/L1/SSE 的真实事实。
        _errorMessage = failure.message;
      } catch (_) {
        _errorMessage = '会话内容暂时不可用，请稍后重试。';
      }
    });
    _notifyListeners();
    return !isTurnTimedOut(sessionId);
  }

  Future<SessionCursorRecovery?> _recoverSelectedSessionFromCursorTurn(
    String sessionId,
  ) async {
    final selectionGeneration = _selectionGeneration;
    final requestedAfterSequence = _cursorFor(sessionId);
    final existingSequences = _timeline.map((event) => event.sequence).toSet();
    final snapshot = await _relay.getSessionSnapshot(
      sessionId,
      afterSequence: requestedAfterSequence,
    );
    // 用户已切换会话时丢弃迟到的恢复响应，不能把上一会话事件画到当前页面。
    if (_selectedSessionId != sessionId ||
        _selectionGeneration != selectionGeneration) {
      return null;
    }
    final addedEventCount = snapshot.events
        .where((event) => !existingSequences.contains(event.sequence))
        .length;
    _mergeSnapshot(snapshot, appendTimeline: true);
    final controls = await _relay.getSessionControls(sessionId);
    // 控制项读取也可能比路由切换更晚返回。此时不能向恢复控制器报告旧会话成功，
    // 否则应用内通知会指向已经离开的会话。
    if (_selectedSessionId != sessionId ||
        _selectionGeneration != selectionGeneration) {
      return null;
    }
    _controls = controls;
    _notifyListeners();
    return SessionCursorRecovery(
      sessionId: sessionId,
      requestedAfterSequence: requestedAfterSequence,
      recoveredCursor: _cursorFor(sessionId),
      addedEventCount: addedEventCount,
    );
  }

  /// 发送前自动恢复（v0.9.2 P2 / C3 / T3 裁决）：
  /// **存在本地实例映射时必须走 resume，只有确实没有映射时才 start。**
  ///
  /// 为什么要改：daemon 重启后 store 里的 instance 映射仍在、内存句柄已释放，
  /// 执行端对该会话的 send 会以 local_state_missing 拒绝。旧实现无条件补
  /// `session.start`，而 daemon 的 start 走 `session/new` **新建** Provider 实例并
  /// 覆盖映射——用户看到会话"恢复"了，实际上下文已断链（P0 实测 b5 对照分支）。
  /// resume 则用映射中的原 instance id 调 `session.load/resume`，续接原会话。
  ///
  /// 判定顺序：
  ///   1) 非 stopped 会话：无需恢复，直接返回 true（保持既有直发路径）。
  ///   2) 先 resume：capability 具备 resume 且 lease 可用时才尝试；失败时读取
  ///      错误面判断是否为"本机没有实例映射"。
  ///   3) 仅当错误明确指向"无本机实例"（首次启动、或从未成功启动过）才回退
  ///      start——这是新会话唯一正确的语义。
  ///   4) 其它失败（Provider 不可用、版本门、环境失败）原样返回 false，
  ///      由调用方把真实原因浮出，绝不静默改走 start 掩盖故障。
  /// [force] 为 true 时**跳过**「status 不是 stopped 就直接放行」的短路。
  ///
  /// 为什么需要 force（v0.9.2 P2 修正，R14 真机暴露）：本机实例映射的丢失
  /// （Daemon 重启、state 目录被清理）与客户端可见的 session.status **无关**——
  /// Daemon 重启不会改写 Relay 的 session 投影，status 可能仍是 idle/running。
  /// 此时按 status 短路会直接放行发送，命令到达执行侧后必然以
  /// local_state_missing 失败，用户看到的就是「明明显示空闲却发不出去」。
  /// 因此失败路径用 force 强制走一次恢复（resume → 回退 start）。
  ///
  /// v0.9.3 P2（T4 裁决）：恢复全程通过 [recoveryNotice] 对用户可见——
  /// 「点了发送却毫无反馈」的静默窗口会让人重复点击、放大故障感；恢复结束
  /// （无论成败）立即清除。重试上限钉死为 1 次：本函数只被调用一轮
  /// （resume → 失败才 start），调用方（sendMessage）对恢复后的重试同样只做
  /// 一次（#recovered 幂等键），再次失败按真实故障浮出，绝不进入静默重试风暴。
  Future<bool> _ensureSessionRunnableForSend({
    required String deviceId,
    required bool canWrite,
    bool force = false,
  }) async {
    if (!force && selectedSession?.status != MobileSessionStatus.stopped) {
      return true;
    }
    // V094-05：结构化恢复阶段与可见提示同步写入。cause 无确证时不断言
    // "检测到终端已重启"（§2.1），阶段从执行路径推进、结束即清除。
    _recoveryNotice = '正在自动恢复会话…';
    _recoveryStage = SessionRecoveryStep(
      step: 'resume',
      attempt: 1,
      maxAttempts: 1,
      detail: '正在恢复会话',
      cancelable: true,
    );
    _notifyListeners();
    try {
      return await _ensureSessionRunnableForSendInner(
        deviceId: deviceId,
        canWrite: canWrite,
      );
    } finally {
      _recoveryNotice = null;
      _recoveryStage = null;
      _notifyListeners();
    }
  }

  /// 恢复链本体（resume 优先 → 不健康/无实例时回退 start），语义见外层注释。
  Future<bool> _ensureSessionRunnableForSendInner({
    required String deviceId,
    required bool canWrite,
  }) async {
    final resumeBlocked = resumeBlockedReason(canWrite: canWrite);
    if (resumeBlocked == null) {
      // 清掉上一轮错误，避免把历史失败误判成本次恢复结果。
      _errorMessage = null;
      await resumeSelectedSession(deviceId: deviceId, canWrite: canWrite);
      if (_errorMessage == null && _sessionRecoveryLooksHealthy) {
        return true;
      }
      // R17：resume 自报成功但状态投影不翻转（daemon 持久映射仍在时 resume
      // 恒成功，却只恢复句柄、不注册实例也不写状态事件——实测会话保持
      // stopped，用户被"恢复未成功"死锁）也必须回退 start：宁可丢上下文
      // 也要把会话救活。resume 以 missing-instance 失败的既有回退语义不变。
      if (_errorMessage != null &&
          !_looksLikeMissingLocalInstance(_errorMessage)) {
        // 真实故障（版本门/Provider 不可用/环境失败）：保持显式错误，不掩盖。
        return false;
      }
    }
    return startSelectedSession(deviceId: deviceId, canWrite: canWrite);
  }

  /// resume 成功后判定会话是否真的可写：status 已离开 stopped，或时间线出现了
  /// 恢复事实。这里只做保守判断——不能仅凭"命令被受理"就宣告恢复成功，
  /// 否则后续 send 仍会以 local_state_missing 失败。
  bool get _sessionRecoveryLooksHealthy =>
      selectedSession?.status != MobileSessionStatus.stopped;

  /// 判断错误面是否指向"本机没有该会话的实例映射"（local_state_missing 语义）。
  /// 只做子串匹配，不依赖 Relay 暴露内部错误码；匹配不到时一律按真实故障处理。
  bool _looksLikeMissingLocalInstance(String? message) {
    if (message == null || message.isEmpty) return false;
    // 这些文案与 internal/daemon/runner.go 的 local_state_missing 语义一一对应：
    //   "local_state_missing: session instance 不存在"          映射缺失；
    //   "...adapter resume 自报成功但未交出/没有可用句柄"        结果自报成功但实例不可用。
    // 两者都由 Daemon 归入同一类可重试错误（LOCAL_STATE_MISSING），客户端据此
    // 才允许回退 start；其余错误一律按真实故障浮出，不掩盖。
    const markers = <String>[
      'local_state_missing',
      '本机实例',
      '本机句柄',
      '尚未启动',
      '请先启动会话',
      'session instance',
    ];
    // 大小写不敏感（R15 真机暴露）：执行侧上报的是错误**码**形态
    // （LOCAL_STATE_MISSING，全大写+下划线），而这里的标记沿用 Daemon 日志里的
    // 小写文案形态。用区分大小写的 contains 会让"同一个语义"因为大小写而漏判，
    // 直接导致自动恢复不触发。
    final normalized = message.toLowerCase();
    for (final marker in markers) {
      if (normalized.contains(marker.toLowerCase())) return true;
    }
    return false;
  }

  /// 提交用户消息。[intent] 是本地提交意图（v0.9.0 C1）：newTurn 创建新业务
  /// 回合（重置 2/60 分钟预算）；steer 注入当前活动回合（继承原锚点与预算，
  /// 只推进同步代际）。UI 的 SessionSubmitMode.send/steer/queue 必须映射到
  /// 对应意图传入，禁止 controller 反推。
  Future<void> sendMessage({
    required String message,
    required String? deviceId,
    required bool canWrite,
    TurnSubmissionIntent intent = TurnSubmissionIntent.newTurn,
    // UI 传 false：受理（命令确认 + 首批快照）后立即返回，让 composer 把
    // 主按钮切换为"中断"；回合完成轮询转后台继续，直到终态再收敛状态行。
    bool awaitTurnCompletion = true,
  }) async {
    final trimmed = message.trim();
    if (trimmed.isEmpty) {
      _setError('请输入消息后再发送。');
      return;
    }
    final sessionId = _selectedSessionId;
    if (sessionId == null ||
        !_ensureWriteAccess(canWrite: canWrite, deviceId: deviceId) ||
        !await _ensureSelectedLeaseAuto(
              sessionId,
              deviceId: deviceId,
              canWrite: canWrite,
            )) {
      return;
    }
    // 已停止会话先自动恢复，再发送；避免 daemon 重启后用户被"请先启动会话"阻断。
    if (!await _ensureSessionRunnableForSend(
      deviceId: deviceId!,
      canWrite: canWrite,
    )) {
      // v0.9.2 G4：恢复失败时区分"能恢复但没恢复成功"与真实故障。
      // 具体原因（Provider 不可用 / 版本门 / 环境失败）已由恢复路径写入错误面，
      // 这里只在完全没有原因时给保守兜底文案。R17 起恢复链含 resume 与启动
      // 双重兜底，仍失败说明执行侧无法服务该会话——引导新建会话而非无限重试。
      _setError(
        _errorMessage ?? '会话自动恢复未成功，请新建会话后重试。',
      );
      return;
    }
    // v0.8.6 A②：上一回合未终态时的同文本重发会被 Relay 幂等去重（不产生
    // 新的 canonical 事件），第二次设置的乐观回显永远等不到清账，实机表现为
    // 同一条消息两条气泡。这里直接拦截：用户应等待终态或点击中断后再发送。
    if (isTurnInFlight) {
      String? lastUserText;
      for (final event in _timeline) {
        if (event.kind == SessionTimelineKind.userMessage) {
          lastUserText = event.text;
        }
      }
      if (lastUserText == trimmed) {
        _setError('相同消息仍在处理中：请等待回合结束，或点击中断后再发送。');
        return;
      }
    }
    // 同一条待发送内容重试复用幂等键；成功后的新输入会生成新的 action key。
    final operation =
        'send:$sessionId:${selectedSession?.lastSequence ?? 0}:$trimmed';
    // 与模型选择器同源：空模型会让 opencode 服务端回退到它的配置默认，
    // 可能命中付费订阅条目，所以发送时必须携带当前生效模型。
    final sessionModel = _controls.model ?? _controls.defaultModel ?? '';
    // ── V094（§2.2）：一次显式发送 = 一个逻辑事务 ─────────────────────────
    // clientMessageId 稳定标识本次发送（自动重发复用；两次显式发送必不同）；
    // draftRevision 记录提交时刻的草稿版本（结算按身份，不按全文对账）。
    final tx = SessionSendTransaction(
      submissionId: 'sendtx-$sessionId-${_sendTxCounter += 1}',
      sessionId: sessionId,
      clientMessageId:
          'cmsg-$sessionId-${_clock().microsecondsSinceEpoch}-${_sendTxCounter + 1}',
      text: trimmed,
      draftRevision: _draftRevisionsBySession[sessionId] ?? 0,
      baseOperation: operation,
      createdAt: _clock(),
      deviceId: deviceId,
      canWrite: canWrite,
    );
    _sendTxBySession[sessionId] = tx;
    // 乐观回显：不等 daemon 事件回传，先在本地挂出待确认的用户气泡。
    _pendingOutgoingBySession[sessionId] = trimmed;
    _notifyListeners();
    // 重试时只换幂等键，密文与意图保持一致（同一份用户输入不被重复引用附件）。
    // background=true（UI 路径）：202 受理即返回，回执观察/恢复链/回合轮询全部
    // 转入后台事务观察器——提交锁不再锁住整个 composer（V094-23）。
    Future<bool> submitSend(
      String opKey, {
      bool background = false,
    }) => _submitCommand(
      sessionId: sessionId,
      operation: opKey,
      kind: SessionCommandKind.send,
      deviceId: deviceId,
      // 这里必须显式传 canWrite：_submitCommand 的默认值是 true，而调用方
      // 传入的是真实的（可能为 false 的）可写判定，不能因为抽成闭包而丢失。
      canWrite: canWrite,
      ciphertext: {
        'fixture_payload': {
          'message': trimmed,
          if (sessionModel.isNotEmpty) 'model': sessionModel,
          // v0.8.5 §3.1：已完成上传的附件以 opaque refs 随 send 密文发送
          // （attachment_id/mime/尺寸/明文 sha256）；生产链路 Daemon 经 §3.3
          // 拉密文 + 会话 DEK 解密后复算校验。refs 与 inline images 互斥。
          if (_completedAttachmentRefs(sessionId).isNotEmpty)
            'attachments': _completedAttachmentRefs(sessionId),
        },
      },
      awaitTurnCompletion: awaitTurnCompletion,
      submissionIntent: intent,
      // V094：受理后命令 ID 回填事务账本；background 时不再在 action 内
      // 等待回执/回合，由 _observeSendTransaction 接管。
      deferSendObservation: background,
      onCommandAccepted: (commandId) => tx.currentCommandId = commandId,
    );
    // UI 路径（composer 的 awaitTurnCompletion=false）把观察转后台；
    // 直调方（历史测试/恢复链内部）保持内联观察语义不变。
    final observeInBackground = !awaitTurnCompletion;
    var accepted = await submitSend(operation, background: observeInBackground);
    // v0.9.2 P2 修正（R14 真机暴露）：发送被执行侧以「本机没有该会话实例」拒绝时
    // 自动恢复并重试一次。触发条件是**执行侧错误**而不是客户端 status——
    // Daemon 重启/state 清理会丢失实例映射，但 Relay 的 session 投影往往仍是
    // idle/running，`_ensureSessionRunnableForSend` 的 status 短路因此不会触发，
    // 用户看到的现象是「显示空闲却发不出去」。
    // V094：该链在后台观察器内执行（结构化阶段恢复中 → 正在重发 1/1）；
    // 内联路径保持既有顺序。
    if (!accepted && _looksLikeMissingLocalInstance(_errorMessage)) {
      _errorMessage = null;
      _notifyListeners();
      final recovered = await _recoverForSendTransaction(
        tx,
        deviceId: deviceId,
        canWrite: canWrite,
      );
      if (recovered) {
        // 幂等键必须变化：Relay 按 operation 去重，沿用旧键会直接返回上一次
        // 失败的命令，重试形同虚设。clientMessageId 保持不变（同一逻辑消息）。
        tx.resendCount += 1;
        tx.phase = SessionSendPhase.resending;
        tx.recoveryStep = SessionRecoveryStep(
          step: 'resend',
          attempt: tx.resendCount,
          maxAttempts: tx.maxResends,
          detail: '正在重发上一条消息',
        );
        _notifyListeners();
        accepted = await submitSend(
          '$operation#recovered',
          background: observeInBackground,
        );
        tx.recoveryStep = null;
      }
    }
    if (accepted) {
      // v0.9.0 C1：回合在途标记与超时标记已在 Relay 202 即时受理分支内处理
      // （_noteSendAcceptedAt202），不再等首批快照返回后才置位。
      // v0.8.5 §3.1：受理成功后清空该会话附件队列（refs 已随密文发送，
      // 保留会让同一批附件在下次发送时被重复引用）。
      if (_attachmentsBySession[sessionId]?.isNotEmpty ?? false) {
        _attachmentsBySession[sessionId] = const [];
        _attachments = const [];
      }
      tx.phase = awaitTurnCompletion
          ? tx.phase // 内联观察已在 _submitCommand 内完成收敛
          : SessionSendPhase.accepted;
      if (!awaitTurnCompletion) {
        // UI 路径：受理即返回；回执窗口/恢复链/结果核验转后台事务观察器。
        unawaited(_observeSendTransaction(tx));
      }
    } else {
      // 提交被拒（验证失败/受理失败）：尚未形成消息事务事实，正文留在
      // 输入框（既有错误面语义）；事务从账本移除，乐观回显清掉避免双气泡。
      if (_sendTxBySession[sessionId] == tx) {
        _sendTxBySession.remove(sessionId);
      }
      _notifyListeners();
    }
    if (!accepted && _pendingOutgoingBySession[sessionId] == trimmed) {
      _pendingOutgoingBySession.remove(sessionId);
      _notifyListeners();
    }
    if (accepted && awaitTurnCompletion) {
      // 发送成功后清除草稿，避免页面重建时把已发送内容重新填回输入框。
      // V094 §2.4：按事务结算——仅当草稿仍是本次提交的正文时才清空；
      // 观察期间用户新写的草稿不允许被旧事务的迟到结算覆盖。
      final currentDraft = _composerDrafts[sessionId];
      if (currentDraft == null || currentDraft.trim() == trimmed) {
        clearComposerDraft(sessionId);
      }
    }
  }

  /// 为发送事务执行恢复链（resume 优先 → 必要时 start），并把结构化阶段
  /// 写入事务与全局恢复提示（V094-05：阶段真实、全程可见）。
  Future<bool> _recoverForSendTransaction(
    SessionSendTransaction tx, {
    required String deviceId,
    required bool canWrite,
  }) async {
    tx.phase = SessionSendPhase.recovering;
    tx.recoveryStep = SessionRecoveryStep(
      step: 'resume',
      attempt: 1,
      maxAttempts: tx.maxResends,
      // cause 无确证时不断言"检测到终端已重启"（§2.1）。
      detail: '正在恢复会话',
      cancelable: true,
    );
    _notifyListeners();
    final recovered = await _ensureSessionRunnableForSend(
      deviceId: deviceId,
      canWrite: canWrite,
      force: true,
    );
    tx.recoveryStep = null;
    return recovered;
  }

  /// V094（§2.5）：后台事务观察器——回执窗口、可信进展、恢复重发与结果核验。
  ///
  /// 口径冻结：
  /// - 回执窗口 30s（sendReceiptPollAttempts，保留 V093-04）；失败回执优先于
  ///   同步代际处理（V093-04b 不回退）；
  /// - 窗口耗尽时：已有可信执行进展 → processing（结果仍在同步）；否则
  ///   verifying（结果待确认）——均不等同失败；
  /// - 自动重发最多 1 次，且尊重 cancelRequested（只取消尚未提交的步骤）；
  /// - 事务按会话隔离：切会话/旧响应不影响其它会话事务，也不被其影响。
  Future<void> _observeSendTransaction(SessionSendTransaction tx) async {
    final commandId = tx.currentCommandId;
    if (commandId == null) return;
    final terminal = await _awaitCommandReceipt(
      commandId,
      maxAttempts: sendReceiptPollAttempts,
      onPoll: () {
        if (tx.hasTrustedProgress && tx.phase == SessionSendPhase.accepted) {
          // 30s 窗口内已确认执行进展：状态槽从"已受理"升级为"处理中"，
          // 但仍保留窗口继续等权威终态（不新发命令）。
          tx.phase = SessionSendPhase.processing;
          _notifyListeners();
        }
      },
    );
    if (tx.isTerminal) return;
    if (terminal != null && terminal.status != 'succeeded') {
      // 失败回执是本命令自己的结果，必须优先于代际/窗口处理（V093-04b）。
      await _bestEffortRefreshAfterCommandFailure(tx.sessionId);
      tx.errorCode = (terminal.errorCode ?? '').trim();
      tx.errorDetail = terminal.errorCode == null || tx.errorCode!.isEmpty
          ? '消息发送失败（命令 ${terminal.status}）'
          : '消息发送失败（${tx.errorCode}）';
      final recoverable = _looksLikeMissingLocalInstance(
        tx.errorCode ?? tx.errorDetail,
      );
      if (recoverable &&
          tx.resendCount < tx.maxResends &&
          !tx.cancelRequested) {
        // 事务观察器跟随提交时的设备身份，不依赖当前选中会话。
        final recovered = await _recoverForSendTransaction(
          tx,
          deviceId: tx.deviceId,
          canWrite: tx.canWrite,
        );
        if (recovered && !tx.cancelRequested) {
          tx.resendCount += 1;
          tx.phase = SessionSendPhase.resending;
          tx.recoveryStep = SessionRecoveryStep(
            step: 'resend',
            attempt: tx.resendCount,
            maxAttempts: tx.maxResends,
            detail: '正在重发上一条消息',
          );
          _notifyListeners();
          final retry = await _submitCommand(
            sessionId: tx.sessionId,
            operation: '${tx.baseOperation}#recovered',
            kind: SessionCommandKind.send,
            deviceId: tx.deviceId,
            canWrite: tx.canWrite,
            ciphertext: {
              'fixture_payload': {'message': tx.text},
            },
            deferSendObservation: true,
            onCommandAccepted: (id) => tx.currentCommandId = id,
          );
          tx.recoveryStep = null;
          if (retry) {
            final retryTerminal = await _awaitCommandReceipt(
              tx.currentCommandId!,
              maxAttempts: sendReceiptPollAttempts,
            );
            _settleSendTransaction(tx, retryTerminal);
            _notifyListeners();
            return;
          }
        }
      }
      // 不可恢复 / 已取消 / 重试后再次失败：保留失败事务（正文在内），
      // 显示明确原因并提供一次手动重试入口（不盲目自动补发）。
      tx.phase = tx.cancelRequested && tx.resendCount == 0
          ? SessionSendPhase.cancelled
          : SessionSendPhase.failed;
      // 失败内容保留在消息事务槽内（失败节点接管展示），乐观回显不删除，
      // 供手动重试/编辑后重试（§2.2 状态表：不盲目自动补发）。
      _notifyListeners();
      return;
    }
    _settleSendTransaction(tx, terminal);
    _notifyListeners();
    // 回执已收敛（成功或未知）：驱动回合完成轮询——首拍合并 + 未完成转
    // 后台轮询（与内联观察同口径）。
    await _driveTurnPollingForTransaction(tx);
    // V094-23 真机回归修正（实施记录 34 §2.8）：回执窗口/后台轮询的有界
    // 窗口可能短于真实回合（DSH send 阻塞到回合结束，65-90s+ 回合实测
    // 存在）。事务观察器是后台任务，必须在 processing/verifying 期间
    // 持续接力驱动快照直到回合终态，否则回合完成后 UI 永远停在「执行中」。
    await _observeTurnUntilTerminal(tx);
  }

  /// 事务观察器的回合终态接力：拍长 [activePollInterval]，直到 canonical
  /// 收口（_activeTurns 移除）或上限（1200 拍）。合并走既有代际守卫；
  /// 传输 live（SSE wake 驱动）时跳过本拍拉取，避免双通道重复请求。
  ///
  /// 节拍等待是可取消的：页面/controller 销毁（dispose）时立即唤醒并退出，
  /// 不在 widget 树拆除后留下 pending timer（V094 回归门要求）。
  Future<void> _observeTurnUntilTerminal(SessionSendTransaction tx) async {
    const attempts = 1200;
    final authGenerationAtStart = _authGeneration;
    final syncGenerationAtStart = _syncGenerations[tx.sessionId] ?? 0;
    bool generationsStale() =>
        _authGeneration != authGenerationAtStart ||
        (_syncGenerations[tx.sessionId] ?? 0) != syncGenerationAtStart;
    for (var i = 0; i < attempts; i++) {
      if (_disposed || generationsStale()) return;
      if (!_activeTurns.containsKey(tx.sessionId)) {
        // 回合已由 canonical 终态收口：刷新 controls 并结束。
        await _refreshControlsAfterTurn(tx.sessionId);
        return;
      }
      await _waitTurnObserverTick();
      if (_disposed || generationsStale()) return;
      if (!_activeTurns.containsKey(tx.sessionId)) continue;
      if (_transportSuppressesPolling(tx.sessionId)) continue;
      try {
        final latest = await _relay.getSessionSnapshot(
          tx.sessionId,
          afterSequence: _cursorFor(tx.sessionId),
        );
        if (_disposed || generationsStale()) return;
        final authGenerationAtPoll = _authGeneration;
        if (_authGeneration == authGenerationAtPoll &&
            _selectedSessionId == tx.sessionId) {
          _mergeSnapshot(latest, appendTimeline: true);
          _evaluateTurnDeadlines(tx.sessionId);
        }
        if (_snapshotCompletesTurn(latest)) {
          if (_selectedSessionId == tx.sessionId) {
            await _refreshControlsAfterTurn(tx.sessionId);
          }
          return;
        }
      } catch (_) {
        // 单拍失败不终止接力：下一拍继续（与后台轮询同口径）。
      }
    }
  }

  /// 可取消的接力节拍：dispose 时取消计时器并唤醒等待者，让接力循环立即
  /// 退出（不遗留 pending timer）。
  Future<void> _waitTurnObserverTick() {
    if (_disposed) return Future<void>.value();
    final completer = Completer<void>();
    _turnObserverWaiter = completer;
    _turnObserverTimer = Timer(activePollInterval, () {
      _turnObserverTimer = null;
      if (!completer.isCompleted) completer.complete();
    });
    return completer.future.whenComplete(() {
      if (identical(_turnObserverWaiter, completer)) {
        _turnObserverWaiter = null;
      }
    });
  }

  /// V094：事务观察器的回合完成轮询入口。defer 模式下 _submitCommand 在
  /// 202 即返回，快照合并由这里接管；代际守卫由 _pollTurnCompletionInBackground
  /// 自带（切换会话/认证切换后自动停止）。
  Future<void> _driveTurnPollingForTransaction(SessionSendTransaction tx) async {
    try {
      // 首批快照已在 defer 收敛分支合并：若 canonical 终态已收口活动回合
      // （_activeTurns 移除），无需再轮询——避免空转的后台轮询悬挂计时器。
      if (!_activeTurns.containsKey(tx.sessionId)) {
        return;
      }
      // 与内联路径同口径：全量回放（after_seq=0）+ replace 合并。
      // 增量空快照会让 _snapshotCompletesTurn 丢失 question/审批等待等
      // "非流式终局"证据，误判为回合在途并空转后台轮询。
      final authGenerationAtDrive = _authGeneration;
      final latest = await _relay.getSessionSnapshot(tx.sessionId);
      if (_authGeneration == authGenerationAtDrive &&
          _selectedSessionId == tx.sessionId) {
        _mergeSnapshot(latest);
      }
      if (_snapshotCompletesTurn(latest)) {
        await _refreshControlsAfterTurn(tx.sessionId);
      } else if (_activeTurns.containsKey(tx.sessionId)) {
        // 回合仍在途：转既有后台轮询（自带代际守卫，有界窗口）。
        unawaited(_pollTurnCompletionInBackground(tx.sessionId, latest));
      }
    } catch (_) {
      // 首拍失败不阻塞事务收敛：后台/前台刷新路径仍会补齐快照。
    }
  }

  /// 按回执收敛事务：null（窗口耗尽/查询失败）按 §2.2 区分"处理中"与
  /// "结果待确认"，绝不把未知结果假报为成功或失败。
  void _settleSendTransaction(
    SessionSendTransaction tx,
    SessionCommandReceipt? terminal,
  ) {
    if (terminal == null) {
      tx.phase = tx.hasTrustedProgress
          ? SessionSendPhase.processing
          : SessionSendPhase.verifying;
      return;
    }
    switch (terminal.status) {
      case 'succeeded':
        tx.phase = SessionSendPhase.completed;
        // 受理成功仅结算本次事务；回执等待期的新草稿/新附件一律不动（§2.4）。
        final currentDraft = _composerDrafts[tx.sessionId];
        if (currentDraft != null && currentDraft.trim() == tx.text) {
          clearComposerDraft(tx.sessionId);
        }
      case 'failed':
      case 'rejected':
      case 'cancelled':
      case 'expired':
        tx.phase = SessionSendPhase.failed;
        tx.errorCode = (terminal.errorCode ?? tx.errorCode)?.trim();
        tx.errorDetail ??= '消息发送失败（命令 ${terminal.status}）';
      default:
        // accepted/running 等非终态：保持当前阶段，不伪造完成。
        break;
    }
  }

  /// V094-05/06：失败事务的手动重试——生成新的显式 attempt，与旧事务保持
  /// 关联并串行；结果未知时必须先核验，不能用新幂等键盲目重复发出。
  Future<bool> retryFailedSend({
    required String? deviceId,
    required bool canWrite,
  }) async {
    final sessionId = _selectedSessionId;
    final failed = lastInterruptedSendTransaction;
    if (sessionId == null || failed == null) return false;
    if (!_ensureWriteAccess(canWrite: canWrite, deviceId: deviceId) ||
        !await _ensureSelectedLeaseAuto(
          sessionId,
          deviceId: deviceId,
          canWrite: canWrite,
        )) {
      return false;
    }
    // 已核验前置：结果待确认的事务必须先核验，不允许直接补发。
    if (failed.phase == SessionSendPhase.verifying) {
      _setError('上一次发送结果尚未确认：请先在时间线核验结果后再重试。');
      return false;
    }
    final retryOperation =
        '${failed.baseOperation}:retry-${_sendTxCounter += 1}';
    final tx = SessionSendTransaction(
      submissionId: 'sendtx-$sessionId-${_sendTxCounter += 1}',
      sessionId: sessionId,
      // 新 attempt 的逻辑身份：重试关联旧事务（clientMessageId 带父标识），
      // 两次用户主动发送不共享身份。
      clientMessageId: '${failed.clientMessageId}-r$_sendTxCounter',
      text: failed.text,
      draftRevision: _draftRevisionsBySession[sessionId] ?? 0,
      baseOperation: retryOperation,
      createdAt: _clock(),
      // _ensureWriteAccess 已确保 deviceId 非空（与既有 send 契约一致）。
      deviceId: deviceId!,
      canWrite: canWrite,
    );
    _sendTxBySession[sessionId] = tx;
    _pendingOutgoingBySession[sessionId] = tx.text;
    _notifyListeners();
    final accepted = await _submitCommand(
      sessionId: sessionId,
      operation: retryOperation,
      kind: SessionCommandKind.send,
      deviceId: deviceId,
      canWrite: canWrite,
      ciphertext: {
        'fixture_payload': {'message': tx.text},
      },
      deferSendObservation: true,
      onCommandAccepted: (commandId) => tx.currentCommandId = commandId,
    );
    if (!accepted) {
      // 手动重试提交被拒：事务保留失败态，正文仍在待处理项中可再次编辑。
      tx.phase = SessionSendPhase.failed;
      tx.errorDetail ??= _errorMessage;
      _notifyListeners();
      return false;
    }
    tx.phase = SessionSendPhase.accepted;
    _notifyListeners();
    unawaited(_observeSendTransaction(tx));
    return true;
  }

  Future<void> stopStreaming({
    required String? deviceId,
    required bool canWrite,
  }) async {
    final sessionId = _selectedSessionId;
    if (sessionId == null ||
        !_ensureWriteAccess(canWrite: canWrite, deviceId: deviceId) ||
        !await _ensureSelectedLeaseAuto(
              sessionId,
              deviceId: deviceId,
              canWrite: canWrite,
            )) {
      return;
    }
    final accepted = await _submitCommand(
      sessionId: sessionId,
      operation: 'abort:$sessionId:${selectedSession?.lastSequence ?? 0}',
      kind: SessionCommandKind.abort,
      deviceId: deviceId!,
    );
    if (accepted) {
      // 用户主动中止即清除本地超时标记（与 daemon 看门狗撤防同口径），
      // 并移除活动回合状态（用户发起的终止动作，不属于伪造服务端事实）。
      _turnTimedOut.remove(sessionId);
      _activeTurns.remove(sessionId);
      // Abort 的命令回执和 canonical session.aborted/stopped 投影可能分开
      // 抵达。先确认命令成功，再用有界增量轮询等 Relay 投影完成，避免刷新过早
      // 错过可见的“已中止”轨迹。
      _pendingOutgoingBySession.remove(sessionId);
      _errorMessage = null;
      _notifyListeners();
      await _awaitAbortProjection(sessionId);
    }
  }

  Future<void> _awaitAbortProjection(String sessionId) async {
    const attempts = 12;
    var latestCursor = _cursorFor(sessionId);
    for (var i = 0; i < attempts; i++) {
      try {
        final snapshot = await _relay.getSessionSnapshot(
          sessionId,
          afterSequence: latestCursor,
        );
        if (_selectedSessionId != sessionId) return;
        _mergeSnapshot(snapshot, appendTimeline: true);
        latestCursor = _cursorFor(sessionId);
        final hasAbortedEvent = snapshot.events.any((event) {
          if (event.eventType == 'session.aborted') return true;
          final parsed = SessionTimelineEvent.fromRelayEvent(event);
          return parsed.label == '已中止';
        });
        if (hasAbortedEvent ||
            snapshot.session.status == MobileSessionStatus.stopped) {
          return;
        }
      } catch (_) {
        // Keep the local state recoverable; the next foreground/cursor refresh
        // can still pick up a delayed canonical event.
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    // Timeout is intentionally silent. A later cursor recovery may still add
    // the canonical abort record; this path never claims success on its behalf.
  }

  Future<MobileSession?> forkFromMessage({
    required String messageId,
    required String? deviceId,
    required bool canWrite,
  }) async {
    final trimmed = messageId.trim();
    final sessionId = _selectedSessionId;
    if (trimmed.isEmpty) {
      _setError('分支消息标识无效。');
      return null;
    }
    if (sessionId == null ||
        !_ensureWriteAccess(canWrite: canWrite, deviceId: deviceId) ||
        !await _ensureSelectedLeaseAuto(
              sessionId,
              deviceId: deviceId,
              canWrite: canWrite,
            )) {
      return null;
    }
    final operation = 'fork:$sessionId:$trimmed';
    return _runAction<MobileSession?>(operation, () async {
      final lease = _selectedLease;
      if (lease == null || lease.sessionId != sessionId || lease.epoch <= 0) {
        throw const RelayFailure(
          RelayFailureKind.validation,
          '会话可操作状态已变化，请重试。',
        );
      }
      final child = await _relay.forkSession(
        sessionId,
        SessionForkInput(
          messageId: trimmed,
          idempotencyKey: _idempotencyKeyFor(operation),
          leaseEpoch: lease.epoch,
          deviceId: deviceId!,
        ),
      );
      _sessions = [child, ..._sessions.where((item) => item.id != child.id)];
      if (_selectedSessionId == sessionId) {
        final snapshot = await _relay.getSessionSnapshot(
          sessionId,
          afterSequence: _cursorFor(sessionId),
        );
        if (_selectedSessionId == sessionId) {
          _mergeSnapshot(snapshot, appendTimeline: true);
        }
      }
      return child;
    });
  }

  /// v0.2/P2：断线/离线后显式恢复 Provider 会话。
  /// 写命令仍携带正数 lease_epoch 与幂等键；唤醒结果由 Daemon 映射为
  /// resumed / restarted_with_context / unsupported，客户端不在此处伪造结果。
  Future<void> resumeSelectedSession({
    required String? deviceId,
    required bool canWrite,
  }) async {
    final sessionId = _selectedSessionId;
    final blocked = resumeBlockedReason(canWrite: canWrite);
    if (sessionId == null || blocked != null) {
      if (blocked != null) _setError(blocked);
      return;
    }
    final accepted = await _submitCommand(
      sessionId: sessionId,
      operation: 'resume:$sessionId:${selectedSession?.lastSequence ?? 0}',
      kind: SessionCommandKind.resume,
      deviceId: deviceId!,
    );
    // v0.8.6 B：resume 会触发 daemon 重新上行 mode 目录等 controls 事实，
    // 回执成功后立即刷新（目录秒级到达，不等回合或重进页面）。
    if (accepted) {
      unawaited(_refreshControlsAfterTurn(sessionId));
    }
  }

  /// resume 入口的阻断原因；离线状态也允许发起（与发送不同），只要求 capability 与 lease。
  String? resumeBlockedReason({required bool canWrite}) {
    final declared = selectedProviderCapabilities.capability('resume');
    if (!declared.isSupported) {
      return declared.reason ?? '恢复会话当前不可用。';
    }
    return controlBlockedReason('resume', canWrite: canWrite);
  }

  Future<bool> resolvePermission({
    required String requestId,
    required bool approved,
    required String? deviceId,
    required bool canWrite,
  }) async {
    final sessionId = _selectedSessionId;
    final requestKey = 'permission:$requestId';
    if (_resolvedRequestKeys.contains(requestKey) ||
        isRequestPending(requestId) ||
        sessionId == null ||
        !_ensureWriteAccess(canWrite: canWrite, deviceId: deviceId) ||
        !await _ensureSelectedLeaseAuto(
              sessionId,
              deviceId: deviceId,
              canWrite: canWrite,
            )) {
      return false;
    }
    // v0.5/P4-D：同一 approval request 的 reject / approve 必须 one-shot。
    // 这里按 requestId 阻断交叉 pending，而不是只按按钮 operation 阻断。
    return _submitCommand(
      sessionId: sessionId,
      operation: '$requestKey:${approved ? 'approve' : 'reject'}',
      kind: approved
          ? SessionCommandKind.permissionApprove
          : SessionCommandKind.permissionReject,
      deviceId: deviceId!,
      ciphertext: {
        'fixture_payload': {'request_id': requestId},
      },
      onAccepted: () => _resolvedRequestKeys.add(requestKey),
    );
  }

  Future<bool> answerQuestion({
    required String requestId,
    required String answer,
    required String? deviceId,
    required bool canWrite,
  }) async {
    final trimmed = answer.trim();
    if (trimmed.isEmpty) {
      _setError('请选择或输入一个回答。');
      return false;
    }
    return answerQuestionBatch(
      requestId: requestId,
      answers: [
        {
          'id': requestId,
          'selected': [trimmed],
        },
      ],
      legacyAnswer: trimmed,
      deviceId: deviceId,
      canWrite: canWrite,
    );
  }

  Future<bool> answerQuestionBatch({
    required String requestId,
    required List<Map<String, dynamic>> answers,
    required String? deviceId,
    required bool canWrite,
    String? legacyAnswer,
  }) async {
    final sessionId = _selectedSessionId;
    final requestKey = 'question:$requestId';
    if (answers.isEmpty) {
      _setError('请选择或输入一个回答。');
      return false;
    }
    if (_resolvedRequestKeys.contains(requestKey) ||
        sessionId == null ||
        !_ensureWriteAccess(canWrite: canWrite, deviceId: deviceId) ||
        !await _ensureSelectedLeaseAuto(
              sessionId,
              deviceId: deviceId,
              canWrite: canWrite,
            )) {
      return false;
    }
    // v0.5/P4-E：DeepSeek question 使用一次 respond 提交完整 answer batch；
    // Flutter 仍复用现有 question.answer 命令，只把 fixture payload 扩展为 answers[]。
    final fixturePayload = <String, dynamic>{
      'request_id': requestId,
      'answers': answers,
    };
    if (legacyAnswer != null) fixturePayload['answer'] = legacyAnswer;
    return _submitCommand(
      sessionId: sessionId,
      operation: '$requestKey:answer',
      kind: SessionCommandKind.questionAnswer,
      deviceId: deviceId!,
      ciphertext: {'fixture_payload': fixturePayload},
      onAccepted: () => _resolvedRequestKeys.add(requestKey),
    );
  }

  Future<bool> skipQuestion({
    required String requestId,
    required String? deviceId,
    required bool canWrite,
  }) async {
    final sessionId = _selectedSessionId;
    final requestKey = 'question:$requestId';
    if (_resolvedRequestKeys.contains(requestKey) ||
        sessionId == null ||
        !_ensureWriteAccess(canWrite: canWrite, deviceId: deviceId) ||
        !await _ensureSelectedLeaseAuto(
              sessionId,
              deviceId: deviceId,
              canWrite: canWrite,
            )) {
      return false;
    }
    // v0.5/P4-C：当前 Relay 命令集没有 question.cancel；skip 按 DeepSeek
    // QuestionComposer 的“空选择提交”语义落到既有 question.answer 写链路，
    // 并只在 fixture payload 中显式标记 skipped，避免伪造 Host 取消能力。
    return _submitCommand(
      sessionId: sessionId,
      operation: '$requestKey:skip',
      kind: SessionCommandKind.questionAnswer,
      deviceId: deviceId!,
      ciphertext: {
        'fixture_payload': {'request_id': requestId, 'skipped': true},
      },
      onAccepted: () => _resolvedRequestKeys.add(requestKey),
    );
  }

  bool isRequestPending(String requestId) =>
      _pendingActionKeys.any((key) => key.contains(':$requestId'));

  bool isRequestResolved(String type, String requestId) =>
      _resolvedRequestKeys.contains('$type:$requestId');

  /// 按 Provider capability、认证角色和当前 lease 依次收口写入口；调用方直接把返回原因呈现给用户。
  String? controlBlockedReason(
    String capability, {
    required bool canWrite,
    bool requiresLease = true,
  }) {
    final declared = selectedProviderCapabilities.capability(capability);
    if (!declared.isSupported) {
      return declared.reason ?? '$capability 当前不可用。';
    }
    if (!canWrite) return '当前设备是只读状态';
    if (_selectedSessionId == null) return '请选择一个会话';
    // lease（单写者控制权）不再是 UI 前置阻断：写命令提交时由
    // _submitCommand 静默自动获取。requiresLease 参数保留以兼容调用方，
    // 但不再产生面向用户的“暂不可操作”文案。
    return null;
  }

  /// 高风险 Skill 先进入本地确认态；这里没有任何 Relay 写入，拒绝也不会产生 Provider 命令。
  void requestSkillConfirmation(
    SessionSkillDescriptor skill, {
    required bool canWrite,
  }) {
    final blocked = controlBlockedReason('invoke_skill', canWrite: canWrite);
    if (blocked != null) {
      _setError(blocked);
      return;
    }
    _skillConfirmation = SkillConfirmation(skill: skill);
    _notifyListeners();
  }

  void rejectSkillConfirmation() {
    if (_skillConfirmation == null) return;
    _skillConfirmation = null;
    _notifyListeners();
  }

  Future<void> confirmSkill({
    required String? deviceId,
    required bool canWrite,
  }) async {
    final confirmation = _skillConfirmation;
    final sessionId = _selectedSessionId;
    final blocked = controlBlockedReason('invoke_skill', canWrite: canWrite);
    if (confirmation == null || sessionId == null || blocked != null) {
      if (blocked != null) _setError(blocked);
      return;
    }
    await _submitCommand(
      sessionId: sessionId,
      operation: 'skill:$sessionId:${confirmation.skill.id}',
      kind: SessionCommandKind.skillInvoke,
      deviceId: deviceId!,
      ciphertext: {
        'fixture_payload': {'skill_id': confirmation.skill.id},
      },
      onAccepted: () => _skillConfirmation = null,
    );
  }

  Future<void> approvePlan({
    required String? deviceId,
    required bool canWrite,
  }) async {
    final plan = _controls.plan;
    final sessionId = _selectedSessionId;
    final blocked = controlBlockedReason('plan', canWrite: canWrite);
    if (plan == null ||
        plan.phase != PlanPhase.awaitingApproval ||
        sessionId == null ||
        blocked != null) {
      if (blocked != null) _setError(blocked);
      return;
    }
    await _submitCommand(
      sessionId: sessionId,
      operation: 'plan:$sessionId:approve',
      kind: SessionCommandKind.planApprove,
      deviceId: deviceId!,
      ciphertext: const {
        'fixture_payload': {'action': 'approve'},
      },
      onAccepted: () => _controls = _controls.copyWith(
        plan: plan.copyWith(phase: PlanPhase.active),
      ),
    );
  }

  Future<void> toggleGoal({
    required String? deviceId,
    required bool canWrite,
  }) async {
    final goal = _controls.goal;
    final sessionId = _selectedSessionId;
    final blocked = controlBlockedReason('goal', canWrite: canWrite);
    if (goal == null ||
        goal.phase == GoalPhase.completed ||
        sessionId == null ||
        blocked != null) {
      if (blocked != null) _setError(blocked);
      return;
    }
    final next = goal.phase == GoalPhase.active
        ? GoalPhase.paused
        : GoalPhase.active;
    await _submitCommand(
      sessionId: sessionId,
      operation: 'goal:$sessionId:${next.wireValue}',
      kind: SessionCommandKind.goalToggle,
      deviceId: deviceId!,
      ciphertext: {
        'fixture_payload': {'phase': next.wireValue},
      },
      onAccepted: () =>
          _controls = _controls.copyWith(goal: goal.copyWith(phase: next)),
    );
  }

  /// v0.5/P5-E2：清除当前 Goal 只通过统一写命令完成。
  ///
  /// UI 不能直接把 Goal 从本地 state 移除；这里继续复用 capability、lease、deviceId
  /// 和幂等 key，fixture / 真实 Relay 都应只返回 receipt 后才更新展示态。
  Future<void> clearGoal({
    required String? deviceId,
    required bool canWrite,
  }) async {
    final goal = _controls.goal;
    final sessionId = _selectedSessionId;
    final blocked = controlBlockedReason('goal', canWrite: canWrite);
    if (goal == null || sessionId == null || blocked != null) {
      if (blocked != null) _setError(blocked);
      return;
    }
    await _submitCommand(
      sessionId: sessionId,
      operation: 'goal-clear:$sessionId',
      kind: SessionCommandKind.goalClear,
      deviceId: deviceId!,
      ciphertext: const {
        'fixture_payload': {'action': 'clear'},
      },
      onAccepted: () => _controls = _controls.copyWith(clearGoal: true),
    );
  }

  /// v0.5/P5-E3：通过 `/goal ...` command-input 创建当前 Goal。
  ///
  /// 这是 slash command 的专用 adjudication 结果，不走普通 `session.send`，
  /// 也不把创建动作伪装成 assistant 回复；Host/Relay receipt accepted 后才更新 dock。
  Future<void> createGoal({
    required String objective,
    required String? deviceId,
    required bool canWrite,
  }) async {
    final sessionId = _selectedSessionId;
    final blocked = controlBlockedReason('goal', canWrite: canWrite);
    if (sessionId == null || blocked != null) {
      if (blocked != null) _setError(blocked);
      return;
    }
    if (_controls.goal != null) {
      _setError('当前已有 Goal，请先编辑或清除后再创建。');
      return;
    }
    final trimmed = objective.trim();
    if (trimmed.isEmpty) {
      _setError('请输入 /goal 后的目标文本。');
      return;
    }
    await _submitCommand(
      sessionId: sessionId,
      operation: 'goal-create:$sessionId:${trimmed.hashCode}',
      kind: SessionCommandKind.goalCreate,
      deviceId: deviceId!,
      ciphertext: {
        'fixture_payload': {'objective': trimmed},
      },
      onAccepted: () => _controls = _controls.copyWith(
        goal: SessionGoalSummary(
          title: trimmed,
          progressLabel: '0 / 1',
          phase: GoalPhase.active,
        ),
      ),
    );
  }

  /// 单项入口复用批量预检，保证 picker、paste 和未来 drop 入口使用同一 oracle。
  bool addAttachmentDraft(AttachmentDraft draft) =>
      addAttachmentDrafts([draft]);

  /// 原子接纳一批附件：任何一项失败都不写入本地队列，也不生成上传请求。
  ///
  /// 图片预检顺序与 DeepSeek Harness 对齐：unsupported type -> count ->
  /// single size -> total size；之后才执行通用密文结构校验。
  bool addAttachmentDrafts(Iterable<AttachmentDraft> drafts) {
    final incoming = drafts.toList(growable: false);
    if (incoming.isEmpty) return true;
    String? reason;
    final imageIncoming = incoming.where((draft) => draft.isImage).toList();
    if (imageIncoming.isNotEmpty) {
      final limits = _controls.imageLimits;
      reason = limits == null
          ? '当前会话尚未提供图片限制，图片入口已安全禁用。'
          : limits.validateBatch(
              existing: _attachments.map((item) => item.draft),
              incoming: incoming,
            );
    }
    if (reason == null) {
      for (final draft in incoming) {
        try {
          draft.validate();
        } on RelayFailure catch (failure) {
          reason = failure.message;
          break;
        }
      }
    }
    if (reason != null) {
      _attachmentRejections = [
        ..._attachmentRejections,
        AttachmentRejection(
          localName: incoming.map((draft) => draft.localName).join('、'),
          reason: '整批拒收：$reason',
        ),
      ];
      _errorMessage = reason;
      _notifyListeners();
      return false;
    }

    final incomingIds = incoming.map((draft) => draft.id).toSet();
    _attachments = [
      ..._attachments.where((item) => !incomingIds.contains(item.draft.id)),
      for (final draft in incoming)
        AttachmentTransfer(draft: draft, phase: AttachmentTransferPhase.queued),
    ];
    _rememberSelectedAttachments();
    _notifyListeners();
    return true;
  }

  void removeAttachment(String attachmentId) {
    _attachments = _attachments
        .where((item) => item.draft.id != attachmentId)
        .toList(growable: false);
    _rememberSelectedAttachments();
    _notifyListeners();
  }

  void dismissAttachmentRejection(String localName) {
    _attachmentRejections = _attachmentRejections
        .where((item) => item.localName != localName)
        .toList(growable: false);
    _notifyListeners();
  }

  /// 一个 attachment 在同一 session 内顺序上传。每块和 complete 都复用稳定幂等键，失败后从已确认块继续。
  Future<void> uploadAttachment({
    required String attachmentId,
    required String? deviceId,
    required bool canWrite,
  }) async {
    final sessionId = _selectedSessionId;
    final blocked = controlBlockedReason('attachments', canWrite: canWrite);
    final transfer = _attachmentByID(attachmentId);
    if (sessionId == null || transfer == null || blocked != null) {
      if (blocked != null) _setError(blocked);
      return;
    }
    final actionKey = 'attachment:$sessionId:$attachmentId';
    if (_pendingActionKeys.contains(actionKey) ||
        transfer.phase == AttachmentTransferPhase.completed) {
      return;
    }
    final lease = _selectedLease;
    if (lease == null || lease.sessionId != sessionId || lease.epoch <= 0) {
      _setError('会话暂不可操作，请稍后重试。');
      return;
    }

    _errorMessage = null;
    _pendingActionKeys.add(actionKey);
    _replaceAttachment(
      attachmentId,
      transfer.copyWith(
        phase: AttachmentTransferPhase.uploading,
        clearError: true,
      ),
    );
    _notifyListeners();
    try {
      var completedChunks = transfer.completedChunks;
      for (
        var index = completedChunks;
        index < transfer.draft.totalChunks;
        index += 1
      ) {
        await _relay.uploadAttachmentChunk(
          AttachmentChunkUploadInput(
            attachmentId: transfer.draft.id,
            sessionId: sessionId,
            mimeType: transfer.draft.mimeType,
            byteSize: transfer.draft.byteSize,
            compression: transfer.draft.compression,
            metadataCiphertext: transfer.draft.metadataCiphertext,
            chunkIndex: index,
            totalChunks: transfer.draft.totalChunks,
            ciphertext: transfer.draft.ciphertextChunks[index],
            idempotencyKey: _idempotencyKeyFor(
              'attachment:$sessionId:$attachmentId:chunk:$index',
            ),
            leaseEpoch: lease.epoch,
            deviceId: deviceId!,
          ),
        );
        completedChunks = index + 1;
        _replaceAttachment(
          attachmentId,
          transfer.copyWith(
            phase: AttachmentTransferPhase.uploading,
            completedChunks: completedChunks,
            clearError: true,
          ),
        );
        _notifyListeners();
      }
      await _relay.completeAttachment(
        AttachmentCompleteInput(
          attachmentId: transfer.draft.id,
          sessionId: sessionId,
          totalChunks: transfer.draft.totalChunks,
          idempotencyKey: _idempotencyKeyFor(
            'attachment:$sessionId:$attachmentId:complete',
          ),
          leaseEpoch: lease.epoch,
          deviceId: deviceId!,
        ),
      );
      _replaceAttachment(
        attachmentId,
        transfer.copyWith(
          phase: AttachmentTransferPhase.completed,
          completedChunks: transfer.draft.totalChunks,
          clearError: true,
        ),
      );
    } on RelayFailure catch (failure) {
      final current = _attachmentByID(attachmentId) ?? transfer;
      _replaceAttachment(
        attachmentId,
        current.copyWith(
          phase: AttachmentTransferPhase.failed,
          errorMessage: failure.message,
        ),
      );
      _errorMessage = failure.message;
    } catch (_) {
      const message = '附件上传未完成，请稍后重试。';
      final current = _attachmentByID(attachmentId) ?? transfer;
      _replaceAttachment(
        attachmentId,
        current.copyWith(
          phase: AttachmentTransferPhase.failed,
          errorMessage: message,
        ),
      );
      _errorMessage = message;
    } finally {
      _pendingActionKeys.remove(actionKey);
      _notifyListeners();
    }
  }

  bool isAttachmentPending(String attachmentId) =>
      _pendingActionKeys.any((key) => key.endsWith(':$attachmentId'));

  /// v0.2/P3：附件选文件入口的阻断原因；DEK 缺失时保持 fail-closed。
  String? attachmentPickBlockedReason({required bool canWrite}) {
    final blocked = controlBlockedReason('attachments', canWrite: canWrite);
    if (blocked != null) return blocked;
    if (!_contentKeyAvailable) return '等待会话附件密钥';
    if (_controls.imageLimits == null) return '等待图片限制投影';
    if (_picker == null) return '附件选择器不可用';
    return null;
  }

  /// v0.2/P3：真实选附件：选择 -> 本地校验 -> DEK 密封（SystemAttachmentPicker）-> 密文队列。
  /// fixture 模式由注入的确定性 picker 返回预密封草稿。
  Future<bool> pickAttachment({
    required String? deviceId,
    required bool canWrite,
  }) async {
    final sessionId = _selectedSessionId;
    final blocked = attachmentPickBlockedReason(canWrite: canWrite);
    if (sessionId == null || blocked != null) {
      if (blocked != null) _setError(blocked);
      return false;
    }
    final picker = _picker!;
    final actionKey = 'pick:$sessionId';
    if (_pendingActionKeys.contains(actionKey)) return false;
    _errorMessage = null;
    _pendingActionKeys.add(actionKey);
    _notifyListeners();
    try {
      final draft = await picker.pickAttachment(
        sessionId: sessionId,
        dekId: 'session-dek:$sessionId',
      );
      if (draft == null) return false;
      return addAttachmentDraft(draft);
    } on RelayFailure catch (failure) {
      _errorMessage = failure.message;
      return false;
    } catch (_) {
      _errorMessage = '附件选择未完成，请稍后重试。';
      return false;
    } finally {
      _pendingActionKeys.remove(actionKey);
      _notifyListeners();
    }
  }

  /// v0.2/P3：composer 内切换模型；目标必须在 controls.models 目录中，命令走 lease+幂等。
  Future<void> selectModel({
    required String model,
    required String? deviceId,
    required bool canWrite,
  }) async {
    final sessionId = _selectedSessionId;
    final blocked = controlBlockedReason('model_select', canWrite: canWrite);
    if (sessionId == null || blocked != null) {
      if (blocked != null) _setError(blocked);
      return;
    }
    final controls = _controls;
    final declaredModels = controls.models.isNotEmpty
        ? controls.models
        : selectedProviderCapabilities.optionsFor('model_select');
    if (!declaredModels.contains(model)) {
      _setError('目标模型不在当前目录中。');
      return;
    }
    // V094-24/25：每次显式操作独立幂等身份（同次传输重试复用该 key），
    // A→B→A→B 每次真实变更都必须到执行端，不再命中第一次 B 的旧命令；
    // 202 只标"切换中"，成功且权威投影一致才标已生效，null 不假报成功。
    final operation = 'model:$sessionId:$model:act-${_configActionCounter += 1}';
    final accepted = await _serializedConfigAction('model', () async {
      _setConfigConfirmation(
        ControlDomainConfirmation(
          domain: 'model',
          state: ControlConfirmState.confirming,
          requested: model,
        ),
      );
      return _submitCommand(
        sessionId: sessionId,
        operation: operation,
        kind: SessionCommandKind.modelSelect,
        deviceId: deviceId!,
        ciphertext: {
          'fixture_payload': {'model': model},
        },
        onTerminal: (terminal) {
          if (terminal == null) {
            _setConfigConfirmation(
              ControlDomainConfirmation(
                domain: 'model',
                state: ControlConfirmState.unknown,
                requested: model,
                detail: '确认结果未知，请稍后核验',
              ),
            );
            return;
          }
          // 成功：异步核验权威投影（不乐观写本地 effective）。
          unawaited(
            _verifyConfigConfirmation('model', model, (c) => c.model ?? ''),
          );
        },
      );
    });
    if (!accepted) return;
    // v0.8.6：自动带回该模型上次使用的推理等级，避免用户重复选择。
    // 校验双目录（新模型声明的 efforts + 会话当前目录）都包含该等级才回带；
    // 目录已变化时回退到 Host 默认，不发必败命令、不浮出误报错误。
    final remembered = _effortsByModel[model];
    if (remembered == null || remembered == _controls.effort) return;
    if (_controls.efforts.isEmpty || !_controls.efforts.contains(remembered)) {
      return;
    }
    final declaredEfforts =
        selectedProviderCapabilities
            .capability('model_select')
            .modelDetails[model]?.efforts ??
        const [];
    if (declaredEfforts.isNotEmpty && !declaredEfforts.contains(remembered)) {
      return;
    }
    await selectEffort(
      effort: remembered,
      deviceId: deviceId,
      canWrite: canWrite,
    );
  }

  /// v0.2/P3：composer 内切换 effort。
  Future<void> selectEffort({
    required String effort,
    required String? deviceId,
    required bool canWrite,
  }) async {
    final sessionId = _selectedSessionId;
    final blocked = controlBlockedReason('effort_select', canWrite: canWrite);
    if (sessionId == null || blocked != null) {
      if (blocked != null) _setError(blocked);
      return;
    }
    final controls = _controls;
    if (!controls.efforts.contains(effort)) {
      _setError('目标 effort 不在当前目录中。');
      return;
    }
    // V094-24/25：独立幂等身份 + 确认状态机（与 selectModel 同构）。
    final accepted = await _serializedConfigAction('effort', () async {
      _setConfigConfirmation(
        ControlDomainConfirmation(
          domain: 'effort',
          state: ControlConfirmState.confirming,
          requested: effort,
        ),
      );
      return _submitCommand(
        sessionId: sessionId,
        operation: 'effort:$sessionId:$effort:act-${_configActionCounter += 1}',
        kind: SessionCommandKind.effortSelect,
        deviceId: deviceId!,
        ciphertext: {
          'fixture_payload': {'effort': effort},
        },
        onTerminal: (terminal) {
          if (terminal == null) {
            _setConfigConfirmation(
              ControlDomainConfirmation(
                domain: 'effort',
                state: ControlConfirmState.unknown,
                requested: effort,
                detail: '确认结果未知，请稍后核验',
              ),
            );
            return;
          }
          unawaited(
            _verifyConfigConfirmation('effort', effort, (c) => c.effort ?? ''),
          );
        },
      );
    });
    if (!accepted) return;
    // v0.8.6：把等级记到当前模型名下，下次选回该模型时自动带回。
    final currentModel =
        controls.model ??
        controls.defaultModel ??
        selectedProviderCapabilities.capability('model_select').defaultOption;
    if (currentModel != null) {
      _rememberModelEffort(currentModel, effort);
    }
  }

  /// v0.3/P0：composer 内切换 permission mode（Happy sessionSetAgentModes 对齐）。
  Future<void> selectPermissionMode({
    required String mode,
    required String? deviceId,
    required bool canWrite,
  }) async {
    final sessionId = _selectedSessionId;
    final blocked = controlBlockedReason('permission_mode', canWrite: canWrite);
    if (sessionId == null || blocked != null) {
      if (blocked != null) _setError(blocked);
      return;
    }
    // v0.8.6 B：停止会话的 mode.set 会命中药 daemon 的 local_state_missing，
    // 客户端预检拦截并给出可执行原因（启动会话后再切换）。
    if (selectedSession?.status == MobileSessionStatus.stopped) {
      _setError('会话未运行，启动后可切换权限模式。');
      return;
    }
    final controls = _controls;
    if (!controls.availablePermissionModes.contains(mode)) {
      _setError('目标 permission mode 不在当前目录中。');
      return;
    }
    // V094-24/25：独立幂等身份 + 确认状态机（风险确认门在上游，展示名
    // 不影响确认语义）。权限生效以 daemon 模式快照同步为准。
    await _serializedConfigAction('permission', () async {
      _setConfigConfirmation(
        ControlDomainConfirmation(
          domain: 'permission',
          state: ControlConfirmState.confirming,
          requested: mode,
        ),
      );
      final accepted = await _submitCommand(
        sessionId: sessionId,
        operation:
            'permission-mode:$sessionId:$mode:act-${_configActionCounter += 1}',
        kind: SessionCommandKind.permissionModeSelect,
        deviceId: deviceId!,
        ciphertext: {
          'fixture_payload': {'mode_id': mode}, // v0.8.5 §3.5：payload key 与 runner 对齐
        },
        onTerminal: (terminal) {
          if (terminal == null) {
            _setConfigConfirmation(
              ControlDomainConfirmation(
                domain: 'permission',
                state: ControlConfirmState.unknown,
                requested: mode,
                detail: '确认结果未知，请稍后核验',
              ),
            );
            return;
          }
          unawaited(
            _verifyConfigConfirmation(
              'permission',
              mode,
              (c) => c.permissionMode ?? '',
            ),
          );
        },
      );
      if (!accepted) {
        _setConfigConfirmation(
          ControlDomainConfirmation(
            domain: 'permission',
            state: ControlConfirmState.failed,
            requested: mode,
            detail: _errorMessage,
          ),
        );
      }
    });
  }

  /// v0.3/P0：编辑当前目标文本（goal capability 门控；不泄漏密文正文）。
  Future<void> editGoal({
    required String objective,
    required String? deviceId,
    required bool canWrite,
  }) async {
    final sessionId = _selectedSessionId;
    final goal = _controls.goal;
    final blocked = controlBlockedReason('goal', canWrite: canWrite);
    if (sessionId == null || goal == null || blocked != null) {
      if (blocked != null) _setError(blocked);
      return;
    }
    final trimmed = objective.trim();
    if (trimmed.isEmpty) {
      _setError('目标文本不能为空。');
      return;
    }
    await _submitCommand(
      sessionId: sessionId,
      operation: 'goal-edit:$sessionId:${trimmed.hashCode}',
      kind: SessionCommandKind.goalEdit,
      deviceId: deviceId!,
      ciphertext: {
        'fixture_payload': {'objective': trimmed},
      },
      onAccepted: () => _controls = controls.copyWith(
        goal: SessionGoalSummary(
          title: trimmed,
          progressLabel: goal.progressLabel,
          phase: goal.phase,
        ),
      ),
    );
  }

  String? composerBlockedReason({required bool canWrite}) {
    if (!canWrite) return '当前设备是只读状态';
    if (_selectedSessionId == null) return '请选择一个会话';
    // lease 不再阻断输入：发送时会自动获取（见 _submitCommand），
    // 输入框与发送按钮始终可用，避免用户面对“暂不可操作”状态条。
    return null;
  }

  void clearError() {
    if (_errorMessage == null) return;
    _errorMessage = null;
    _notifyListeners();
  }

  /// 打开模型 seat 时重新读取当前会话目录；失败只返回 notice，不清空旧目录。
  ///
  /// 这样 reconnect 或 catalog reload 失败不会把原本可用的 Host target 假装成空目录。
  Future<String?> refreshSelectedControls() async {
    final sessionId = _selectedSessionId;
    if (sessionId == null) return '请选择一个会话。';
    final refreshed = await _runAction<SessionControlState?>(
      'controls-refresh:$sessionId',
      () => _relay.getSessionControls(sessionId),
    );
    if (refreshed == null) return _errorMessage ?? '模型目录暂时不可用，请重试。';
    if (_selectedSessionId != sessionId) return '会话已切换，请重新打开模型目录。';
    _controls = refreshed;
    _notifyListeners();
    return null;
  }

  /// 已知 slash command 是否声明了图片输入能力。
  ///
  /// 未知 slash 文本仍按普通消息处理；已知控制命令带图片时整次提交拒绝，
  /// 不消费 draft、引用或图片，避免命令载荷被部分提交。
  String? commandImageAdmissionError(String message) {
    if (!attachments.any((item) => item.draft.isImage)) return null;
    final token = message.trimLeft().split(RegExp(r'\s+')).first;
    const knownCommands = {
      '/goal',
      '/permission',
      '/model',
      '/export',
      '/feedback',
    };
    if (!knownCommands.contains(token)) return null;
    return '当前 $token 命令不支持图片附件，请移除图片后重试。';
  }

  /// 读取指定会话的草稿（仅内存；真实写入仍只在用户显式发送时发生）。
  String? composerDraftFor(String sessionId) => _composerDrafts[sessionId];

  SessionComposerSessionState composerStateFor(String sessionId) {
    return _composerStates[sessionId] ??
        SessionComposerSessionState(
          draft: _composerDrafts[sessionId] ?? '',
          references: const [],
          queue: const [],
        );
  }

  /// 保存完整 session-scoped input；attempt/claim 不进入 controller，避免跨路由复活。
  void saveComposerState(String sessionId, SessionComposerSessionState state) {
    if (sessionId.trim().isEmpty) return;
    final normalized = state.draft.length > 8192
        ? state.draft.substring(0, 8192)
        : state.draft;
    final next = state.copyWith(draft: normalized);
    _composerStates[sessionId] = next;
    if (normalized.isEmpty) {
      _composerDrafts.remove(sessionId);
    } else {
      _composerDrafts[sessionId] = normalized;
    }
  }

  /// 保存 composer 草稿。空文本与超过 8 KiB 的超长内容直接清除，防止内存被垃圾内容占用。
  void saveComposerDraft(String sessionId, String text) {
    if (sessionId.trim().isEmpty) return;
    final normalized = text.length > 8192 ? text.substring(0, 8192) : text;
    final prior = composerStateFor(sessionId);
    saveComposerState(sessionId, prior.copyWith(draft: normalized));
  }

  /// 发送成功后清除该会话草稿；草稿绝不落明文盘。
  void clearComposerDraft(String sessionId) {
    final prior = composerStateFor(sessionId);
    final hadDraft =
        _composerDrafts.remove(sessionId) != null ||
        prior.draft.isNotEmpty ||
        prior.references.isNotEmpty;
    if (hadDraft) {
      _composerStates[sessionId] = prior.copyWith(
        draft: '',
        references: const [],
      );
      _notifyListeners();
    }
  }

  /// v0.8.5 §3.1：把当前会话已完成上传的附件投影为 send 密文的 opaque refs。
  /// 只含白名单元数据（attachment_id/mime/尺寸/明文 sha256），不含文件名与正文；
  /// sha256 缺省（旧草稿）时省略该键，Daemon 侧解密后按登记值复算校验。
  List<Map<String, Object>> _completedAttachmentRefs(String sessionId) {
    // 附件队列以 _attachments 为当前会话事实源（_attachmentsBySession 只作切换缓存），
    // 因此直接读 _attachments；切换会话时该队列已被重置。
    final transfers = _attachments;
    final refs = <Map<String, Object>>[];
    for (final transfer in transfers) {
      if (transfer.phase != AttachmentTransferPhase.completed) continue;
      final draft = transfer.draft;
      refs.add({
        'attachment_id': draft.id,
        'mime': draft.mimeType,
        'size_bytes': draft.byteSize,
        if (draft.plaintextSHA256Hex != null)
          'sha256': draft.plaintextSHA256Hex!,
      });
    }
    return refs;
  }

  Future<void> _loadSelectedSession(String sessionId) async {
    if (_sessionById(sessionId) == null) {
      _setError('找不到所选会话。');
      return;
    }
    final previousSessionId = _selectedSessionId;
    if (previousSessionId != null && previousSessionId != sessionId) {
      _attachmentsBySession[previousSessionId] = List.unmodifiable(
        _attachments,
      );
    }
    final selectionGeneration = ++_selectionGeneration;
    _errorMessage = null;
    // v0.9.0 C6：切换会话取消上一选择的 stream/watchdog/退避。
    _stopSessionEventTransport();
    _historyErrorMessage = null;
    _historyLoading = false;
    _selectedSessionId = sessionId;
    _selectedLease = null;
    _contentKeyAvailable = false;
    // 在读取新会话前先清空上一会话 timeline。否则首次 snapshot 的 cursor 推导会误用旧序号，
    // 并可能遗漏新会话恢复事件或短暂展示错误的会话内容。
    _timeline = const [];
    _resolvedRequestKeys.clear();
    _skillConfirmation = null;
    _attachments = List.unmodifiable(
      _attachmentsBySession[sessionId] ?? const <AttachmentTransfer>[],
    );
    _attachmentRejections = const [];
    _controls = const SessionControlState.empty();
    _isDetailLoading = true;
    _notifyListeners();
    try {
      // 会话 DEK 可用性只影响附件选文件入口；异步读取不阻塞快照。
      unawaited(_loadContentKeyAvailability(sessionId, selectionGeneration));
      // 状态行"已连接/未连接"徽章消费能力快照。启动期缓存可能早于 daemon
      // 探测完成（或成功拿到"探测未完成"的暂态结果），因此打开会话时强制
      // 刷新一次（低频操作，单次 GET 可接受）；完成后 notifyListeners 让状态
      // 行以服务端当前事实重渲染。日常节流仍保护其他潜在调用方。
      unawaited(refreshCapabilities(force: true));
      final snapshot = await _relay.getSessionSnapshot(sessionId);
      if (_selectedSessionId != sessionId ||
          _selectionGeneration != selectionGeneration) {
        return;
      }
      _mergeSnapshot(snapshot);
      // v0.9.0 C4：打开并成功合并该会话快照后清除完成角标。
      _unseenCompletedSessionIds.remove(sessionId);
      // v0.9.0 C6：先成功合并一次目标会话快照，再用其 cursor 建立 SSE。
      _startSessionEventTransportIfNeeded(sessionId);
      final controls = await _relay.getSessionControls(sessionId);
      if (_selectedSessionId == sessionId &&
          _selectionGeneration == selectionGeneration) {
        _controls = controls;
      }
    } on RelayFailure catch (failure) {
      if (_selectedSessionId == sessionId &&
          _selectionGeneration == selectionGeneration) {
        _errorMessage = failure.message;
        _historyErrorMessage = failure.message;
      }
    } catch (_) {
      if (_selectedSessionId == sessionId &&
          _selectionGeneration == selectionGeneration) {
        _errorMessage = '会话内容暂时不可用，请稍后重试。';
        _historyErrorMessage = _errorMessage;
      }
    } finally {
      if (_selectedSessionId == sessionId &&
          _selectionGeneration == selectionGeneration) {
        _isDetailLoading = false;
        _notifyListeners();
      }
    }
  }

  /// 轮询命令终态回执。succeeded/accepted 等非失败终态返回回执；failed/rejected/
  /// cancelled/expired 返回回执；状态查询失败或超时返回 null，调用方自行决定
  /// 是否回退到"受理即确认"的旧语义。
  /// [maxAttempts] 缺省用 [receiptPollAttempts]（6s，快速反馈路径）；
  /// send 终态确认传 [sendReceiptPollAttempts]（30s，覆盖 daemon 重启投递时延，
  /// V093-04 / T4）。
  Future<SessionCommandReceipt?> _awaitCommandReceipt(
    String commandId, {
    int? maxAttempts,
    // V094：每拍回调——事务观察器用它把"已受理"升级为"处理中"（可信进展）。
    void Function()? onPoll,
  }) async {
    final attempts = maxAttempts ?? receiptPollAttempts;
    for (var attempt = 0; attempt < attempts; attempt += 1) {
      try {
        final receipt = await _relay.getSessionCommand(commandId);
        switch (receipt.status) {
          case 'failed':
          case 'rejected':
          case 'cancelled':
          case 'expired':
            return receipt;
          case 'succeeded':
            return receipt;
        }
      } on RelayFailure {
        return null;
      }
      onPoll?.call();
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return null;
  }

  /// 轮询命令终态。succeeded 返回 true；failed/rejected/cancelled/expired 返回
  /// false；状态查询失败或超时返回 true，避免确认链路故障阻塞既有受理语义。
  Future<bool> _awaitCommandTerminal(String commandId) async {
    final receipt = await _awaitCommandReceipt(commandId);
    return receipt == null || receipt.status == 'succeeded';
  }

  Future<bool> _submitCommand({
    required String sessionId,
    required String operation,
    required SessionCommandKind kind,
    required String deviceId,
    bool canWrite = true,
    Map<String, dynamic>? ciphertext,
    VoidCallback? onAccepted,
    bool awaitTurnCompletion = true,
    // v0.9.0 C1：send 的本地提交意图（newTurn/steer），在 202 受理分支用于
    // 决定回合锚点是重置还是继承。
    TurnSubmissionIntent submissionIntent = TurnSubmissionIntent.newTurn,
    // V094-23：send 提交/观察解耦。true 时 202 受理后立即返回 true，
    // 回执窗口与回合轮询由后台事务观察器接管；提交锁（全局 busy）不再
    // 覆盖整个 30s 回执窗口。非 send 命令忽略该参数。
    bool deferSendObservation = false,
    // V094-06：命令受理（拿到 Relay 命令 ID）即回调，供事务账本登记
    // currentCommandId；onAccepted（终态确认后回调）语义不变。
    void Function(String commandId)? onCommandAccepted,
    // V094-24：配置命令的终态回调——terminal 为 null（查询失败/超时）时也
    // 会回调，调用方据此进入"结果待确认"，绝不假报成功。提供本回调时
    // onAccepted 不再生效。
    void Function(SessionCommandReceipt? terminal)? onTerminal,
  }) async {
    // 写命令统一在这里自动确保 lease：调用方可能刚从前台/断网恢复，
    // 本地 lease 已作废，此刻静默补获取一次，避免把“暂不可操作”抛给用户。
    if (!await _ensureSelectedLeaseAuto(
      sessionId,
      deviceId: deviceId,
      canWrite: canWrite,
    )) {
      return false;
    }
    // v0.9.0 C2：回合状态可能被本命令改变的 kind 在实际提交前推进同步代际，
    // 使提交前发出的旧快照/旧回包在返回后按代际失配被丢弃（正常取消，不报错）。
    if (kind == SessionCommandKind.send ||
        kind == SessionCommandKind.abort) {
      _bumpSyncGeneration(sessionId);
    }
    final accepted = await _runAction<bool>(operation, () async {
      final lease = _selectedLease;
      if (lease == null || lease.sessionId != sessionId || lease.epoch <= 0) {
        throw const RelayFailure(
          RelayFailureKind.validation,
          '会话可操作状态已变化，请重试。',
        );
      }
      // v0.9.0 C2：本命令后续异步链携带的同步代际（提交前已推进）。
      final syncGeneration = _syncGenerations[sessionId] ?? 0;
      final command = SessionCommandInput(
        kind: kind,
        idempotencyKey: _idempotencyKeyFor(operation),
        leaseEpoch: lease.epoch,
        deviceId: deviceId,
        ciphertext: ciphertext,
      );
      final receipt = await _relay.submitSessionCommand(sessionId, command);
      if (kind == SessionCommandKind.send) {
        // v0.9.0 C1：202 即时受理分支——与命令终态/快照等待解耦。回合锚点
        // （acceptedAt + 2/60 分钟预算 + 意图）必须在这里原子记录，禁止等
        // _awaitCommandReceipt 或首批快照返回后才起算。相同幂等命令重试复用
        // 已有锚点（活动回合仍在时不重置），不得重复续期。
        _noteSendAcceptedAt202(sessionId, submissionIntent);
        // v0.8.7 门禁 2：send 受理即新回合埋点基线——首字延迟起点，同时清掉
        // 上一回合未对账的帧状态，避免跨回合长度串账。
        streamingTelemetry.observeSendAccepted();
        // V094-06：受理即登记命令 ID（事务账本），供消息级状态与关联展示。
        onCommandAccepted?.call(receipt.id);
        // V094-23：defer 模式下受理即收敛——30s 回执窗口/回合轮询由事务
        // 观察器接管，本 action 不再持有全局 busy。但保留旧
        // awaitTurnCompletion=false 的返回契约：「受理 + 首批快照」后就绪，
        // 用户发送的内容立即可见，不出现时间线空窗。
        if (deferSendObservation) {
          try {
            final authGenerationAtSubmit = _authGeneration;
            final first = await _relay.getSessionSnapshot(
              sessionId,
              afterSequence: _cursorFor(sessionId),
            );
            // 与 inline generationsStale 同口径三重守卫（认证/同步/会话归属）：
            // dispose/注销/切会话后的迟到回包必须安全丢弃（C7/C2 契约）。
            if (_authGeneration == authGenerationAtSubmit &&
                _selectedSessionId == sessionId &&
                _syncGenerations[sessionId] == syncGeneration) {
              _mergeSnapshot(first);
            }
          } catch (_) {
            // 首批快照失败不阻塞受理返回：观察器与前台刷新路径会补齐。
          }
          return true;
        }
      }
      if (_syncGenerations[sessionId] != syncGeneration) {
        // 提交等待期间代际已被推进（如并发 abort）：本链按正常取消收敛。
        return true;
      }
      if (onTerminal != null) {
        // V094-24：配置命令走显式终态回调。null（查询失败/超时）不触发
        // 成功回调，由调用方进入"结果待确认"；failed 抛错保留原值。
        final terminal = await _awaitCommandReceipt(receipt.id);
        if (terminal != null && terminal.status != 'succeeded') {
          onTerminal(terminal);
          throw const RelayFailure(
            RelayFailureKind.protocol,
            '操作未被会话执行端接受，请重试。',
          );
        }
        onTerminal(terminal);
      } else if (onAccepted != null) {
        // 执行端异步收口命令：受理（202）不代表成功。带乐观更新面的命令必须等
        // 终态确认，failed 视为失败浮出错误；确认链路不可用时退回受理即确认的
        // 旧行为，不放大故障。
        final confirmed = await _awaitCommandTerminal(receipt.id);
        if (!confirmed) {
          throw const RelayFailure(
            RelayFailureKind.protocol,
            '操作未被会话执行端接受，请重试。',
          );
        }
        onAccepted();
      }
      if (kind == SessionCommandKind.send && onAccepted == null) {
        // send 同样不能把受理当成功：Daemon 执行失败（如本机实例缺失
        // local_state_missing）必须立刻浮出并清掉乐观气泡，而不是让客户端在
        // 快照轮询耗尽后无限停留在生成中。终态查询不可用（null）时保持旧的
        // 快照轮询语义，不放大确认链路抖动。
        // v0.9.3 V093-04：send 用加长窗口（30s）——daemon 重启后的首条 send
        // 的失败回执可能晚于旧的 6s 窗口到达，窗口太短会让 LOCAL_STATE_MISSING
        // 自动恢复永远不触发（R18 云端 F4 的根因之一）。
        final terminal = await _awaitCommandReceipt(
          receipt.id,
          maxAttempts: sendReceiptPollAttempts,
        );
        // v0.9.3 V093-04 录屏复现修正：失败回执是**本命令自己的结果**，必须
        // 优先于同步代际守卫处理。SSE live 形态下 canonical 终态合并
        // （turn.completed(stopped) → _mergeSnapshot 收口）会先于回执读取推进
        // 同步代际，若先按代际静默 return true，LOCAL_STATE_MISSING 自动恢复
        // 会被当成「正常取消」吞掉——用户看到的是发送失败、会话停止、零恢复
        // 且无任何提示。失败路径代际容忍；成功/未知路径的代际守卫保持不变。
        if (terminal != null && terminal.status != 'succeeded') {
          // 执行端可能已经把会话收口为 idle，但失败回执本身不包含 session
          // 投影；先补拉一次快照，避免旧的 streaming 状态继续留在 UI。
          await _bestEffortRefreshAfterCommandFailure(sessionId);
          // v0.9.2 G4 修正（R15 真机暴露）：把执行侧的具体原因（error_code）带进错误面。
          // 原实现只报「命令 failed」，造成两个后果：
          //   1) 用户看不到"为什么失败"，只看到通用文案——与 G4「错误可见且可区分」冲突；
          //   2) 上层无法据此判定**可重试类别**：Daemon 重启后的 LOCAL_STATE_MISSING
          //      本可自动 resume 重试，却因为文案里没有这个标记被当成真实故障，
          //      用户被卡在「显示空闲却发不出去」。
          final reason = (terminal.errorCode ?? '').trim();
          throw RelayFailure(
            RelayFailureKind.protocol,
            reason.isEmpty
                ? '消息发送失败（命令 ${terminal.status}），请查看时间线中的失败提示。'
                : '消息发送失败（命令 ${terminal.status} · $reason），请查看时间线中的失败提示。',
          );
        }
        if (_syncGenerations[sessionId] != syncGeneration) {
          // 提交等待期间代际已被推进（如并发 abort）：本链按正常取消收敛。
          return true;
        }
      }
      if (kind == SessionCommandKind.abort) {
        final terminal = await _awaitCommandReceipt(receipt.id);
        if (terminal != null && terminal.status != 'succeeded') {
          throw RelayFailure(
            RelayFailureKind.protocol,
            '中止命令未成功（${terminal.status}），当前回合仍可能继续。',
          );
        }
      }
      // v0.8.7 门禁 2：send 回合内的轮询批次采样——记录每次快照拉取的耗时与
      // 本批新事件量，作为 delta 到达节奏（since_last_ms 之外的佐证面）。
      Future<SessionSnapshot> timedPollFetch(int attempt, {int afterSequence = 0}) async {
        final watch = Stopwatch()..start();
        final snapshot = await _relay.getSessionSnapshot(
          sessionId,
          afterSequence: afterSequence,
        );
        watch.stop();
        streamingTelemetry.observePoll(
          sessionId: sessionId,
          attempt: attempt,
          newEvents: snapshot.events.length,
          fetchMs: watch.elapsedMilliseconds,
        );
        return snapshot;
      }

      // v0.9.0 C2：代际守卫。每次 await 后校验认证/同步代际与会话归属；
      // 失配属于正常取消（steer/中止/新回合/认证切换已接管），静默退出。
      // 会话切换不在此处硬取消：本任务跟随会话（C3——切走时跳过合并，
      // 切回同一会话后继续恢复合并），页面级隔离由 selectionGeneration
      // 在 _loadSelectedSession 等选择路径上执行。
      final authGenerationAtSubmit = _authGeneration;
      bool generationsStale() =>
          _authGeneration != authGenerationAtSubmit ||
          _syncGenerations[sessionId] != syncGeneration ||
          (_selectedSessionId != null && _selectedSessionId != sessionId);

      // 提交后模型需要数秒才产出事件；首次拉取时 message.completed 多半尚未落库。
      // 每一批都合并，直到明确的 completed_turn 或非 streaming 状态到达，
      // 否则只合并第一批会把回复显示出来却遗留“生成中”状态。
      var latest = await timedPollFetch(0);
      if (generationsStale()) return true;
      if (_selectedSessionId == sessionId) _mergeSnapshot(latest);
      var completed = _snapshotCompletesTurn(latest);
      if (kind == SessionCommandKind.send && !completed && awaitTurnCompletion) {
        // 免费模型一轮常见 30-60s；轮询窗口必须覆盖典型回合并，
        // 否则回复落地后客户端仍停留在“生成中”，只能重进会话恢复。
        final attempts = foregroundPollAttempts;
        for (var i = 0; i < attempts; i++) {
          // v0.8.7：在途窗口使用收紧档（250ms）——打字机渲染的到达粒度由
          // 此决定；窗口 attempts 结构与超时收敛语义不变（v0.8.6 A①）。
          await Future<void>.delayed(activePollInterval);
          if (generationsStale()) return true;
          // v0.9.0 C6：SSE live 时由 wake 驱动快照，跳过本拍在途轮询。
          if (_transportSuppressesPolling(sessionId)) continue;
          latest = await timedPollFetch(
            i + 1,
            afterSequence: latest.session.lastSequence,
          );
          // 即使本批没有新事件，也要合并 session.status。事件可能已在前一批
          // 被消费，而执行端随后才把 streaming 收口为 idle。
          if (generationsStale()) return true;
          if (_selectedSessionId == sessionId) {
            _mergeSnapshot(latest, appendTimeline: true);
            // v0.9.0 C1：每拍按锚点评估 UX deadline（2 分钟只切 UX 表达）。
            _evaluateTurnDeadlines(sessionId);
            // v0.8.7 打字机流式的核心一环：在途批次合并后必须通知 UI，气泡
            // 文本才随 delta 逐步生长；否则时间线只在回合终态一次性出现。
            _notifyListeners();
          }
          completed = _snapshotCompletesTurn(latest);
          if (completed) break;
        }
      }
      if (kind == SessionCommandKind.send && completed) {
        // 终态已由 _mergeSnapshot 的 canonical 收口路径移除活动回合；
        // 这里只负责刷新 controls。
        await _refreshControlsAfterTurn(sessionId);
      }
      if (kind == SessionCommandKind.send &&
          !completed &&
          !generationsStale()) {
        // ignore: avoid_print
        // v0.8.6 A①：前台窗口（60s）结束仍无终态时，必须继续后台轮询直到
        // 有界总窗口（再 60s）。原实现只覆盖 awaitTurnCompletion=false 的
        // 调用方；默认路径 60s 后无人续驱，"处理中"会永久驻留。
        unawaited(_pollTurnCompletionInBackground(sessionId, latest));
      }
      return true;
    });
    return accepted == true;
  }

  /// v0.9.0 C1：Relay 202 即时受理分支。send 的回合运行期锚点在这里原子记录：
  /// - newTurn：新建活动回合状态（acceptedAt=当前单调时刻，2/60 分钟预算起算，
  ///   清除上一轮本地超时标记）。相同幂等命令重试到达时活动回合仍在——复用已有
  ///   锚点，不重复续期。
  /// - steer：不创建新业务回合、不清超时、不重置续轮期限，完全继承原锚点；
  ///   本机无锚点（进程重启恢复/他端发起的活动回合）时以本次受理观察的单调
  ///   时刻建立运行期锚点（observedAt 口径）。
  /// 同时把回合在途标记置位——composer 主按钮在 202 即切换为"中断"，
  /// 不等首批快照。
  void _noteSendAcceptedAt202(String sessionId, TurnSubmissionIntent intent) {
    final nowMs = monotonicElapsed().inMilliseconds;
    final existing = _activeTurns[sessionId];
    if (intent == TurnSubmissionIntent.steer) {
      if (existing != null) {
        // 继承原业务回合起点、超时标记与期限；不重置预算。
        return;
      }
      _activeTurns[sessionId] = SessionActiveTurn(
        sessionId: sessionId,
        intent: intent,
        monotonicAnchorMs: nowMs,
      );
    } else {
      if (existing != null) {
        // 上一回合尚未终态时收到的 newTurn 受理（同 command 幂等重试）：
        // 复用已有锚点，禁止重复续期。
        return;
      }
      _activeTurns[sessionId] = SessionActiveTurn(
        sessionId: sessionId,
        intent: intent,
        monotonicAnchorMs: nowMs,
      );
      // 新回合受理即清除上一轮的本地超时标记（重新计时）。
      _turnTimedOut.remove(sessionId);
    }
    // v0.9.2 R17：deadline 节拍与传输解耦——SSE live 抑制轮询/L1 拉取后，
    // 超时评估必须有自己的节拍，否则悬挂回合永远收敛不了。
    _ensureTurnDeadlineTimer();
    _notifyListeners();
  }

  /// 回合完成后台轮询：继续按 500ms 合并快照直到终态，并在终态后刷新
  /// controls。带会话守卫与 v0.9.0 三重代际守卫，切换会话/认证切换/新同步
  /// 代际后自动停止（正常取消，不显示错误）。
  Future<void> _pollTurnCompletionInBackground(
    String sessionId,
    SessionSnapshot latest,
  ) async {
    final attempts = backgroundPollAttempts;
    // ignore: avoid_print
    // v0.9.0 C2：捕获本任务的认证/同步代际；任何失配即退出（正常取消）。
    // 选择代际不在此处校验：切换会话由下方的会话归属检查终止本任务（C3），
    // 同会话页面重挂载后由重新加载路径接管。
    final authGenerationAtStart = _authGeneration;
    final syncGenerationAtStart = _syncGenerations[sessionId] ?? 0;
    bool generationsStale() =>
        _authGeneration != authGenerationAtStart ||
        _syncGenerations[sessionId] != syncGenerationAtStart;
    var completed = _snapshotCompletesTurn(latest);
    // v0.8.7 门禁 2：后台轮询批次同样采样；attempt 从前台窗口之后续号。
    const foregroundAttemptBaseline = 121;
    for (var i = 0; i < attempts && !completed; i++) {
      await Future<void>.delayed(pollInterval);
      // v0.9.0 C2：休眠醒来先验代际，失配即正常取消（不发起任何新请求）。
      if (generationsStale()) return;
      // v0.9.0 C6：SSE live 时由 wake 驱动快照，暂停在途轮询拉取。
      if (_transportSuppressesPolling(sessionId)) continue;
      try {
        final watch = Stopwatch()..start();
        latest = await _relay.getSessionSnapshot(
          sessionId,
          afterSequence: latest.session.lastSequence,
        );
        watch.stop();
        streamingTelemetry.observePoll(
          sessionId: sessionId,
          attempt: foregroundAttemptBaseline + i,
          newEvents: latest.events.length,
          fetchMs: watch.elapsedMilliseconds,
        );
      } catch (_) {
        // 单次快照失败不终止轮询；下一拍继续。
        continue;
      }
      if (_selectedSessionId != sessionId) return;
      // v0.9.0 C2：代际失配即正常取消——新回合/steer 已接管该会话的同步。
      if (generationsStale()) return;
      _mergeSnapshot(latest, appendTimeline: true);
      // v0.9.0 C1：每拍按锚点评估 UX deadline（2 分钟只切 UX 表达）。
      _evaluateTurnDeadlines(sessionId);
      // v0.8.7：后台续轮同样通知 UI，保证非本端可见窗口的流式生长。
      _notifyListeners();
      completed = _snapshotCompletesTurn(latest);
    }
    // v0.9.0 C2：窗口结束后的终态写入同样要过代际守卫；失配时不得改写
    // 当前回合的任何状态（包括超时标记与在途标记）。
    if (generationsStale()) return;
    if (completed) {
      _turnTimedOut.remove(sessionId);
      await _refreshControlsAfterTurn(sessionId);
    } else {
      // v0.9.0 C1（seq48 事故根因修复）：有界后台窗口耗尽仍无终态时，不再
      // "停止数据同步"、不伪造终态、不停止回合事实——按锚点评估 deadline
      // （已到 2 分钟则切 UX 超时表达），并交接给 L1 10 秒降频续轮继续同步，
      // 直到 canonical 终态或 60 分钟续轮期限。迟到的 daemon 看门狗事实事件
      // 仍按事件校正清除超时。
      _evaluateTurnDeadlines(sessionId);
      if (generationsStale()) return;
      unawaited(_runL1DegradedPolling(sessionId));
    }
  }

  // ─── v0.9.0 C4：L3 quiet reconcile ─────────────────────────────────────
  /// quiet reconcile 启停（lifecycle recovery 驱动）。开启时启动全局周期拍；
  /// 前台恢复的即时首拍由 recovery 在 cursor recovery 后显式触发一次，
  /// Timer.periodic 首拍在完整间隔之后——二者不叠加。
  void setQuietReconcileActive(bool active) {
    if (_quietReconcileActive == active) return;
    _quietReconcileActive = active;
    if (active && !_disposed) {
      _quietReconcileTimer ??= Timer.periodic(
        quietReconcileInterval,
        (_) => unawaited(quietReconcileTick()),
      );
    } else {
      _quietReconcileTimer?.cancel();
      _quietReconcileTimer = null;
    }
  }

  /// L3 一拍：quiet list reconcile + 差异快照调度。
  /// 约束（C4）：不把列表切 loading/error、不覆盖已有列表；失败只记脱敏状态
  /// 等下一拍；只比较本地与远端的 status/lastSequence，status 翻转优先于仅序号
  /// 前进；每拍最多 [quietReconcileBatchSize] 个快照、并发最多
  /// [quietReconcileConcurrency]，正在被 L1/SSE/手动拉取的会话由单航班去重。
  Future<void> quietReconcileTick() async {
    if (_disposed || !_quietReconcileActive) return;
    if (!_hasObservableActiveTurns) return;
    List<MobileSession> remote;
    try {
      remote = await _listSessionsShared();
    } catch (_) {
      // quiet 路径不触发列表错误态；等待下一拍。
      return;
    }
    if (_disposed || !_quietReconcileActive) return;
    final flipped = <String>[];
    final advanced = <String>[];
    for (final remoteSession in remote) {
      final local = _sessionById(remoteSession.id);
      if (local == null) continue;
      if (remoteSession.status != local.status) {
        flipped.add(remoteSession.id);
      } else if (remoteSession.lastSequence > local.lastSequence) {
        advanced.add(remoteSession.id);
      }
    }
    // 状态翻转优先于仅序号前进；每拍限量，未处理项留到后续拍。
    final batch = [...flipped, ...advanced].take(quietReconcileBatchSize);
    var index = 0;
    final ids = batch.toList(growable: false);
    Future<void> worker() async {
      while (index < ids.length && !_disposed && _quietReconcileActive) {
        final id = ids[index++];
        await _runSnapshotTurn(id, () => _reconcileSnapshotTurn(id));
      }
    }
    await Future.wait([
      for (var i = 0; i < quietReconcileConcurrency; i++) worker(),
    ]);
  }

  /// L3 差异快照回合并：只读增量，失败不置角标、不进错误态（下一拍重试）。
  Future<void> _reconcileSnapshotTurn(String sessionId) async {
    final authGenerationAtStart = _authGeneration;
    try {
      final snapshot = await _relay.getSessionSnapshot(
        sessionId,
        afterSequence: _cursorFor(sessionId),
      );
      if (_disposed || _authGeneration != authGenerationAtStart) return;
      _mergeSnapshot(snapshot, appendTimeline: true);
      _notifyListeners();
    } catch (_) {
      // 单次失败保留现状；下一拍/L1/手动刷新仍可发现事实。
    }
  }

  /// v0.9.0 C1/T7：按单调锚点评估回合 deadline。到达 2 分钟 UX deadline 只切换
  /// UX 表达（超时标记 + 清账乐观回显 + 通知），活动回合事实与同步任务保持；
  /// 等待时长唯一来源是锚点，禁止 poll attempts×interval 或服务端时间推导。
  void _evaluateTurnDeadlines(String sessionId) {
    final turn = _activeTurns[sessionId];
    if (turn == null || turn.timedOut) return;
    if (monotonicElapsed().inMilliseconds < turn.uxDeadlineMs) return;
    turn.timedOut = true;
    _turnTimedOut.add(sessionId);
    // 超时清账乐观回显（canonical user_message 多半已入时间线；本次发送已失败
    // 时不留永久回显）。空草稿仍允许用户中止，有草稿走既有 queue/steer 交互。
    _pendingOutgoingBySession.remove(sessionId);
    _notifyListeners();
  }

  /// v0.9.2 R17：deadline 评估与传输解耦的节拍器。C6 起 SSE live 时在途轮询与
  /// L1 都跳过拉取、SSE 空轮询也不触发 wake——若执行侧对受理的回合静默无事件
  /// （无 turn.phase、无终态，实测 R17：resume 只恢复句柄不产生任何状态事件），
  /// deadline 评估就没有任何调用点，UI 会永远停留在"生成中"。这里以固定节拍
  /// 独立评估所有活跃回合；无活跃回合时自取消，全程不产生任何网络请求。
  @visibleForTesting
  Duration turnDeadlineTickInterval = const Duration(seconds: 5);
  Timer? _turnDeadlineTimer;

  /// V094-23 终态接力的可取消节拍（dispose 时取消并唤醒等待者）。
  Timer? _turnObserverTimer;
  Completer<void>? _turnObserverWaiter;

  /// 202 锚定即武装节拍器（幂等）；测试经 [turnDeadlineTickArmed] 与
  /// [evaluateTurnDeadlineTick] 直接驱动。
  void _ensureTurnDeadlineTimer() {
    if (_disposed || _turnDeadlineTimer != null) return;
    _turnDeadlineTimer = Timer.periodic(turnDeadlineTickInterval, (_) {
      if (_disposed || _activeTurns.isEmpty) {
        _turnDeadlineTimer?.cancel();
        _turnDeadlineTimer = null;
        return;
      }
      evaluateTurnDeadlineTick();
    });
  }

  /// 是否仍有未收敛的 deadline 节拍器（测试观测用）。
  @visibleForTesting
  bool get turnDeadlineTickArmed => _turnDeadlineTimer != null;

  /// 节拍一次：评估所有活跃回合的 UX deadline。
  /// [_evaluateTurnDeadlines] 自带幂等（已置位/未到期的回合零变更零通知），
  /// 因此节拍本身不会产生通知风暴。
  @visibleForTesting
  void evaluateTurnDeadlineTick() {
    for (final sessionId in List<String>.of(_activeTurns.keys)) {
      _evaluateTurnDeadlines(sessionId);
    }
  }

  /// v0.9.0 C1/T7：L1 降频续轮——选中会话 10 秒一拍（单会话 0.1 QPS），
  /// 从已合并 cursor 增量拉快照直到 canonical 终态；到 60 分钟 continuation
  /// deadline 只停止该任务并保留超时提示。切换会话/认证切换/新同步代际按
  /// 正常取消退出；SSE（P4）与 L3（P3）仍可独立发现迟到事实。
  @visibleForTesting
  Duration l1PollInterval = const Duration(seconds: 10);

  Future<void> _runL1DegradedPolling(String sessionId) async {
    final authGenerationAtStart = _authGeneration;
    final syncGenerationAtStart = _syncGenerations[sessionId] ?? 0;
    bool stale() =>
        _disposed ||
        _authGeneration != authGenerationAtStart ||
        _syncGenerations[sessionId] != syncGenerationAtStart ||
        _selectedSessionId != sessionId;
    while (true) {
      if (stale()) return;
      final turn = _activeTurns[sessionId];
      if (turn == null) return;
      // 到期只停止该任务并保留超时提示；不伪造终态、不清活动回合。
      if (monotonicElapsed().inMilliseconds >= turn.continuationDeadlineMs) {
        return;
      }
      await Future<void>.delayed(l1PollInterval);
      if (stale()) return;
      // v0.9.0 C6：SSE live 时由 wake 驱动快照，L1 保留但跳过拉取。
      if (_transportSuppressesPolling(sessionId)) continue;
      try {
        final snapshot = await _relay.getSessionSnapshot(
          sessionId,
          afterSequence: _cursorFor(sessionId),
        );
        if (stale()) return;
        _mergeSnapshot(snapshot, appendTimeline: true);
        // 终态合并在 _mergeSnapshot 内推进同步代际，下一拍由 stale() 退出。
        if (stale()) return;
        _evaluateTurnDeadlines(sessionId);
        _notifyListeners();
      } catch (_) {
        // 单次快照失败不终止续轮；下一拍继续（轮询托底语义）。
      }
    }
  }

  Future<void> _refreshControlsAfterTurn(String sessionId) async {
    try {
      final controls = await _relay.getSessionControls(sessionId);
      if (_selectedSessionId == sessionId) {
        _controls = controls;
        _notifyListeners();
      }
    } catch (_) {
      // A usage projection can lag the event upload. The next snapshot/recovery
      // will retry controls without turning a successful send into an error.
    }
  }

  /// 发送命令已在执行端失败时，补拉一次只读快照收口 session.status 和事件。
  /// 刷新失败不能覆盖原始发送错误，也不能把失败变成成功。
  /// v0.9.0 C2：经每会话单航班门执行，避免与其它快照来源并发重复。
  Future<void> _bestEffortRefreshAfterCommandFailure(String sessionId) async {
    if (_selectedSessionId != sessionId) return;
    await _runSnapshotTurn(sessionId, () async {
      try {
        final snapshot = await _relay.getSessionSnapshot(
          sessionId,
          afterSequence: _cursorFor(sessionId),
        );
        if (_selectedSessionId == sessionId) {
          _mergeSnapshot(snapshot, appendTimeline: true);
        }
      } catch (_) {
        // Keep the command failure as the user-visible error when recovery is unavailable.
      }
    });
  }

  bool _snapshotCompletesTurn(SessionSnapshot snapshot) {
    if (snapshot.session.status != MobileSessionStatus.streaming) return true;
    final events = snapshot.events
        .map(SessionTimelineEvent.fromRelayEvent)
        .toList(growable: false);
    // Fixture turns deliberately pause at permission/question waits. They are
    // no longer generating from the user's perspective, so do not hold the
    // command poll open while preserving the pending interaction UI.
    if (events.any(
      (event) =>
          (event.permission != null && event.permission!.resolved != true) ||
          (event.question != null && event.question!.resolved != true),
    )) {
      return true;
    }
    return events.any((event) => event.completedTurn);
  }

  /// 流式合并：连续的 assistant 流式增量坍缩为单个生长节点（打字机）；非流式的
  /// message.completed 全文替换其前的流式节点，避免"生长气泡 + 完整气泡"并排。
  /// 空 completed_turn 终态标记并入上一条真实消息，避免尾标残留为“运行中”。
  ///
  /// v0.8.4（ADR-015 §5）：thought 通道按同种类独立折叠——localdev 编码器对
  /// 每条 thought 增量回发全量已收文本，同一身份的连续流式帧坍缩为一个生长
  /// 节点；thought 与 assistant 之间天然以 kind 区分，绝不互相并入。
  List<SessionTimelineEvent> _coalesceStreaming(
    List<SessionTimelineEvent> events,
  ) {
    final out = <SessionTimelineEvent>[];
    for (final event in events) {
      if (_isCoalescibleStreamMessage(event) &&
          event.completedTurn &&
          event.text?.trim().isNotEmpty != true) {
        final index = _findLastTurnMessageIndex(out, event);
        if (index != null) {
          out[index] = _settleTurnMessage(out[index], event);
          continue;
        }
      }

      // V094 收口（真机观察项）：思考流的跨节点累积。localdev/真实桥的
      // thought_delta 不携带 messageId（全量已收文本语义），且思考流中间
      // 会穿插 assistant completed 消息——相邻折叠判不到。同回合内
      // （中间无 user message / turn 终态）最后一条 streaming thought 就是
      // 同一思考流的演进，直接整体替换，不再产生第二个「思考中」节点。
      if (event.kind == SessionTimelineKind.assistantThought &&
          event.isStreaming &&
          (event.messageId?.trim().isEmpty ?? true)) {
        final thoughtIndex = _findLastStreamingThoughtIndexInTurn(out);
        if (thoughtIndex != null) {
          out[thoughtIndex] = event;
          continue;
        }
      }

      final last = out.isEmpty ? null : out.last;
      final lastMessageIndex =
          _isCoalescibleStreamMessage(event) && event.isStreaming
          ? _findLastTurnMessageIndex(out, event)
          : null;
      final lastMessage = lastMessageIndex == null
          ? null
          : out[lastMessageIndex];
      final duplicateLateStreamingFrame =
          lastMessage != null &&
          _isCoalescibleStreamMessage(event) &&
          event.isStreaming &&
          !lastMessage.isStreaming &&
          _sameStreamMessageIdentity(lastMessage, event) &&
          _sameNonEmptyText(lastMessage, event);
      if (duplicateLateStreamingFrame) {
        continue;
      }

      // 同类（answer/thought 各自独立）且上一帧仍在流式：增量帧与同一身份的
      // completed 帧都整体替换上一帧；身份变化（新消息）另起新节点。
      final replacesStreaming =
          last != null &&
          _isCoalescibleStreamMessage(last) &&
          _isCoalescibleStreamMessage(event) &&
          last.isStreaming &&
          (event.text?.trim().isNotEmpty == true || !event.completedTurn) &&
          _sameStreamMessageIdentity(last, event);
      if (replacesStreaming) {
        out[out.length - 1] = event;
        continue;
      }
      out.add(event);
    }
    return out;
  }

  /// 从列表尾向回找同回合内最后一条 streaming 思考节点。
  /// 回合边界：canonical user message（新一轮输入）或 completedTurn 终态——
  /// 越过边界说明上一回合的思考流已终结，不得合并。
  /// V094 收口测试辅助：直接合并一次快照（公开折叠行为给 widget/单测）。
  @visibleForTesting
  void debugMergeSnapshotForTest(String sessionId, SessionSnapshot snapshot) {
    _selectedSessionId ??= sessionId;
    _mergeSnapshot(snapshot, appendTimeline: true);
  }

  int? _findLastStreamingThoughtIndexInTurn(
    List<SessionTimelineEvent> events,
  ) {
    for (var index = events.length - 1; index >= 0; index -= 1) {
      final event = events[index];
      if (event.kind == SessionTimelineKind.userMessage ||
          event.completedTurn) {
        return null;
      }
      if (event.kind == SessionTimelineKind.assistantThought &&
          event.isStreaming) {
        return index;
      }
    }
    return null;
  }

  bool _isCoalescibleStreamMessage(SessionTimelineEvent event) =>
      event.kind == SessionTimelineKind.assistantMessage ||
      event.kind == SessionTimelineKind.assistantThought;

  bool _sameStreamMessageIdentity(
    SessionTimelineEvent left,
    SessionTimelineEvent right,
  ) {
    if (left.kind != right.kind) return false;
    final leftId = left.messageId?.trim() ?? '';
    final rightId = right.messageId?.trim() ?? '';
    return leftId.isEmpty || rightId.isEmpty || leftId == rightId;
  }

  bool _sameNonEmptyText(
    SessionTimelineEvent left,
    SessionTimelineEvent right,
  ) {
    final leftText = left.text?.trim();
    final rightText = right.text?.trim();
    return leftText != null &&
        leftText.isNotEmpty &&
        rightText != null &&
        rightText.isNotEmpty &&
        leftText == rightText;
  }

  int? _findLastTurnMessageIndex(
    List<SessionTimelineEvent> events,
    SessionTimelineEvent terminalEvent,
  ) {
    for (var index = events.length - 1; index >= 0; index -= 1) {
      final candidate = events[index];
      if (candidate.kind == SessionTimelineKind.userMessage) return null;
      if (!_isCoalescibleStreamMessage(candidate)) continue;
      if (_sameStreamMessageIdentity(candidate, terminalEvent)) return index;
    }
    return null;
  }

  SessionTimelineEvent _settleTurnMessage(
    SessionTimelineEvent message,
    SessionTimelineEvent terminalEvent,
  ) {
    final terminalText = terminalEvent.text?.trim().isNotEmpty == true
        ? terminalEvent.text
        : null;
    final text = terminalText ?? message.text;
    final copyText = terminalEvent.copyText ?? message.copyText ?? text;
    return SessionTimelineEvent(
      sequence: message.sequence,
      kind: message.kind,
      label: message.label,
      text: text,
      errorCode: terminalEvent.errorCode ?? message.errorCode,
      httpStatus: terminalEvent.httpStatus != 0
          ? terminalEvent.httpStatus
          : message.httpStatus,
      isStreaming: false,
      toolStatus: terminalEvent.toolStatus ?? message.toolStatus,
      permission: terminalEvent.permission ?? message.permission,
      question: terminalEvent.question ?? message.question,
      messageId: terminalEvent.messageId ?? message.messageId,
      createdAt: terminalEvent.createdAt ?? message.createdAt,
      copyText: copyText,
      completedTurn: true,
      forkAvailable: terminalEvent.forkAvailable || message.forkAvailable,
      pendingSteering: terminalEvent.pendingSteering || message.pendingSteering,
      referenceLabels: terminalEvent.referenceLabels.isNotEmpty
          ? terminalEvent.referenceLabels
          : message.referenceLabels,
      filePath: terminalEvent.filePath ?? message.filePath,
      toolInput: terminalEvent.toolInput ?? message.toolInput,
      toolOutput: terminalEvent.toolOutput ?? message.toolOutput,
      inspectTarget: terminalEvent.inspectTarget ?? message.inspectTarget,
      producedFilePaths: terminalEvent.producedFilePaths.isNotEmpty
          ? terminalEvent.producedFilePaths
          : message.producedFilePaths,
      toolSubcalls: terminalEvent.toolSubcalls.isNotEmpty
          ? terminalEvent.toolSubcalls
          : message.toolSubcalls,
      phase: terminalEvent.phase ?? message.phase,
      phaseReason: terminalEvent.phaseReason ?? message.phaseReason,
      phaseRevision: max(terminalEvent.phaseRevision, message.phaseRevision),
      thoughtVisibility:
          terminalEvent.thoughtVisibility ?? message.thoughtVisibility,
      thoughtSummary: terminalEvent.thoughtSummary || message.thoughtSummary,
    );
  }

  void _mergeSnapshot(SessionSnapshot snapshot, {bool appendTimeline = false}) {
    // v0.9.0 C3：记录客户端成功合并事件的时刻（墙钟），供超时横幅新鲜度
    // 次级行展示；服务端时间只用于事件展示，不用于网络健康判断。
    _lastSnapshotMergedAt[snapshot.session.id] = _clock();
    // 以 sequence 为唯一序：重复投递去重、乱序排序，replace 与 append 两条路径同规。
    final incoming =
        <int, SessionTimelineEvent>{
            for (final event in snapshot.events)
              event.sequence: SessionTimelineEvent.fromRelayEvent(event),
          }.values.toList()
          ..sort((left, right) => left.sequence.compareTo(right.sequence));
    // v0.8.7 门禁 2：逐帧流式埋点。只喂 assistant/thought 通道（工具、相位、
    // 权限等与流式无关）；sink 内部以会话级 seq 高水位去重，快照全量重解析
    // 或重复投递不会产生重复埋点；正文不入 sink（审计红线）。
    for (final event in incoming) {
      final isAssistant = event.kind == SessionTimelineKind.assistantMessage;
      final isThought = event.kind == SessionTimelineKind.assistantThought;
      if (!isAssistant && !isThought) continue;
      streamingTelemetry.observeStreamingFrame(
        sessionId: snapshot.session.id,
        seq: event.sequence,
        kind: isAssistant ? 'assistant' : 'thought',
        messageId: event.messageId,
        text: event.text,
        streaming: event.isStreaming,
      );
    }
    final session =
        incoming.any((event) => event.completedTurn) &&
            snapshot.session.status == MobileSessionStatus.streaming
        ? snapshot.session.copyWith(status: MobileSessionStatus.idle)
        : snapshot.session;
    _sessions = [
      session,
      ..._sessions.where((item) => item.id != snapshot.session.id),
    ];
    // v0.8.6 A①：终态事实优先于本地超时提示——迟到的 daemon 看门狗事件或
    // Provider 终态到达时，按事件校正、清除本地"回合超时"标记。
    if (_turnTimedOut.isNotEmpty &&
        (incoming.any((event) => event.completedTurn) ||
            snapshot.session.status != MobileSessionStatus.streaming)) {
      _turnTimedOut.remove(snapshot.session.id);
    }
    // v0.9.0 C1：canonical 终态收口——活动回合事实只由服务端事实解除
    // （终态事件，或会话进入 idle/stopped/errored），本地 UX 超时永远不伪装
    // 终态。收口时移除运行期状态并推进同步代际，使旧异步任务按代际正常取消。
    const canonicalTerminalStatuses = {
      MobileSessionStatus.idle,
      MobileSessionStatus.stopped,
      MobileSessionStatus.errored,
    };
    if (incoming.any((event) => event.completedTurn) ||
        canonicalTerminalStatuses.contains(snapshot.session.status)) {
      _activeTurns.remove(snapshot.session.id);
      _bumpSyncGeneration(snapshot.session.id);
      // v0.9.0 C4：完成角标——只有该会话此前在本机被观察为活动、且本次快照
      // 确认真实 idle 投影、且它不是当前选中会话时才置位；stopped/errored
      // 投影不算「完成结果」。
      final wasObservedActive = _observedActiveSessionIds.remove(
        snapshot.session.id,
      );
      if (wasObservedActive &&
          _selectedSessionId != snapshot.session.id &&
          snapshot.session.status == MobileSessionStatus.idle) {
        _unseenCompletedSessionIds.add(snapshot.session.id);
      }
    } else if (snapshot.session.status == MobileSessionStatus.streaming) {
      // 本机观察为活动：角标置位的资格条件。
      _observedActiveSessionIds.add(snapshot.session.id);
    }
    // v0.9.5 P2：首屏窗口截断标记（增量响应的 has_more 恒为 false，不会误置位）。
    if (snapshot.hasMore) {
      _sessionsWithMoreHistory.add(snapshot.session.id);
    }
    final priorCursor = _cursorFor(snapshot.session.id);
    final highestIncoming = incoming.fold<int>(
      priorCursor,
      (highest, event) => event.sequence > highest ? event.sequence : highest,
    );
    _sessionCursors[snapshot.session.id] = highestIncoming;
    if (!appendTimeline) {
      _timelineWindows[snapshot.session.id] = List.unmodifiable(incoming);
      if (_selectedSessionId == snapshot.session.id) {
        final coalesced = _coalesceStreaming(incoming);
        final start = coalesced.length > 50 ? coalesced.length - 50 : 0;
        _timeline = List.unmodifiable(coalesced.sublist(start));
      }
      return;
    }
    final priorWindow = _timelineWindows[snapshot.session.id] ?? const [];
    final mergedWindow =
        <int, SessionTimelineEvent>{
            for (final event in priorWindow) event.sequence: event,
            for (final event in incoming) event.sequence: event,
          }.values.toList()
          ..sort((left, right) => left.sequence.compareTo(right.sequence));
    _timelineWindows[snapshot.session.id] = List.unmodifiable(mergedWindow);
    if (_selectedSessionId != snapshot.session.id) return;
    // Relay 的 after_seq 语义应当排除已确认事件；客户端仍按 sequence 去重并排序，
    // 防止网络重连、代理重试或重复投递把同一时间线节点展示两次。
    final merged =
        <int, SessionTimelineEvent>{
            for (final event in _timeline) event.sequence: event,
            for (final event in incoming) event.sequence: event,
          }.values.toList()
          ..sort((left, right) => left.sequence.compareTo(right.sequence));
    _timeline = List.unmodifiable(_coalesceStreaming(merged));
    // 规范化 user.message 已合并进时间线时，该会话的乐观回显完成使命，立即清账
    // 避免同一条消息渲染两个气泡。
    // V094 §2.2：失败/待确认事务的回显是"消息待处理项"，不因 Runner 在执行前
    // 写出的 canonical user.message 而清账——失败记录必须留在气泡上直到
    // 用户重试/编辑或新一轮发送取代。
    final pending = _pendingOutgoingBySession[snapshot.session.id];
    final activeTx = _sendTxBySession[snapshot.session.id];
    final pendingIsFailureRecord =
        activeTx != null &&
        activeTx.text == pending &&
        (activeTx.phase == SessionSendPhase.failed ||
            activeTx.phase == SessionSendPhase.verifying);
    if (pending != null &&
        !pendingIsFailureRecord &&
        merged.any(
          (event) =>
              event.kind == SessionTimelineKind.userMessage &&
              event.text == pending,
        )) {
      _pendingOutgoingBySession.remove(snapshot.session.id);
    }
    // V094 §2.5：窗口内出现流式投影 = 可信执行进展（30s 耗尽后保持"处理中"）。
    if (activeTx != null &&
        activeTx.phase == SessionSendPhase.accepted &&
        snapshot.session.status == MobileSessionStatus.streaming) {
      activeTx.hasTrustedProgress = true;
    }
  }

  int _cursorFor(String? sessionId) {
    if (sessionId == null) return 0;
    final known = _sessionCursors[sessionId];
    if (known != null) return known;
    var highest = 0;
    if (_selectedSessionId == sessionId) {
      for (final event in _timeline) {
        if (event.sequence > highest) highest = event.sequence;
      }
    }
    return highest;
  }

  /// 会话切换后异步确认 DEK 可用性；迟到的旧会话响应会被 generation 丢弃。
  Future<void> _loadContentKeyAvailability(
    String sessionId,
    int selectionGeneration,
  ) async {
    var available = false;
    try {
      available = await _relay.sessionContentKeyAvailable(sessionId);
    } catch (_) {
      available = false;
    }
    if (_selectedSessionId != sessionId ||
        _selectionGeneration != selectionGeneration) {
      return;
    }
    _contentKeyAvailable = available;
    _notifyListeners();
  }

  AttachmentTransfer? _attachmentByID(String attachmentId) {
    for (final transfer in _attachments) {
      if (transfer.draft.id == attachmentId) return transfer;
    }
    return null;
  }

  void _replaceAttachment(String attachmentId, AttachmentTransfer next) {
    _attachments = _attachments
        .map((item) => item.draft.id == attachmentId ? next : item)
        .toList(growable: false);
    _rememberSelectedAttachments();
  }

  void _rememberSelectedAttachments() {
    final sessionId = _selectedSessionId;
    if (sessionId == null) return;
    _attachmentsBySession[sessionId] = List.unmodifiable(_attachments);
  }

  MobileSession? _sessionById(String? sessionId) {
    if (sessionId == null) return null;
    for (final session in _sessions) {
      if (session.id == sessionId) return session;
    }
    return null;
  }

  bool _ensureWriteAccess({required bool canWrite, required String? deviceId}) {
    if (!canWrite || deviceId == null || deviceId.isEmpty) {
      _setError('当前设备为只读状态，没有 Android 写控制端，请使用 owner 设备继续。');
      return false;
    }
    return true;
  }

  /// 写操作前自动确保持有当前会话 lease：前台+在线时缺失会静默补获取一次。
  /// 后台/离线（闸门关闭）时不自动获取，返回 false 并保留原“暂不可操作”提示，
  /// 避免把用户尚未看到的输入在后台悄悄发出。
  Future<bool> _ensureSelectedLeaseAuto(
    String sessionId, {
    required String? deviceId,
    required bool canWrite,
  }) async {
    if (!_autoLeaseEnabled) {
      final lease = _selectedLease;
      if (lease == null ||
          lease.sessionId != sessionId ||
          lease.epoch <= 0) {
        _setError('会话暂不可操作，请稍后重试。');
        return false;
      }
      return true;
    }
    return ensureSelectedLeaseAuto(
      deviceId: deviceId,
      canWrite: canWrite,
      silent: true,
    );
  }

  String _idempotencyKeyFor(
    String operation,
  ) => _idempotencyKeys.putIfAbsent(operation, () {
    _idempotencyCounter += 1;
    final randomPart = _random.nextInt(1 << 32).toRadixString(16);
    return 'mobile-${_clock().toUtc().microsecondsSinceEpoch}-${_idempotencyCounter.toString().padLeft(4, '0')}-$randomPart';
  });

  Future<T?> _runAction<T>(
    String actionKey,
    Future<T> Function() action, {
    bool reportFailure = true,
  }) async {
    if (_pendingActionKeys.contains(actionKey)) return null;
    _errorMessage = null;
    _pendingActionKeys.add(actionKey);
    _notifyListeners();
    try {
      return await action();
    } on RelayFailure catch (failure) {
      if (reportFailure) _errorMessage = failure.message;
      return null;
    } catch (_) {
      if (reportFailure) _errorMessage = '操作未完成，请稍后重试。';
      return null;
    } finally {
      _pendingActionKeys.remove(actionKey);
      _notifyListeners();
    }
  }

  void _clearSelection() {
    _selectionGeneration += 1;
    _selectedSessionId = null;
    _selectedLease = null;
    _timeline = const [];
    _resolvedRequestKeys.clear();
    _controls = const SessionControlState.empty();
    _skillConfirmation = null;
    _attachments = const [];
    _attachmentRejections = const [];
    // V094 真机回归修复（实施记录 34 §5.1）：会话切换必须清空上一会话的
    // 错误面——否则 A 会话的「Relay 暂时不可用」等历史加载错误会残留到
    // B 会话（快照 200 正常却仍显示失败横幅），违反"错误属于其会话事务"。
    // 此时 _selectedSessionId 已置空，事务/回显按会话键整表清理由
    // resetForAuthBoundary 与各切换路径自行负责；这里只清跨会话残留面。
    _errorMessage = null;
    _historyErrorMessage = null;
  }

  /// v0.9.0 C2：每会话快照刷新单航班入口。同会话已有在途刷新时只置 pending
  /// 并返回当前在途 Future；在途请求结束后从最新已合并 cursor 再补一轮，
  /// 不排队重复请求。SSE 唤醒（P4）、L1（P2）、L3（P3）、手动刷新与 lifecycle
  /// recovery 都必须进入该入口，保证每会话最多一个 snapshot refresh in-flight。
  Future<void> _runSnapshotTurn(
    String sessionId,
    Future<void> Function() turn,
  ) {
    final existing = _snapshotTurnsInFlight[sessionId];
    if (existing != null) {
      _snapshotTurnsPending.add(sessionId);
      return existing;
    }
    // 用 async 函数而非 Future(...) 构造：async 函数体同步执行到首个 await，
    // 整条链保持在微任务语义（FakeAsync/widget 测试无需额外 pump 即可收敛）；
    // Future(...) 走 Timer.run 宏任务，会破坏既有测试的时序契约。
    final gate = _executeSnapshotTurn(sessionId, turn);
    _snapshotTurnsInFlight[sessionId] = gate;
    return gate;
  }

  Future<void> _executeSnapshotTurn(
    String sessionId,
    Future<void> Function() turn,
  ) async {
    try {
      await turn();
      // 新唤醒只置 pending：这里串行补齐合并期间积压的唤醒（每轮都从
      // 已合并 cursor 增量拉取，不会重复回放已确认事件）。
      while (_snapshotTurnsPending.remove(sessionId)) {
        if (_disposed) return;
        await turn();
      }
    } finally {
      _snapshotTurnsInFlight.remove(sessionId);
    }
  }

  /// v0.9.0 C7：认证边界收口。注销/恢复换设备/账号切换/本机设备被撤销前，
  /// 由认证协调方（providers 的 App 认证状态监听）调用：
  /// - 递增认证代际：旧代际的轮询循环、快照回包在下一次代际校验处按正常取消
  ///   丢弃，不显示错误；
  /// - 清空会话运行期状态（活动回合、超时标记、cursor、乐观回显、草稿、附件
  ///   暂存），账号切换不得串任何运行期数据；
  /// - 会话列表回到 loading，重新认证后由 initialize 重新拉取；
  /// - 不清理 token 与密文缓存（调用方负责）。
  void resetForAuthBoundary() {
    if (_disposed) return;
    _authGeneration += 1;
    _activeTurns.clear();
    _turnTimedOut.clear();
    _pendingOutgoingBySession.clear();
    _sessionCursors.clear();
    _timelineWindows.clear();
    _composerDrafts.clear();
    _composerStates.clear();
    _attachmentsBySession.clear();
    _syncGenerations.clear();
    _snapshotTurnsPending.clear();
    _effortsByModel = {};
    _unseenCompletedSessionIds.clear();
    _observedActiveSessionIds.clear();
    _quietReconcileActive = false;
    _quietReconcileTimer?.cancel();
    _quietReconcileTimer = null;
    _stopSessionEventTransport();
    _clearSelection();
    _sessions = const [];
    _phase = SessionListPhase.loading;
    _workspaces = const [];
    _workspacePhase = WorkspaceListPhase.loading;
    _capabilities = CapabilityMatrix.empty;
    _capabilitiesFetchedAt = null;
    _notifyListeners();
  }

  @override
  void dispose() {
    // v0.9.0 C7：dispose 同步阻止新调度、递增认证代际并清空运行期状态；
    // 轮询循环靠代际自终止，任何完成中的 Future 返回后经 _notifyListeners
    // 丢弃通知，不再触碰已释放的 ChangeNotifier。
    _disposed = true;
    _authGeneration += 1;
    _activeTurns.clear();
    _snapshotTurnsPending.clear();
    _snapshotTurnsInFlight.clear();
    _stopSessionEventTransport();
    _quietReconcileTimer?.cancel();
    _quietReconcileTimer = null;
    _turnDeadlineTimer?.cancel();
    _turnDeadlineTimer = null;
    _turnObserverTimer?.cancel();
    _turnObserverTimer = null;
    final turnObserverWaiter = _turnObserverWaiter;
    _turnObserverWaiter = null;
    if (turnObserverWaiter != null && !turnObserverWaiter.isCompleted) {
      turnObserverWaiter.complete();
    }
    super.dispose();
  }

  void _setError(String message) {
    _errorMessage = message;
    _notifyListeners();
  }
}
