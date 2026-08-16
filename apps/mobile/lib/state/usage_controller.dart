import 'package:flutter/foundation.dart';

import '../domain/models.dart';
import '../domain/usage_models.dart';
import '../relay/relay_repository.dart';

/// 用量页的加载阶段。
enum UsagePhase { loading, ready, error, unavailable }

/// P3 用量统计页的只读状态机。
///
/// 它只消费 Relay 白名单整数聚合（ADR-010）：today/7d/30d 的 UTC 日桶计数与
/// Provider 分解。不持有 prompt、回复、费用或精确事件时间；服务端未返回
/// 任何数据时显示「无可用统计」，客户端绝不估算或补零。
class UsageController extends ChangeNotifier {
  UsageController({required RelayRepository relay}) : this._(relay);

  UsageController._(this._relay);

  final RelayRepository _relay;

  UsagePhase _phase = UsagePhase.loading;
  UsageSummary _summary = UsageSummary.empty;
  int _days = 30;
  String? _errorMessage;
  bool _isRefreshing = false;
  bool _initializing = false;

  UsagePhase get phase => _phase;
  UsageSummary get summary => _summary;
  int get days => _days;
  String? get errorMessage => _errorMessage;
  bool get isRefreshing => _isRefreshing;

  /// 是否有任何可展示的统计；无数据时页面显示「无可用统计」而非零值图表。
  bool get hasData => _summary.providers.isNotEmpty;

  /// 今日 UTC 日桶内的聚合（供 1 天视图使用）。
  /// 以摘要自带的 utc_today 投影为唯一事实源（ADR-010），不依赖本机时钟，
  /// 避免设备与 Relay 跨日不一致时今日过滤错位。
  List<UsageDayAggregate> get todayProviders {
    final day = _summary.utcToday;
    if (day.isEmpty) return const [];
    return _summary.providers
        .where((aggregate) => aggregate.utcDay == day)
        .toList(growable: false);
  }

  Future<void> initialize() => refresh(30);

  /// 切换统计窗口并重新读取；刷新失败保留最后一份可信摘要。
  Future<void> refresh(int days) async {
    if (_isRefreshing || _initializing) return;
    _initializing = true;
    final hadData = _summary.providers.isNotEmpty;
    _isRefreshing = true;
    _errorMessage = null;
    _days = days;
    if (!hadData) _phase = UsagePhase.loading;
    notifyListeners();
    try {
      _summary = await _relay.getUsageSummary(days: days);
      _phase = _summary.providers.isEmpty
          ? UsagePhase.unavailable
          : UsagePhase.ready;
    } on RelayFailure catch (failure) {
      _errorMessage = failure.message;
      if (!hadData) _phase = UsagePhase.error;
    } catch (_) {
      _errorMessage = '用量统计暂时不可用，请稍后重试。';
      if (!hadData) _phase = UsagePhase.error;
    } finally {
      _initializing = false;
      _isRefreshing = false;
      notifyListeners();
    }
  }
}
