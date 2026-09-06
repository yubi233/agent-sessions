import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../app/providers.dart';
import '../domain/terminal_models.dart';
import '../state/terminal_status_controller.dart';
import 'appearance_controls.dart';
import 'app_theme.dart';

/// P3 的只读机器页：只消费 Relay 白名单状态，不展示终端 ID、路径、日志或任何写操作。
class TerminalStatusScreen extends ConsumerStatefulWidget {
  const TerminalStatusScreen({super.key});

  @override
  ConsumerState<TerminalStatusScreen> createState() =>
      _TerminalStatusScreenState();
}

class _TerminalStatusScreenState extends ConsumerState<TerminalStatusScreen> {
  @override
  void initState() {
    super.initState();
    // 遗留 2026-09-02 #3 收口：controller 只在 App 启动时 initialize 一次，
    // 本页此前进入时直接渲染旧快照——长时间挂机后 lastSeen 落到 90s 新鲜度
    // 窗口之外，会把实际在线的终端渲染成「状态过期」。与主页终端卡片
    // v0.8.6 同口径：每次进入页面后下一帧刷新一次；controller.refresh()
    // 自带并发去重，AppBar 手动刷新按钮语义不变。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref.read(terminalStatusControllerProvider).refresh();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(terminalStatusControllerProvider);
    return Scaffold(
      key: const Key('terminal-status-screen'),
      appBar: AppBar(
        title: const Text('终端状态'),
        leading: IconButton(
          key: const Key('terminal-status-back-button'),
          tooltip: '返回会话',
          onPressed: () => context.go('/home'),
          icon: const Icon(Icons.arrow_back),
        ),
        actions: [
          const AppearanceMenu(),
          IconButton(
            key: const Key('terminal-status-refresh-button'),
            tooltip: '刷新终端状态',
            onPressed: controller.isRefreshing ? null : controller.refresh,
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
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              child: _TerminalStatusBody(controller: controller),
            ),
          ),
        ),
      ),
    );
  }
}

class _TerminalStatusBody extends StatelessWidget {
  const _TerminalStatusBody({required this.controller});

  final TerminalStatusController controller;

  @override
  Widget build(BuildContext context) {
    final terminals = controller.terminals;
    if (controller.phase == TerminalListPhase.loading && terminals.isEmpty) {
      return const Center(
        key: Key('terminal-status-loading'),
        child: CircularProgressIndicator(),
      );
    }
    if (controller.phase == TerminalListPhase.error && terminals.isEmpty) {
      return _TerminalFailureState(
        message: controller.errorMessage ?? '终端状态暂时不可用。',
        onRetry: controller.refresh,
      );
    }

    return ListView(
      key: const Key('terminal-status-list'),
      children: [
        const _TerminalPageHeader(),
        const SizedBox(height: 16),
        if (controller.errorMessage != null) ...[
          _TerminalInlineError(
            message: controller.errorMessage!,
            onRetry: controller.refresh,
          ),
          const SizedBox(height: 12),
        ],
        if (terminals.isEmpty)
          const _TerminalEmptyState()
        else
          for (var index = 0; index < terminals.length; index += 1) ...[
            _TerminalTile(
              terminal: terminals[index],
              availability: controller.availabilityFor(terminals[index]),
              index: index,
            ),
            const SizedBox(height: 8),
          ],
        const SizedBox(height: 16),
        const _TerminalBoundaryNote(),
      ],
    );
  }
}

class _TerminalPageHeader extends StatelessWidget {
  const _TerminalPageHeader();

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('连接的终端', style: Theme.of(context).textTheme.headlineSmall),
      const SizedBox(height: 4),
      Text(
        '显示 Relay 已确认的在线状态和版本。',
        style: Theme.of(context).textTheme.bodyMedium,
      ),
    ],
  );
}

class _TerminalTile extends StatelessWidget {
  const _TerminalTile({
    required this.terminal,
    required this.availability,
    required this.index,
  });

  final TerminalSummary terminal;
  final TerminalAvailability availability;
  final int index;

