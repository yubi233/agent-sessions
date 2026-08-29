import 'dart:async';

import 'package:flutter/material.dart';

import '../../../domain/control_models.dart';
import '../../../domain/session_projection_models.dart';
import '../../app_theme.dart';
import 'session_context_meter.dart';
import 'session_stats_line.dart';

/// Host 投影的模型与推理等级目录。目录只包含可展示、可选择的安全标签。
@immutable
class SessionModelCatalog {
  const SessionModelCatalog({
    required this.model,
    required this.effort,
    required this.models,
    required this.efforts,
  });

  final String? model;
  final String? effort;
  final List<String> models;
  final List<String> efforts;
}

/// 目录刷新结果。刷新失败时仍带回当前安全投影，避免把旧目录误画成空目录。
@immutable
class SessionModelCatalogRefresh {
  const SessionModelCatalogRefresh({required this.catalog, this.error});

  final SessionModelCatalog catalog;
  final String? error;
}

/// v0.5/P5-E5：会话级模型与推理等级入口。
///
/// Composer 只保留一个固定高度的单行摘要。点击摘要在同一底部弹层中选择模型和
/// 推理等级；详情按钮只展示 display-safe 投影，不读取 Provider 正文或密文。
class SessionModelSeat extends StatefulWidget {
  const SessionModelSeat({
    required this.catalog,
    required this.modelBlockedReason,
    required this.effortBlockedReason,
    required this.onRefresh,
    required this.onSelectModel,
    required this.onSelectEffort,
    this.provider,
    this.providerVersion,
    this.providerAvailable = false,
    this.modelCapability = const CapabilityEntry(
      name: 'model_select',
      availability: CapabilityAvailability.unsupported,
    ),
    this.effortCapability = const CapabilityEntry(
      name: 'effort_select',
      availability: CapabilityAvailability.unsupported,
    ),
    this.busy = false,
    this.usage,
    super.key,
  });

  final String? provider;
  final String? providerVersion;
  final bool providerAvailable;
  final SessionModelCatalog catalog;
  final CapabilityEntry modelCapability;
  final CapabilityEntry effortCapability;
  final String? modelBlockedReason;
  final String? effortBlockedReason;
  final bool busy;
  final SessionUsageSummary? usage;
  final Future<SessionModelCatalogRefresh> Function() onRefresh;
  final Future<String?> Function(String model) onSelectModel;
  final Future<String?> Function(String effort) onSelectEffort;

  @override
  State<SessionModelSeat> createState() => _SessionModelSeatState();
}

class _SessionModelSeatState extends State<SessionModelSeat> {
  final _triggerFocusNode = FocusNode(debugLabel: 'session-model-seat-trigger');

  bool get _modelDisabled => widget.busy || widget.modelBlockedReason != null;
  bool get _effortDisabled => widget.busy || widget.effortBlockedReason != null;
  bool get _canOpenPicker =>
      widget.providerAvailable && (!_modelDisabled || !_effortDisabled);

  String get _displayModel {
    final model = widget.catalog.model?.trim();
    if (model != null && model.isNotEmpty) return model;
    final provider = widget.provider?.trim();
    if (provider != null && provider.isNotEmpty) return provider;
    return '模型不可用';
  }

  bool get _usesAutomaticReasoning {
    final provider = widget.provider?.trim().toLowerCase();
    final effort = widget.catalog.effort?.trim();
    return provider == 'opencode' && (effort == null || effort.isEmpty);
  }

  String get _displayEffort {
    final effort = widget.catalog.effort?.trim();
    if (effort != null && effort.isNotEmpty) return effort;
    return _usesAutomaticReasoning ? '自动' : '—';
  }

  String get _pickerHint {
    if (!widget.providerAvailable) return 'Provider 当前不可用。';
    if (_canOpenPicker) {
      return _effortDisabled ? '选择模型' : '选择模型和推理等级';
    }
    return widget.modelBlockedReason ??
        widget.effortBlockedReason ??
        '模型和推理等级当前不可用';
  }

  @override
  void dispose() {
    _triggerFocusNode.dispose();
    super.dispose();
  }

