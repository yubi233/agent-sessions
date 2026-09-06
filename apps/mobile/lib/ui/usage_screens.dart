import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../app/providers.dart';
import '../domain/usage_models.dart';
import '../state/usage_controller.dart';
import 'app_theme.dart';

/// P3 用量统计页：today/7d/30d 的 UTC 日桶白名单计数与 Provider 分解。
///
/// 图表完全本地绘制，不引入第三方图表依赖；无数据时明确显示「无可用统计」，
/// 不估算、不补零（ADR-010）。
class UsageScreen extends ConsumerStatefulWidget {
  const UsageScreen({super.key});

  @override
  ConsumerState<UsageScreen> createState() => _UsageScreenState();
}

class _UsageScreenState extends ConsumerState<UsageScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(ref.read(usageControllerProvider).initialize());
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(usageControllerProvider);
    return Scaffold(
      key: const Key('usage-screen'),
      appBar: AppBar(
        title: const Text('用量'),
        leading: IconButton(
          key: const Key('usage-back-button'),
          tooltip: '返回设置',
          onPressed: () => context.go('/settings'),
          icon: const Icon(Icons.arrow_back),
        ),
        actions: [
          IconButton(
            key: const Key('usage-refresh-button'),
            tooltip: '刷新用量',
            onPressed: controller.isRefreshing
                ? null
                : () => unawaited(controller.refresh(controller.days)),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: _UsageBody(controller: controller),
          ),
        ),
      ),
    );
  }
}

class _UsageBody extends StatelessWidget {
  const _UsageBody({required this.controller});

  final UsageController controller;

  @override
  Widget build(BuildContext context) {
    if (controller.phase == UsagePhase.loading) {
      return const Center(
        key: Key('usage-loading'),
        child: CircularProgressIndicator(),
      );
    }
    if (controller.phase == UsagePhase.error) {
      return _UsageError(
        message: controller.errorMessage ?? '用量统计暂时不可用。',
        onRetry: () => controller.refresh(controller.days),
      );
    }
    return ListView(
      key: const Key('usage-list'),
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: [
        _UsageWindowSelector(
          selectedDays: controller.days,
          onSelected: (days) => unawaited(controller.refresh(days)),
        ),
        const SizedBox(height: AppSpacing.lg),
        if (controller.hasData) ...[
          _UsageTotalCard(
            summary: controller.summary,
            isToday: controller.days == 1,
          ),
          const SizedBox(height: AppSpacing.lg),
          _UsageProviderChart(summary: controller.summary),
          const SizedBox(height: AppSpacing.sm),
          Text(
            '统计按 UTC 日桶聚合，仅包含白名单整数计数（ADR-010）。',
            key: const Key('usage-utc-note'),
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ] else
          const _UsageNoDataState(),
      ],
    );
  }
}

class _UsageWindowSelector extends StatelessWidget {
  const _UsageWindowSelector({
    required this.selectedDays,
    required this.onSelected,
  });

  final int selectedDays;
  final void Function(int days) onSelected;

  @override
  Widget build(BuildContext context) => SegmentedButton<int>(
    key: const Key('usage-window-selector'),
    segments: const [
      ButtonSegment(value: 1, label: Text('今日')),
      ButtonSegment(value: 7, label: Text('7 天')),
      ButtonSegment(value: 30, label: Text('30 天')),
    ],
    selected: {selectedDays},
    onSelectionChanged: (selection) => onSelected(selection.first),
  );
}

class _UsageTotalCard extends StatelessWidget {
  const _UsageTotalCard({required this.summary, required this.isToday});

  final UsageSummary summary;
  final bool isToday;

