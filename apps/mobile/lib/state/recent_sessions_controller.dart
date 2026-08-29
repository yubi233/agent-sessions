import 'package:flutter/foundation.dart';

import '../domain/models.dart';
import '../domain/session_models.dart';
import '../relay/relay_repository.dart';

/// 最近会话页的加载阶段。
enum RecentSessionsPhase { loading, ready, error }

/// 最近会话页的视图：默认列表或已归档列表。
enum RecentSessionsView { recent, archived }

/// P3 最近会话页的只读状态机。
///
/// 它只消费 Relay 白名单会话元数据（id/status/provider/last_seq/last_activity），
/// 按稳定排序展示，不持有会话正文、token 或任何写命令；归档视图额外提供
/// unarchive 恢复入口（Relay 本地元数据操作）。跨账号/已删除会话由 Relay
/// 授权边界裁决，客户端不猜测存在性。
class RecentSessionsController extends ChangeNotifier {
  RecentSessionsController({required RelayRepository relay}) : this._(relay);

  RecentSessionsController._(this._relay);

  final RelayRepository _relay;

  RecentSessionsPhase _phase = RecentSessionsPhase.loading;
  List<MobileSession> _sessions = const [];
  RecentSessionsView _view = RecentSessionsView.recent;
  String? _errorMessage;
  bool _isRefreshing = false;
  bool _initializing = false;

  RecentSessionsPhase get phase => _phase;
  RecentSessionsView get view => _view;
  bool get isArchivedView => _view == RecentSessionsView.archived;
  List<MobileSession> get sessions =>
      List<MobileSession>.unmodifiable(_sessions);
  String? get errorMessage => _errorMessage;
  bool get isRefreshing => _isRefreshing;
  bool get isEmpty => _phase == RecentSessionsPhase.ready && _sessions.isEmpty;

  Future<void> initialize() => refresh();

  /// 切换最近/已归档视图；同一视图重复切换不重复请求。
  Future<void> switchView(RecentSessionsView view) async {
    if (_view == view) return;
    _view = view;
    _errorMessage = null;
    notifyListeners();
    await refresh();
  }

  /// 读取当前视图的会话并按最后活动时间稳定排序；刷新失败时保留最后一份可信列表。
  Future<void> refresh() async {
    if (_isRefreshing || _initializing) return;
    _initializing = true;
    final hadData = _sessions.isNotEmpty;
    _isRefreshing = true;
    _errorMessage = null;
    if (!hadData) _phase = RecentSessionsPhase.loading;
    notifyListeners();
    try {
      final raw = _view == RecentSessionsView.archived
          ? await _relay.listArchivedSessions()
          : await _relay.listSessions();
      final sorted = [...raw]..sort(MobileSession.compareByLastActivity);
      _sessions = sorted;
      _phase = RecentSessionsPhase.ready;
    } on RelayFailure catch (failure) {
      _errorMessage = failure.message;
      if (!hadData) _phase = RecentSessionsPhase.error;
    } catch (_) {
      _errorMessage = _view == RecentSessionsView.archived
          ? '已归档会话暂时不可用，请稍后重试。'
          : '最近会话暂时不可用，请稍后重试。';
      if (!hadData) _phase = RecentSessionsPhase.error;
    } finally {
      _initializing = false;
      _isRefreshing = false;
      notifyListeners();
    }
  }

  /// 取消归档：从归档视图移除；会话回到默认列表（Relay 侧刷新活动时间，避免
  /// 立即被休眠自动归档再次收走）。
  Future<bool> unarchiveSession(String sessionId) async {
    if (sessionId.trim().isEmpty) return false;
    try {
      await _relay.unarchiveSession(sessionId);
    } catch (_) {
      return false;
    }
    _sessions = _sessions
        .where((session) => session.id != sessionId)
        .toList(growable: false);
    notifyListeners();
    return true;
  }
}
