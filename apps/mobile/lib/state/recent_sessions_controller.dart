import 'package:flutter/foundation.dart';

import '../domain/models.dart';
import '../domain/session_models.dart';
import '../relay/relay_repository.dart';

/// 最近会话页的加载阶段。
enum RecentSessionsPhase { loading, ready, error }

/// P3 最近会话页的只读状态机。
///
/// 它只消费 Relay 白名单会话元数据（id/status/provider/last_seq/updated_at），
/// 按稳定排序展示，不持有会话正文、token 或任何写命令。跨账号/已删除会话
/// 由 Relay 授权边界裁决，客户端不猜测存在性。
class RecentSessionsController extends ChangeNotifier {
  RecentSessionsController({required RelayRepository relay}) : this._(relay);

  RecentSessionsController._(this._relay);

  final RelayRepository _relay;

  RecentSessionsPhase _phase = RecentSessionsPhase.loading;
  List<MobileSession> _sessions = const [];
  String? _errorMessage;
  bool _isRefreshing = false;
  bool _initializing = false;

  RecentSessionsPhase get phase => _phase;
  List<MobileSession> get sessions =>
      List<MobileSession>.unmodifiable(_sessions);
  String? get errorMessage => _errorMessage;
  bool get isRefreshing => _isRefreshing;
  bool get isEmpty => _phase == RecentSessionsPhase.ready && _sessions.isEmpty;

  Future<void> initialize() => refresh();

  /// 读取最近会话并按更新时间稳定排序；刷新失败时保留最后一份可信列表。
  Future<void> refresh() async {
    if (_isRefreshing || _initializing) return;
    _initializing = true;
    final hadData = _sessions.isNotEmpty;
    _isRefreshing = true;
    _errorMessage = null;
    if (!hadData) _phase = RecentSessionsPhase.loading;
    notifyListeners();
    try {
      final raw = await _relay.listSessions();
      final sorted = [...raw]..sort(_compareByUpdatedAt);
      _sessions = sorted;
      _phase = RecentSessionsPhase.ready;
    } on RelayFailure catch (failure) {
      _errorMessage = failure.message;
      if (!hadData) _phase = RecentSessionsPhase.error;
    } catch (_) {
      _errorMessage = '最近会话暂时不可用，请稍后重试。';
      if (!hadData) _phase = RecentSessionsPhase.error;
    } finally {
      _initializing = false;
      _isRefreshing = false;
      notifyListeners();
    }
  }

  /// 稳定排序：updatedAt 降序；同时间戳时按 lastSequence 降序；再退到 id 字典序，
  /// 避免页面刷新出现跳项。
  int _compareByUpdatedAt(MobileSession left, MobileSession right) {
    final leftTime = left.updatedAt?.millisecondsSinceEpoch;
    final rightTime = right.updatedAt?.millisecondsSinceEpoch;
    if (leftTime != null && rightTime != null && leftTime != rightTime) {
      return rightTime.compareTo(leftTime);
    }
    if (leftTime != null && rightTime == null) return -1;
    if (leftTime == null && rightTime != null) return 1;
    if (left.lastSequence != right.lastSequence) {
      return right.lastSequence.compareTo(left.lastSequence);
    }
    return left.id.compareTo(right.id);
  }
}