  @override
  Widget build(BuildContext context) {
    final (input, output) = summary.totals;
    return Container(
      key: const Key('usage-total-card'),
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border.all(color: context.appColors.border),
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: Row(
        children: [
          Expanded(
            child: _TotalItem(
              label: isToday ? '今日输入' : '窗口输入',
              value: _formatTokens(input),
              color: context.appColors.success,
            ),
          ),
          Container(
            width: 1,
            height: 40,
            color: context.appColors.border,
          ),
          Expanded(
            child: _TotalItem(
              label: isToday ? '今日输出' : '窗口输出',
              value: _formatTokens(output),
              color: context.appColors.info,
            ),
          ),
        ],
      ),
    );
  }
}

class _TotalItem extends StatelessWidget {
  const _TotalItem({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Text(label, style: Theme.of(context).textTheme.labelMedium),
      const SizedBox(height: AppSpacing.xs),
      Text(
        value,
        key: Key('usage-total-$label'),
        style: Theme.of(context).textTheme.titleMedium?.copyWith(color: color),
      ),
    ],
  );
}

/// Provider 分解柱状图：本地纯绘制，无第三方依赖。柱高按最大值归一化，
/// 底部展示 Provider 与计数；不显示任何正文或精确时间。
class _UsageProviderChart extends StatelessWidget {
  const _UsageProviderChart({required this.summary});

  final UsageSummary summary;

  @override
  Widget build(BuildContext context) {
    final providers = <String, int>{};
    for (final aggregate in summary.providers) {
      providers[aggregate.provider] =
          (providers[aggregate.provider] ?? 0) + aggregate.totalTokens;
    }
    if (providers.isEmpty) {
      // 不再静默消失：图表区块为空时给出可见说明，避免"区块凭空蒸发"。
      return Padding(
        padding: const EdgeInsets.only(top: AppSpacing.xs),
        child: Row(
          children: [
            Icon(
              Icons.info_outline,
              size: AppSizes.iconMd,
              color: Theme.of(context).textTheme.bodySmall?.color,
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                '本期暂无 Provider 用量数据。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      );
    }
    final maxValue = providers.values.reduce((a, b) => a > b ? a : b);
    return Container(
      key: const Key('usage-provider-chart'),
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border.all(color: context.appColors.border),
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Provider 用量', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: AppSpacing.md),
          SizedBox(
            // 120 恰好等于"数值行+4+柱80+4+名称行"，零冗余：textScale>1 即溢出。
            // 放宽到 136 留出余量，并约束两行文本 ellipsis 防换行撑爆。
            height: 136,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final entry in providers.entries) ...[
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Text(
                          _formatTokens(entry.value),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                        const SizedBox(height: AppSpacing.xs),
                        Container(
                          key: Key('usage-bar-${entry.key}'),
                          height: maxValue == 0
                              ? 2
                              : (entry.value / maxValue) * 80,
                          decoration: BoxDecoration(
                            color: context.appColors.info,
                            borderRadius: const BorderRadius.vertical(
                              top: Radius.circular(AppRadius.micro),
                            ),
                          ),
                        ),
                        const SizedBox(height: AppSpacing.xs),
                        Text(
                          entry.key,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _UsageNoDataState extends StatelessWidget {
  const _UsageNoDataState();

  @override
  Widget build(BuildContext context) => Container(
    key: const Key('usage-no-data'),
    padding: const EdgeInsets.all(AppSpacing.lg),
    decoration: BoxDecoration(
      color: context.appColors.surfaceRaised,
      border: Border.all(color: context.appColors.border),
      borderRadius: BorderRadius.circular(AppRadius.card),
    ),
    child: const Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.info_outline),
        SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(
            '无可用统计。它需要 Daemon 上报白名单计数并经 Relay 聚合后才会计入，当前不会显示估算值。',
          ),
        ),
      ],
    ),
  );
}

class _UsageError extends StatelessWidget {
  const _UsageError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    key: const Key('usage-error'),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xxl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_off_outlined, size: AppSizes.iconEmpty),
          const SizedBox(height: AppSpacing.md),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: AppSpacing.md),
          IconButton(
            key: const Key('usage-retry-button'),
            tooltip: '重试读取用量',
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
    ),
  );
}

String _formatTokens(int value) {
  if (value >= 1_000_000) return '${(value / 1_000_000).toStringAsFixed(1)}M';
  if (value >= 1_000) return '${(value / 1_000).toStringAsFixed(1)}k';
  return '$value';
}
