import 'package:flutter/foundation.dart';

import '../domain/models.dart';
import '../domain/terminal_models.dart';
import '../relay/relay_repository.dart';

/// P3 机器页的只读状态机。它不持有工作区路径、命令 payload 或 Daemon 日志。
enum TerminalListPhase { loading, ready, error }

class TerminalStatusController extends ChangeNotifier {
  TerminalStatusController({required this.relay, DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final RelayRepository relay;
  final DateTime Function() _clock;

  TerminalListPhase _phase = TerminalListPhase.loading;
  List<TerminalSummary> _terminals = const [];
  String? _errorMessage;
  bool _isRefreshing = false;

  TerminalListPhase get phase => _phase;
  List<TerminalSummary> get terminals =>
      List<TerminalSummary>.unmodifiable(_terminals);
  String? get errorMessage => _errorMessage;
  bool get isRefreshing => _isRefreshing;

  TerminalAvailability availabilityFor(TerminalSummary terminal) =>
      terminal.availabilityAt(_clock());

  Future<void> initialize() => refresh();

  /// 读取现有 Relay 白名单投影。刷新失败时保留旧列表，避免把最后一次可信状态清空。
  Future<void> refresh() async {
    if (_isRefreshing) return;
    final hadTerminals = _terminals.isNotEmpty;
    _isRefreshing = true;
    _errorMessage = null;
    if (!hadTerminals) _phase = TerminalListPhase.loading;
    notifyListeners();

    try {
      _terminals = await relay.listTerminals();
      _phase = TerminalListPhase.ready;
    } on RelayFailure catch (failure) {
      _errorMessage = failure.message;
      if (!hadTerminals) _phase = TerminalListPhase.error;
    } catch (_) {
      _errorMessage = '终端状态暂时不可用，请稍后重试。';
      if (!hadTerminals) _phase = TerminalListPhase.error;
    } finally {
      _isRefreshing = false;
      notifyListeners();
    }
  }
}