  Future<void> _openPicker() async {
    if (!_canOpenPicker) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => _SessionModelPickerSheet(
        catalog: widget.catalog,
        modelEnabled: !_modelDisabled,
        effortEnabled: !_effortDisabled,
        modelBlockedReason: widget.modelBlockedReason,
        effortBlockedReason: widget.effortBlockedReason,
        onRefresh: widget.onRefresh,
        onSelectModel: widget.onSelectModel,
        onSelectEffort: widget.onSelectEffort,
      ),
    );
    if (mounted && _canOpenPicker) _triggerFocusNode.requestFocus();
  }

  Future<void> _openDetails() async {
    final usage = widget.usage;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('session-model-details-dialog'),
        title: const Text('模型设置'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _ModelDetailRow(
                  key: const Key('session-model-details-provider'),
                  label: 'Provider',
                  value: _providerLabel,
                ),
                _ModelDetailRow(
                  key: const Key('session-model-details-version'),
                  label: '版本',
                  value: _versionLabel,
                ),
                _ModelDetailRow(
                  key: const Key('session-model-details-availability'),
                  label: '状态',
                  value: widget.providerAvailable ? '可用' : '不可用',
                ),
                _ModelDetailRow(
                  key: const Key('session-model-details-model'),
                  label: '模型',
                  value: _displayModel,
                ),
                if (widget.catalog.effort != null &&
                        widget.catalog.effort!.isNotEmpty ||
                    _usesAutomaticReasoning)
                  _ModelDetailRow(
                    key: const Key('session-model-details-effort'),
                    label: _usesAutomaticReasoning ? '推理' : '推理等级',
                    value: _usesAutomaticReasoning
                        ? '自动（模型内置）'
                        : widget.catalog.effort!,
                  ),
                _ModelDetailRow(
                  key: const Key('session-model-details-catalog'),
                  label: '目录',
                  value:
                      '模型 ${widget.catalog.models.length} 项，推理等级 ${widget.catalog.efforts.length} 项',
                ),
                const Divider(height: 20),
                _ModelDetailRow(
                  key: const Key('session-model-details-model-capability'),
                  label: '模型切换',
                  value: _capabilityDescription(
                    widget.modelCapability,
                    widget.modelBlockedReason,
                  ),
                ),
                _ModelDetailRow(
                  key: const Key('session-model-details-effort-capability'),
                  label: _usesAutomaticReasoning ? '推理' : '推理等级',
                  value: _usesAutomaticReasoning
                      ? '自动推理（当前模型未提供可选档位）'
                      : _capabilityDescription(
                          widget.effortCapability,
                          widget.effortBlockedReason,
                        ),
                ),
                if (usage != null) ...[
                  const Divider(height: 20),
                  Text(
                    '用量统计',
                    style: Theme.of(dialogContext).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  SessionStatsLine(
                    stats: SessionStatsLineProjection.fromUsage(usage),
                  ),
                  if (usage.contextWindowTokens > 0)
                    _ModelDetailRow(
                      key: const Key('session-model-details-context'),
                      label: '上下文',
                      value:
                          '${SessionUsageSummary.compactForDisplay(usage.contextTokens)} / '
                          '${SessionUsageSummary.compactForDisplay(usage.contextWindowTokens)}'
                          '（${((usage.contextRatio ?? 0) * 100).toStringAsFixed(0)}%）',
                    ),
                  SessionContextMeter(
                    meter: SessionContextMeterProjection.fromUsage(usage),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            key: const Key('session-model-details-close'),
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
    if (mounted) _triggerFocusNode.requestFocus();
  }

  String get _providerLabel {
    final provider = widget.provider?.trim();
    return provider == null || provider.isEmpty ? '不可用' : provider;
  }

  String get _versionLabel {
    final version = widget.providerVersion?.trim();
    return version == null || version.isEmpty ? '未提供' : version;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      key: const Key('session-model-seat'),
      height: 32,
      child: Row(
        children: [
          Icon(
            Icons.account_tree_outlined,
            size: 14,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 4),
          const SizedBox(
            width: 36,
            child: Text('main', maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Tooltip(
              message: _pickerHint,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  key: const Key('session-model-seat-trigger'),
                  focusNode: _triggerFocusNode,
                  canRequestFocus: _canOpenPicker,
                  borderRadius: BorderRadius.circular(AppRadius.small),
                  onTap: _canOpenPicker ? _openPicker : null,
                  child: Semantics(
                    button: true,
                    enabled: _canOpenPicker,
                    label: '模型 $_displayModel，推理等级 $_displayEffort',
                    hint: _pickerHint,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Row(
                        children: [
                          Icon(
                            _providerIcon(widget.provider),
                            size: 14,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 4),
                          Flexible(
                            flex: 3,
                            child: Text(
                              _displayModel,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.end,
                              style: theme.textTheme.labelSmall,
                            ),
                          ),
                          Text(
                            ' / ',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          Flexible(
                            flex: 2,
                            child: Text(
                              _displayEffort,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelSmall,
                            ),
                          ),
                          const SizedBox(width: 2),
                          Icon(
                            Icons.expand_more,
                            size: 16,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Tooltip(
            message: '查看模型设置详情',
            child: IconButton(
              key: const Key('session-model-seat-details'),
              tooltip: '查看模型设置详情',
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 32, height: 32),
              onPressed: _openDetails,
              icon: const Icon(Icons.info_outline, size: 17),
            ),
          ),
        ],
      ),
    );
  }
}

class _SessionModelPickerSheet extends StatefulWidget {
  const _SessionModelPickerSheet({
    required this.catalog,
    required this.modelEnabled,
    required this.effortEnabled,
    required this.modelBlockedReason,
    required this.effortBlockedReason,
    required this.onRefresh,
    required this.onSelectModel,
    required this.onSelectEffort,
  });

  final SessionModelCatalog catalog;
  final bool modelEnabled;
  final bool effortEnabled;
  final String? modelBlockedReason;
  final String? effortBlockedReason;
  final Future<SessionModelCatalogRefresh> Function() onRefresh;
  final Future<String?> Function(String model) onSelectModel;
  final Future<String?> Function(String effort) onSelectEffort;

  @override
  State<_SessionModelPickerSheet> createState() =>
      _SessionModelPickerSheetState();
}

class _SessionModelPickerSheetState extends State<_SessionModelPickerSheet> {
  late SessionModelCatalog _catalog;
  bool _loading = true;
  bool _selectionBusy = false;
  String? _catalogError;
  String? _selectionError;

  @override
  void initState() {
    super.initState();
    _catalog = widget.catalog;
    // The sheet mounts during the route transition. Defer the controller refresh
    // until the first frame so Riverpod listeners are not notified during build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_reload());
    });
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _catalogError = null;
      _selectionError = null;
    });
    try {
      final refresh = await widget.onRefresh();
      if (!mounted) return;
      setState(() {
        _catalog = refresh.catalog;
        _catalogError = refresh.error;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _catalogError = '模型目录暂时不可用，请重试。';
        _loading = false;
      });
    }
  }

  Future<void> _selectModel(String model) async {
    if (_selectionBusy || !widget.modelEnabled) return;
    if (model == _catalog.model) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _selectionBusy = true;
      _selectionError = null;
    });
    final error = await widget.onSelectModel(model);
    if (!mounted) return;
    if (error == null) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _selectionBusy = false;
      _selectionError = error;
    });
  }

  Future<void> _selectEffort(String effort) async {
    if (_selectionBusy || !widget.effortEnabled) return;
    if (effort == _catalog.effort) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _selectionBusy = true;
      _selectionError = null;
    });
    final error = await widget.onSelectEffort(effort);
    if (!mounted) return;
    if (error == null) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _selectionBusy = false;
      _selectionError = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FractionallySizedBox(
      heightFactor: 0.7,
      child: Material(
        key: const Key('session-model-selection-sheet'),
        color: theme.colorScheme.surface,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppRadius.card),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            Container(
              width: 32,
              height: 4,
              margin: const EdgeInsets.only(top: 8, bottom: 6),
              decoration: BoxDecoration(
                color: theme.colorScheme.onSurfaceVariant.withValues(
                  alpha: 0.4,
                ),
                borderRadius: BorderRadius.circular(AppRadius.small),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 8, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text('模型与推理等级', style: theme.textTheme.titleSmall),
                  ),
                  IconButton(
                    key: const Key('session-model-selection-close'),
                    tooltip: '关闭模型选择',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, size: 20),
                  ),
                ],
              ),
            ),
            if (_loading)
              const LinearProgressIndicator(
                key: Key('session-model-selection-loading'),
                minHeight: 2,
              ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 16),
                children: [
                  if (_catalogError != null)
                    _CatalogNotice(
                      key: const Key('session-model-selection-catalog-error'),
                      message: _catalogError!,
                      actionLabel: '重试',
                      onAction: _selectionBusy
                          ? null
                          : () => unawaited(_reload()),
                    ),
                  if (_selectionError != null)
                    _CatalogNotice(
                      key: const Key('session-model-selection-error'),
                      message: _selectionError!,
                    ),
                  _PickerSection(
                    key: const Key('session-model-selection-model-section'),
                    title: '模型',
                    options: _catalog.models,
                    selected: _catalog.model,
                    optionPrefix: 'session-model-option-',
                    enabled: widget.modelEnabled,
                    disabledReason: widget.modelBlockedReason,
                    selectionBusy: _selectionBusy,
                    emptyKey: const Key('session-model-empty'),
                    onSelect: _selectModel,
                  ),
                  const Divider(height: 20),
                  _PickerSection(
                    key: const Key('session-model-selection-effort-section'),
                    title: '推理等级',
                    options: _catalog.efforts,
                    selected: _catalog.effort,
                    optionPrefix: 'session-effort-option-',
                    enabled: widget.effortEnabled,
                    disabledReason: widget.effortBlockedReason,
                    selectionBusy: _selectionBusy,
                    emptyKey: const Key('session-effort-empty'),
                    onSelect: _selectEffort,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PickerSection extends StatelessWidget {
  const _PickerSection({
    required this.title,
    required this.options,
    required this.selected,
    required this.optionPrefix,
    required this.enabled,
    required this.disabledReason,
    required this.selectionBusy,
    required this.emptyKey,
    required this.onSelect,
    super.key,
  });

  final String title;
  final List<String> options;
  final String? selected;
  final String optionPrefix;
  final bool enabled;
  final String? disabledReason;
  final bool selectionBusy;
  final Key emptyKey;
  final Future<void> Function(String value) onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
          child: Text(title, style: theme.textTheme.labelLarge),
        ),
        if (!enabled)
          Padding(
            key: Key(
              'session-model-selection-${title == '模型' ? 'model' : 'effort'}-blocked',
            ),
            padding: const EdgeInsets.all(8),
            child: Text(
              disabledReason ?? '$title 当前不可用。',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          )
        else if (options.isEmpty)
          Padding(
            key: emptyKey,
            padding: const EdgeInsets.all(8),
            child: const Text('当前目录为空，Host 尚未提供可用选项。'),
          )
        else
          for (final option in options)
            ListTile(
              key: Key('$optionPrefix$option'),
              dense: true,
              enabled: !selectionBusy,
              leading: Icon(
                option == selected ? Icons.check_circle : Icons.circle_outlined,
                size: 18,
              ),
              title: Text(option, maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: () => unawaited(onSelect(option)),
            ),
      ],
    );
  }
}

