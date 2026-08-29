import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../domain/session_projection_models.dart';
import '../../../state/session_message_feedback_controller.dart';

typedef SessionForkHandler = Future<void> Function(String messageId);

/// v0.5 Chat node 的 keyed renderer。
///
/// 这里消费的是 display-safe projection，不直接读取 Relay event，也不处理写命令。
/// 这样 pending interaction、密文占位和隐藏推理都由投影层先裁剪，再进入 UI。
class SessionChatNodeSeat extends StatelessWidget {
  const SessionChatNodeSeat({
    required this.node,
    this.onOpenFile,
    this.onInspect,
    this.onFork,
    this.feedbackController,
    super.key,
  });

  final ConversationNode node;
  final Future<void> Function(String path)? onOpenFile;
  final void Function(String target)? onInspect;
  final SessionForkHandler? onFork;
  final SessionMessageFeedbackController? feedbackController;

  @override
  Widget build(BuildContext context) {
    return KeyedSubtree(
      key: Key('session-chat-node-${node.key}'),
      child: Semantics(
        container: true,
        label: '会话节点 ${node.label}',
        child: switch (node.kind) {
          ConversationNodeKind.user => _ChatBubble(
            node: node,
            user: true,
            onOpenFile: onOpenFile,
          ),
          ConversationNodeKind.assistant => _ChatBubble(
            node: node,
            user: false,
            onOpenFile: onOpenFile,
            onFork: onFork,
            feedbackController: feedbackController,
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
  const _ChatBubble({
    required this.node,
    required this.user,
    this.onOpenFile,
    this.onFork,
    this.feedbackController,
  });

  final ConversationNode node;
  final bool user;
  final Future<void> Function(String path)? onOpenFile;
  final SessionForkHandler? onFork;
  final SessionMessageFeedbackController? feedbackController;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final background = user
        ? scheme.primaryContainer
        : scheme.surfaceContainerHigh;
    final foreground = user ? scheme.onPrimaryContainer : scheme.onSurface;
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
                border: Border.all(
                  color: user
                      ? scheme.primary.withValues(alpha: 0.22)
                      : scheme.outlineVariant,
                ),
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(12),
                  topRight: const Radius.circular(12),
                  bottomLeft: Radius.circular(user ? 12 : 4),
                  bottomRight: Radius.circular(user ? 4 : 12),
                ),
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
                    user
                        ? Text(node.text!, style: TextStyle(color: foreground))
                        : _DisplaySafeMarkdown(
                            text: node.text!,
                            color: foreground,
                          ),
                  ],
                  if (node.references.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    _ReferenceChips(
                      sequence: node.sequence,
                      references: node.references,
                      foreground: foreground,
                      onOpenFile: onOpenFile,
                    ),
                  ],
                ],
              ),
            ),
            if (!user) _AssistantTailStatus(node: node),
            _MessageActionsRow(
              node: node,
              onFork: onFork,
              feedbackController: feedbackController,
            ),
          ],
        ),
      ),
    );
  }
}

class _AssistantTailStatus extends StatelessWidget {
  const _AssistantTailStatus({required this.node});

  final ConversationNode node;

  @override
  Widget build(BuildContext context) {
    final stopped = const {
      'stopped',
      'interrupted',
      'aborted',
    }.contains(node.toolStatus?.toLowerCase());
    final label = node.isStreaming
        ? '运行中'
        : stopped
        ? '已停止'
        : node.completedTurn
        ? '已完成'
        : null;
    if (label == null) return const SizedBox.shrink();
    return Padding(
      key: Key('session-assistant-tail-status-${node.sequence}'),
      padding: const EdgeInsets.only(top: 3),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            node.isStreaming
                ? Icons.more_horiz
                : stopped
                ? Icons.stop_circle_outlined
                : Icons.check_circle_outline,
            size: 14,
          ),
          const SizedBox(width: 4),
          Text(label, style: Theme.of(context).textTheme.labelSmall),
        ],
      ),
    );
  }
}

class _DisplaySafeMarkdown extends StatelessWidget {
  const _DisplaySafeMarkdown({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context).textTheme.bodyMedium?.copyWith(color: color);
    final children = <Widget>[];
    var fenced = false;
    final code = <String>[];
    for (final line in text.split('\n')) {
      if (line.trimLeft().startsWith('```')) {
        if (fenced) {
          children.add(_MarkdownCodeBlock(text: code.join('\n')));
          code.clear();
        }
        fenced = !fenced;
        continue;
      }
      if (fenced) {
        code.add(line);
        continue;
      }
      if (line.startsWith('# ')) {
        children.add(
          Text(
            line.substring(2),
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
            ),
          ),
        );
      } else if (line.startsWith('## ')) {
        children.add(
          Text(
            line.substring(3),
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
            ),
          ),
        );
      } else if (line.startsWith('- ') || line.startsWith('* ')) {
        children.add(
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('• ', style: base),
              Expanded(
                child: _InlineMarkdown(text: line.substring(2), style: base),
              ),
            ],
          ),
        );
      } else if (line.isEmpty) {
        children.add(const SizedBox(height: 6));
      } else {
        children.add(_InlineMarkdown(text: line, style: base));
      }
    }
    if (code.isNotEmpty) {
      children.add(_MarkdownCodeBlock(text: code.join('\n')));
    }
    return Column(
      key: const Key('session-assistant-markdown'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }
}

