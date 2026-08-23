import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/session_models.dart';
import '../../state/session_controller.dart';

typedef WorkspaceDirectoryFlow = Future<String?> Function(BuildContext context);

/// DeepSeek Harness WorkspacePickFlow 的 Flutter 等价边界。
///
/// 列表来自 Relay 白名单；目录只能由注入的 Host/fixture flow 返回。移动端不会把
/// Android 本地路径当成 Host 路径。选择和目录收养期间所有入口均单飞。
class SessionWorkspacePicker extends StatefulWidget {
  const SessionWorkspacePicker({
    required this.controller,
    required this.selectedId,
    required this.onPick,
    required this.canWrite,
    required this.deviceId,
    this.directoryFlow,
    this.markMissingAsDeleted = false,
    this.label = '工作区',
    this.asComposerInput = false,
    super.key,
  });

  final SessionController controller;
  final String? selectedId;
  final Future<bool> Function(String workspaceId) onPick;
  final bool canWrite;
  final String? deviceId;
  final WorkspaceDirectoryFlow? directoryFlow;
  final bool markMissingAsDeleted;
  final String label;
  final bool asComposerInput;

  @override
  State<SessionWorkspacePicker> createState() => _SessionWorkspacePickerState();
}

class _SessionWorkspacePickerState extends State<SessionWorkspacePicker> {
  final _menuController = MenuController();
  final _anchorFocus = FocusNode(debugLabel: 'workspace-picker');
  bool _flowBusy = false;
  String? _localPendingId;

  bool get _busy =>
      _flowBusy ||
      _localPendingId != null ||
      widget.controller.workspaceSettling;

  @override
  void dispose() {
    _anchorFocus.dispose();
    super.dispose();
  }

