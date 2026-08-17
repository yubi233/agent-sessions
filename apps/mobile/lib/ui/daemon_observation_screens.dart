import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../app/providers.dart';
import '../domain/daemon_observation_models.dart';
import '../domain/session_models.dart';
import '../state/daemon_observation_controller.dart';
import 'app_theme.dart';

/// P2-F Daemon 观察页：只展示 Relay 裁剪后的命令状态与加密事件元数据。
/// 页面没有 lease、composer、命令提交或解密入口；无 DEK 时始终保持安全占位。
class DaemonObservationScreen extends ConsumerWidget {
  const DaemonObservationScreen({super.key, required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(
      daemonObservationControllerProvider(sessionId),
    );
    final observation = controller.observation;
    return Scaffold(
      key: const Key('daemon-observation-screen'),
      appBar: AppBar(
        title: const Text('Daemon 观察'),
        leading: IconButton(
          key: const Key('daemon-observation-back-button'),
          tooltip: '返回会话',
          onPressed: () => context.go('/sessions/$sessionId'),
          icon: const Icon(Icons.arrow_back),
        ),
        actions: [
          IconButton(
            key: const Key('daemon-observation-refresh-button'),
            tooltip: '刷新 Daemon 观察',
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
            child: _DaemonObservationBody(
              controller: controller,
              observation: observation,
            ),
          ),
        ),
      ),
    );
  }
}

class _DaemonObservationBody extends StatelessWidget {
  const _DaemonObservationBody({
    required this.controller,
    required this.observation,
  });

  final DaemonObservationController controller;
  final DaemonSessionObservation? observation;

  @override
  Widget build(BuildContext context) {
    if (controller.phase == DaemonObservationPhase.loading &&
        observation == null) {
      return const Center(
        key: Key('daemon-observation-loading'),
        child: CircularProgressIndicator(),
      );
    }
    if (controller.phase == DaemonObservationPhase.error &&
        observation == null) {
      return _ObservationFailure(
        message: controller.errorMessage ?? 'Daemon 观察暂时不可用。',
        onRetry: controller.refresh,
      );
    }
    final current = observation;
    if (current == null) {
      return const SizedBox.shrink();
    }
    return RefreshIndicator(
      onRefresh: controller.refresh,
      child: ListView(
        key: const Key('daemon-observation-list'),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          _ObservationHeader(session: current.session),
          const SizedBox(height: 16),
          if (controller.errorMessage != null) ...[
            _ObservationInlineError(
              message: controller.errorMessage!,
              onRetry: controller.refresh,
            ),
            const SizedBox(height: 12),
          ],
          const _ObservationSectionLabel('Daemon 命令'),
          const SizedBox(height: 8),
          if (current.commands.isEmpty)
            const _ObservationEmptyState(
              key: Key('daemon-observation-commands-empty'),
              icon: Icons.inbox_outlined,
              message: '尚未收到可观察的 Daemon 命令。',
            )
          else
            for (var index = 0; index < current.commands.length; index += 1)
              Padding(
                padding: EdgeInsets.only(
                  bottom: index + 1 == current.commands.length ? 0 : 8,
                ),
                child: _CommandObservationTile(
                  key: Key('daemon-observation-command-$index'),
                  command: current.commands[index],
                ),
              ),
          const SizedBox(height: 20),
          const _ObservationSectionLabel('加密事件'),
          const SizedBox(height: 8),
          if (current.events.isEmpty)
            const _ObservationEmptyState(
              key: Key('daemon-observation-events-empty'),
              icon: Icons.lock_outline,
              message: '尚未收到可观察的加密事件。',
            )
          else
            for (var index = 0; index < current.events.length; index += 1)
              Padding(
                padding: EdgeInsets.only(
                  bottom: index + 1 == current.events.length ? 0 : 8,
                ),
                child: _CipherEventObservationTile(
                  key: Key('daemon-observation-event-$index'),
                  event: current.events[index],
                ),
              ),
          const SizedBox(height: 16),
          const _ObservationBoundaryNote(),
        ],
      ),
    );
  }
}

class _ObservationHeader extends StatelessWidget {
  const _ObservationHeader({required this.session});

  final DaemonObservationSession session;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('会话执行状态', style: Theme.of(context).textTheme.headlineSmall),
      const SizedBox(height: 4),
      Text(
        '${_sessionStatusLabel(session.status)} · ${session.provider} · 事件序号 ${session.lastSequence}',
        style: Theme.of(context).textTheme.bodyMedium,
      ),
    ],
  );
}

