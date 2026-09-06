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
    // v0.9.0 C4：完成角标集合来自 SessionController（认证运行期内存集合）。
    final unseenCompleted = ref.watch(
      sessionControllerProvider,
    ).unseenCompletedSessionIds;
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
              child: _RecentSessionsBody(
                controller: controller,
                unseenCompletedSessionIds: unseenCompleted,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RecentSessionsBody extends StatelessWidget {
  const _RecentSessionsBody({
    required this.controller,
    this.unseenCompletedSessionIds = const {},
  });

  final RecentSessionsController controller;

  /// v0.9.0 C4：完成角标集合（来自 SessionController）。
  final Set<String> unseenCompletedSessionIds;

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
      padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.xxl),
      children: [
        SegmentedButton<RecentSessionsView>(
          key: const Key('recent-sessions-view-toggle'),
          segments: const [
            ButtonSegment(value: RecentSessionsView.recent, label: Text('最近')),
            ButtonSegment(
              value: RecentSessionsView.archived,
              icon: Icon(Icons.archive_outlined, size: AppSizes.iconMd),
              label: Text('已归档'),
            ),
          ],
          selected: {controller.view},
          showSelectedIcon: false,
          onSelectionChanged: (selection) =>
              unawaited(controller.switchView(selection.first)),
        ),
        const SizedBox(height: AppSpacing.sm),
        _RecentHeader(archived: controller.isArchivedView),
        const SizedBox(height: AppSpacing.sm),
        if (controller.errorMessage != null) ...[
          _RecentInlineError(
            message: controller.errorMessage!,
            onRetry: controller.refresh,
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
        if (sessions.isEmpty)
          _RecentEmptyState(archived: controller.isArchivedView)
        else
          for (final session in sessions)
            if (controller.isArchivedView)
              _ArchivedSessionTile(
                key: ValueKey('archived-${session.id}'),
                session: session,
                onTap: () => context.push('/sessions/${session.id}'),
                onUnarchive: () => controller.unarchiveSession(session.id),
              )
            else
              _RecentSessionTile(
                session: session,
                hasUnseenCompletion: unseenCompletedSessionIds.contains(
                  session.id,
                ),
                onTap: () => context.push('/sessions/${session.id}'),
              ),
      ],
    );
  }
}

class _RecentHeader extends StatelessWidget {
  const _RecentHeader({required this.archived});

  final bool archived;

  @override
  Widget build(BuildContext context) => Text(
    archived ? '已归档会话保留全部数据，可随时恢复到默认列表。' : '按最近更新时间排序的会话。',
    key: const Key('recent-sessions-header'),
    style: Theme.of(context).textTheme.bodyMedium,
  );
}

class _ArchivedSessionTile extends StatelessWidget {
  const _ArchivedSessionTile({
    super.key,
    required this.session,
    required this.onTap,
    required this.onUnarchive,
  });

  final MobileSession session;
  final VoidCallback onTap;
  final Future<bool> Function() onUnarchive;

  @override
  Widget build(BuildContext context) {
    final presentation = _statusPresentation(context, session.status);
    return ListTile(
      key: Key('recent-session-${session.id}'),
      contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
      leading: CircleAvatar(radius: 18, child: Icon(presentation.icon, size: AppSizes.iconLg)),
      title: Text(
        session.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '${session.provider} · 归档于 ${_updatedLabel(session.archivedAt)}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            key: Key('recent-session-unarchive-${session.id}'),
            tooltip: '取消归档',
            icon: const Icon(Icons.unarchive_outlined),
            onPressed: () async {
              final restored = await onUnarchive();
              if (!context.mounted || !restored) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('${session.title} 已恢复到默认列表')),
              );
            },
          ),
          const Icon(Icons.chevron_right),
        ],
      ),
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

class _RecentSessionTile extends StatelessWidget {
  const _RecentSessionTile({
    required this.session,
    required this.onTap,
    this.hasUnseenCompletion = false,
  });

  final MobileSession session;
  final VoidCallback onTap;

  /// v0.9.0 C4：「有新完成结果」角标（快照确认真实 idle 终态后置位）。
  final bool hasUnseenCompletion;

  @override
  Widget build(BuildContext context) {
    final presentation = _statusPresentation(context, session.status);
    return ListTile(
      key: Key('recent-session-${session.id}'),
      contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
      leading: CircleAvatar(
        radius: 18,
        child: Icon(presentation.icon, size: AppSizes.iconLg),
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
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (hasUnseenCompletion)
            Semantics(
              label: '有新完成结果',
              child: Padding(
                key: Key('session-completion-badge-${session.id}'),
                padding: const EdgeInsets.only(right: AppSpacing.xs),
                child: Icon(
                  Icons.mark_chat_unread_outlined,
                  size: AppSizes.iconSm,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
          const Icon(Icons.chevron_right),
        ],
      ),
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
      // "出错"是明确的失败语义：用 error 红而非 warning 琥珀，与 git 错误色一致。
      color: Theme.of(context).colorScheme.error,
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
  const _RecentEmptyState({required this.archived});

  final bool archived;

  @override
  Widget build(BuildContext context) => Center(
    key: const Key('recent-sessions-empty'),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: AppLayout.emptyStateInset),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(archived ? Icons.archive_outlined : Icons.history, size: AppSizes.iconEmpty),
          const SizedBox(height: AppSpacing.md),
          Text(
            archived ? '暂无已归档会话' : '还没有会话',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            archived ? '归档的会话会显示在这里，可随时恢复。' : '创建会话后，最近会话会显示在这里。',
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
    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.errorContainer,
      border: Border.all(color: Theme.of(context).colorScheme.error),
      borderRadius: BorderRadius.circular(AppRadius.card),
    ),
    child: Row(
      children: [
        const Icon(Icons.error_outline),
        const SizedBox(width: AppSpacing.sm),
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
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xxl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_off_outlined, size: AppSizes.iconEmpty),
          const SizedBox(height: AppSpacing.md),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: AppSpacing.md),
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
