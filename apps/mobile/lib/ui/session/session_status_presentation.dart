import 'package:flutter/material.dart';

import 'session_subagent_chrome.dart';

import '../../domain/session_models.dart';
import '../app_theme.dart';

/// 会话状态呈现的共享底层（架构收口拆分）：状态行文案/色调、内联错误条、
/// 只读横幅与页头标题。session_screens（详情视图）与 session_home_screens
/// （首页视图）共同消费；Happy 链保持库私有。
class ReadOnlyBanner extends StatelessWidget {
  const ReadOnlyBanner({super.key});

  @override
  Widget build(BuildContext context) => Container(
    key: const Key('session-readonly-banner'),
    // 提示条统一 note 档 padding=12。
    padding: const EdgeInsets.all(AppSpacing.md),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      border: Border.all(color: Theme.of(context).dividerColor),
      borderRadius: BorderRadius.circular(AppRadius.card),
    ),
    child: const Row(
      children: [
        Icon(Icons.visibility_outlined, size: AppSizes.iconMd),
        SizedBox(width: AppSpacing.sm),
        Expanded(child: Text('当前设备为只读状态，仍可查看会话。')),
      ],
    ),
  );
}


class InlineError extends StatelessWidget {
  const InlineError({required this.message, required this.onRetry, super.key});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.errorContainer,
      border: Border.all(color: Theme.of(context).colorScheme.error),
      borderRadius: BorderRadius.circular(AppRadius.card),
    ),
    child: Row(
      children: [
        const Icon(Icons.error_outline),
        const SizedBox(width: AppSpacing.md),
        Expanded(child: Text(message)),
        IconButton(
          tooltip: '关闭提示',
          onPressed: onRetry,
          icon: const Icon(Icons.close),
        ),
      ],
    ),
  );
}

class SessionHeaderTitle extends StatelessWidget {
  const SessionHeaderTitle({super.key, required this.title});

  final String title;

  @override
  Widget build(BuildContext context) => Semantics(
    label: title,
    child: Row(
      key: const Key('mobile-header-title'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Container(
          key: const Key('mobile-header-status'),
          width: AppSizes.statusDot,
          height: AppSizes.statusDot,
          decoration: BoxDecoration(
            color: context.appColors.success,
            shape: BoxShape.circle,
          ),
        ),
      ],
    ),
  );
}

/// Happy 的会话标题：标题和项目名分两行居中，避免把项目名挤进操作按钮。
class HappySessionHeaderTitle extends StatelessWidget {
  const HappySessionHeaderTitle({
    super.key,
    required this.session,
    required this.onOpenParent,
  });

  final MobileSession? session;
  final VoidCallback? onOpenParent;

