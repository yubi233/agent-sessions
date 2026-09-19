import 'dart:async';

import 'package:flutter/material.dart';

import '../../app_theme.dart';
import 'package:flutter/services.dart';

import '../../../domain/session_projection_models.dart';
import 'session_markdown_text.dart';
import 'typewriter_reveal_text.dart';
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
              padding: const EdgeInsets.all(AppSpacing.md),
              decoration: BoxDecoration(
                color: background,
                border: Border.all(
                  color: user
                      ? scheme.primary.withValues(alpha: 0.22)
                      : scheme.outlineVariant,
                ),
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(AppRadius.large),
                  topRight: const Radius.circular(AppRadius.large),
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
                        const SizedBox(width: AppSpacing.sm),
                        _PendingSteeringBadge(foreground: foreground),
                      ],
                    ],
                  ),
                  if (node.text?.trim().isNotEmpty == true) ...[
                    const SizedBox(height: AppSpacing.sm),
                    user
                        ? Text(node.text!, style: TextStyle(color: foreground))
                        // v0.8.7 打字机平滑释放：只释放已到达文本的前缀
                        // （fail-closed 不超前于数据），completed 全文到达立即
                        // 对账收敛；回滚开关置关时整段渲染（现状形态）。
                        : TypewriterRevealText(
                            text: node.text!,
                            streaming: node.isStreaming,
                            builder: (context, revealedText) =>
                                _DisplaySafeMarkdown(
                                  text: revealedText,
                                  color: foreground,
                                ),
                          ),
                  ],
                  if (node.references.isNotEmpty) ...[
                    const SizedBox(height: AppSpacing.sm),
                    _ReferenceChips(
                      sequence: node.sequence,
                      references: node.references,
                      foreground: foreground,
                      onOpenFile: onOpenFile,
                    ),
                  ],
                  // V094-06：消息级状态行（正在提交/已受理/处理中/恢复中/
                  // 正在重发/结果待确认/发送失败）。失败用语义错误色，
                  // 状态不只靠颜色表达（同时有文字）；canonical 历史节点
                  // 无该行（状态未确认降级，不给全历史补写状态）。
                  if (node.deliveryStatus != null) ...[
                    const SizedBox(height: AppSpacing.sm),
                    _DeliveryStatusLine(node: node, foreground: foreground),
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

/// V094-06：用户气泡内的消息级状态行。
/// 文案来自 SessionSendPhase.userLabel；补充说明承载失败原因/核验提示。
/// 状态不以颜色单独表达：图标 + 文字同时呈现，并带 Semantics 标签。
class _DeliveryStatusLine extends StatelessWidget {
  const _DeliveryStatusLine({required this.node, required this.foreground});

  final ConversationNode node;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 状态词是 UI 契约（SessionSendPhase.userLabel 冻结值），这里按词匹配
    // 语义色调，避免 UI 层直接依赖 controller 内部枚举类型。
    const failedLabel = '发送失败';
    const verifyLabel = '结果待确认';
    final isFailed = node.deliveryStatus == failedLabel;
    final isVerify = node.deliveryStatus == verifyLabel;
    final statusColor = isFailed
        ? scheme.error
        : isVerify
        ? context.appColors.warning
        : foreground.withValues(alpha: 0.78);
    return Semantics(
      label: '消息状态：${node.deliveryStatus}',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isFailed
                ? Icons.error_outline
                : isVerify
                ? Icons.help_outline
                : Icons.schedule_outlined,
            size: AppSizes.iconSm,
            color: statusColor,
          ),
          const SizedBox(width: AppSpacing.xs),
          Flexible(
            child: Text(
              node.deliveryDetail == null
                  ? node.deliveryStatus!
                  : '${node.deliveryStatus} · ${node.deliveryDetail}',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: statusColor,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
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
      padding: const EdgeInsets.only(top: AppSpacing.xs),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            node.isStreaming
                ? Icons.more_horiz
                : stopped
                ? Icons.stop_circle_outlined
                : Icons.check_circle_outline,
            size: AppSizes.iconSm,
          ),
          const SizedBox(width: AppSpacing.xs),
          Text(label, style: Theme.of(context).textTheme.labelSmall),
        ],
      ),
    );
  }
}

/// v0.8.6 D（G10）：助手消息 Markdown 渲染入口。实现迁入
/// SessionMarkdownText（GFM 语法面 + display-safe 边界），本类只保留调用点
/// 兼容的薄包装。
class _DisplaySafeMarkdown extends StatelessWidget {
  const _DisplaySafeMarkdown({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) =>
      SessionMarkdownText(text: text, color: color);
}


class _PendingSteeringBadge extends StatelessWidget {
  const _PendingSteeringBadge({required this.foreground});