class _InlineMarkdown extends StatelessWidget {
  const _InlineMarkdown({required this.text, required this.style});

  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final spans = <InlineSpan>[];
    final expression = RegExp(r'(`[^`]+`|\*\*[^*]+\*\*)');
    var cursor = 0;
    for (final match in expression.allMatches(text)) {
      if (match.start > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, match.start)));
      }
      final token = match.group(0)!;
      if (token.startsWith('`')) {
        spans.add(
          TextSpan(
            text: token.substring(1, token.length - 1),
            style: style?.copyWith(
              fontFamily: 'monospace',
              backgroundColor: Theme.of(
                context,
              ).colorScheme.surfaceContainerHighest,
            ),
          ),
        );
      } else {
        spans.add(
          TextSpan(
            text: token.substring(2, token.length - 2),
            style: style?.copyWith(fontWeight: FontWeight.w700),
          ),
        );
      }
      cursor = match.end;
    }
    if (cursor < text.length) spans.add(TextSpan(text: text.substring(cursor)));
    return Text.rich(TextSpan(style: style, children: spans));
  }
}

class _MarkdownCodeBlock extends StatelessWidget {
  const _MarkdownCodeBlock({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    constraints: const BoxConstraints(maxHeight: 180),
    margin: const EdgeInsets.symmetric(vertical: 4),
    padding: const EdgeInsets.all(10),
    color: Theme.of(context).colorScheme.surfaceContainerHighest,
    child: SingleChildScrollView(
      child: SelectableText(
        text,
        style: const TextStyle(fontFamily: 'monospace'),
      ),
    ),
  );
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
    this.onOpenFile,
  });

  final int sequence;
  final List<ConversationReferenceChip> references;
  final Color foreground;
  final Future<void> Function(String path)? onOpenFile;

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
          onOpenFile: onOpenFile,
        ),
    ],
  );
}

class _ReferenceChip extends StatelessWidget {
  const _ReferenceChip({
    required this.reference,
    required this.foreground,
    this.onOpenFile,
    super.key,
  });

  final ConversationReferenceChip reference;
  final Color foreground;
  final Future<void> Function(String path)? onOpenFile;

  @override
  Widget build(BuildContext context) {
    final icon = switch (reference.kind) {
      ConversationReferenceKind.command => Icons.terminal_outlined,
      ConversationReferenceKind.session => Icons.account_tree_outlined,
      ConversationReferenceKind.file => Icons.insert_drive_file_outlined,
      ConversationReferenceKind.folder => Icons.folder_outlined,
    };
    final canOpen =
        reference.kind == ConversationReferenceKind.file &&
        reference.target?.trim().isNotEmpty == true &&
        onOpenFile != null;
    if (canOpen) {
      return ActionChip(
        avatar: Icon(icon, size: 14, color: foreground.withValues(alpha: 0.74)),
        label: Text(reference.label),
        onPressed: () => unawaited(onOpenFile!(reference.target!)),
      );
    }
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
  const _MessageActionsRow({
    required this.node,
    this.onFork,
    this.feedbackController,
  });

  final ConversationNode node;
  final SessionForkHandler? onFork;
  final SessionMessageFeedbackController? feedbackController;

  @override
  State<_MessageActionsRow> createState() => _MessageActionsRowState();
}

class _MessageActionsRowState extends State<_MessageActionsRow> {
  String? _feedback;
  final LayerLink _noteLink = LayerLink();
  OverlayEntry? _noteOverlay;
  final FocusNode _noteFocus = FocusNode();
  final FocusNode _noteTriggerFocus = FocusNode();
  final TextEditingController _noteController = TextEditingController();
  bool _noteOpen = false;