class _CommandObservationTile extends StatelessWidget {
  const _CommandObservationTile({super.key, required this.command});

  final DaemonCommandObservation command;

  @override
  Widget build(BuildContext context) {
    final color = _commandColor(context, command.status);
    return Semantics(
      label:
          '${command.kind.label}，${command.status.label}，${command.deliveryState.label}',
      child: Container(
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
                Icon(Icons.memory_outlined, color: color),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    command.kind.label,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Text(
                  command.status.label,
                  style: Theme.of(
                    context,
                  ).textTheme.labelMedium?.copyWith(color: color),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              command.deliveryState.label,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (command.errorCode case final errorCode?) ...[
              const SizedBox(height: 8),
              Text(
                errorCode.label,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: context.appColors.warning,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '状态代码: ${errorCode.wireValue}',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _CipherEventObservationTile extends StatelessWidget {
  const _CipherEventObservationTile({super.key, required this.event});

  final DaemonCipherEventObservation event;

  @override
  Widget build(BuildContext context) {
    final verified = event.envelope.state == CipherEnvelopeState.verified;
    final color = verified
        ? context.appColors.success
        : context.appColors.neutral;
    return Semantics(
      label:
          '${event.eventType.label}，事件序号 ${event.sequence}，${verified ? '已验证加密封装' : '加密内容不可用'}',
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          border: Border.all(color: context.appColors.border),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              verified ? Icons.verified_outlined : Icons.lock_outline,
              color: color,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    event.eventType.label,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    verified
                        ? '已验证加密封装 · payload v${event.envelope.payloadVersion}'
                        : '加密内容不可用',
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: color),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '事件序号 ${event.sequence}',
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ObservationEmptyState extends StatelessWidget {
  const _ObservationEmptyState({
    super.key,
    required this.icon,
    required this.message,
  });

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 28),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 32),
        const SizedBox(height: 10),
        Text(message, textAlign: TextAlign.center),
      ],
    ),
  );
}

class _ObservationFailure extends StatelessWidget {
  const _ObservationFailure({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    key: const Key('daemon-observation-error'),
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
            key: const Key('daemon-observation-retry-button'),
            tooltip: '重试 Daemon 观察',
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
    ),
  );
}

class _ObservationInlineError extends StatelessWidget {
  const _ObservationInlineError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Container(
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
          tooltip: '重试 Daemon 观察',
          onPressed: onRetry,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
  );
}

class _ObservationSectionLabel extends StatelessWidget {
  const _ObservationSectionLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) =>
      Text(label, style: Theme.of(context).textTheme.titleSmall);
}

class _ObservationBoundaryNote extends StatelessWidget {
  const _ObservationBoundaryNote();

  @override
  Widget build(BuildContext context) => Container(
    key: const Key('daemon-observation-boundary-note'),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: context.appColors.surfaceRaised,
      border: Border.all(color: context.appColors.border),
      borderRadius: BorderRadius.circular(8),
    ),
    child: const Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.info_outline, size: 18),
        SizedBox(width: 10),
        Expanded(
          child: Text(
            '此页面只读取 Relay 安全投影。没有会话内容密钥时，加密事件不会解密或显示正文；终端命令流、会话控制和本机路径当前不可用。',
          ),
        ),
      ],
    ),
  );
}

String _sessionStatusLabel(MobileSessionStatus status) => switch (status) {
  MobileSessionStatus.idle => '空闲',
  MobileSessionStatus.streaming => '运行中',
  MobileSessionStatus.waitingPermission => '等待权限',
  MobileSessionStatus.waitingQuestion => '等待提问',
  MobileSessionStatus.stopped => '已停止',
  MobileSessionStatus.errored => '出错',
  MobileSessionStatus.offline => '离线',
  MobileSessionStatus.unknown => '未确认',
};

Color _commandColor(
  BuildContext context,
  DaemonObservationCommandStatus status,
) => switch (status) {
  DaemonObservationCommandStatus.succeeded => context.appColors.success,
  DaemonObservationCommandStatus.failed ||
  DaemonObservationCommandStatus.rejected => context.appColors.warning,
  DaemonObservationCommandStatus.cancelled ||
  DaemonObservationCommandStatus.expired => context.appColors.neutral,
  _ => context.appColors.info,
};
