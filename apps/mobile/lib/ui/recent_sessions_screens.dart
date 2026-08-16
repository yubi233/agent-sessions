import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../app/providers.dart';
import '../domain/session_models.dart';
import '../state/recent_sessions_controller.dart';
import 'appearance_controls.dart';
import 'app_theme.dart';

/// P3 最近会话页：只读展示 Relay 白名单会话元数据，按更新时间稳定排序。
///
/// 点击会话深链进入详情；不提供写入口，空/离线/错误/刷新均有明确状态。
class RecentSessionsScreen extends ConsumerStatefulWidget {
  const RecentSessionsScreen({super.key});

  @override
  ConsumerState<RecentSessionsScreen> createState() =>
      _RecentSessionsScreenState();
}

class _RecentSessionsScreenState extends ConsumerState<RecentSessionsScreen>
    with AutomaticKeepAliveClientMixin {
  final _refreshIndicatorKey = GlobalKey<RefreshIndicatorState>();

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(ref.read(recentSessionsControllerProvider).initialize());
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final controller = ref.watch(recentSessionsControllerProvider);
    return Scaffold(
      key: const Key('recent-sessions-screen'),
      appBar: AppBar(
        title: const Text('最近会话'),
        leading: IconButton(
          key: const Key('recent-sessions-back-button'),
          tooltip: '返回',
          onPressed: () => context.go('/home'),
          icon: const Icon(Icons.arrow_back),
        ),
        actions: [
          const AppearanceMenu(),
          IconButton(
            key: const Key('recent-sessions-refresh-button'),
            tooltip: '刷新最近会话',
            onPressed: controller.isRefreshing
                ? null
                : () => unawaited(controller.refresh()),
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
            child: RefreshIndicator(
              key: _refreshIndicatorKey,
              onRefresh: controller.refresh,
              child: _RecentSessionsBody(controller: controller),
            ),
          ),
        ),
      ),
    );
  }
}

class _RecentSessionsBody extends StatelessWidget {
  const _RecentSessionsBody({required this.controller});

  final RecentSessionsController controller;

  @override
  Widget build(BuildContext context) {
    if (controller.phase == RecentSessionsPhase.loading) {
      return const Center(
        key: Key('recent-sessions-loading'),
        child: CircularProgressIndicator(),
      );
    }
    if (controller.phase == RecentSessionsPhase.error) {
      return _RecentErrorState(
        message: controller.errorMessage ?? '最近会话暂时不可用。',
        onRetry: controller.refresh,
      );
    }
    final sessions = controller.sessions;
    return ListView(
      key: const Key('recent-sessions-list'),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        const _RecentHeader(),
        const SizedBox(height: 8),
        if (controller.errorMessage != null) ...[
          _RecentInlineError(
            message: controller.errorMessage!,
            onRetry: controller.refresh,
          ),
          const SizedBox(height: 8),
        ],
        if (sessions.isEmpty)
          const _RecentEmptyState()
        else
          for (final session in sessions)
            _RecentSessionTile(
              session: session,
              onTap: () => context.push('/sessions/${session.id}'),
            ),
      ],
    );
  }
}

class _RecentHeader extends StatelessWidget {
  const _RecentHeader();

  @override
  Widget build(BuildContext context) => Text(
    '按最近更新时间排序的会话。',
    key: const Key('recent-sessions-header'),
    style: Theme.of(context).textTheme.bodyMedium,
  );
}

class _RecentSessionTile extends StatelessWidget {
  const _RecentSessionTile({required this.session, required this.onTap});

  final MobileSession session;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final presentation = _statusPresentation(context, session.status);
    return ListTile(
      key: Key('recent-session-${session.id}'),
      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
      leading: CircleAvatar(
        radius: 18,
        child: Icon(presentation.icon, size: 20),
      ),
      title: Text(
        session.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '${session.provider} · ${_updatedLabel(session.updatedAt)}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }

  String _updatedLabel(DateTime? updatedAt) {
    if (updatedAt == null) return '时间未知';
    final local = updatedAt.toLocal();
    final now = DateTime.now();
    final difference = now.difference(local);
    if (difference.inMinutes < 1) return '刚刚';
    if (difference.inHours < 1) return '${difference.inMinutes} 分钟前';
    if (difference.inDays < 1) return '${difference.inHours} 小时前';
    return '${difference.inDays} 天前';
  }
}

_StatusPresentation _statusPresentation(
  BuildContext context,
  MobileSessionStatus status,
) {
  final colors = context.appColors;
  return switch (status) {
    MobileSessionStatus.streaming => _StatusPresentation(
      label: '运行中',
      icon: Icons.play_circle_outline,
      color: colors.success,
    ),
    MobileSessionStatus.waitingPermission ||
    MobileSessionStatus.waitingQuestion => _StatusPresentation(
      label: '等待处理',
      icon: Icons.help_outline,
      color: colors.warning,
    ),
    MobileSessionStatus.offline => _StatusPresentation(
      label: '离线',
      icon: Icons.cloud_off_outlined,
      color: colors.neutral,
    ),
    MobileSessionStatus.stopped => _StatusPresentation(
      label: '已停止',
      icon: Icons.stop_circle_outlined,
      color: colors.neutral,
    ),
    MobileSessionStatus.errored => _StatusPresentation(
      label: '出错',
      icon: Icons.error_outline,
      color: colors.warning,
    ),
    MobileSessionStatus.idle || MobileSessionStatus.unknown => _StatusPresentation(
      label: '空闲',
      icon: Icons.circle_outlined,
      color: colors.neutral,
    ),
  };
}

class _StatusPresentation {
  const _StatusPresentation({
    required this.label,
    required this.icon,
    required this.color,
  });

  final String label;
  final IconData icon;
  final Color color;
}

class _RecentEmptyState extends StatelessWidget {
  const _RecentEmptyState();

  @override
  Widget build(BuildContext context) => Center(
    key: const Key('recent-sessions-empty'),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 56),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.history, size: 32),
          const SizedBox(height: 12),
          Text('还没有会话', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            '创建会话后，最近会话会显示在这里。',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      ),
    ),
  );
}

class _RecentInlineError extends StatelessWidget {
  const _RecentInlineError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Container(
    key: const Key('recent-sessions-inline-error'),
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
          tooltip: '重试读取最近会话',
          onPressed: onRetry,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
  );
}

class _RecentErrorState extends StatelessWidget {
  const _RecentErrorState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    key: const Key('recent-sessions-error'),
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
            tooltip: '重试读取最近会话',
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
    ),
  );
}
