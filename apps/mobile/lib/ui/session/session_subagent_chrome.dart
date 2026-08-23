import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/delegation_models.dart';
import '../../state/delegation_controller.dart';

class SessionSubagentCatalogAction extends StatefulWidget {
  const SessionSubagentCatalogAction({
    required this.controller,
    required this.parentSessionId,
    required this.available,
    required this.onOpenChild,
    super.key,
  });

  final DelegationController controller;
  final String parentSessionId;
  final bool available;
  final Future<void> Function(String childSessionId) onOpenChild;

  @override
  State<SessionSubagentCatalogAction> createState() =>
      _SessionSubagentCatalogActionState();
}

class _SessionSubagentCatalogActionState
    extends State<SessionSubagentCatalogAction> {
  final FocusNode _triggerFocus = FocusNode(debugLabel: 'subagent-catalog');

  @override
  void dispose() {
    _triggerFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.available && widget.controller.delegations.isEmpty) {
      return const SizedBox.shrink();
    }
    return IconButton(
      key: const Key('session-subagent-catalog'),
      focusNode: _triggerFocus,
      tooltip: '子会话目录',
      onPressed: () => _openCatalog(context),
      icon: Badge.count(
        count: widget.controller.delegations.length,
        isLabelVisible: widget.controller.delegations.isNotEmpty,
        child: const Icon(Icons.account_tree_outlined),
      ),
    );
  }

  Future<void> _openCatalog(BuildContext context) async {
    unawaited(
      widget.controller.loadForParent(widget.parentSessionId, force: true),
    );
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _SessionSubagentCatalogSheet(
        controller: widget.controller,
        parentSessionId: widget.parentSessionId,
        onOpenChild: widget.onOpenChild,
      ),
    );
    if (mounted) _triggerFocus.requestFocus();
  }
}

class _SessionSubagentCatalogSheet extends StatefulWidget {
  const _SessionSubagentCatalogSheet({
    required this.controller,
    required this.parentSessionId,
    required this.onOpenChild,
  });

  final DelegationController controller;
  final String parentSessionId;
  final Future<void> Function(String childSessionId) onOpenChild;

  @override
  State<_SessionSubagentCatalogSheet> createState() =>
      _SessionSubagentCatalogSheetState();
}

