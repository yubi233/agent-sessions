import 'package:flutter/foundation.dart';

import '../domain/daemon_observation_models.dart';
import '../domain/models.dart';
import '../relay/relay_repository.dart';

enum DaemonObservationPhase { loading, ready, error }

/// P2-F 会话 Daemon 观察状态机。
/// 它只调用 Relay 的只读安全投影，不保存 token、DEK、原始 envelope 或任何待发送命令。
class DaemonObservationController extends ChangeNotifier {
  factory DaemonObservationController({
    required RelayRepository relay,
    required String sessionId,
  }) => DaemonObservationController._(relay, sessionId);

  DaemonObservationController._(this._relay, this.sessionId);

  final RelayRepository _relay;
  final String sessionId;

  DaemonObservationPhase _phase = DaemonObservationPhase.loading;
  DaemonSessionObservation? _observation;
  String? _errorMessage;
  bool _isRefreshing = false;

  DaemonObservationPhase get phase => _phase;
  DaemonSessionObservation? get observation => _observation;
  String? get errorMessage => _errorMessage;
  bool get isRefreshing => _isRefreshing;

  Future<void> initialize() => refresh();

  /// 增量读取从当前已确认的 Relay event_seq 继续。命令列表每次返回最新安全投影，
  /// 事件只在内存中按序号去重，既不解密，也不会写入本地持久化缓存。
  Future<void> refresh() async {
    if (_isRefreshing) return;
    final prior = _observation;
    _isRefreshing = true;
    _errorMessage = null;
    if (prior == null) _phase = DaemonObservationPhase.loading;
    notifyListeners();

    try {
      final incoming = await _relay.getSessionDaemonObservation(
        sessionId,
        afterSequence: prior?.session.lastSequence ?? 0,
      );
      _observation = prior == null ? incoming : prior.mergeIncrement(incoming);
      _phase = DaemonObservationPhase.ready;
    } on RelayFailure catch (failure) {
      _errorMessage = failure.message;
      if (prior == null) _phase = DaemonObservationPhase.error;
    } catch (_) {
      _errorMessage = 'Daemon 观察暂时不可用，请稍后重试。';
      if (prior == null) _phase = DaemonObservationPhase.error;
    } finally {
      _isRefreshing = false;
      notifyListeners();
    }
  }
}
