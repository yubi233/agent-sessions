import 'models.dart';

/// usage 聚合的 UTC 日桶投影（ADR-010）。字段全部为白名单整数计数，
/// 不包含 prompt、回复、费用、精确事件时间或会话正文。
class UsageDayAggregate {
  const UsageDayAggregate({
    required this.provider,
    required this.utcDay,
    required this.inputTokens,
    required this.outputTokens,
    required this.cacheReadTokens,
    required this.cacheWriteTokens,
  });

  factory UsageDayAggregate.fromRelayJson(Map<String, dynamic> json) {
    final provider = json['provider'];
    final day = json['utc_day'];
    if (provider is! String || provider.trim().isEmpty) {
      throw const RelayFailure(
        RelayFailureKind.protocol,
        'Relay 返回了无效的用量 Provider。',
      );
    }
    if (day is! String || day.trim().isEmpty) {
      throw const RelayFailure(
        RelayFailureKind.protocol,
        'Relay 返回了无效的用量日桶。',
      );
    }
    return UsageDayAggregate(
      provider: provider.trim(),
      utcDay: day.trim(),
      inputTokens: _nonNegativeInt(json['input_tokens']),
      outputTokens: _nonNegativeInt(json['output_tokens']),
      cacheReadTokens: _nonNegativeInt(json['cache_read_tokens']),
      cacheWriteTokens: _nonNegativeInt(json['cache_write_tokens']),
    );
  }

  final String provider;
  final String utcDay;
  final int inputTokens;
  final int outputTokens;
  final int cacheReadTokens;
  final int cacheWriteTokens;

  int get totalTokens => inputTokens + outputTokens;
}

/// 账号在最近 1/7/30 天（UTC 日桶）的用量摘要。
class UsageSummary {
  const UsageSummary({
    required this.days,
    required this.utcToday,
    required this.providers,
  });

  factory UsageSummary.fromRelayJson(Map<String, dynamic> json) {
    final days = json['days'];
    final utcToday = json['utc_today'];
    if (days is! num || days.toInt() <= 0) {
      throw const RelayFailure(
        RelayFailureKind.protocol,
        'Relay 返回了无效的用量窗口。',
      );
    }
    if (utcToday is! String || utcToday.trim().isEmpty) {
      throw const RelayFailure(
        RelayFailureKind.protocol,
        'Relay 返回了无效的用量 UTC 今日。',
      );
    }
    final rawProviders = json['providers'];
    if (rawProviders is! List) {
      throw const RelayFailure(
        RelayFailureKind.protocol,
        'Relay 用量聚合格式错误。',
      );
    }
    return UsageSummary(
      days: days.toInt(),
      utcToday: utcToday.trim(),
      providers: rawProviders
          .whereType<Map>()
          .map(
            (entry) =>
                UsageDayAggregate.fromRelayJson(Map<String, dynamic>.from(entry)),
          )
          .toList(growable: false),
    );
  }

  final int days;
  final String utcToday;
  final List<UsageDayAggregate> providers;

  static const empty = UsageSummary(days: 0, utcToday: '', providers: []);

  /// 全部 Provider 的输入/输出合计（白名单整数，客户端不自行估算）。
  (int input, int output) get totals {
    var input = 0;
    var output = 0;
    for (final aggregate in providers) {
      input += aggregate.inputTokens;
      output += aggregate.outputTokens;
    }
    return (input, output);
  }
}

int _nonNegativeInt(Object? value) {
  if (value is int && value >= 0) return value;
  if (value is num && value >= 0 && value == value.truncateToDouble()) {
    return value.toInt();
  }
  throw const RelayFailure(
    RelayFailureKind.protocol,
    'Relay 返回了无效的用量计数。',
  );
}
