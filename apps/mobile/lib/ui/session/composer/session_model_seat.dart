import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 模型 seat 的 pane；root 只负责选择进入模型目录或 effort 目录。
enum _SessionModelPane { root, model, effort }

enum _SessionModelCatalogStatus { idle, loading, ready, error }

/// v0.5/P5-E5：会话级模型/effort seat。
///
/// 该组件只消费 Host 投影的目录和当前值，所有选择都通过上层注入的
/// `SessionController` 回调提交。每次打开都会刷新目录；加载失败停留在菜单内，
/// 选择失败显示 notice 并保留当前 pane，避免把本地选中态伪装成 Host 已消费。
class SessionModelSeat extends StatefulWidget {
  const SessionModelSeat({
    required this.model,
    required this.effort,
    required this.models,
    required this.efforts,
    required this.modelBlockedReason,
    required this.effortBlockedReason,
    required this.onRefresh,
    required this.onSelectModel,
    required this.onSelectEffort,
    this.busy = false,
    super.key,
  });

  final String? model;
  final String? effort;
  final List<String> models;
  final List<String> efforts;
  final String? modelBlockedReason;
  final String? effortBlockedReason;
  final bool busy;
  final Future<String?> Function() onRefresh;
  final Future<String?> Function(String model) onSelectModel;
  final Future<String?> Function(String effort) onSelectEffort;

  @override
  State<SessionModelSeat> createState() => _SessionModelSeatState();
}

class _SessionModelSeatState extends State<SessionModelSeat> {
  _SessionModelPane _pane = _SessionModelPane.root;
  _SessionModelCatalogStatus _status = _SessionModelCatalogStatus.idle;
  String? _catalogError;
  String? _selectionNotice;
  bool _selectionBusy = false;
  bool _menuOpen = false;
  final _menuFocusNode = FocusNode(debugLabel: 'session-model-menu');

  @override
  void dispose() {
    _menuFocusNode.dispose();
    super.dispose();
  }

  bool get _modelDisabled => widget.busy || widget.modelBlockedReason != null;
  bool get _effortDisabled => widget.busy || widget.effortBlockedReason != null;

  void _open(_SessionModelPane pane) {
    if ((pane == _SessionModelPane.model && _modelDisabled) ||
        (pane == _SessionModelPane.effort && _effortDisabled)) {
      return;
    }
    setState(() {
      _menuOpen = true;
      _pane = pane;
      _status = _SessionModelCatalogStatus.loading;
      _catalogError = null;
      _selectionNotice = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _menuFocusNode.requestFocus();
    });
    unawaited(_reloadCatalog());
  }

  void _close() {
    setState(() {
      _menuOpen = false;
      _pane = _SessionModelPane.root;
      _catalogError = null;
      _selectionNotice = null;
    });
  }

  Future<void> _reloadCatalog() async {
    final error = await widget.onRefresh();
    if (!mounted) return;
    setState(() {
      _status = error == null
          ? _SessionModelCatalogStatus.ready
          : _SessionModelCatalogStatus.error;
      _catalogError = error;
      if (error != null) _selectionNotice = null;
    });
  }

  KeyEventResult _handleMenuKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      if (_pane != _SessionModelPane.root) {
        setState(() {
          _pane = _SessionModelPane.root;
          _selectionNotice = null;
        });
      } else {
        _close();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _chooseModel(String model) async {
    if (_selectionBusy) return;
    if (model == widget.model) {
      _close();
      return;
    }
    setState(() {
      _selectionBusy = true;
      _selectionNotice = null;
    });
    final error = await widget.onSelectModel(model);
    if (!mounted) return;
    setState(() {
      _selectionBusy = false;
      _selectionNotice = error;
    });
    if (error == null) _close();
  }

  Future<void> _chooseEffort(String effort) async {
    if (_selectionBusy) return;
    if (effort == widget.effort) {
      _close();
      return;
    }
    setState(() {
      _selectionBusy = true;
      _selectionNotice = null;
    });
    final error = await widget.onSelectEffort(effort);
    if (!mounted) return;
    setState(() {
      _selectionBusy = false;
      _selectionNotice = error;
    });
    if (error == null) _close();
  }

  @override
  Widget build(BuildContext context) {
    final modelReason = widget.modelBlockedReason;
    final effortReason = widget.effortBlockedReason;
    return Semantics(
      container: true,
      label: '模型与 effort seat',
      hint: modelReason ?? effortReason,
      child: Column(
        key: const Key('session-model-seat'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Tooltip(
                  message: modelReason ?? '打开模型目录',
                  child: OutlinedButton.icon(
                    key: const Key('composer-model-select'),
                    onPressed: _modelDisabled
                        ? null
                        : () => _open(_SessionModelPane.root),
                    icon: const Icon(Icons.smart_toy_outlined, size: 17),
                    label: Text(widget.model ?? '选择模型'),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Tooltip(
                  message: effortReason ?? '打开 effort 目录',
                  child: OutlinedButton.icon(
                    key: const Key('composer-effort-select'),
                    onPressed: _effortDisabled
                        ? null
                        : () => _open(_SessionModelPane.root),
                    icon: const Icon(Icons.tune_outlined, size: 17),
                    label: Text(widget.effort ?? '选择 effort'),
                  ),
                ),
              ),
            ],
          ),
          if (modelReason != null || effortReason != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                modelReason ?? effortReason!,
                key: const Key('session-model-seat-blocked'),
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ),
          if (_menuOpen) _buildMenu(context),
        ],
      ),
    );
  }