  @override
  Widget build(BuildContext context) => Column(
    key: const Key('happy-session-header'),
    mainAxisAlignment: MainAxisAlignment.center,
    crossAxisAlignment: CrossAxisAlignment.center,
    children: [
      Row(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (session?.parentSessionId != null && onOpenParent != null) ...[
            SessionSubagentBreadcrumb(
              parentSessionId: session?.parentSessionId,
              onOpenParent: onOpenParent!,
            ),
            const SizedBox(width: AppSpacing.xs),
          ],
          Flexible(
            child: Text(
              // V094-18（UI-18）：标题消费真实数据——displayName 优先
              // （MobileSession.title 内置 id 短码回退），不再硬编码「新对话」。
              session?.title ?? '新对话',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
      // V094-18：副标题带「工作区 ·」语义前缀；显示名来自 Relay 下发的
      // workspace_name，缺失时占位（绝不伪造本地路径）。
      Text(
        '工作区 · ${session?.workspaceName?.trim().isNotEmpty == true ? session!.workspaceName!.trim() : '未知'}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    ],
  );
}

class HappyProviderAvatar extends StatelessWidget {
  const HappyProviderAvatar({super.key, required this.provider});

  final String? provider;

  @override
  Widget build(BuildContext context) {
    final normalized = provider?.toLowerCase() ?? '';
    final icon = switch (normalized) {
      'codex' => Icons.auto_awesome,
      'claude' => Icons.psychology_outlined,
      'opencode' => Icons.terminal_outlined,
      // DeepSeek Harness：ACP 桥接入，使用 hub 图形区分于终端形态的 OpenCode。
      'dsh' => Icons.hub_outlined,
      _ => Icons.smart_toy_outlined,
    };
    return Container(
      key: const Key('happy-session-provider-avatar'),
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.secondaryContainer,
        shape: BoxShape.circle,
      ),
      child: Icon(
        icon,
        size: AppSizes.iconMd,
        color: Theme.of(context).colorScheme.onSecondaryContainer,
      ),
    );
  }
}

class SessionStatusPresentation {
  const SessionStatusPresentation({
    required this.label,
    required this.tone,
    required this.icon,
  });

  final String label;
  final SessionStatusTone tone;
  final IconData icon;
}

enum SessionStatusTone { info, warning, neutral, error, success }

Color sessionStatusColor(BuildContext context, SessionStatusTone tone) =>
    switch (tone) {
      SessionStatusTone.info => context.appColors.info,
      SessionStatusTone.warning => context.appColors.warning,
      SessionStatusTone.neutral => context.appColors.neutral,
      SessionStatusTone.error => Theme.of(context).colorScheme.error,
      SessionStatusTone.success => context.appColors.success,
    };

/// 会话卡片状态行：状态仅来自 Relay/Terminal，会附上可选的最后活动相对时间。
String sessionStatusLineText(MobileSession session) {
  final presentation = sessionStatusPresentation(session);
  final time = relativeTime(session.lastActivityAt ?? session.updatedAt);
  return time.isEmpty ? presentation.label : '${presentation.label} · $time';
}

/// 会话状态完全来自 Relay/Terminal，上次活动时间不参与状态推断。
/// v0.8.6 A③：回合在途而 status 投影尚未收到任何 step 事件时（恒 idle 的
/// 窗口期），header 显示"执行中"——与状态条/相位行同源，消除矛盾表面。
SessionStatusPresentation sessionStatusPresentation(
  MobileSession? session, {
  bool turnInFlight = false,
}) {
  final status = session?.status;
  if (turnInFlight && status == MobileSessionStatus.idle) {
    return const SessionStatusPresentation(
      label: '执行中',
      tone: SessionStatusTone.info,
      icon: Icons.autorenew_outlined,
    );
  }
  return switch (status) {
    MobileSessionStatus.idle => const SessionStatusPresentation(
      label: '空闲',
      tone: SessionStatusTone.neutral,
      icon: Icons.pause_circle_outline,
    ),
    MobileSessionStatus.streaming => const SessionStatusPresentation(
      label: '生成中',
      tone: SessionStatusTone.info,
      icon: Icons.auto_awesome_outlined,
    ),
    MobileSessionStatus.waitingPermission => const SessionStatusPresentation(
      label: '等待确认',
      tone: SessionStatusTone.warning,
      icon: Icons.shield_outlined,
    ),
    MobileSessionStatus.waitingQuestion => const SessionStatusPresentation(
      label: '等待回答',
      tone: SessionStatusTone.warning,
      icon: Icons.help_outline,
    ),
    MobileSessionStatus.stopped => const SessionStatusPresentation(
      label: '已停止',
      tone: SessionStatusTone.neutral,
      icon: Icons.stop_circle_outlined,
    ),
    MobileSessionStatus.errored => const SessionStatusPresentation(
      label: '出现错误',
      tone: SessionStatusTone.error,
      icon: Icons.error_outline,
    ),
    MobileSessionStatus.offline => const SessionStatusPresentation(
      label: '离线',
      tone: SessionStatusTone.neutral,
      icon: Icons.cloud_off_outlined,
    ),
    _ => const SessionStatusPresentation(
      label: '在线',
      tone: SessionStatusTone.success,
      icon: Icons.forum_outlined,
    ),
  };
}

String relativeTime(DateTime? value) {
  if (value == null) return '';
  final difference = DateTime.now().difference(value).abs();
  if (difference.inMinutes < 1) return '刚刚';
  if (difference.inHours < 1) return '${difference.inMinutes} 分钟';
  if (difference.inDays < 1) return '${difference.inHours} 小时';
  return '${difference.inDays} 天';
}

/// v0.9.0 C3/T5：超时横幅次级行的事件新鲜度文案。
/// 只做展示格式化（客户端墙钟 HH:mm），网络健康判断不消费该值。
String formatTimeoutFreshness(DateTime? mergedAt) {
  if (mergedAt == null) return '尚未同步到事件';
  String two(int value) => value.toString().padLeft(2, '0');
  return '最近同步 '
      '${two(mergedAt.hour)}:${two(mergedAt.minute)}:${two(mergedAt.second)}';
}
