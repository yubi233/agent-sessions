// Trajectory 视图模块（v0.5/P6）：从 session_screens.dart 迁出的 full-height ledger view。
// 只消费自身 target projection 与一次性 inspect target；不读取或改变 Chat projection。
import 'dart:async';

import 'package:flutter/material.dart';

import '../../../domain/session_projection_models.dart';
import '../../../state/session_view_controller.dart';
import '../../app_theme.dart';

class SessionTrajectoryView extends StatefulWidget {
  const SessionTrajectoryView({
    required this.records,
    required this.inspectTarget,
    required this.onInspectConsumed,
    this.initialState = const SessionTrajectoryViewState(),
    this.onStateChanged,
    super.key,
  });

  final List<TrajectoryRecord> records;
  final String? inspectTarget;
  final VoidCallback onInspectConsumed;
  final SessionTrajectoryViewState initialState;
  final ValueChanged<SessionTrajectoryViewState>? onStateChanged;

  @override
  State<SessionTrajectoryView> createState() => _SessionTrajectoryViewState();
}

class _SessionTrajectoryViewState extends State<SessionTrajectoryView> {
  late final ScrollController _ledgerController;
  late String _query;
  late String _appliedQuery;
  Timer? _searchDebounce;
  late bool _equalWidth;
  late bool _foldTurns;
  late bool _foldAssistantCalls;
  int _visibleLimit = 10;
  late double _rangeStart;
  late double _rangeEnd;
  late bool _rangeActive;
  late String? _selectedKey;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialState;
    _query = initial.query;
    _appliedQuery = initial.query.trim();
    _equalWidth = initial.equalWidth;
    _foldTurns = initial.foldTurns;
    _foldAssistantCalls = initial.foldAssistantCalls;
    _rangeStart = initial.rangeStart;
    _rangeEnd = initial.rangeEnd;
    _rangeActive = initial.rangeActive;
    _selectedKey = initial.selectedKey;
    _ledgerController = ScrollController(
      initialScrollOffset: initial.scrollOffset,
    )..addListener(_saveScrollOffset);
  }

  void _saveScrollOffset() {
    _emitState(
      SessionTrajectoryViewState(
        scrollOffset: _ledgerController.hasClients
            ? _ledgerController.offset
            : _ledgerController.initialScrollOffset,
        query: _query,
        equalWidth: _equalWidth,
        foldTurns: _foldTurns,
        foldAssistantCalls: _foldAssistantCalls,
        rangeStart: _rangeStart,
        rangeEnd: _rangeEnd,
        rangeActive: _rangeActive,
        selectedKey: _selectedKey,
      ),
    );
  }

  void _emitState([SessionTrajectoryViewState? state]) {
    widget.onStateChanged?.call(
      state ??
          SessionTrajectoryViewState(
            scrollOffset: _ledgerController.hasClients
                ? _ledgerController.offset
                : 0,
            query: _query,
            equalWidth: _equalWidth,
            foldTurns: _foldTurns,
            foldAssistantCalls: _foldAssistantCalls,
            rangeStart: _rangeStart,
            rangeEnd: _rangeEnd,
            rangeActive: _rangeActive,
            selectedKey: _selectedKey,
          ),
    );
  }

  @override
  void dispose() {
    _saveScrollOffset();
    _searchDebounce?.cancel();
    _ledgerController.removeListener(_saveScrollOffset);
    _ledgerController.dispose();
    super.dispose();
  }

  /// P6-A：搜索、折叠或 mode 变化后重置 ledger offset。
  /// 该状态只属于 Trajectory view，不回写 Chat projection 或会话写入口。
  void _resetLedgerOffset() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_ledgerController.hasClients) return;
      _ledgerController.jumpTo(0);
    });
  }

  /// P6-B：搜索索引节流。输入框立即反映用户文字，过滤索引延迟 250ms 更新，
  /// 避免每次按键都重建整条 ledger；streaming partial 仍在 records 中参与搜索。
  void _setQuery(String value) {
    setState(() => _query = value);
    _emitState();
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      setState(() => _appliedQuery = value.trim());
      _resetLedgerOffset();
    });
  }

  void _setEqualWidth(bool value) {
    setState(() {
      _equalWidth = value;
      // P6-B：切换 timeline mode 时清空旧 range selection，避免旧时间轴选区套到新布局。
      _clearRangeSelection();
    });
    _emitState();
    _resetLedgerOffset();
  }

  void _setFoldTurns(bool value) {
    setState(() => _foldTurns = value);
    _emitState();
    _resetLedgerOffset();
  }

  void _setFoldAssistantCalls(bool value) {
    setState(() => _foldAssistantCalls = value);
    _emitState();
    _resetLedgerOffset();
  }

  /// 按当前 toolbar / timeline 过滤后的全量 records；范围选择用 fraction 过滤。
  List<TrajectoryRecord> get _filtered {
    final q = _appliedQuery.trim().toLowerCase();
    final records = widget.records
        .where((record) {
          if (q.isNotEmpty) {
            final haystack = [
              record.label,
              record.status ?? '',
              record.summary ?? '',
            ].join(' ').toLowerCase();
            if (!haystack.contains(q)) return false;
          }
          // 折叠 turn：只保留 user/assistant 分组头，跳过 tool/reasoning 细粒度记录。
          if (_foldTurns) {
            const groupHead = {
              ConversationNodeKind.user,
              ConversationNodeKind.assistant,
            };
            if (!groupHead.contains(record.kind)) return false;
          }
          // 折叠 assistant call：隐藏 tool 记录。
          if (_foldAssistantCalls && record.kind == ConversationNodeKind.tool) {
            return false;
          }
          // Overview timeline 范围选择：只显示落在选区内的记录。
          if (_rangeActive) {
            final pos = _positionFor(record);
            if (pos < _rangeStart || pos > _rangeEnd) return false;
          }
          return true;
        })
        .toList(growable: false);
    return records;
  }

  /// Ledger 当前渲染窗口：默认只显示最近 [_visibleLimit] 条，支持 load older 展开。
  List<TrajectoryRecord> get _ledgerRecords {
    final filtered = _filtered;
    if (filtered.length <= _visibleLimit) return filtered;
    return filtered.sublist(filtered.length - _visibleLimit);
  }

  bool get _hasOlder => _filtered.length > _visibleLimit;

  /// 把当前渲染窗口展开为“turn 分组头 + record”的轻量条目序列。
  /// 分组头只来自投影层给出的 [TrajectoryRecord.turnId]，不写回 Chat/Relay。
  List<Object> get _ledgerItems {
    final items = <Object>[];
    String? lastTurn;
    for (final record in _ledgerRecords) {
      if (record.turnId != lastTurn) {
        items.add(_TrajectoryTurnHeaderData(record.turnId));
        lastTurn = record.turnId;
      }
      items.add(record);
    }
    return items;
  }

  void _loadOlder() {
    setState(() => _visibleLimit += 10);
    _emitState();
    _resetLedgerOffset();
  }

  /// 计算记录在 Overview timeline 上的 0..1 位置。
  /// 没有可靠时间时回退到等宽位置，不伪造真实时长。
  double _positionFor(TrajectoryRecord record) {
    final total = widget.records.length;
    if (total <= 1) return 0.5;
    final index = widget.records.indexWhere((item) => item.key == record.key);
    final normalizedIndex = index / (total - 1);
    if (_equalWidth || widget.records.every((item) => item.createdAt == null)) {
      return normalizedIndex;
    }
    final times = widget.records
        .map((item) => item.createdAt)
        .whereType<DateTime>()
        .toList();
    if (times.isEmpty) return normalizedIndex;
    final min = times.reduce(
      (left, right) => left.isBefore(right) ? left : right,
    );
    final max = times.reduce(
      (left, right) => left.isAfter(right) ? left : right,
    );
    final span = max.difference(min).inMicroseconds;
    final current = record.createdAt;
    if (current == null || span <= 0) return normalizedIndex;
    return (current.difference(min).inMicroseconds / span).clamp(0.0, 1.0);
  }

  void _setRange(double start, double end) {
    setState(() {
      _rangeActive = true;
      _rangeStart = start.clamp(0.0, 1.0);
      _rangeEnd = end.clamp(0.0, 1.0);
      if (_rangeStart > _rangeEnd) {
        final tmp = _rangeStart;
        _rangeStart = _rangeEnd;
        _rangeEnd = tmp;
      }
    });
    _emitState();
    _resetLedgerOffset();
  }

  void _clearRangeSelection() {
    _rangeActive = false;
    _rangeStart = 0;
    _rangeEnd = 1;
  }

  void _selectRecord(String key) {
    setState(() => _selectedKey = key);
    _emitState();
    _resetLedgerOffset();
  }

  void _closeInspector() {
    setState(() => _selectedKey = null);
    _emitState();
  }

  @override
  Widget build(BuildContext context) {
    final target = widget.inspectTarget;
    if (target != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final match = widget.records
            .where((record) => record.inspectTarget == target)
            .firstOrNull;
        if (match != null) _selectRecord(match.key);
        widget.onInspectConsumed();
      });
    }
    final visibleItems = _ledgerItems;
    final selected = widget.records
        .where((record) => record.key == _selectedKey)
        .firstOrNull;
    final headers = <Widget>[
      if (target != null) _TrajectoryInspectBanner(target: target),
      _TrajectoryToolbar(
        query: _query,
        equalWidth: _equalWidth,
        foldTurns: _foldTurns,
        foldAssistantCalls: _foldAssistantCalls,
        onQueryChanged: _setQuery,
        onEqualWidth: _setEqualWidth,
        onFoldTurns: _setFoldTurns,
        onFoldAssistantCalls: _setFoldAssistantCalls,
      ),
      _TrajectoryTimeline(
        records: widget.records,
        equalWidth: _equalWidth,
        rangeStart: _rangeStart,
        rangeEnd: _rangeEnd,
        rangeActive: _rangeActive,
        onRangeChanged: _setRange,
        onClearRange: () {
          setState(_clearRangeSelection);
          _resetLedgerOffset();
        },
        onRecordTap: _selectRecord,
      ),
      if (selected != null)
        _TrajectoryInspector(record: selected, onClose: _closeInspector),
    ];
    final itemCount =
        headers.length + (_hasOlder ? 1 : 0) + visibleItems.length;
    return Container(
      key: const Key('session-trajectory-view'),
      child: ListView.builder(
        key: const Key('session-trajectory-ledger'),
        controller: _ledgerController,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        itemCount: itemCount,
        itemBuilder: (context, index) {
          if (index < headers.length) return headers[index];
          var ledgerIndex = index - headers.length;
          if (_hasOlder && ledgerIndex == 0) {
            return _TrajectoryLoadOlder(onTap: _loadOlder);
          }
          if (_hasOlder) ledgerIndex -= 1;
          if (ledgerIndex < 0 || ledgerIndex >= visibleItems.length) {
            return const SizedBox.shrink();
          }
          final item = visibleItems[ledgerIndex];
          if (item is _TrajectoryTurnHeaderData) {
            return _TrajectoryTurnHeader(turnId: item.turnId);
          }
          final record = item as TrajectoryRecord;
          return _TrajectoryRow(
            record: record,
            equalWidth: _equalWidth,
            selected: record.key == _selectedKey,
            onTap: () => _selectRecord(record.key),
          );
        },
      ),
    );
  }
}

