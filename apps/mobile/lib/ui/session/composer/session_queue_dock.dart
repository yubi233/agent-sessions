import 'package:flutter/material.dart';

import '../../../state/session_composer_controller.dart';

/// v0.5/P5：会话级权威 transient inbox（队列）投影组件。
///
/// 对应《迭代计划v0.5.md》第 3 节「QueueDock」系列强制交互契约：
/// - 队列是会话级权威 transient inbox 投影，任何提交（逐条 steer、全部发送）都必须是显式用户动作；
/// - 多项默认折叠，单项不显示 count header；编辑 / busy 时强制展开；
/// - 纯文本项可编辑/删除，非文本或不可变队列项禁用编辑并说明原因；
/// - subagent / 不可变队列只读展示，不渲染可误触的编辑/steer 动作；
/// - 操作失败通过 composer notice/toast 呈现，不得静默丢失本地编辑态。
///
/// 该组件只读取 machine snapshot 的 `queue` 投影并通过回调把用户动作交回
/// `SessionComposerInputMachine` / `_SessionComposer`，不持有队列状态自身。
class SessionQueueDock extends StatefulWidget {
  const SessionQueueDock({
    super.key,
    required this.messages,
    required this.onRemove,
    required this.onEdit,
    required this.onSteer,
    required this.onSendAll,
    required this.running,
  });

  /// 排队项列表（来自 `SessionComposerInputMachine` 快照）。
  final List<QueuedComposerMessage> messages;

  /// 删除某项（显式用户动作）。
  final ValueChanged<String> onRemove;

  /// 保存编辑后的文本。
  final void Function(String id, String text) onEdit;

  /// 逐条 strict steer（只发送指定的那一项）。
  final ValueChanged<String> onSteer;

  /// 以显式动作发送全部排队项。
  final VoidCallback onSendAll;

  /// 会话是否处于 streaming / busy。busy 时强制展开，避免折叠态掩盖队列。
  final bool running;

  @override
  State<SessionQueueDock> createState() => _SessionQueueDockState();
}

/// v0.5/P5：会话级权威 transient inbox 投影状态。
///
/// - 多项默认折叠，单项不显示 count header；
/// - 编辑 / busy 时强制展开（编辑涉及的原条目标记进行中）；
/// - 纯文本项可编辑/删除，非文本或不可变队列项禁用编辑并说明原因；
/// - 任何提交（逐条 steer、全部发送）都必须是显式用户动作；
/// - 不可变/子代理队列只读展示，不渲染可误触的编辑/steer 动作。
class _SessionQueueDockState extends State<SessionQueueDock> {
  /// 折叠态：多项默认折叠（[collapse]），只有单项或强制展开才全量展示。
  bool _expanded = false;

  /// 当前正在编辑的排队项 id（一次只允许编辑一项）。
  String? _editingId;

  /// 编辑输入框 controller（编辑态复用同一 TextField identity，保存/取消才释放）。
  late TextEditingController _editController;

  @override
  void initState() {
    super.initState();
    _editController = TextEditingController();
  }

  @override
  void dispose() {
    _editController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant SessionQueueDock oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 编辑项被删除或更新后清空编辑态；但不要因为外部重建而打断正在进行的编辑。
    if (_editingId != null &&
        !widget.messages.any((item) => item.id == _editingId)) {
      setState(() => _editingId = null);
    }
  }

  /// 开始编辑：非文本 / 不可变项不允许进入编辑态（[item.editable] 为 false）。
  void _startEdit(QueuedComposerMessage item) {
    if (!item.editable) return;
    setState(() {
      _editingId = item.id;
      _expanded = true;
      _editController.text = item.text;
    });
  }