  @override
  Widget build(BuildContext context) {
    final presentation = _availabilityPresentation(context, availability);
    final daemonVersion = terminal.daemonVersion ?? '版本未知';
    return Semantics(
      label: '${terminal.hostname}，${presentation.label}，${terminal.platform}',
      child: Container(
        key: Key('terminal-status-tile-$index'),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          border: Border.all(color: context.appColors.border),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(presentation.icon, color: presentation.color),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    terminal.hostname,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  presentation.label,
                  key: Key('terminal-status-label-$index'),
                  style: Theme.of(
                    context,
                  ).textTheme.labelMedium?.copyWith(color: presentation.color),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              '${terminal.platform} · Daemon $daemonVersion',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 4),
            Text(
              _lastSeenLabel(terminal.lastSeen),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 4),
            Text(
              '协议 v${terminal.protocolVersion}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _TerminalEmptyState extends StatelessWidget {
  const _TerminalEmptyState();

  @override
  Widget build(BuildContext context) => Center(
    key: const Key('terminal-status-empty'),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 56),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.terminal_outlined, size: 32),
          const SizedBox(height: 12),
          Text('还没有已确认的终端', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            '完成终端配对并启动 Daemon 后，状态会显示在这里。',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      ),
    ),
  );
}

class _TerminalFailureState extends StatelessWidget {
  const _TerminalFailureState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    key: const Key('terminal-status-error'),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_off_outlined, size: 32),
          const SizedBox(height: 12),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          IconButton(
            key: const Key('terminal-status-retry-button'),
            tooltip: '重试读取终端状态',
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
    ),
  );
}

class _TerminalInlineError extends StatelessWidget {
  const _TerminalInlineError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Container(
    key: const Key('terminal-status-inline-error'),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.errorContainer,
      border: Border.all(color: Theme.of(context).colorScheme.error),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Row(
      children: [
        const Icon(Icons.error_outline),
        const SizedBox(width: 8),
        Expanded(child: Text(message)),
        IconButton(
          tooltip: '重试读取终端状态',
          onPressed: onRetry,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
  );
}

class _TerminalBoundaryNote extends StatelessWidget {
  const _TerminalBoundaryNote();

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    child: Container(
      key: const Key('terminal-status-unavailable-note'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: context.appColors.surfaceRaised,
        border: Border.all(color: context.appColors.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '此页面仅供查看。终端重启、工作区关联和活跃会话详情需要后续受控 Daemon 契约，当前不可用。',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    ),
  );
}

_AvailabilityPresentation _availabilityPresentation(
  BuildContext context,
  TerminalAvailability availability,
) {
  final colors = context.appColors;
  return switch (availability) {
    TerminalAvailability.online => _AvailabilityPresentation(
      label: '在线',
      icon: Icons.check_circle_outline,
      color: colors.success,
    ),
    TerminalAvailability.offline => _AvailabilityPresentation(
      label: '离线',
      icon: Icons.cloud_off_outlined,
      color: colors.neutral,
    ),
    TerminalAvailability.stale => _AvailabilityPresentation(
      label: '状态过期',
      icon: Icons.schedule_outlined,
      color: colors.warning,
    ),
    TerminalAvailability.unsupported => _AvailabilityPresentation(
      label: '协议不支持',
      icon: Icons.report_gmailerrorred_outlined,
      color: colors.warning,
    ),
    TerminalAvailability.unknown => _AvailabilityPresentation(
      label: '状态未确认',
      icon: Icons.help_outline,
      color: colors.neutral,
    ),
  };
}

class _AvailabilityPresentation {
  const _AvailabilityPresentation({
    required this.label,
    required this.icon,
    required this.color,
  });

  final String label;
  final IconData icon;
  final Color color;
}

String _lastSeenLabel(DateTime? lastSeen) {
  if (lastSeen == null) return '最后在线时间未知';
  return '最后在线 ${lastSeen.toLocal().toIso8601String().replaceFirst('T', ' ').split('.').first}';
}
