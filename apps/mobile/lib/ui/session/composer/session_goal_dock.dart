import 'package:flutter/material.dart';

import '../../app_theme.dart';
import 'package:flutter/services.dart';

import '../../../domain/control_models.dart';

/// v0.5/P5-E：GoalDock 是 `conversation.input.dock` 的只读/轻编辑 strip。
///
/// 当前会话页已将 Goal 操作收纳到模型设置弹窗；此组件保留给兼容调用方，
/// 不再由会话 composer 挂载。
///
/// 这里不读取 timeline，也不直接提交 Relay 命令；保存与暂停/恢复都通过上层
/// `SessionController` 注入的回调执行，确保 Goal 仍走统一 lease、capability 与幂等链路。
class SessionGoalDock extends StatefulWidget {
  const SessionGoalDock({
    required this.goal,
    required this.blockedReason,
    required this.busy,
    required this.onSave,
    required this.onToggle,
    required this.onClear,
    super.key,
  });

  final SessionGoalSummary? goal;
  final String? blockedReason;
  final bool busy;
  final Future<String?> Function(String objective) onSave;
  final Future<String?> Function() onToggle;
  final Future<String?> Function() onClear;

  @override
  State<SessionGoalDock> createState() => _SessionGoalDockState();
}

class _SessionGoalDockState extends State<SessionGoalDock> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  bool _editing = false;
  bool _actionBusy = false;
  String? _inlineError;

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant SessionGoalDock oldWidget) {
    super.didUpdateWidget(oldWidget);
    final goal = widget.goal;
    if (!_editing && goal != null && oldWidget.goal?.title != goal.title) {
      _controller.text = goal.title;
    }
  }

  bool get _blocked =>
      widget.goal == null ||
      widget.blockedReason != null ||
      widget.busy ||
      _actionBusy;

  void _startEditing() {
    final goal = widget.goal;
    if (goal == null || _blocked) return;
    setState(() {
      _editing = true;
      _inlineError = null;
      _controller.text = goal.title;
      _controller.selection = TextSelection.collapsed(
        offset: goal.title.length,
      );
    });
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _focusNode.requestFocus(),
    );
  }

  void _cancelEditing() {
    final goal = widget.goal;
    setState(() {
      _editing = false;
      _inlineError = null;
      if (goal != null) _controller.text = goal.title;
    });
  }

  Future<void> _save() async {
    final value = _controller.text.trim();
    if (value.isEmpty) {
      setState(() => _inlineError = '目标文本不能为空。');
      return;
    }
    setState(() {
      _actionBusy = true;
      _inlineError = null;
    });
    final error = await widget.onSave(value);
    if (!mounted) return;
    setState(() {
      _actionBusy = false;
      if (error == null) {
        _editing = false;
      } else {
        _inlineError = error;
      }
    });
  }

  Future<void> _toggle() async {
    if (_blocked || widget.goal?.phase == GoalPhase.completed) return;
    setState(() {
      _actionBusy = true;
      _inlineError = null;
    });
    final error = await widget.onToggle();
    if (!mounted) return;
    setState(() {
      _actionBusy = false;
      _inlineError = error;
    });
  }

  Future<void> _clear() async {
    if (_blocked) return;
    setState(() {
      _actionBusy = true;
      _inlineError = null;
    });
    final error = await widget.onClear();
    if (!mounted) return;
    setState(() {
      _actionBusy = false;
      _inlineError = error;
      if (error == null) _editing = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final goal = widget.goal;
    if (goal == null || goal.phase == GoalPhase.completed) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final blocked = widget.blockedReason;
    return Container(
      key: const Key('session-goal-dock'),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(
                Icons.flag_outlined,
                size: 18,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Goal · ${goal.phase.label} · ${goal.progressLabel}',
                  key: const Key('session-goal-dock-status'),
                  style: theme.textTheme.labelMedium,
                ),
              ),
              IconButton(
                key: const Key('session-goal-dock-edit'),
                tooltip: blocked ?? '编辑 Goal',
                onPressed: _blocked ? null : _startEditing,
                icon: const Icon(Icons.edit_outlined, size: 19),
              ),
              IconButton(
                key: const Key('session-goal-dock-toggle'),
                tooltip:
                    blocked ??
                    (goal.phase == GoalPhase.active ? '暂停 Goal' : '恢复 Goal'),
                onPressed: _blocked ? null : _toggle,
                icon: Icon(
                  goal.phase == GoalPhase.active
                      ? Icons.pause_circle_outline
                      : Icons.play_circle_outline,
                  size: 20,
                ),
              ),
              IconButton(
                key: const Key('session-goal-dock-clear'),
                tooltip: blocked ?? '清除 Goal',
                onPressed: _blocked ? null : _clear,
                icon: const Icon(Icons.clear_outlined, size: 20),
              ),
            ],
          ),
          if (_editing) ...[
            const SizedBox(height: 8),
            Shortcuts(
              shortcuts: const {
                SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
              },
              child: Actions(
                actions: {
                  DismissIntent: CallbackAction<DismissIntent>(
                    onInvoke: (_) {
                      _cancelEditing();
                      return null;
                    },
                  ),
                },
                child: TextField(
                  key: const Key('session-goal-dock-input'),
                  controller: _controller,
                  focusNode: _focusNode,
                  enabled: !_actionBusy,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _save(),
                  decoration: const InputDecoration(
                    isDense: true,
                    labelText: '编辑 Goal',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              alignment: WrapAlignment.end,
              children: [
                TextButton(
                  key: const Key('session-goal-dock-cancel'),
                  onPressed: _actionBusy ? null : _cancelEditing,
                  child: const Text('取消'),
                ),
                FilledButton(
                  key: const Key('session-goal-dock-submit'),
                  onPressed: _actionBusy ? null : _save,
                  child: const Text('保存'),
                ),
              ],
            ),
          ] else ...[
            const SizedBox(height: 4),
            Text(goal.title, key: const Key('session-goal-dock-title')),
          ],
          if (blocked != null) ...[
            const SizedBox(height: 4),
            Text(
              blocked,
              key: const Key('session-goal-dock-blocked'),
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],
          if (_inlineError != null) ...[
            const SizedBox(height: 4),
            Text(
              _inlineError!,
              key: const Key('session-goal-dock-error'),
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
