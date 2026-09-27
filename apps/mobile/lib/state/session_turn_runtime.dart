/// v0.9.0 C1（迭代计划 §3/C1）：本地提交意图。
/// UI 已区分 send/steer/queue 三种提交模式，但此前都汇入同一 sendMessage；
/// 新回合与 steer 的超时预算语义不同，必须显式传入 controller，
/// 禁止靠文案、草稿或 `_turnInFlight` 猜测。不改变 Relay `session.send` wire kind。
enum TurnSubmissionIntent {
  /// 新业务回合：只有在前一回合已有 canonical 终态后受理才重置回合起点与超时预算。
  newTurn,

  /// steer 注入当前活动回合：不创建新业务回合、不清超时、不重置续轮期限；
  /// 只推进同步代际使提交前的旧快照作废。
  steer,
}

/// 会话级活动回合运行期状态（C1）。把此前混在单一 `_turnInFlight` 布尔量里的
/// 三件事拆成独立表达：
/// ① 服务端是否仍有活动回合——本对象存在于 controller 的活动回合表中即代表；
/// ② 前台等待是否已超时——[timedOut]（到达 [uxDeadlineMs] 后置位，只改 UX 表达）；
/// ③ 当前是否在执行同步任务——controller 内的轮询/快照循环各自持有代际，与本对象无关。
///
/// 锚点语义（C1，T7 裁决）：
/// - 本机 send 在 Relay 202 即时受理分支记录单调锚点（`acceptedAt`）；
/// - 进程重启恢复或他端发起的活动回合，以首次成功观察的单调时刻建立本 App
///   运行期锚点（observedAt）；
/// - 单调锚点不跨进程持久化；同一进程内进入后台再恢复时 elapsed 继续累计、
///   不重新起算；禁止用 attempts×interval 或服务端时间推导等待时长。
///
/// [timedOut] 是唯一可变字段（到达 UX deadline 后由 controller 置位），
/// 其余字段在构造后不可变。
// ignore: must_be_immutable
final class SessionActiveTurn {
  SessionActiveTurn({
    required this.sessionId,
    required this.intent,
    required int monotonicAnchorMs,
    this.uxBudget = uxBudgetDefault,
    this.continuationBudget = continuationBudgetDefault,
  }) : _anchorMs = monotonicAnchorMs;

  /// T7 裁决：send 受理起 2 分钟 UX 超时。
  static const Duration uxBudgetDefault = Duration(minutes: 2);

  /// T7 裁决：send 受理起 60 分钟 continuation deadline（到期只停止续轮任务）。
  static const Duration continuationBudgetDefault = Duration(minutes: 60);

  /// 回合所属会话。
  final String sessionId;

  /// 建立锚点时的提交意图；steer 继承原锚点时不会覆盖原 intent。
  final TurnSubmissionIntent intent;

  /// UX 超时预算（默认 2 分钟）。
  final Duration uxBudget;

  /// 续轮期限预算（默认 60 分钟）。
  final Duration continuationBudget;

  /// 单调锚点（毫秒，相对注入的单调时钟起点）。
  final int _anchorMs;

  /// UX 超时是否已置位（到达 2 分钟 deadline 后由 controller 置位；
  /// canonical 终态合并时随活动回合状态一起清除）。
  bool timedOut = false;

  /// UX 超时切换点（单调毫秒）。
  int get uxDeadlineMs => _anchorMs + uxBudget.inMilliseconds;

  /// 续轮期限点（单调毫秒）。
  int get continuationDeadlineMs =>
      _anchorMs + continuationBudget.inMilliseconds;

  /// 相对锚点已等待时长。
  Duration elapsed(int nowMonotonicMs) =>
      Duration(milliseconds: nowMonotonicMs - _anchorMs);
}

/// 回合注册表（架构收口拆自 SessionController）：每会话的活动回合槽与客户端侧
/// "回合超时"标记。只负责登记、查询与撤防，不发起轮询、不发通知；轮询循环、
/// 快照对账与静默对账仍由 SessionController 编排（绑定 disposed/通知/传输生命周期）。
final class SessionTurnRegistry {
  final Map<String, SessionActiveTurn> _turns = {};
  final Set<String> _timedOut = {};

  /// 该会话是否仍有活动回合（send 受理至终态收口之间）；null 会话按无回合。
  bool contains(String? sessionId) =>
      sessionId != null && _turns.containsKey(sessionId);

  bool get isNotEmpty => _turns.isNotEmpty;
  bool get isEmpty => _turns.isEmpty;

  /// 选中会话的活动回合；null 表示无活动回合或未选中。
  SessionActiveTurn? bySession(String? sessionId) =>
      sessionId == null ? null : _turns[sessionId];

  /// 读取指定会话的活动回合（调用方已保证 sessionId 非空）。
  SessionActiveTurn? peek(String sessionId) => _turns[sessionId];

  /// 登记/替换活动回合（同会话新回合以最新为准）。
  void put(String sessionId, SessionActiveTurn turn) =>
      _turns[sessionId] = turn;

  /// 收口移除活动回合（终态/中止/看门狗/快照对账路径）。
  void remove(String sessionId) => _turns.remove(sessionId);

  /// 当前全部活动回合的会话 ID 快照（轮询遍历用，防御性拷贝）。
  List<String> get ids => List<String>.of(_turns.keys);

  /// 客户端侧回合超时标记（V086-11）：终态事实到达后按事件校正清除。
  bool isTimedOut(String? sessionId) =>
      sessionId != null && _timedOut.contains(sessionId);

  void markTimedOut(String sessionId) => _timedOut.add(sessionId);

  /// 撤防：终态/中止/新回合登记后清除超时标记。
  void disarmTimeout(String sessionId) => _timedOut.remove(sessionId);

  bool get anyTimedOut => _timedOut.isNotEmpty;

  /// 全量清空（认证边界重置/dispose）。
  void clear() {
    _turns.clear();
    _timedOut.clear();
  }
}

