import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../domain/session_projection_models.dart';

/// v0.5 Chat node 的 keyed renderer。
///
/// 这里消费的是 display-safe projection，不直接读取 Relay event，也不处理写命令。
/// 这样 pending interaction、密文占位和隐藏推理都由投影层先裁剪，再进入 UI。
class SessionChatNodeSeat extends StatelessWidget {
  const SessionChatNodeSeat({
    required this.node,
    this.onOpenFile,
    this.onInspect,
    super.key,
  });

  final ConversationNode node;
  final Future<void> Function(String path)? onOpenFile;
  final void Function(String target)? onInspect;

  @override
  Widget build(BuildContext context) {
    return KeyedSubtree(
      key: Key('session-chat-node-${node.key}'),
      child: Semantics(
        container: true,
        label: '会话节点 ${node.label}',
        child: switch (node.kind) {
          ConversationNodeKind.user => _ChatBubble(node: node, user: true),
          ConversationNodeKind.assistant => _ChatBubble(
            node: node,
            user: false,
          ),
          ConversationNodeKind.reasoning => _ReasoningRow(node: node),
          ConversationNodeKind.tool => _ToolStepRow(
            node: node,
            onOpenFile: onOpenFile,
            onInspect: onInspect,
          ),
          ConversationNodeKind.command => _CompactSystemRow(
            node: node,
            icon: Icons.terminal_outlined,
            tone: _SystemRowTone.neutral,
            onOpenFile: onOpenFile,
          ),
          ConversationNodeKind.compaction => _CompactSystemRow(
            node: node,
            icon: Icons.compress_outlined,
            tone: _SystemRowTone.neutral,
          ),
          ConversationNodeKind.retry => _CompactSystemRow(
            node: node,
            icon: Icons.replay_outlined,
            tone: _SystemRowTone.warning,
          ),
          ConversationNodeKind.error => _CompactSystemRow(
            node: node,
            icon: Icons.error_outline,
            tone: _SystemRowTone.error,
          ),
          ConversationNodeKind.encrypted => _CompactSystemRow(
            node: node,
            icon: Icons.lock_outline,
            tone: _SystemRowTone.neutral,
          ),
          ConversationNodeKind.notice => _CompactSystemRow(
            node: node,
            icon: Icons.info_outline,
            tone: _SystemRowTone.neutral,
          ),
          ConversationNodeKind.turnTail => _CompactSystemRow(
            node: node,
            icon: Icons.done_all_outlined,
            tone: _SystemRowTone.neutral,
          ).maybeProducedFiles(node, onOpenFile),
        },
      ),
    );
  }
}

class _ChatBubble extends StatelessWidget {
  const _ChatBubble({required this.node, required this.user});

  final ConversationNode node;
  final bool user;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final background = user
        ? const Color(0xffffefb0)
        : scheme.surfaceContainerHigh;
    final foreground = user ? const Color(0xff1d1d1f) : scheme.onSurface;
    return Align(
      alignment: user ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 382),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: user
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: background,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        node.label,
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(
                              color: foreground.withValues(alpha: 0.72),
                            ),
                      ),
                      if (node.pendingSteering) ...[
                        const SizedBox(width: 8),
                        _PendingSteeringBadge(foreground: foreground),
                      ],
                    ],
                  ),
                  if (node.text?.trim().isNotEmpty == true) ...[
                    const SizedBox(height: 6),
                    Text(node.text!, style: TextStyle(color: foreground)),
                  ],
                  if (node.references.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    _ReferenceChips(
                      sequence: node.sequence,
                      references: node.references,
                      foreground: foreground,
                    ),
                  ],
                ],
              ),
            ),
            _MessageActionsRow(node: node),
          ],
        ),
      ),
    );
  }
}

class _PendingSteeringBadge extends StatelessWidget {
  const _PendingSteeringBadge({required this.foreground});

  final Color foreground;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    key: const Key('session-pending-steering-badge'),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(999),
      border: Border.all(color: foreground.withValues(alpha: 0.36)),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      child: Text(
        '等待接管',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: foreground.withValues(alpha: 0.74),
        ),
      ),
    ),
  );
}