  @override
  void initState() {
    super.initState();
    _noteFocus.onKeyEvent = (_, event) {
      if (event is KeyDownEvent &&
          event.logicalKey == LogicalKeyboardKey.escape) {
        _closeNote();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    };
  }

  @override
  void dispose() {
    _closeNote(restoreFocus: false);
    _noteFocus.dispose();
    _noteTriggerFocus.dispose();
    _noteController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final node = widget.node;
    final feedback = widget.feedbackController;
    final messageId = node.messageId;
    final item = messageId == null ? null : feedback?.itemFor(messageId);
    final feedbackError = messageId == null
        ? null
        : feedback?.errorFor(messageId);
    final feedbackBusy =
        messageId != null &&
        (feedback?.isLoading(messageId) == true ||
            feedback?.isMutating(messageId) == true);
    final hasActions =
        node.canCopy ||
        node.showTimestamp ||
        node.canFork ||
        node.forkUnavailable ||
        node.feedbackAvailable;
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
                node.canFork && widget.onFork != null
                    ? 'session-message-fork-${node.sequence}'
                    : 'session-message-fork-unavailable-${node.sequence}',
              ),
              iconSize: 18,
              constraints: const BoxConstraints.tightFor(width: 32, height: 32),
              padding: EdgeInsets.zero,
              tooltip: node.canFork && widget.onFork != null
                  ? '从这里分支'
                  : '当前 Relay 未提供分支写入能力',
              onPressed: node.canFork && widget.onFork != null
                  ? () => unawaited(widget.onFork!(node.messageId!))
                  : null,
              icon: const Icon(Icons.call_split_outlined),
            ),
          if (node.feedbackAvailable && messageId != null) ...[
            _FeedbackButton(
              key: Key(_sequenceKey('session-message-like-', node.sequence)),
              label: '喜欢',
              icon: Icons.thumb_up_outlined,
              active: item?.rating == ConversationFeedbackRating.positive,
              enabled: feedback != null && !feedbackBusy,
              onEnsure: () async => feedback?.ensure(messageId),
              onPressed: () => unawaited(
                feedback!.toggle(
                  messageId,
                  ConversationFeedbackRating.positive,
                ),
              ),
            ),
            _FeedbackButton(
              key: Key(_sequenceKey('session-message-dislike-', node.sequence)),
              label: '不喜欢',
              icon: Icons.thumb_down_outlined,
              active: item?.rating == ConversationFeedbackRating.negative,
              enabled: feedback != null && !feedbackBusy,
              onEnsure: () async => feedback?.ensure(messageId),
              onPressed: () => unawaited(
                feedback!.toggle(
                  messageId,
                  ConversationFeedbackRating.negative,
                ),
              ),
            ),
            if (item != null)
              CompositedTransformTarget(
                link: _noteLink,
                child: IconButton(
                  key: Key(
                    _sequenceKey('session-message-note-', node.sequence),
                  ),
                  focusNode: _noteTriggerFocus,
                  tooltip: item.note?.isNotEmpty == true ? '编辑反馈备注' : '添加反馈备注',
                  iconSize: 18,
                  constraints: const BoxConstraints.tightFor(
                    width: 32,
                    height: 32,
                  ),
                  padding: EdgeInsets.zero,
                  onPressed: feedbackBusy ? null : _toggleNote,
                  icon: Icon(
                    item.note?.isNotEmpty == true
                        ? Icons.sticky_note_2
                        : Icons.note_add_outlined,
                  ),
                ),
              ),
          ],
          if (_feedback != null)
            Text(
              _feedback!,
              key: Key('session-message-action-feedback-${node.sequence}'),
              style: Theme.of(context).textTheme.labelSmall,
            ),
          if (feedbackError != null)
            Text(
              _feedbackErrorText(feedbackError),
              key: Key(
                _sequenceKey('session-message-feedback-error-', node.sequence),
              ),
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.error,
              ),
            ),
        ],
      ),
    );
  }

  String _feedbackErrorText(String code) => switch (code) {
    'version-conflict' => '反馈已被其他设备修改，请重试。',
    'unsupported' => '当前 Relay 未声明消息反馈能力。',
    'load-failed' => '反馈读取失败，重新聚焦可重试。',
    'busy' => '反馈操作进行中。',
    'validation' => '反馈备注需要先选择喜欢或不喜欢。',
    _ => '反馈保存失败，请重试。',
  };

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

  void _toggleNote() {
    final messageId = widget.node.messageId;
    final item = messageId == null
        ? null
        : widget.feedbackController?.itemFor(messageId);
    if (messageId == null || item == null) return;
    if (_noteOpen) {
      _closeNote();
      return;
    }
    _noteController.text = item.note ?? '';
    _noteOpen = true;
    _noteOverlay = OverlayEntry(
      builder: (context) => Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: _closeNote,
              child: const SizedBox.expand(),
            ),
          ),
          CompositedTransformFollower(
            link: _noteLink,
            showWhenUnlinked: false,
            offset: const Offset(0, 36),
            child: Material(
              elevation: 8,
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 260,
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextField(
                        key: Key(
                          _sequenceKey(
                            'session-message-note-input-',
                            widget.node.sequence,
                          ),
                        ),
                        controller: _noteController,
                        focusNode: _noteFocus,
                        maxLines: 3,
                        decoration: const InputDecoration(
                          labelText: '反馈备注',
                          isDense: true,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            key: Key(
                              _sequenceKey(
                                'session-message-note-cancel-',
                                widget.node.sequence,
                              ),
                            ),
                            onPressed: _closeNote,
                            child: const Text('取消'),
                          ),
                          FilledButton(
                            key: Key(
                              _sequenceKey(
                                'session-message-note-save-',
                                widget.node.sequence,
                              ),
                            ),
                            onPressed: () => unawaited(_saveNote(messageId)),
                            child: const Text('保存'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
    Overlay.of(context).insert(_noteOverlay!);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_noteOpen) _noteFocus.requestFocus();
    });
  }

  Future<void> _saveNote(String messageId) async {
    final controller = widget.feedbackController;
    if (controller == null) return;
    final result = await controller.saveNote(messageId, _noteController.text);
    if (mounted && result.ok) _closeNote();
  }

  void _closeNote({bool restoreFocus = true}) {
    if (!_noteOpen && _noteOverlay == null) return;
    _noteOpen = false;
    _noteOverlay?.remove();
    _noteOverlay = null;
    if (restoreFocus && mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _noteTriggerFocus.requestFocus();
      });
    }
  }

  String _formatTime(DateTime value) {
    final hour = value.hour.toString().padLeft(2, '0');
    final minute = value.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  String _sequenceKey(String prefix, int sequence) => '$prefix$sequence';
}