  Widget _buildMenu(BuildContext context) {
    final theme = Theme.of(context);
    return Focus(
      focusNode: _menuFocusNode,
      onKeyEvent: _handleMenuKey,
      child: FocusTraversalGroup(
        child: Container(
          key: const Key('session-model-menu'),
          margin: const EdgeInsets.only(top: 6),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHigh,
            border: Border.all(color: theme.dividerColor),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Material(
            color: Colors.transparent,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildMenuHeader(context),
                if (_catalogError != null) _buildCatalogError(context),
                if (_selectionNotice != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(
                      _selectionNotice!,
                      key: const Key('session-model-selection-notice'),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ),
                if (_status == _SessionModelCatalogStatus.loading)
                  const Padding(
                    padding: EdgeInsets.all(10),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        SizedBox(width: 8),
                        Text('正在刷新模型目录…'),
                      ],
                    ),
                  )
                else
                  _buildPane(context),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMenuHeader(BuildContext context) {
    final title = switch (_pane) {
      _SessionModelPane.root => '模型 seat',
      _SessionModelPane.model => '选择模型',
      _SessionModelPane.effort => '选择 effort',
    };
    return Row(
      children: [
        if (_pane != _SessionModelPane.root)
          IconButton(
            key: const Key('session-model-menu-back'),
            tooltip: '返回模型 seat',
            onPressed: () => setState(() {
              _pane = _SessionModelPane.root;
              _selectionNotice = null;
            }),
            icon: const Icon(Icons.arrow_back, size: 18),
          ),
        Expanded(
          child: Text(
            title,
            key: Key('session-model-menu-title-${_pane.name}'),
            style: Theme.of(context).textTheme.labelLarge,
          ),
        ),
        IconButton(
          key: const Key('session-model-menu-close'),
          tooltip: '关闭模型 seat',
          onPressed: _close,
          icon: const Icon(Icons.close, size: 18),
        ),
      ],
    );
  }

  Widget _buildCatalogError(BuildContext context) => Container(
    key: const Key('session-model-menu-error'),
    margin: const EdgeInsets.only(bottom: 6),
    padding: const EdgeInsets.all(8),
    color: Theme.of(context).colorScheme.errorContainer,
    child: Row(
      children: [
        Expanded(child: Text(_catalogError!)),
        TextButton(
          key: const Key('session-model-menu-retry'),
          onPressed: _selectionBusy ? null : () => unawaited(_reloadCatalog()),
          child: const Text('重试'),
        ),
      ],
    ),
  );

  Widget _buildPane(BuildContext context) {
    switch (_pane) {
      case _SessionModelPane.root:
        return Column(
          key: const Key('session-model-pane-root'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 空目录也要可进入对应 pane，展示“Host 尚未提供可用选项”的空态；
            // 只有 capability/busy 锁定才禁用整行。
            _menuRow(
              key: const Key('session-model-menu-model'),
              title: '模型',
              value: widget.model,
              enabled: !_modelDisabled,
              onTap: () => setState(() => _pane = _SessionModelPane.model),
            ),
            _menuRow(
              key: const Key('session-model-menu-effort'),
              title: 'effort',
              value: widget.effort,
              enabled: !_effortDisabled,
              onTap: () => setState(() => _pane = _SessionModelPane.effort),
            ),
          ],
        );
      case _SessionModelPane.model:
        return _buildOptions(
          key: const Key('session-model-pane-model'),
          emptyKey: const Key('session-model-empty'),
          options: widget.models,
          selected: widget.model,
          optionPrefix: 'session-model-option-',
          onChoose: _chooseModel,
        );
      case _SessionModelPane.effort:
        return _buildOptions(
          key: const Key('session-model-pane-effort'),
          emptyKey: const Key('session-effort-empty'),
          options: widget.efforts,
          selected: widget.effort,
          optionPrefix: 'session-effort-option-',
          onChoose: _chooseEffort,
        );
    }
  }

  Widget _menuRow({
    required Key key,
    required String title,
    required String? value,
    required bool enabled,
    required VoidCallback onTap,
  }) => ListTile(
    key: key,
    dense: true,
    enabled: enabled,
    title: Text(title),
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(value ?? '不可用'),
        const SizedBox(width: 4),
        const Icon(Icons.chevron_right, size: 18),
      ],
    ),
    onTap: enabled ? onTap : null,
  );

  Widget _buildOptions({
    required Key key,
    required Key emptyKey,
    required List<String> options,
    required String? selected,
    required String optionPrefix,
    required Future<void> Function(String value) onChoose,
  }) {
    if (options.isEmpty) {
      return Padding(
        key: emptyKey,
        padding: const EdgeInsets.all(10),
        child: const Text('当前目录为空，Host 尚未提供可用选项。'),
      );
    }
    return Column(
      key: key,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final option in options)
          ListTile(
            key: Key('$optionPrefix$option'),
            dense: true,
            enabled: !_selectionBusy,
            leading: Icon(
              option == selected ? Icons.check : Icons.circle_outlined,
              size: 18,
            ),
            title: Text(option),
            onTap: () => unawaited(onChoose(option)),
          ),
      ],
    );
  }
}
