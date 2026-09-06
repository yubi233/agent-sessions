import 'package:flutter/material.dart';

import '../../app_theme.dart';

import '../../../domain/control_models.dart';

/// v0.5/P5-E4：TodoDock 是 `conversation.input.dock` 的只读 todo strip。
///
/// 对齐 DeepSeek Harness `TodoPanel`：只消费 Host/fixture 计算好的 whole-list
/// projection，列表为空时隐藏；本地不编辑、不删除、不重排，避免 UI 伪造 Host todo 状态。
class SessionTodoDock extends StatefulWidget {
  const SessionTodoDock({required this.todos, super.key});

  final List<SessionTodoItem> todos;

  @override
  State<SessionTodoDock> createState() => _SessionTodoDockState();
}

class _SessionTodoDockState extends State<SessionTodoDock> {
  bool _collapsed = true;

  int _count(TodoItemStatus status) =>
      widget.todos.where((item) => item.status == status).length;

  String get _progressLabel {
    final done = _count(TodoItemStatus.completed);
    final active = _count(TodoItemStatus.inProgress);
    final pending = _count(TodoItemStatus.pending);
    final parts = <String>[
      if (done > 0) '已完成 $done',
      if (active > 0) '进行中 $active',
      if (pending > 0) '待处理 $pending',
    ];
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    if (widget.todos.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Container(
      key: const Key('session-todo-dock'),
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            key: const Key('session-todo-dock-toggle'),
            borderRadius: BorderRadius.circular(AppRadius.card),
            onTap: () => setState(() => _collapsed = !_collapsed),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: AppSpacing.sm),
              child: Row(
                children: [
                  const Icon(Icons.checklist_outlined, size: AppSizes.iconMd),
                  const SizedBox(width: AppSpacing.sm),
                  Text('Todo', style: theme.textTheme.labelLarge),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      _progressLabel,
                      key: const Key('session-todo-dock-progress'),
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  Icon(
                    _collapsed
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down,
                    size: AppSizes.iconMd,
                  ),
                ],
              ),
            ),
          ),
          if (!_collapsed)
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.sm, 0, AppSpacing.sm, AppSpacing.sm),
              child: Column(
                key: const Key('session-todo-dock-list'),
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final item in widget.todos) _TodoDockItem(item: item),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _TodoDockItem extends StatelessWidget {
  const _TodoDockItem({required this.item});

  final SessionTodoItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final icon = switch (item.status) {
      TodoItemStatus.completed => Icons.check_circle_outline,
      TodoItemStatus.inProgress => Icons.sync_outlined,
      TodoItemStatus.pending => Icons.radio_button_unchecked,
    };
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.sm),
      child: Row(
        key: Key(
          'session-todo-item-${item.status.wireValue}-${item.content.hashCode}',
        ),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: AppSizes.iconSm, color: theme.colorScheme.primary),
          const SizedBox(width: AppSpacing.sm),
          Expanded(child: Text(item.content)),
          const SizedBox(width: AppSpacing.sm),
          Text(
            item.status.label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
