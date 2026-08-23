// Approval 接管面板（v0.5/P4）：composer chain 中 permission 的唯一交互面。
// 从 session_screens.dart 迁出；原 _PermissionRequestItem / _SystemNotice。
import 'package:flutter/material.dart';

import '../../../domain/session_models.dart';
import '../../../state/session_controller.dart';
class SessionApprovalPanel extends StatelessWidget {
  const SessionApprovalPanel({
    super.key,
    required this.event,
    required this.canWrite,
    required this.hasLease,
    required this.sessions,
    required this.deviceId,
  });

  final SessionTimelineEvent event;
  final bool canWrite;
  final bool hasLease;
  final SessionController sessions;
  final String? deviceId;

  @override
  Widget build(BuildContext context) {
    final permission = event.permission;
    if (permission == null) return SessionSystemNotice(event: event);
    final resolved =
        permission.resolved == true ||
        sessions.isRequestResolved('permission', permission.requestId);
    final pending = sessions.isRequestPending(permission.requestId);
    final enabled = canWrite && hasLease && !resolved && !pending;
    return Container(
      key: Key('permission-card-${permission.requestId}'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.tertiaryContainer,
        border: Border.all(color: Theme.of(context).colorScheme.tertiary),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            key: Key('permission-waiting-strip-${permission.requestId}'),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.tertiary,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.circle,
                  size: 8,
                  color: Theme.of(context).colorScheme.onTertiary,
                ),
                const SizedBox(width: 8),
                Text(
                  '等待确认',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onTertiary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (pending) ...[
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Theme.of(context).colorScheme.onTertiary,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Icon(Icons.shield_outlined),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  permission.title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // v0.5/P4-D：理由和命令可能是模型生成的长文本；滚动区只包住正文，
          // 决策按钮留在外层，避免命令过长时 allow/reject 不可达。
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 140),
            child: SingleChildScrollView(
              key: Key('permission-command-scroll-${permission.requestId}'),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(permission.summary),
                  if (permission.command != null) ...[
                    const SizedBox(height: 8),
                    Container(
                      key: Key(
                        'permission-command-text-${permission.requestId}',
                      ),
                      width: double.infinity,
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surface,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: Theme.of(context).dividerColor,
                        ),
                      ),
                      child: Text(
                        permission.command!,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              IconButton(
                key: Key('permission-reject-${permission.requestId}'),
                tooltip: '拒绝',
                onPressed: enabled
                    ? () => sessions.resolvePermission(
                        requestId: permission.requestId,
                        approved: false,
                        deviceId: deviceId,
                        canWrite: canWrite,
                      )
                    : null,
                icon: const Icon(Icons.close),
              ),
              IconButton(
                key: Key('permission-approve-${permission.requestId}'),
                tooltip: '允许',
                onPressed: enabled
                    ? () => sessions.resolvePermission(
                        requestId: permission.requestId,
                        approved: true,
                        deviceId: deviceId,
                        canWrite: canWrite,
                      )
                    : null,
                icon: const Icon(Icons.check),
              ),
            ],
          ),
          if (resolved)
            Text(
              '已处理',
              key: Key('permission-resolved-${permission.requestId}'),
              style: Theme.of(context).textTheme.labelMedium,
            ),
        ],
      ),
    );
  }
}


class SessionSystemNotice extends StatelessWidget {
  const SessionSystemNotice({super.key, required this.event});

  final SessionTimelineEvent event;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Align(
      key: Key('timeline-notice-${event.sequence}'),
      alignment: Alignment.centerLeft,
      child: Text(
        event.text == null ? event.label : '${event.label} · ${event.text}',
        style: Theme.of(context).textTheme.bodyMedium,
      ),
    ),
  );
}