  final Color foreground;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    key: const Key('session-pending-steering-badge'),
    decoration: ShapeDecoration(
      shape: StadiumBorder(
        side: BorderSide(color: foreground.withValues(alpha: 0.36)),
      ),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: AppSpacing.micro),
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
        avatar: Icon(icon, size: AppSizes.iconSm, color: foreground.withValues(alpha: 0.74)),
        label: Text(reference.label),
        onPressed: () => unawaited(onOpenFile!(reference.target!)),
      );
    }
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: foreground.withValues(alpha: 0.08),
        shape: const StadiumBorder(),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: AppSizes.iconSm, color: foreground.withValues(alpha: 0.74)),
            const SizedBox(width: AppSpacing.xs),
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

    // V094-11/14（UI-11/14 冻结口径）：元信息单行——时间 + 复制（常用直出）
    // + 「更多」菜单（分支/点赞/点踩/备注收进展开区），默认可见动作区最多
    // 一行；按钮命中区扩到 ≥48×48dp（图形可小、命中不缩）。备注浮层锚定
    // 在「更多」按钮上（CompositedTransformTarget），行为与原独立按钮一致。
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.xs),
      child: Row(
        key: Key('session-message-actions-${node.sequence}'),
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (node.showTimestamp && node.createdAt != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
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
              iconSize: AppSizes.iconMd,
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              padding: EdgeInsets.zero,
              onPressed: () => _copy(node),
              icon: const Icon(Icons.copy_outlined),
            ),
          if (node.canFork ||
              node.forkUnavailable ||
              (node.feedbackAvailable && messageId != null))
            CompositedTransformTarget(
              link: _noteLink,
              child: Focus(
                focusNode: _noteTriggerFocus,
                child: PopupMenuButton<String>(
                  key: Key('session-message-more-${node.sequence}'),
                  tooltip: '更多动作',
                  iconSize: AppSizes.iconMd,
                  constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                  padding: EdgeInsets.zero,
                  color: item != null
                      ? Theme.of(context).colorScheme.primary
                      : null,
                  // 打开菜单即懒加载反馈状态（原按钮 Focus/MouseRegion 的
                  // onEnsure 语义等价迁移，幂等）。
                  onOpened:
                      messageId == null || feedback == null
                          ? null
                          : () => unawaited(feedback.ensure(messageId)),
                  itemBuilder:
                      (_) => [
                    if (node.canFork || node.forkUnavailable)
                      PopupMenuItem<String>(
                        value: 'fork',
                        enabled: node.canFork && widget.onFork != null,
                        key: Key(
                          node.canFork && widget.onFork != null
                              ? 'session-message-fork-${node.sequence}'
                              : 'session-message-fork-unavailable-${node.sequence}',
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.call_split_outlined, size: AppSizes.iconSm),
                            const SizedBox(width: AppSpacing.sm),
                            Text(
                              node.canFork && widget.onFork != null
                                  ? '从这里分支'
                                  : '当前 Relay 未提供分支写入能力',
                            ),
                          ],
                        ),
                      ),
                    if (node.feedbackAvailable && messageId != null) ...[
                      PopupMenuItem<String>(
                        value: 'like',
                        enabled: feedback != null && !feedbackBusy,
                        key: Key(
                          _sequenceKey('session-message-like-', node.sequence),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.thumb_up_outlined,
                              size: AppSizes.iconSm,
                              color: item?.rating ==
                                      ConversationFeedbackRating.positive
                                  ? Theme.of(context).colorScheme.primary
                                  : null,
                            ),
                            const SizedBox(width: AppSpacing.sm),
                            Text(
                              item?.rating ==
                                      ConversationFeedbackRating.positive
                                  ? '喜欢（已选择）'
                                  : '喜欢',
                            ),
                          ],
                        ),
                      ),
                      PopupMenuItem<String>(
                        value: 'dislike',
                        enabled: feedback != null && !feedbackBusy,
                        key: Key(
                          _sequenceKey(
                            'session-message-dislike-',
                            node.sequence,
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.thumb_down_outlined,
                              size: AppSizes.iconSm,
                              color: item?.rating ==
                                      ConversationFeedbackRating.negative
                                  ? Theme.of(context).colorScheme.primary
                                  : null,
                            ),
                            const SizedBox(width: AppSpacing.sm),
                            Text(
                              item?.rating ==
                                      ConversationFeedbackRating.negative
                                  ? '不喜欢（已选择）'
                                  : '不喜欢',
                            ),
                          ],
                        ),
                      ),
                      if (item != null)
                        PopupMenuItem<String>(
                          value: 'note',
                          enabled: !feedbackBusy,
                          key: Key(
                            _sequenceKey('session-message-note-', node.sequence),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                item.note?.isNotEmpty == true
                                    ? Icons.sticky_note_2
                                    : Icons.note_add_outlined,
                                size: AppSizes.iconSm,
                              ),
                              const SizedBox(width: AppSpacing.sm),
                              Text(
                                item.note?.isNotEmpty == true
                                    ? '编辑反馈备注'
                                    : '添加反馈备注',
                              ),
                            ],
                          ),
                        ),
                    ],
                  ],
                  onSelected: (value) {
                    switch (value) {
                      case 'fork':
                        if (node.canFork && widget.onFork != null) {
                          unawaited(widget.onFork!(node.messageId!));
                        }
                      case 'like':
                        if (feedback != null && messageId != null) {
                          unawaited(
                            feedback.toggle(
                              messageId,
                              ConversationFeedbackRating.positive,
                            ),
                          );
                        }
                      case 'dislike':
                        if (feedback != null && messageId != null) {
                          unawaited(
                            feedback.toggle(
                              messageId,
                              ConversationFeedbackRating.negative,
                            ),
                          );
                        }
                      case 'note':
                        _toggleNote();
                    }
                  },
                ),
              ),
            ),
          if (_feedback != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
              child: Text(
                _feedback!,
                key: Key('session-message-action-feedback-${node.sequence}'),
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
          if (feedbackError != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
              child: Text(
                _feedbackErrorText(feedbackError),
                key: Key(
                  _sequenceKey('session-message-feedback-error-', node.sequence),
                ),
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Theme.of(context).colorScheme.error,
                ),
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
              borderRadius: BorderRadius.circular(AppRadius.card),
              child: SizedBox(
                width: 260,
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.sm),
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
                      const SizedBox(height: AppSpacing.sm),
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
        borderRadius: BorderRadius.circular(AppRadius.card),
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
              padding: const EdgeInsets.fromLTRB(AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.lg),
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
        borderRadius: BorderRadius.circular(AppRadius.card),
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
          childrenPadding: const EdgeInsets.fromLTRB(AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.lg),
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
                  icon: const Icon(Icons.manage_search_outlined, size: AppSizes.iconSm),
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
    padding: const EdgeInsets.only(left: AppSpacing.md, top: AppSpacing.xs),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final call in subcalls)
          Container(
            key: ValueKey(call.callId),
            margin: const EdgeInsets.only(bottom: AppSpacing.sm),
            padding: const EdgeInsets.only(left: AppSpacing.sm),
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
              icon: const Icon(Icons.open_in_new_outlined, size: AppSizes.iconSm),
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
    padding: const EdgeInsets.only(bottom: AppSpacing.sm),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 180),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.card),
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
        ),
        child: SingleChildScrollView(
          key: Key('session-tool-detail-scroll-$label'),
          padding: const EdgeInsets.all(AppSpacing.sm),
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
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
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
                size: AppSizes.iconMd,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: AppSpacing.sm),
              Text(
                '产物文件',
                style: Theme.of(
                  context,
                ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
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
                    size: AppSizes.iconSm,
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
                  icon: const Icon(Icons.folder_open_outlined, size: AppSizes.iconSm),
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
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: color, width: 3)),
        color: scheme.surfaceContainerLowest,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: AppSizes.iconMd, color: color),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Flexible(
                      child: Text(
                        node.label,
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: color,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    if (node.errorCode?.trim().isNotEmpty == true) ...[
                      const SizedBox(width: AppSpacing.sm),
                      Container(
                        key: Key('session-error-code-${node.sequence}'),
                        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 1),
                        decoration: BoxDecoration(
                          color: scheme.errorContainer,
                          borderRadius: BorderRadius.circular(AppRadius.micro),
                        ),
                        child: Text(
                          node.httpStatus != 0
                              ? '${node.errorCode} · ${node.httpStatus}'
                              : node.errorCode!,
                          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: scheme.onErrorContainer,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                if (detail?.trim().isNotEmpty == true) ...[
                  const SizedBox(height: AppSpacing.xs),
                  Text(detail!, style: Theme.of(context).textTheme.bodySmall),
                ],
                if (node.filePath?.trim().isNotEmpty == true) ...[
                  const SizedBox(height: AppSpacing.sm),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      key: Key('session-tool-open-path-${node.sequence}'),
                      onPressed: () => onOpenFile?.call(node.filePath!),
                      icon: const Icon(Icons.open_in_new_outlined, size: AppSizes.iconSm),
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
