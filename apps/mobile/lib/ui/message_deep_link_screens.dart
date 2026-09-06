import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../app/providers.dart';
import '../domain/session_models.dart';
import '../state/message_deep_link_controller.dart';
import 'app_theme.dart';

/// P3 单消息深链页：只定位授权会话中目标消息。
///
/// 无权/已删除/过期 message ID 显示统一 empty 状态，不泄漏存在性；
/// 复制只复制可见消息文本，不附加 token、内部 ID 或隐藏正文。
class MessageDeepLinkScreen extends ConsumerStatefulWidget {
  const MessageDeepLinkScreen({
    required this.sessionId,
    required this.messageSequence,
    super.key,
  });

  final String sessionId;
  final int messageSequence;

  @override
  ConsumerState<MessageDeepLinkScreen> createState() =>
      _MessageDeepLinkScreenState();
}

class _MessageDeepLinkScreenState
    extends ConsumerState<MessageDeepLinkScreen> {
  @override
  void initState() {
    super.initState();
    // 深链跳转时在 initState 显式选中并加载会话；延迟到微任务避免 Riverpod
    // build 期修改 provider 的断言。
    Future<void>.microtask(() {
      if (!mounted) return;
      ref
          .read(messageDeepLinkControllerProvider)
          .load(sessionId: widget.sessionId);
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(messageDeepLinkControllerProvider);
    return Scaffold(
      key: const Key('message-deeplink-screen'),
      appBar: AppBar(
        title: const Text('消息'),
        leading: IconButton(
          key: const Key('message-deeplink-back-button'),
          tooltip: '返回会话',
          onPressed: () => context.go('/sessions/${widget.sessionId}'),
          icon: const Icon(Icons.arrow_back),
        ),
      ),
      body: SafeArea(
        top: false,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: _MessageDeepLinkBody(
              controller: controller,
              sessionId: widget.sessionId,
              targetSequence: widget.messageSequence,
            ),
          ),
        ),
      ),
    );
  }
}

class _MessageDeepLinkBody extends StatelessWidget {
  const _MessageDeepLinkBody({
    required this.controller,
    required this.sessionId,
    required this.targetSequence,
  });

  final MessageDeepLinkController controller;
  final String sessionId;
  final int targetSequence;

  @override
  Widget build(BuildContext context) {
    if (controller.phase == MessageDeepLinkPhase.loading) {
      return const Center(
        key: Key('message-deeplink-loading'),
        child: CircularProgressIndicator(),
      );
    }
    if (controller.phase == MessageDeepLinkPhase.error) {
      return _DeepLinkError(
        message: controller.errorMessage ?? '消息暂时不可用。',
        onRetry: () => controller.load(
          sessionId: controller.currentSessionId ?? sessionId,
        ),
      );
    }
    final event = controller.eventFor(targetSequence);
    if (event == null) {
      // 无权/不存在统一展示，不泄漏消息是否存在。
      return Center(
        key: const Key('message-deeplink-empty'),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xxl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.search_off_outlined, size: AppSizes.iconEmpty),
              const SizedBox(height: AppSpacing.md),
              Text(
                '未找到消息。链接可能已过期或无权访问。',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          ),
        ),
      );
    }
    return ListView(
      key: const Key('message-deeplink-list'),
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: [
        _MessageCard(event: event),
        const SizedBox(height: AppSpacing.md),
        const _DeepLinkBoundaryNote(),
      ],
    );
  }
}

class _MessageCard extends StatelessWidget {
  const _MessageCard({required this.event});

  final SessionTimelineEvent event;

  @override
  Widget build(BuildContext context) {
    final text = event.text?.trim();
    final content = text == null || text.isEmpty ? event.label : text;
    return Container(
      key: const Key('message-deeplink-card'),
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border.all(color: context.appColors.border),
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(_kindIcon(event.kind), size: AppSizes.iconSm),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  event.label,
                  style: Theme.of(context).textTheme.labelMedium,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          // 只选择可见消息文本；复制不含 token/内部 ID/隐藏正文。
          SelectableText(
            content,
            key: const Key('message-deeplink-text'),
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            '事件序号 ${event.sequence}',
            key: const Key('message-deeplink-sequence'),
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ],
      ),
    );
  }

  IconData _kindIcon(SessionTimelineKind kind) => switch (kind) {
    SessionTimelineKind.userMessage => Icons.person_outline,
    SessionTimelineKind.assistantMessage => Icons.smart_toy_outlined,
    // v0.8.4：thought 与 phase 是独立通道；deep-link 摘要里分别用脑图与脉冲图标。
    SessionTimelineKind.assistantThought => Icons.psychology_outlined,
    SessionTimelineKind.turnPhase => Icons.timelapse,
    SessionTimelineKind.toolActivity => Icons.build_outlined,
    SessionTimelineKind.permissionRequest => Icons.shield_outlined,
    SessionTimelineKind.questionRequest => Icons.help_outline,
    SessionTimelineKind.systemNotice => Icons.info_outline,
    SessionTimelineKind.encryptedPlaceholder => Icons.lock_outline,
  };
}

class _DeepLinkBoundaryNote extends StatelessWidget {
  const _DeepLinkBoundaryNote();

  @override
  Widget build(BuildContext context) => Container(
    key: const Key('message-deeplink-note'),
    padding: const EdgeInsets.all(AppSpacing.md),
    decoration: BoxDecoration(
      color: context.appColors.surfaceRaised,
      border: Border.all(color: context.appColors.border),
      borderRadius: BorderRadius.circular(AppRadius.card),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.info_outline, size: AppSizes.iconMd),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(
            '深链只定位当前账户可见会话中的消息；复制不会附加 token、内部 ID 或隐藏正文。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    ),
  );
}

class _DeepLinkError extends StatelessWidget {
  const _DeepLinkError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    key: const Key('message-deeplink-error'),
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
            key: const Key('message-deeplink-retry-button'),
            tooltip: '重试读取消息',
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
    ),
  );
}
