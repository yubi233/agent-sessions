import 'package:flutter/material.dart';

import '../../state/session_view_controller.dart';

/// 会话详情页内部 header：替代 AppBar + 零散状态条，提供固定 chrome 边界。
class SessionHeader extends StatelessWidget {
  const SessionHeader({
    required this.title,
    required this.status,
    required this.mode,
    required this.onModeChanged,
    required this.onBack,
    required this.actions,
    this.utilities,
    super.key,
  });

  final Widget title;
  final Widget status;
  final SessionViewMode mode;
  final ValueChanged<SessionViewMode> onModeChanged;
  final VoidCallback onBack;
  final Widget actions;
  final Widget? utilities;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      key: const Key('session-strict-header'),
      color: theme.colorScheme.surface,
      elevation: 0,
      child: Semantics(
        container: true,
        label: '会话标题栏',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: kToolbarHeight,
              child: Row(
                children: [
                  IconButton(
                    key: const Key('session-detail-back-button'),
                    tooltip: '返回会话列表',
                    onPressed: onBack,
                    icon: const Icon(Icons.arrow_back),
                  ),
                  Expanded(child: title),
                  actions,
                ],
              ),
            ),
            status,
            if (utilities != null)
              ConstrainedBox(
                // v0.5/P1：header utilities 是严格 chrome 的一部分，但移动端高度必须受控；
                // 长控制面在自己的滚动区内展开，不能挤掉 conversation view 与 sticky composer。
                constraints: const BoxConstraints(maxHeight: 72),
                child: SingleChildScrollView(
                  primary: false,
                  padding: EdgeInsets.zero,
                  child: utilities!,
                ),
              ),
            SessionViewTabs(mode: mode, onChanged: onModeChanged),
          ],
        ),
      ),
    );
  }
}

/// Strict header 内的固定 View Ring。Chat 与 Trajectory 切换只改本地 view store。
class SessionViewTabs extends StatelessWidget {
  const SessionViewTabs({
    required this.mode,
    required this.onChanged,
    super.key,
  });

  final SessionViewMode mode;
  final ValueChanged<SessionViewMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final active = Theme.of(context).colorScheme.primary;
    final inactive = Theme.of(context).colorScheme.onSurfaceVariant;
    return Semantics(
      label: '会话视图切换',
      child: Container(
        key: const Key('session-view-tabs'),
        height: 42,
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: Theme.of(context).dividerColor),
          ),
        ),
        child: Row(
          children: [
            _SessionViewTab(
              key: const Key('session-tab-chat'),
              label: '对话',
              selected: mode == SessionViewMode.chat,
              color: mode == SessionViewMode.chat ? active : inactive,
              onTap: () => onChanged(SessionViewMode.chat),
            ),
            _SessionViewTab(
              key: const Key('session-tab-trajectory'),
              label: '轨迹',
              selected: mode == SessionViewMode.trajectory,
              color: mode == SessionViewMode.trajectory ? active : inactive,
              onTap: () => onChanged(SessionViewMode.trajectory),
            ),
          ],
        ),
      ),
    );
  }
}

class _SessionViewTab extends StatelessWidget {
  const _SessionViewTab({
    required this.label,
    required this.selected,
    required this.color,
    required this.onTap,
    super.key,
  });

  final String label;
  final bool selected;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Semantics(
      button: true,
      selected: selected,
      label: label,
      child: InkWell(
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(label, style: TextStyle(color: color)),
            ),
            AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              height: 2,
              color: selected ? color : Colors.transparent,
            ),
          ],
        ),
      ),
    ),
  );
}