  KeyEventResult _handleKey(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent || _busy) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.space) {
      _menuController.open();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _pick(String workspaceId) async {
    if (_busy) return;
    _menuController.close();
    setState(() => _localPendingId = workspaceId);
    var accepted = false;
    try {
      accepted = await widget.onPick(workspaceId);
    } catch (_) {
      accepted = false;
    } finally {
      if (mounted) setState(() => _localPendingId = null);
    }
    if (!mounted) return;
    _anchorFocus.requestFocus();
    if (!accepted) {
      await _showError(
        widget.controller.workspaceErrorMessage ??
            widget.controller.errorMessage ??
            '工作区未能打开，请重试。',
      );
    }
  }

  Future<void> _addWorkspace() async {
    if (_busy) return;
    final flow = widget.directoryFlow;
    if (flow == null) return;
    _menuController.close();
    setState(() => _flowBusy = true);
    try {
      final path = await flow(context);
      if (!mounted || path == null || path.trim().isEmpty) return;
      final workspace = await widget.controller.createWorkspaceFromDirectory(
        canonicalRoot: path,
        deviceId: widget.deviceId,
        canWrite: widget.canWrite,
      );
      if (!mounted) return;
      if (workspace == null) {
        setState(() => _flowBusy = false);
        await _showError(
          widget.controller.workspaceErrorMessage ?? '目录未能登记为工作区。',
          allowChooseAgain: true,
        );
        return;
      }
      setState(() => _flowBusy = false);
      await _pick(workspace.id);
    } finally {
      if (mounted && _flowBusy) setState(() => _flowBusy = false);
      if (mounted) _anchorFocus.requestFocus();
    }
  }

  Future<void> _showError(
    String message, {
    bool allowChooseAgain = false,
  }) async {
    final chooseAgain = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('session-workspace-error-dialog'),
        title: const Text('无法打开工作区'),
        content: Text(message, key: const Key('session-workspace-error')),
        actions: [
          TextButton(
            key: const Key('session-workspace-error-close'),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('关闭'),
          ),
          if (allowChooseAgain && widget.directoryFlow != null)
            FilledButton(
              key: const Key('session-workspace-choose-again'),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('重新选择'),
            ),
        ],
      ),
    );
    if (mounted) _anchorFocus.requestFocus();
    if (chooseAgain == true) unawaited(_addWorkspace());
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final workspaces = widget.controller.workspaces;
        final selectedId = widget.selectedId?.trim() ?? '';
        final selected = workspaces
            .where((workspace) => workspace.id == selectedId)
            .firstOrNull;
        final deleted =
            widget.markMissingAsDeleted &&
            selectedId.isNotEmpty &&
            widget.controller.workspacePhase == WorkspaceListPhase.ready &&
            selected == null;
        final pendingId =
            _localPendingId ?? widget.controller.pendingWorkspaceId;
        final shown = deleted
            ? '工作区已移除'
            : selected?.label ?? (selectedId.isEmpty ? '选择工作区' : selectedId);
        return Semantics(
          button: true,
          label: '${widget.label}：$shown',
          enabled: !_busy,
          child: MenuAnchor(
            controller: _menuController,
            menuChildren: _menuChildren(workspaces),
            childFocusNode: _anchorFocus,
            builder: (context, controller, child) => Focus(
              focusNode: _anchorFocus,
              onKeyEvent: _handleKey,
              child: InkWell(
                key: const Key('session-workspace-picker'),
                onTap: _busy ? null : controller.open,
                borderRadius: BorderRadius.circular(6),
                child: widget.asComposerInput
                    ? TextField(
                        key: const Key('session-composer-input'),
                        readOnly: true,
                        enabled: widget.canWrite && !_busy,
                        maxLines: 3,
                        decoration: InputDecoration(
                          hintText: pendingId == null
                              ? '选择工作区开始会话'
                              : '正在打开 $shown',
                          suffixIcon: pendingId != null || _flowBusy
                              ? const Padding(
                                  key: Key('session-workspace-pending'),
                                  padding: EdgeInsets.all(14),
                                  child: SizedBox.square(
                                    dimension: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  ),
                                )
                              : const Icon(Icons.folder_open_outlined),
                          errorText: deleted ? '请重新选择可用工作区。' : null,
                        ),
                        onTap: _busy ? null : controller.open,
                      )
                    : InputDecorator(
                        decoration: InputDecoration(
                          labelText: widget.label,
                          suffixIcon: pendingId != null || _flowBusy
                              ? const Padding(
                                  key: Key('session-workspace-pending'),
                                  padding: EdgeInsets.all(14),
                                  child: SizedBox.square(
                                    dimension: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  ),
                                )
                              : const Icon(Icons.unfold_more),
                          errorText: deleted ? '请重新选择可用工作区。' : null,
                        ),
                        child: Text(
                          pendingId == null ? shown : '正在打开 $shown',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
              ),
            ),
          ),
        );
      },
    );
  }

  List<Widget> _menuChildren(List<MobileWorkspace> workspaces) {
    final phase = widget.controller.workspacePhase;
    final children = <Widget>[];
    if (phase == WorkspaceListPhase.loading) {
      children.add(
        const MenuItemButton(
          key: Key('session-workspace-loading'),
          onPressed: null,
          child: Text('正在加载工作区...'),
        ),
      );
    } else if (phase == WorkspaceListPhase.error) {
      children.add(
        MenuItemButton(
          key: const Key('session-workspace-retry'),
          onPressed: _busy
              ? null
              : () {
                  _menuController.close();
                  unawaited(widget.controller.refreshWorkspaces());
                },
          leadingIcon: const Icon(Icons.refresh),
          child: Text(widget.controller.workspaceErrorMessage ?? '加载失败，点击重试'),
        ),
      );
    } else {
      if (workspaces.isEmpty) {
        children.add(
          const MenuItemButton(
            key: Key('session-workspace-empty'),
            onPressed: null,
            child: Text('暂无工作区'),
          ),
        );
      }
      for (final workspace in workspaces) {
        children.add(
          MenuItemButton(
            key: Key('session-workspace-${workspace.id}'),
            onPressed: _busy ? null : () => unawaited(_pick(workspace.id)),
            leadingIcon: const Icon(Icons.folder_outlined),
            trailingIcon: workspace.id == widget.selectedId
                ? const Icon(Icons.check, size: 18)
                : null,
            child: Text(workspace.label),
          ),
        );
      }
    }
    children.add(const Divider(height: 1));
    children.add(
      MenuItemButton(
        key: const Key('session-workspace-add'),
        onPressed: _busy || !widget.canWrite || widget.directoryFlow == null
            ? null
            : () => unawaited(_addWorkspace()),
        leadingIcon: const Icon(Icons.create_new_folder_outlined),
        child: Text(widget.directoryFlow == null ? 'Host 目录选择不可用' : '添加工作区'),
      ),
    );
    return children;
  }
}

/// deterministic fixture 的目录 flow。它只用于本地 UI/录屏，不进入真实 Relay 配置。
Future<String?> showFixtureWorkspaceDirectoryFlow(BuildContext context) async {
  final controller = TextEditingController(text: '/fixture/workspace');
  try {
    return await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('session-workspace-directory-flow'),
        title: const Text('选择 Host 工作区目录'),
        content: TextField(
          key: const Key('session-workspace-directory-input'),
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Fixture 目录'),
        ),
        actions: [
          TextButton(
            key: const Key('session-workspace-directory-cancel'),
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('session-workspace-directory-submit'),
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('选择'),
          ),
        ],
      ),
    );
  } finally {
    controller.dispose();
  }
}