  /// 单项不显示 count header，也不显示折叠/展开按钮。
  bool get _singleRow => widget.messages.length == 1;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final messages = widget.messages;
    // 编辑中或 busy 时强制展开；否则多项默认折叠，单项不折叠（无 count header）。
    final expanded = _expanded || widget.running || _singleRow;
    final visible = messages.length <= 1 || expanded
        ? messages
        : [messages.first, messages.last];
    return Container(
      key: const Key('session-queue-dock'),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(10, 8, 6, 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Text(
                _singleRow ? '1 条排队消息' : '${messages.length} 条排队消息',
                style: theme.textTheme.labelMedium,
              ),
              const Spacer(),
              if (!_singleRow)
                TextButton(
                  key: const Key('session-queue-toggle'),
                  onPressed: () => setState(() => _expanded = !_expanded),
                  child: Text(expanded ? '折叠' : '展开'),
                ),
              TextButton.icon(
                key: const Key('session-queue-send-all'),
                onPressed: widget.onSendAll,
                icon: const Icon(Icons.send_outlined, size: 16),
                label: const Text('全部发送'),
              ),
            ],
          ),
          for (final item in visible) _queueRow(context, item),
          // 只在确有被折叠隐藏的项时才显示剩余提示；两项折叠时首尾即全部项，
          // 不应出现「还有 0 条未显示」这类无意义文案。
          if (messages.length > 1 &&
              !expanded &&
              visible.length < messages.length)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '还有 ${messages.length - visible.length} 条排队消息未显示',
                style: theme.textTheme.labelSmall,
              ),
            ),
        ],
      ),
    );
  }

  /// 单行排队项渲染：编辑态 / 普通态二选一。
  ///
  /// - 编辑态：输入框 + 保存/取消，保存前清空文本不会提交空值；
  /// - 普通态：文本 + （可 steer 时）steer 按钮 + 编辑/删除按钮；
  /// - 非文本 / 不可变项：编辑按钮禁用并显示原因，不渲染 steer。
  Widget _queueRow(BuildContext context, QueuedComposerMessage item) {
    final theme = Theme.of(context);
    final editing = _editingId == item.id;
    return Container(
      key: Key('session-queue-row-${item.id}'),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: editing
          ? Row(
              children: [
                Expanded(
                  child: TextField(
                    key: Key('session-queue-edit-input-${item.id}'),
                    controller: _editController,
                    autofocus: true,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(isDense: true),
                  ),
                ),
                IconButton(
                  key: Key('session-queue-edit-save-${item.id}'),
                  tooltip: '保存修改',
                  onPressed: () {
                    final next = _editController.text.trim();
                    if (next.isNotEmpty) {
                      widget.onEdit(item.id, next);
                    }
                    setState(() => _editingId = null);
                  },
                  icon: const Icon(Icons.check, size: 18),
                ),
                IconButton(
                  key: Key('session-queue-edit-cancel-${item.id}'),
                  tooltip: '取消编辑',
                  onPressed: () => setState(() => _editingId = null),
                  icon: const Icon(Icons.close, size: 18),
                ),
              ],
            )
          : Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        item.text,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (item.steerable)
                      IconButton(
                        key: Key('session-queue-steer-${item.id}'),
                        tooltip: '只提交这条',
                        onPressed: () => widget.onSteer(item.id),
                        icon: const Icon(Icons.send, size: 18),
                      ),
                    IconButton(
                      key: Key('session-queue-edit-${item.id}'),
                      tooltip: item.editable ? '编辑排队消息' : '该队列项不可编辑',
                      onPressed: item.editable ? () => _startEdit(item) : null,
                      icon: const Icon(Icons.edit_outlined, size: 18),
                    ),
                    IconButton(
                      key: Key('session-queue-remove-${item.id}'),
                      tooltip: '删除排队消息',
                      onPressed: () => widget.onRemove(item.id),
                      icon: const Icon(Icons.delete_outline, size: 18),
                    ),
                  ],
                ),
                if (!item.editable)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '该排队项为图片/附件，无法编辑。',
                      key: Key('session-queue-edit-blocked-${item.id}'),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}
