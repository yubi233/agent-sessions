import 'package:flutter/foundation.dart';

/// v0.5 会话窗口的两个固定入口；只描述 UI 视图，不承载 Relay 事件或写命令。
enum SessionViewMode { chat, trajectory }

/// Resident shell 的逐会话 UI 状态。
///
/// 这些状态只影响本地展示：active view、后续滚动锚点和 inspector 都不能写回 Relay。
/// 用独立 controller 保存，是为了路由或 tab 重建时不误清 composer 草稿和 view 选择。
class SessionViewController extends ChangeNotifier {
  final Map<String, SessionViewMode> _activeViews = {};

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

  /// 会话被路由/列表移除后释放本地 view 状态，避免后续同 id fixture 串状态。
  void forget(String sessionId) {
    if (_activeViews.remove(sessionId) != null) {
      notifyListeners();
    }
  }
}