class _ReferenceChips extends StatelessWidget {
  const _ReferenceChips({
    required this.sequence,
    required this.references,
    required this.foreground,
  });

  final int sequence;
  final List<ConversationReferenceChip> references;
  final Color foreground;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 6,
    runSpacing: 6,
    children: [
      for (var index = 0; index < references.length; index++)
        _ReferenceChip(
          key: Key('session-reference-chip-$sequence-$index'),
          reference: references[index],
          foreground: foreground,
        ),
    ],
  );
}

class _ReferenceChip extends StatelessWidget {
  const _ReferenceChip({
    required this.reference,
    required this.foreground,
    super.key,
  });

  final ConversationReferenceChip reference;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    final icon = switch (reference.kind) {
      ConversationReferenceKind.command => Icons.terminal_outlined,
      ConversationReferenceKind.session => Icons.account_tree_outlined,
      ConversationReferenceKind.file => Icons.insert_drive_file_outlined,
      ConversationReferenceKind.folder => Icons.folder_outlined,
    };
    return DecoratedBox(
      decoration: BoxDecoration(
        color: foreground.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: foreground.withValues(alpha: 0.74)),
            const SizedBox(width: 4),
            Text(
              reference.label,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: foreground.withValues(alpha: 0.86),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MessageActionsRow extends StatefulWidget {
  const _MessageActionsRow({required this.node});

  final ConversationNode node;

  @override
  State<_MessageActionsRow> createState() => _MessageActionsRowState();
}

class _MessageActionsRowState extends State<_MessageActionsRow> {
  String? _feedback;

  @override
  Widget build(BuildContext context) {
    final node = widget.node;
    final hasActions =
        node.canCopy ||
        node.showTimestamp ||
        node.canFork ||
        node.forkUnavailable;
    if (!hasActions) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Wrap(
        key: Key('session-message-actions-${node.sequence}'),
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 4,
        children: [
          if (node.showTimestamp && node.createdAt != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                _formatTime(node.createdAt!),
                key: Key('session-message-time-${node.sequence}'),
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
          if (node.canCopy)
            IconButton(
              key: Key('session-message-copy-${node.sequence}'),
              tooltip: '复制',
              iconSize: 18,
              constraints: const BoxConstraints.tightFor(width: 32, height: 32),
              padding: EdgeInsets.zero,
              onPressed: () => _copy(node),
              icon: const Icon(Icons.copy_outlined),
            ),
          if (node.canFork || node.forkUnavailable)
            IconButton(
              key: Key(
                node.canFork
                    ? 'session-message-fork-${node.sequence}'
                    : 'session-message-fork-unavailable-${node.sequence}',
              ),
              tooltip: node.canFork ? '从这里分支' : '仅可从可分支的完成轮次尾部创建分支',
              iconSize: 18,
              constraints: const BoxConstraints.tightFor(width: 32, height: 32),
              padding: EdgeInsets.zero,
              onPressed: node.canFork ? () => _markForkRequested(node) : null,
              icon: const Icon(Icons.call_split_outlined),
            ),
          if (_feedback != null)
            Text(
              _feedback!,
              key: Key('session-message-action-feedback-${node.sequence}'),
              style: Theme.of(context).textTheme.labelSmall,
            ),
        ],
      ),
    );
  }

  Future<void> _copy(ConversationNode node) async {
    final text = node.copyText ?? node.text ?? '';
    try {
      await Clipboard.setData(ClipboardData(text: text));
      if (!mounted) return;
      setState(() => _feedback = '已复制');
    } catch (_) {
      if (!mounted) return;
      setState(() => _feedback = '复制失败');
    }
  }

  void _markForkRequested(ConversationNode node) {
    // P2-B 只建立 action chrome；真实 fork 写入口仍要等 Relay/Provider capability 接入。
    setState(() => _feedback = '分支入口待接入');
  }

  String _formatTime(DateTime value) {
    final hour = value.hour.toString().padLeft(2, '0');
    final minute = value.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }
}

class _ReasoningRow extends StatelessWidget {
  const _ReasoningRow({required this.node});

  final ConversationNode node;

  @override
  Widget build(BuildContext context) {
    final summary = node.safeReasoningSummary?.trim();
    return Card(
      key: Key('session-reasoning-row-${node.sequence}'),
      elevation: 0,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: ExpansionTile(
        leading: const Icon(Icons.psychology_alt_outlined),
        title: Text(node.isStreaming ? 'Think · 运行中' : 'Think'),
        subtitle: Text(
          summary?.isNotEmpty == true ? summary! : '没有可展示的安全推理摘要',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                summary?.isNotEmpty == true
                    ? summary!
                    : '上游未提供 display-safe summary。',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ToolStepRow extends StatelessWidget {
  const _ToolStepRow({
    required this.node,
    required this.onOpenFile,
    required this.onInspect,
  });

  final ConversationNode node;
  final Future<void> Function(String path)? onOpenFile;
  final void Function(String target)? onInspect;

  @override
  Widget build(BuildContext context) {
    final details = node.toolDetails;
    final hasDetails = details?.hasContent == true;
    final hasPath = node.filePath?.trim().isNotEmpty == true;
    if (!hasDetails) {
      return _CompactSystemRow(
        node: node,
        icon: Icons.build_outlined,
        tone: node.isStreaming
            ? _SystemRowTone.warning
            : _SystemRowTone.neutral,
        trailing: node.toolStatus,
        onOpenFile: onOpenFile,
      );
    }

    final scheme = Theme.of(context).colorScheme;
    final tone = node.isStreaming
        ? _SystemRowTone.warning
        : _SystemRowTone.neutral;
    final color = switch (tone) {
      _SystemRowTone.neutral => scheme.onSurfaceVariant,
      _SystemRowTone.warning => scheme.tertiary,
      _SystemRowTone.error => scheme.error,
    };
    final detail = node.toolStatus ?? node.text;
    return Card(
      key: Key('session-compact-node-${node.sequence}-${node.kind.name}'),
      elevation: 0,
      color: scheme.surfaceContainerLowest,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: color.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: ExpansionTile(
        key: Key('session-tool-details-${node.sequence}'),
        leading: Icon(Icons.build_outlined, color: color),
        title: Text(
          node.label,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
            color: color,
            fontWeight: FontWeight.w700,
          ),
        ),
        subtitle: _ToolRowSubtitle(
          detail: detail,
          node: node,
          hasPath: hasPath,
          onOpenFile: onOpenFile,
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
        children: [
          if (details?.input?.trim().isNotEmpty == true)
            _ToolDetailBlock(
              key: Key('session-tool-input-${node.sequence}'),
              label: 'IN',
              text: details!.input!,
            ),
          if (details?.output?.trim().isNotEmpty == true)
            _ToolDetailBlock(
              key: Key('session-tool-output-${node.sequence}'),
              label: 'OUT',
              text: details!.output!,
            ),
          if (details?.inspectTarget?.trim().isNotEmpty == true)
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                key: Key('session-tool-inspect-${node.sequence}'),
                onPressed: () => onInspect?.call(details!.inspectTarget!),
                icon: const Icon(Icons.manage_search_outlined, size: 16),
                label: const Text('Inspect'),
              ),
            ),
        ],
      ),
    );
  }
}

class _ToolRowSubtitle extends StatelessWidget {
  const _ToolRowSubtitle({
    required this.detail,
    required this.node,
    required this.hasPath,
    required this.onOpenFile,
  });

  final String? detail;
  final ConversationNode node;
  final bool hasPath;
  final Future<void> Function(String path)? onOpenFile;

  @override
  Widget build(BuildContext context) {
    final hasDetail = detail?.trim().isNotEmpty == true;
    if (!hasDetail && !hasPath) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (hasDetail) Text(detail!),
        if (hasPath)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: Key('session-tool-open-path-${node.sequence}'),
              onPressed: () => onOpenFile?.call(node.filePath!),
              icon: const Icon(Icons.open_in_new_outlined, size: 16),
              label: Text(node.filePath!),
            ),
          ),
      ],
    );
  }
}

class _ToolDetailBlock extends StatelessWidget {
  const _ToolDetailBlock({required this.label, required this.text, super.key});

  final String label;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 180),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
        ),
        child: SingleChildScrollView(
          key: Key('session-tool-detail-scroll-$label'),
          padding: const EdgeInsets.all(10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 34,
                child: Text(
                  label,
                  style: Theme.of(
                    context,
                  ).textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w800),
                ),
              ),
              Expanded(
                child: Text(
                  text,
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

extension _ProducedFilesRowSwitch on Widget {
  Widget maybeProducedFiles(
    ConversationNode node,
    Future<void> Function(String path)? onOpenFile,
  ) {
    if (node.producedFiles.isEmpty) return this;
    return _ProducedFilesRow(node: node, onOpenFile: onOpenFile);
  }
}

class _ProducedFilesRow extends StatelessWidget {
  const _ProducedFilesRow({required this.node, required this.onOpenFile});

  static const _visibleLimit = 3;

  final ConversationNode node;
  final Future<void> Function(String path)? onOpenFile;

  @override
  Widget build(BuildContext context) {
    final files = node.producedFiles;
    final visibleCount = files.length < _visibleLimit
        ? files.length
        : _visibleLimit;
    final hidden = files.length - visibleCount;
    return Container(
      key: Key('session-produced-files-row-${node.sequence}'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(
            color: Theme.of(context).colorScheme.primary,
            width: 3,
          ),
        ),
        color: Theme.of(context).colorScheme.surfaceContainerLowest,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.task_outlined,
                size: 18,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Text(
                '产物文件',
                style: Theme.of(
                  context,
                ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (var index = 0; index < visibleCount; index++)
                ActionChip(
                  key: Key('session-produced-file-${node.sequence}-$index'),
                  avatar: const Icon(
                    Icons.insert_drive_file_outlined,
                    size: 16,
                  ),
                  label: Text(files[index].label),
                  tooltip: files[index].path,
                  onPressed: () => onOpenFile?.call(files[index].path),
                ),
              if (hidden > 0)
                Chip(
                  key: Key('session-produced-files-more-${node.sequence}'),
                  label: Text('+$hidden'),
                ),
              if (hidden > 0)
                TextButton.icon(
                  key: Key(
                    'session-produced-files-open-folder-${node.sequence}',
                  ),
                  onPressed: () => onOpenFile?.call('.'),
                  icon: const Icon(Icons.folder_open_outlined, size: 16),
                  label: const Text('打开目录'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

enum _SystemRowTone { neutral, warning, error }

class _CompactSystemRow extends StatelessWidget {
  const _CompactSystemRow({
    required this.node,
    required this.icon,
    required this.tone,
    this.trailing,
    this.onOpenFile,
  });

  final ConversationNode node;
  final IconData icon;
  final _SystemRowTone tone;
  final String? trailing;
  final Future<void> Function(String path)? onOpenFile;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = switch (tone) {
      _SystemRowTone.neutral => scheme.onSurfaceVariant,
      _SystemRowTone.warning => scheme.tertiary,
      _SystemRowTone.error => scheme.error,
    };
    final detail = trailing ?? node.toolStatus ?? node.text;
    return Container(
      key: Key('session-compact-node-${node.sequence}-${node.kind.name}'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: color, width: 3)),
        color: scheme.surfaceContainerLowest,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  node.label,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (detail?.trim().isNotEmpty == true) ...[
                  const SizedBox(height: 4),
                  Text(detail!, style: Theme.of(context).textTheme.bodySmall),
                ],
                if (node.filePath?.trim().isNotEmpty == true) ...[
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      key: Key('session-tool-open-path-${node.sequence}'),
                      onPressed: () => onOpenFile?.call(node.filePath!),
                      icon: const Icon(Icons.open_in_new_outlined, size: 16),
                      label: Text(node.filePath!),
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
