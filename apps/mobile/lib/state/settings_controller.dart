import 'package:flutter/foundation.dart';

import '../domain/control_models.dart';
import '../domain/models.dart';
import '../domain/terminal_models.dart';
import '../relay/relay_repository.dart';

/// 设置中心分区读取阶段的聚合状态机。
enum SettingsSectionPhase { loading, ready, error }

/// P3 设置中心的只读聚合器。
///
/// 它只消费 Relay 白名单元数据（设备、能力矩阵、终端状态），不持有 token、
/// 恢复码明文、会话正文或任何写命令。usage 分区在 ADR-010 服务端聚合契约
/// 落地前固定降级为 unavailable，不展示伪造的统计数字。
class SettingsController extends ChangeNotifier {
  SettingsController({
    required RelayRepository relay,
    DateTime Function()? clock,
  }) : this._(relay, clock: clock);

  SettingsController._(this._relay, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final RelayRepository _relay;
  final DateTime Function() _clock;

  SettingsSectionPhase _phase = SettingsSectionPhase.loading;
  List<Device> _devices = const [];
  CapabilityMatrix _capabilities = CapabilityMatrix.empty;
  List<TerminalSummary> _terminals = const [];
  bool _usageUnavailable = true;
  String? _errorMessage;
  bool _isRefreshing = false;
  bool _initializing = false;

  SettingsSectionPhase get phase => _phase;
  List<Device> get devices => List<Device>.unmodifiable(_devices);
  CapabilityMatrix get capabilities => _capabilities;
  List<TerminalSummary> get terminals =>
      List<TerminalSummary>.unmodifiable(_terminals);
  bool get isRefreshing => _isRefreshing;
  String? get errorMessage => _errorMessage;

  /// usage 分区是否可展示真实统计。ADR-010 的 Relay/Daemon 聚合链路未部署前恒为 true，
  /// 页面必须显示「无可用统计」而不是估算值。
  bool get usageUnavailable => _usageUnavailable;

  /// 是否已经存在认证 owner 设备（用于账户分区提示 owner 状态）。
  bool get hasOwner => _devices.any((device) => device.isOwner);

  /// 终端状态只用于「连接」分区展示，不携带路径、日志或命令 payload。
  TerminalAvailability availabilityFor(TerminalSummary terminal) =>
      terminal.availabilityAt(_clock());

  Future<void> initialize() => refresh();

  /// 并行读取设置中心需要的全部白名单投影。刷新失败时保留最后一份可信状态，
  /// 只在没有任何数据时才进入 error 阶段。
  Future<void> refresh() async {
    if (_isRefreshing || _initializing) return;
    _initializing = true;
    final hadData =
        _devices.isNotEmpty || _terminals.isNotEmpty || _capabilities.providers.isNotEmpty;
    _isRefreshing = true;
    _errorMessage = null;
    if (!hadData) _phase = SettingsSectionPhase.loading;
    notifyListeners();
    try {
      final results = await Future.wait([
        _relay.listDevices(),
        _relay.listTerminals(),
        _relay.getCapabilities(),
      ]);
      _devices = results[0] as List<Device>;
      _terminals = results[1] as List<TerminalSummary>;
      _capabilities = results[2] as CapabilityMatrix;
      _usageUnavailable = true;
      _phase = SettingsSectionPhase.ready;
    } on RelayFailure catch (failure) {
      _errorMessage = failure.message;
      if (!hadData) _phase = SettingsSectionPhase.error;
    } catch (_) {
      _errorMessage = '设置数据暂时不可用，请稍后重试。';
      if (!hadData) _phase = SettingsSectionPhase.error;
    } finally {
      _initializing = false;
      _isRefreshing = false;
      notifyListeners();
    }
  }
}
