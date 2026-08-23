import 'package:flutter/foundation.dart';

/// v0.5 会话窗口的两个固定入口；只描述 UI 视图，不承载 Relay 事件或写命令。
enum SessionViewMode { chat, trajectory }

class SessionTrajectoryViewState {
  const SessionTrajectoryViewState({
    this.scrollOffset = 0,
    this.query = '',
    this.equalWidth = false,
    this.foldTurns = false,
    this.foldAssistantCalls = false,
    this.rangeStart = 0,
    this.rangeEnd = 1,
    this.rangeActive = false,
    this.selectedKey,
  });

  final double scrollOffset;
  final String query;
  final bool equalWidth;
  final bool foldTurns;
  final bool foldAssistantCalls;
  final double rangeStart;
  final double rangeEnd;
  final bool rangeActive;
  final String? selectedKey;

  SessionTrajectoryViewState copyWith({
    double? scrollOffset,
    String? query,
    bool? equalWidth,
    bool? foldTurns,
    bool? foldAssistantCalls,
    double? rangeStart,
    double? rangeEnd,
    bool? rangeActive,
    String? selectedKey,
    bool clearSelectedKey = false,
  }) => SessionTrajectoryViewState(
    scrollOffset: scrollOffset ?? this.scrollOffset,
    query: query ?? this.query,
    equalWidth: equalWidth ?? this.equalWidth,
    foldTurns: foldTurns ?? this.foldTurns,
    foldAssistantCalls: foldAssistantCalls ?? this.foldAssistantCalls,
    rangeStart: rangeStart ?? this.rangeStart,
    rangeEnd: rangeEnd ?? this.rangeEnd,
    rangeActive: rangeActive ?? this.rangeActive,
    selectedKey: clearSelectedKey ? null : selectedKey ?? this.selectedKey,
  );
}

/// Resident shell 的逐会话 UI 状态。
///
/// 这些状态只影响本地展示：active view、后续滚动锚点和 inspector 都不能写回 Relay。
/// 用独立 controller 保存，是为了路由或 tab 重建时不误清 composer 草稿和 view 选择。
class SessionViewController extends ChangeNotifier {
  final Map<String, SessionViewMode> _activeViews = {};
  final Map<String, String> _inspectTargets = {};
  final Map<String, double> _chatScrollOffsets = {};
  final Map<String, SessionTrajectoryViewState> _trajectoryStates = {};

  /// 读取某个会话当前 view；没有选择时按 DeepSeek Harness 口径回落到 Chat。
  SessionViewMode modeFor(String sessionId) =>
      _activeViews[sessionId] ?? SessionViewMode.chat;

  /// 切换会话 view 时只更新本地 UI 状态，不触发 SessionController 写命令。
  void setMode(String sessionId, SessionViewMode mode) {
    if (sessionId.trim().isEmpty) return;
    if (_activeViews[sessionId] == mode) return;
    _activeViews[sessionId] = mode;
    notifyListeners();
  }

  /// Chat -> Trajectory 的一次性 inspect handoff。
  ///
  /// 这里只保存本地 UI 目标，不写 Relay、不持久化；Trajectory 应用后必须清空，
  /// 避免后续 tab 切换重复选中旧工具调用。
  void setInspectTarget(String sessionId, String target) {
    if (sessionId.trim().isEmpty || target.trim().isEmpty) return;
    _inspectTargets[sessionId] = target.trim();
    _activeViews[sessionId] = SessionViewMode.trajectory;
    notifyListeners();
  }

  String? inspectTargetFor(String sessionId) => _inspectTargets[sessionId];

  double chatScrollOffsetFor(String sessionId) =>
      _chatScrollOffsets[sessionId] ?? 0;

  SessionTrajectoryViewState trajectoryStateFor(String sessionId) =>
      _trajectoryStates[sessionId] ?? const SessionTrajectoryViewState();

  void setTrajectoryState(String sessionId, SessionTrajectoryViewState state) {
    if (sessionId.trim().isEmpty) return;
    _trajectoryStates[sessionId] = state;
  }

  /// 滚动回调频率高，只写本地内存且不 notify；重挂载时由详情页读取。
  void setChatScrollOffset(String sessionId, double offset) {
    if (sessionId.trim().isEmpty || !offset.isFinite) return;
    _chatScrollOffsets[sessionId] = offset < 0 ? 0 : offset;
  }

  void clearInspectTarget(String sessionId, String target) {
    if (_inspectTargets[sessionId] != target) return;
    _inspectTargets.remove(sessionId);
    notifyListeners();
  }

  /// 会话被路由/列表移除后释放本地 view 状态，避免后续同 id fixture 串状态。
  void forget(String sessionId) {
    final removedView = _activeViews.remove(sessionId) != null;
    final removedInspect = _inspectTargets.remove(sessionId) != null;
    final removedScroll = _chatScrollOffsets.remove(sessionId) != null;
    final removedTrajectory = _trajectoryStates.remove(sessionId) != null;
    if (removedView || removedInspect || removedScroll || removedTrajectory) {
      notifyListeners();
    }
  }
}