/// P6 Trajectory toolbar：搜索 + duration/equal-width + turn/call 折叠。
class _TrajectoryToolbar extends StatelessWidget {
  const _TrajectoryToolbar({
    required this.query,
    required this.equalWidth,
    required this.foldTurns,
    required this.foldAssistantCalls,
    required this.onQueryChanged,
    required this.onEqualWidth,
    required this.onFoldTurns,
    required this.onFoldAssistantCalls,
  });

  final String query;
  final bool equalWidth;
  final bool foldTurns;
  final bool foldAssistantCalls;
  final ValueChanged<String> onQueryChanged;
  final ValueChanged<bool> onEqualWidth;
  final ValueChanged<bool> onFoldTurns;
  final ValueChanged<bool> onFoldAssistantCalls;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Column(
        children: [
          TextField(
            key: const Key('session-trajectory-search'),
            decoration: const InputDecoration(
              labelText: '搜索轨迹',
              isDense: true,
              prefixIcon: Icon(Icons.search, size: 18),
            ),
            onChanged: onQueryChanged,
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              FilterChip(
                key: const Key('session-trajectory-mode-toggle'),
                label: Text(equalWidth ? '等宽' : '时长'),
                selected: equalWidth,
                onSelected: onEqualWidth,
              ),
              const SizedBox(width: 6),
              FilterChip(
                key: const Key('session-trajectory-fold-turns'),
                label: const Text('折叠轮次'),
                selected: foldTurns,
                onSelected: onFoldTurns,
              ),
              const SizedBox(width: 6),
              FilterChip(
                key: const Key('session-trajectory-fold-calls'),
                label: const Text('折叠调用'),
                selected: foldAssistantCalls,
                onSelected: onFoldAssistantCalls,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// P6 Trajectory 单条记录行：序列 + 语义标签 + 状态 + 摘要。
class _TrajectoryRow extends StatelessWidget {
  const _TrajectoryRow({
    required this.record,
    required this.equalWidth,
    required this.selected,
    required this.onTap,
  });

  final TrajectoryRecord record;
  final bool equalWidth;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      key: Key('trajectory-row-${record.key}'),
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
        decoration: selected
            ? BoxDecoration(
                color: theme.colorScheme.primaryContainer.withValues(
                  alpha: 0.35,
                ),
                borderRadius: BorderRadius.circular(8),
              )
            : null,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 28,
              child: Text(
                '${record.sequence}',
                style: theme.textTheme.labelSmall,
              ),
            ),
            // v0.5/P6：duration/equal-width 切换只改展示条，不触碰 Chat projection。
            if (equalWidth)
              const SizedBox(width: 2)
            else
              Padding(
                padding: const EdgeInsets.only(right: 6, top: 2),
                child: Container(
                  width: 3,
                  height: 30,
                  decoration: BoxDecoration(
                    color: _kindColor(theme, record.kind),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          record.label,
                          style: theme.textTheme.titleSmall,
                        ),
                      ),
                      if (record.isStreaming) ...[
                        const SizedBox(width: 6),
                        Icon(
                          Icons.sync,
                          size: 12,
                          color: theme.colorScheme.primary,
                        ),
                      ],
                    ],
                  ),
                  if (record.status?.isNotEmpty == true) ...[
                    const SizedBox(height: 2),
                    Text(record.status!, style: theme.textTheme.bodySmall),
                  ],
                  if (record.summary?.trim().isNotEmpty == true) ...[
                    const SizedBox(height: 4),
                    Text(record.summary!),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Color _kindColor(ThemeData theme, ConversationNodeKind kind) {
    return switch (kind) {
      ConversationNodeKind.user => theme.colorScheme.primary,
      ConversationNodeKind.assistant => theme.colorScheme.tertiary,
      ConversationNodeKind.tool => theme.colorScheme.secondary,
      _ => theme.colorScheme.outlineVariant,
    };
  }
}

/// 轻量 ledger 条目：turn 分组头的数据占位。
class _TrajectoryTurnHeaderData {
  const _TrajectoryTurnHeaderData(this.turnId);

  final String? turnId;
}

/// Trajectory turn 分组头。
class _TrajectoryTurnHeader extends StatelessWidget {
  const _TrajectoryTurnHeader({required this.turnId});

  final String? turnId;

  @override
  Widget build(BuildContext context) => Padding(
    key: Key('trajectory-turn-header-${turnId ?? 'none'}'),
    padding: const EdgeInsets.only(top: 8, bottom: 2),
    child: Text(
      turnId == null ? '未分组' : '轮次 ${turnId!.replaceFirst('turn-', '#')}',
      style: Theme.of(
        context,
      ).textTheme.labelMedium?.copyWith(fontWeight: FontWeight.bold),
    ),
  );
}

/// Trajectory load older 行：仅在有更早记录时出现。
class _TrajectoryLoadOlder extends StatelessWidget {
  const _TrajectoryLoadOlder({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Center(
    child: TextButton(
      key: const Key('session-trajectory-load-older'),
      onPressed: onTap,
      child: const Text('加载更早轨迹'),
    ),
  );
}

/// Trajectory Overview timeline：支持拖拽范围选择和点击选择最近记录。
///
/// 时间字段缺失时回退到等宽位置，不伪造真实时长；切换 mode 会由上层清空选区。
class _TrajectoryTimeline extends StatefulWidget {
  const _TrajectoryTimeline({
    required this.records,
    required this.equalWidth,
    required this.rangeStart,
    required this.rangeEnd,
    required this.rangeActive,
    required this.onRangeChanged,
    required this.onClearRange,
    required this.onRecordTap,
  });

  final List<TrajectoryRecord> records;
  final bool equalWidth;
  final double rangeStart;
  final double rangeEnd;
  final bool rangeActive;
  final void Function(double start, double end) onRangeChanged;
  final VoidCallback onClearRange;
  final ValueChanged<String> onRecordTap;

  @override
  State<_TrajectoryTimeline> createState() => _TrajectoryTimelineState();
}

class _TrajectoryTimelineState extends State<_TrajectoryTimeline> {
  double? _dragStart;

  double _positionFor(TrajectoryRecord record) {
    final total = widget.records.length;
    if (total <= 1) return 0.5;
    final index = widget.records.indexWhere((item) => item.key == record.key);
    final normalizedIndex = index / (total - 1);
    if (widget.equalWidth ||
        widget.records.every((item) => item.createdAt == null)) {
      return normalizedIndex;
    }
    final times = widget.records
        .map((item) => item.createdAt)
        .whereType<DateTime>()
        .toList();
    if (times.isEmpty) return normalizedIndex;
    final min = times.reduce(
      (left, right) => left.isBefore(right) ? left : right,
    );
    final max = times.reduce(
      (left, right) => left.isAfter(right) ? left : right,
    );
    final span = max.difference(min).inMicroseconds;
    final current = record.createdAt;
    if (current == null || span <= 0) return normalizedIndex;
    return (current.difference(min).inMicroseconds / span).clamp(0.0, 1.0);
  }

  TrajectoryRecord _nearest(double position) {
    if (widget.records.isEmpty) {
      throw StateError('timeline should not be empty');
    }
    var best = widget.records.first;
    var bestDistance = double.infinity;
    for (final record in widget.records) {
      final distance = (_positionFor(record) - position).abs();
      if (distance < bestDistance) {
        bestDistance = distance;
        best = record;
      }
    }
    return best;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Overview',
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              if (widget.rangeActive)
                TextButton(
                  key: const Key('session-trajectory-range-clear'),
                  onPressed: widget.onClearRange,
                  child: const Text('清除选区'),
                ),
            ],
          ),
          const SizedBox(height: 2),
          LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              final start = widget.rangeStart * width;
              final end = widget.rangeEnd * width;
              return GestureDetector(
                key: const Key('session-trajectory-overview'),
                behavior: HitTestBehavior.opaque,
                onHorizontalDragStart: (details) {
                  final position = (details.localPosition.dx / width).clamp(
                    0.0,
                    1.0,
                  );
                  setState(() => _dragStart = position);
                  widget.onRangeChanged(position, position);
                  widget.onRecordTap(_nearest(position).key);
                },
                onHorizontalDragUpdate: (details) {
                  final startPosition = _dragStart;
                  if (startPosition == null) return;
                  final position = (details.localPosition.dx / width).clamp(
                    0.0,
                    1.0,
                  );
                  widget.onRangeChanged(startPosition, position);
                },
                onHorizontalDragEnd: (_) => setState(() => _dragStart = null),
                onHorizontalDragCancel: () => setState(() => _dragStart = null),
                onTapUp: (details) {
                  final position = (details.localPosition.dx / width).clamp(
                    0.0,
                    1.0,
                  );
                  widget.onRangeChanged(position, position);
                  widget.onRecordTap(_nearest(position).key);
                },
                child: Container(
                  height: 36,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(AppRadius.card),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(AppRadius.card),
                    child: Stack(
                      children: [
                        if (widget.rangeActive)
                          Positioned(
                            left: start,
                            width: (end - start).abs().clamp(0.0, width),
                            top: 0,
                            bottom: 0,
                            child: ColoredBox(
                              color: theme.colorScheme.primaryContainer,
                            ),
                          ),
                        for (final record in widget.records)
                          Positioned(
                            left: (_positionFor(record) * width).clamp(
                              0.0,
                              width - 2,
                            ),
                            top: 4,
                            bottom: 4,
                            child: Container(
                              width: 2,
                              decoration: BoxDecoration(
                                color: _kindColor(theme, record.kind),
                                borderRadius: BorderRadius.circular(1),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Color _kindColor(ThemeData theme, ConversationNodeKind kind) {
    return switch (kind) {
      ConversationNodeKind.user => theme.colorScheme.primary,
      ConversationNodeKind.assistant => theme.colorScheme.tertiary,
      ConversationNodeKind.tool => theme.colorScheme.secondary,
      _ => theme.colorScheme.outlineVariant,
    };
  }
}

/// Trajectory record inspector：展示当前选中记录的 display-safe 字段。
class _TrajectoryInspector extends StatelessWidget {
  const _TrajectoryInspector({required this.record, required this.onClose});

  final TrajectoryRecord record;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      key: const Key('session-trajectory-inspector'),
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text('记录检查器', style: theme.textTheme.labelLarge)),
              IconButton(
                key: const Key('session-trajectory-inspector-close'),
                tooltip: '关闭记录检查器',
                onPressed: onClose,
                icon: const Icon(Icons.close, size: 18),
              ),
            ],
          ),
          Text('序列 ${record.sequence} · ${record.label}'),
          if (record.status?.isNotEmpty == true) ...[
            const SizedBox(height: 2),
            Text('状态：${record.status}'),
          ],
          if (record.summary?.trim().isNotEmpty == true) ...[
            const SizedBox(height: 2),
            Text('摘要：${record.summary}'),
          ],
          if (record.turnId != null) ...[
            const SizedBox(height: 2),
            Text('轮次：${record.turnId}'),
          ],
          if (record.createdAt != null) ...[
            const SizedBox(height: 2),
            Text('时间：${record.createdAt!.toIso8601String()}'),
          ],
          if (record.inspectTarget != null) ...[
            const SizedBox(height: 2),
            Text('Inspect：${record.inspectTarget}'),
          ],
        ],
      ),
    );
  }
}

class _TrajectoryInspectBanner extends StatelessWidget {
  const _TrajectoryInspectBanner({required this.target});

  final String target;

  @override
  Widget build(BuildContext context) => Container(
    key: const Key('session-trajectory-inspect-target'),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.primaryContainer,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Row(
      children: [
        const Icon(Icons.manage_search_outlined),
        const SizedBox(width: 8),
        Expanded(child: Text('Inspect target: $target')),
      ],
    ),
  );
}
