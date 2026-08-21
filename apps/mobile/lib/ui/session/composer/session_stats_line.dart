import 'package:flutter/material.dart';

import '../../../domain/control_models.dart';
import '../../../domain/session_projection_models.dart';

/// v0.5/P7：composer.dock 的 StatsLine 只读读数。
///
/// 所有字段都来自 display-safe projection；缺字段时省略或显示 unavailable，
/// 不填 0，不把窗口回退说成全会话统计。
class SessionStatsLine extends StatelessWidget {
  const SessionStatsLine({required this.stats, super.key});

  final SessionStatsLineProjection stats;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = <Widget>[
      if (stats.inputTokens != null)
        _StatsChip(
          key: const Key('session-stats-input'),
          label:
              '输入 ${SessionUsageSummary.compactForDisplay(stats.inputTokens!)}',
        ),
      if (stats.outputTokens != null)
        _StatsChip(
          key: const Key('session-stats-output'),
          label:
              '输出 ${SessionUsageSummary.compactForDisplay(stats.outputTokens!)}',
        ),
      if (stats.cacheTokens != null)
        _StatsChip(
          key: const Key('session-stats-cache'),
          label:
              '缓存 ${SessionUsageSummary.compactForDisplay(stats.cacheTokens!)}',
        ),
      if (stats.turnCount != null)
        _StatsChip(
          key: const Key('session-stats-turns'),
          label: '轮次 ${stats.turnCount}',
        ),
      if (stats.stepCount != null)
        _StatsChip(
          key: const Key('session-stats-steps'),
          label: '步骤 ${stats.stepCount}',
        ),
        if (stats.ttftMs != null)
          _StatsChip(
            key: const Key('session-stats-ttft'),
            label: '首字 ${(stats.ttftMs! / 1000).toStringAsFixed(1)}s',
          ),
        if (stats.decodeThroughput != null)
          _StatsChip(
            key: const Key('session-stats-throughput'),
            label: '解码 ${stats.decodeThroughput!.toStringAsFixed(1)} tok/s',
          ),
    ];

    if (items.isEmpty) {
      return Padding(
        key: const Key('session-stats-line'),
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(
          '统计不可用',
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    return Padding(
      key: const Key('session-stats-line'),
      padding: const EdgeInsets.only(bottom: 6),
      child: Wrap(spacing: 8, runSpacing: 4, children: items),
    );
  }
}

class _StatsChip extends StatelessWidget {
  const _StatsChip({required this.label, super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(label, style: theme.textTheme.labelSmall),
    );
  }
}