class _CatalogNotice extends StatelessWidget {
  const _CatalogNotice({
    required this.message,
    this.actionLabel,
    this.onAction,
    super.key,
  });

  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 8),
    padding: const EdgeInsets.all(8),
    color: Theme.of(context).colorScheme.errorContainer,
    child: Row(
      children: [
        Expanded(child: Text(message)),
        if (actionLabel != null)
          TextButton(onPressed: onAction, child: Text(actionLabel!)),
      ],
    ),
  );
}

class _ModelDetailRow extends StatelessWidget {
  const _ModelDetailRow({required this.label, required this.value, super.key});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 72,
          child: Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(
          child: Text(value, maxLines: 3, overflow: TextOverflow.ellipsis),
        ),
      ],
    ),
  );
}

String _capabilityDescription(
  CapabilityEntry capability,
  String? blockedReason,
) {
  final reason = blockedReason?.trim();
  if (reason != null && reason.isNotEmpty) {
    return '${capability.availability.label} · $reason';
  }
  final declaredReason = capability.reason?.trim();
  if (declaredReason != null && declaredReason.isNotEmpty) {
    return '${capability.availability.label} · $declaredReason';
  }
  return capability.availability.label;
}

IconData _providerIcon(String? provider) {
  return switch (provider?.toLowerCase()) {
    'codex' => Icons.auto_awesome,
    'claude' => Icons.psychology_outlined,
    'opencode' => Icons.terminal_outlined,
    'dsh' => Icons.hub_outlined,
    _ => Icons.smart_toy_outlined,
  };
}