class _SessionSubagentCatalogSheetState
    extends State<_SessionSubagentCatalogSheet> {
  final Set<String> _expanded = {};

  Future<void> _toggle(String childId) async {
    if (_expanded.remove(childId)) {
      setState(() {});
      return;
    }
    setState(() => _expanded.add(childId));
    await widget.controller.loadCatalog(childId);
  }

  Future<void> _open(String childId) async {
    Navigator.of(context).pop();
    await widget.onOpenChild(childId);
  }

  List<Widget> _rows(
    BuildContext context,
    String parentId,
    List<SessionDelegation> delegations,
    int level,
  ) {
    return [
      for (final delegation in delegations) ...[
        _CatalogDelegationRow(
          delegation: delegation,
          level: level,
          expanded:
              delegation.childSessionId != null &&
              _expanded.contains(delegation.childSessionId),
          onToggle: delegation.childSessionId == null
              ? null
              : () => _toggle(delegation.childSessionId!),
          onOpenChild: delegation.childSessionId == null
              ? null
              : () => _open(delegation.childSessionId!),
        ),
        if (delegation.childSessionId != null &&
            _expanded.contains(delegation.childSessionId))
          ..._branchRows(context, delegation.childSessionId!, level + 1),
      ],
    ];
  }

  List<Widget> _branchRows(BuildContext context, String parentId, int level) {
    final phase = widget.controller.catalogPhaseFor(parentId);
    final message = widget.controller.catalogMessageFor(parentId);
    if (phase == DelegationPhase.loading || phase == DelegationPhase.idle) {
      return [
        Padding(
          key: Key('session-subagent-branch-loading-$parentId'),
          padding: EdgeInsets.only(left: 24.0 * level, top: 8, bottom: 8),
          child: const LinearProgressIndicator(),
        ),
      ];
    }
    if (phase == DelegationPhase.error) {
      return [
        ListTile(
          key: Key('session-subagent-branch-error-$parentId'),
          contentPadding: EdgeInsets.only(left: 24.0 * level, right: 12),
          leading: const Icon(Icons.error_outline),
          title: Text(message ?? '子树不可用'),
          trailing: TextButton(
            onPressed: () =>
                unawaited(widget.controller.loadCatalog(parentId, force: true)),
            child: const Text('重试'),
          ),
        ),
      ];
    }
    final children = widget.controller.catalogFor(parentId);
    if (children.isEmpty) {
      return [
        ListTile(
          key: Key('session-subagent-branch-empty-$parentId'),
          contentPadding: EdgeInsets.only(left: 24.0 * level, right: 12),
          dense: true,
          leading: const Icon(Icons.horizontal_rule, size: 16),
          title: const Text('没有更深层子会话'),
        ),
      ];
    }
    return _rows(context, parentId, children, level);
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final controller = widget.controller;
        return ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.72,
          ),
          child: Column(
            key: const Key('session-subagent-catalog-sheet'),
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.account_tree_outlined),
                title: const Text('子会话'),
                subtitle: Text('${controller.delegations.length} 个节点'),
                trailing: IconButton(
                  key: const Key('session-subagent-catalog-refresh'),
                  tooltip: '刷新子会话目录',
                  onPressed: controller.isLoading
                      ? null
                      : () => unawaited(
                          controller.loadForParent(
                            widget.parentSessionId,
                            force: true,
                          ),
                        ),
                  icon: const Icon(Icons.refresh),
                ),
              ),
              if (controller.isLoading)
                const LinearProgressIndicator(
                  key: Key('session-subagent-catalog-loading'),
                ),
              if (controller.message != null)
                ListTile(
                  key: const Key('session-subagent-catalog-error'),
                  leading: const Icon(Icons.error_outline),
                  title: Text(controller.message!),
                  trailing: TextButton(
                    onPressed: () => unawaited(
                      controller.loadForParent(
                        widget.parentSessionId,
                        force: true,
                      ),
                    ),
                    child: const Text('重试'),
                  ),
                ),
              if (!controller.isLoading &&
                  controller.message == null &&
                  controller.delegations.isEmpty)
                const ListTile(
                  key: Key('session-subagent-catalog-empty'),
                  leading: Icon(Icons.info_outline),
                  title: Text('还没有子会话'),
                ),
              Flexible(
                child: FocusTraversalGroup(
                  policy: WidgetOrderTraversalPolicy(),
                  child: ListView(
                    shrinkWrap: true,
                    children: _rows(
                      context,
                      widget.parentSessionId,
                      controller.delegations,
                      1,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    ),
  );
}

class _CatalogDelegationRow extends StatelessWidget {
  const _CatalogDelegationRow({
    required this.delegation,
    required this.level,
    required this.expanded,
    required this.onToggle,
    required this.onOpenChild,
  });

  final SessionDelegation delegation;
  final int level;
  final bool expanded;
  final VoidCallback? onToggle;
  final VoidCallback? onOpenChild;

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final context = node.context;
    if (context == null) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      FocusScope.of(context).nextFocus();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      FocusScope.of(context).previousFocus();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight && !expanded) {
      onToggle?.call();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft && expanded) {
      onToggle?.call();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.space) {
      onOpenChild?.call();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final enabled = onOpenChild != null;
    final diagnostic = enabled
        ? '${delegation.status.label} · ${delegation.summaryFingerprint} · token/时长不可用'
        : '${delegation.status.label} · 子会话尚不可打开';
    return Semantics(
      button: enabled,
      enabled: enabled,
      focusable: enabled,
      label: '第 $level 层子会话 ${delegation.targetProvider}，$diagnostic',
      child: Focus(
        canRequestFocus: enabled,
        onKeyEvent: _handleKey,
        child: ListTile(
          key: Key('session-subagent-entry-${delegation.id}'),
          enabled: enabled,
          contentPadding: EdgeInsets.only(
            left: 12 + (level - 1) * 24,
            right: 8,
          ),
          leading: Icon(
            delegation.status == DelegationStatus.running
                ? Icons.radio_button_checked
                : enabled
                ? Icons.check_circle_outline
                : Icons.error_outline,
          ),
          title: Text(delegation.targetProvider),
          subtitle: Text(diagnostic),
          trailing: enabled
              ? Wrap(
                  children: [
                    IconButton(
                      key: Key('session-subagent-toggle-${delegation.id}'),
                      tooltip: expanded ? '收起子树' : '展开子树',
                      onPressed: onToggle,
                      icon: Icon(
                        expanded ? Icons.expand_more : Icons.chevron_right,
                      ),
                    ),
                    const Icon(Icons.open_in_new),
                  ],
                )
              : null,
          onTap: onOpenChild,
        ),
      ),
    );
  }
}

class SessionSubagentBreadcrumb extends StatelessWidget {
  const SessionSubagentBreadcrumb({
    required this.parentSessionId,
    required this.onOpenParent,
    super.key,
  });

  final String? parentSessionId;
  final VoidCallback onOpenParent;

  @override
  Widget build(BuildContext context) {
    final parent = parentSessionId?.trim();
    if (parent == null || parent.isEmpty) return const SizedBox.shrink();
    return Semantics(
      button: true,
      label: '返回父会话',
      child: InkWell(
        key: const Key('session-subagent-breadcrumb'),
        onTap: onOpenParent,
        borderRadius: BorderRadius.circular(4),
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [Icon(Icons.chevron_left, size: 15), Text('父会话 / 子会话')],
          ),
        ),
      ),
    );
  }
}

class SessionSubagentReadOnlyComposer extends StatelessWidget {
  const SessionSubagentReadOnlyComposer({required this.reason, super.key});

  final String reason;

  @override
  Widget build(BuildContext context) {
    final oneShot = reason == 'one-shot';
    return Semantics(
      liveRegion: true,
      label: oneShot ? '一次性子会话只读' : '父会话不可用，子会话只读',
      child: Container(
        key: const Key('session-subagent-readonly'),
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          border: Border.all(color: Theme.of(context).dividerColor),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              oneShot ? '一次性子会话' : '子会话暂时只读',
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: 3),
            Text(
              oneShot ? '此子会话由父会话寻址，不能直接发送人工输入。' : '父会话当前不可用，恢复后再继续控制。',
              key: const Key('session-composer-blocked-reason'),
            ),
          ],
        ),
      ),
    );
  }
}