class _FeedbackButton extends StatelessWidget {
  const _FeedbackButton({
    required this.label,
    required this.icon,
    required this.active,
    required this.enabled,
    required this.onEnsure,
    required this.onPressed,
    super.key,
  });

  final String label;
  final IconData icon;
  final bool active;
  final bool enabled;
  final Future<void> Function() onEnsure;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Focus(
    onFocusChange: (focused) {
      if (focused) unawaited(onEnsure());
    },
    child: Semantics(
      button: true,
      toggled: active,
      label: active ? '$label（已选择）' : label,
      child: MouseRegion(
        onEnter: (_) => unawaited(onEnsure()),
        child: IconButton(
          tooltip: label,
          iconSize: 18,
          constraints: const BoxConstraints.tightFor(width: 32, height: 32),
          padding: EdgeInsets.zero,
          color: active ? Theme.of(context).colorScheme.primary : null,
          onPressed: enabled ? onPressed : null,
          icon: Icon(icon),
        ),
      ),
    ),
  );
}

class _ReasoningRow extends StatelessWidget {
  const _ReasoningRow({required this.node});

  final ConversationNode node;

  @override
  Widget build(BuildContext context) {
    final summary = node.safeReasoningSummary?.trim();
    return Container(
      key: Key('session-reasoning-row-${node.sequence}'),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      // ExpansionTile 的 ListTile 需要最近的 Material 承载背景和水波纹，
      // 否则外层 DecoratedBox 会触发 Flutter 的不可见水波纹断言。
      child: Material(
        type: MaterialType.transparency,
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
    return Container(
      key: Key('session-compact-node-${node.sequence}-${node.kind.name}'),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        border: Border.all(color: color.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(8),
      ),
      // 与推理折叠行保持同一 Material 边界，保证点击反馈不会被卡片背景遮住。
      child: Material(
        type: MaterialType.transparency,
        child: ExpansionTile(
          leading: Icon(Icons.build_outlined, color: color),
          title: Text(
            node.label,
            // 把稳定定位键放在可点击标题上，避免懒加载/底部 composer 使整行中心落到视口外。
            key: Key('session-tool-details-${node.sequence}'),
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
            if (details?.subcalls.isNotEmpty == true)
              _ToolSubcallTree(
                key: const ValueKey('session-tool-subcalls'),
                subcalls: details!.subcalls,
                onOpenFile: onOpenFile,
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
      ),
    );
  }
}

class _ToolSubcallTree extends StatelessWidget {
  const _ToolSubcallTree({
    required this.subcalls,
    required this.onOpenFile,
    super.key,
  });

  final List<ConversationToolSubcall> subcalls;
  final Future<void> Function(String path)? onOpenFile;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 12, top: 4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final call in subcalls)
          Container(
            key: ValueKey(call.callId),
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.only(left: 10),
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  call.label,
                  style: Theme.of(context).textTheme.labelMedium,
                ),
                if (call.status?.trim().isNotEmpty == true)
                  Text(
                    call.status!,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                if (call.input?.trim().isNotEmpty == true)
                  _ToolDetailBlock(label: 'IN', text: call.input!),
                if (call.output?.trim().isNotEmpty == true)
                  _ToolDetailBlock(label: 'OUT', text: call.output!),
                if (call.subcalls.isNotEmpty)
                  _ToolSubcallTree(
                    subcalls: call.subcalls,
                    onOpenFile: onOpenFile,
                  ),
              ],
            ),
          ),
      ],
    ),
  );
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
