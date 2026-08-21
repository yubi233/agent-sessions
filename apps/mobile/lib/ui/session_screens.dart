import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../app/providers.dart';
import '../domain/composer_preferences.dart';
import '../domain/control_models.dart';
import '../domain/delegation_models.dart';
import '../domain/session_input_grammar.dart';
import '../domain/session_models.dart';
import '../domain/session_projection_models.dart';
import '../state/app_controller.dart';
import '../state/delegation_controller.dart';
import '../state/lifecycle_recovery_controller.dart';
import '../state/session_composer_controller.dart';
import '../state/session_controller.dart';
import '../state/session_projection_controller.dart';
import '../state/session_view_controller.dart';
import 'appearance_controls.dart';
import 'app_theme.dart';
import 'session/chat/session_chat_view.dart';
import 'session/composer/session_goal_dock.dart';
import 'session/composer/session_queue_dock.dart';
import 'session/composer/session_model_seat.dart';
import 'session/composer/session_context_meter.dart';
import 'session/composer/session_stats_line.dart';

import 'session/composer/session_todo_dock.dart';
import 'session/session_conversation_root.dart';
import 'session/session_header.dart';

/// Happy 风格会话首页：优先呈现会话工作流，同时将 owner 安全入口保留在轻量控制区。
class SessionHomeScreen extends ConsumerWidget {
  const SessionHomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final app = ref.watch(appControllerProvider);
    final sessions = ref.watch(sessionControllerProvider);
    return Scaffold(
      key: const Key('session-home-screen'),
      appBar: AppBar(
        title: const _SessionHeaderTitle(title: 'Sessions'),
        actions: [
          const AppearanceMenu(),
          IconButton(
            key: const Key('session-command-palette-button'),
            tooltip: '命令面板',
            onPressed: () => context.push('/command-palette'),
            icon: const Icon(Icons.terminal_outlined),
          ),
          IconButton(
            key: const Key('session-recent-button'),
            tooltip: '最近会话',
            onPressed: () => context.push('/sessions/recent'),
            icon: const Icon(Icons.history),
          ),
          IconButton(
            key: const Key('session-new-button'),
            tooltip: '新建会话',
            onPressed: app.canManageDevices && !app.isBusy
                ? () => context.push('/sessions/new')
                : null,
            icon: const Icon(Icons.add),
          ),
          IconButton(
            key: const Key('signout-button'),
            tooltip: '断开此设备',
            onPressed: app.isBusy ? null : app.signOut,
            icon: const Icon(Icons.logout_outlined),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: RefreshIndicator(
              onRefresh: sessions.refreshSessions,
              child: _SessionHomeBody(app: app, sessions: sessions),
            ),
          ),
        ),
      ),
    );
  }
}

class _SessionHomeBody extends StatelessWidget {
  const _SessionHomeBody({required this.app, required this.sessions});

  final AppController app;
  final SessionController sessions;

  @override
  Widget build(BuildContext context) {
    if (sessions.phase == SessionListPhase.loading &&
        sessions.sessions.isEmpty) {
      return const Center(
        key: Key('session-list-loading'),
        child: CircularProgressIndicator(),
      );
    }
    if (sessions.phase == SessionListPhase.error && sessions.sessions.isEmpty) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
        children: [
          _InlineError(
            key: const Key('session-list-error'),
            message: sessions.errorMessage ?? '会话列表暂时不可用。',
            onRetry: sessions.refreshSessions,
          ),
          const SizedBox(height: 16),
          _SecurityControls(app: app),
        ],
      );
    }

    final groups = _groupSessions(sessions.sessions);
    return ListView(
      key: const Key('session-list-scroll'),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        if (sessions.errorMessage != null) ...[
          _InlineError(
            key: const Key('session-error-message'),
            message: sessions.errorMessage!,
            onRetry: sessions.clearError,
          ),
          const SizedBox(height: 8),
        ],
        if (!app.canManageDevices) ...[
          const _ReadOnlyBanner(),
          const SizedBox(height: 12),
        ],
        if (sessions.isEmpty)
          _SessionEmptyState(canWrite: app.canManageDevices)
        else ...[
          const _SectionLabel('会话'),
          for (final group in groups.entries) ...[
            _ProjectGroupHeader(title: group.key),
            for (final session in group.value)
              _SessionListItem(
                session: session,
                selected: session.id == sessions.selectedSessionId,
                onTap: () async {
                  await sessions.selectSession(session.id);
                  if (!context.mounted) return;
                  context.push('/sessions/${session.id}');
                },
              ),
          ],
        ],
        const SizedBox(height: 16),
        _SecurityControls(app: app),
      ],
    );
  }
}

Map<String, List<MobileSession>> _groupSessions(List<MobileSession> sessions) {
  final groups = <String, List<MobileSession>>{};
  for (final session in sessions) {
    final project = session.projectName?.trim().isNotEmpty == true
        ? session.projectName!.trim()
        : '未命名项目';
    groups.putIfAbsent(project, () => []).add(session);
  }
  return groups;
}

class NewSessionScreen extends ConsumerStatefulWidget {
  const NewSessionScreen({super.key});

  @override
  ConsumerState<NewSessionScreen> createState() => _NewSessionScreenState();
}

class _NewSessionScreenState extends ConsumerState<NewSessionScreen> {
  static const _defaultWorkspaceId = String.fromEnvironment(
    'LOCAL_DEV_WORKSPACE_ID',
    defaultValue: 'fixture-workspace',
  );
  final _formKey = GlobalKey<FormState>();
  final _workspaceController = TextEditingController(text: _defaultWorkspaceId);
  String _provider = 'codex';

  @override
  void dispose() {
    _workspaceController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = ref.watch(appControllerProvider);
    final sessions = ref.watch(sessionControllerProvider);
    return Scaffold(
      appBar: AppBar(
        title: const _SessionHeaderTitle(title: '新建会话'),
        leading: IconButton(
          key: const Key('new-session-back-button'),
          tooltip: '返回会话列表',
          onPressed: () => context.pop(),
          icon: const Icon(Icons.arrow_back),
        ),
      ),
      body: SafeArea(
        top: false,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text('开始一个会话', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 6),
                Text(
                  '会话会绑定到已授权的工作区；实际 Provider 调度不在本地 fixture 中执行。',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 20),
                Form(
                  key: _formKey,
                  child: Column(
                    children: [
                      TextFormField(
                        key: const Key('new-session-workspace-input'),
                        controller: _workspaceController,
                        decoration: const InputDecoration(labelText: '工作区 ID'),
                        validator: (value) => value?.trim().isNotEmpty == true
                            ? null
                            : '请输入工作区 ID。',
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        key: const Key('new-session-provider-select'),
                        initialValue: _provider,
                        decoration: const InputDecoration(
                          labelText: 'Provider',
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: 'codex',
                            child: Text('Codex'),
                          ),
                          DropdownMenuItem(
                            value: 'claude',
                            child: Text('Claude'),
                          ),
                          DropdownMenuItem(
                            value: 'opencode',
                            child: Text('OpenCode'),
                          ),
                        ],
                        onChanged: app.canManageDevices && !sessions.isBusy
                            ? (value) =>
                                  setState(() => _provider = value ?? 'codex')
                            : null,
                      ),
                      const SizedBox(height: 20),
                      if (!app.canManageDevices) const _ReadOnlyBanner(),
                      if (!app.canManageDevices) const SizedBox(height: 12),
                      FilledButton.icon(
                        key: const Key('new-session-create-button'),
                        onPressed: app.canManageDevices && !sessions.isBusy
                            ? () => _create(app, sessions)
                            : null,
                        icon: const Icon(Icons.play_arrow),
                        label: const Text('创建会话'),
                      ),
                      if (sessions.errorMessage != null) ...[
                        const SizedBox(height: 12),
                        _InlineError(
                          message: sessions.errorMessage!,
                          onRetry: sessions.clearError,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _create(AppController app, SessionController sessions) async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final session = await sessions.createSession(
      workspaceId: _workspaceController.text,
      provider: _provider,
      deviceId: app.currentDevice?.id,
      canWrite: app.canManageDevices,
    );
    if (!mounted || session == null) return;
    context.go('/sessions/${session.id}');
  }
}

class _SessionChatView extends StatelessWidget {
  const _SessionChatView({
    required this.sessions,
    required this.recovery,
    required this.delegations,
    required this.canWrite,
    required this.deviceId,
    required this.sessionId,
    required this.onInspectTarget,
  });

  final SessionController sessions;
  final SessionRecoveryController recovery;
  final DelegationController delegations;
  final bool canWrite;
  final String? deviceId;
  final String sessionId;
  final void Function(String target) onInspectTarget;

  @override
  Widget build(BuildContext context) {
    final projection = const SessionProjectionController().buildSnapshot(
      timeline: sessions.timeline,
      controls: sessions.controls,
    );
    // v0.5/P2：Chat 只消费 projection nodes；permission/question pending 已被投影层排除，
    // 后续由 composer chain 接管，避免消息流和 composer 双重渲染同一交互。
    final hasConversationContent = projection.chatNodes.any(
      (node) =>
          node.kind == ConversationNodeKind.user ||
          node.kind == ConversationNodeKind.assistant ||
          node.kind == ConversationNodeKind.reasoning,
    );
    return SessionChatView(
      nodes: projection.chatNodes,
      running: sessions.isStreaming,
      onInspectTarget: onInspectTarget,
      emptyHero: hasConversationContent
          ? null
          : _ConversationEmptyHero(session: sessions.selectedSession),
      footer: [
        _DelegationPanel(
          controller: delegations,
          sessions: sessions,
          canWrite: canWrite,
          deviceId: deviceId,
          onDecision: (delegation, decision) async {
            final result = await delegations.decide(
              delegation: delegation,
              decision: decision,
              capabilities: sessions.capabilityMatrix,
              canWrite: canWrite,
              deviceId: deviceId,
              parentLease: sessions.selectedLease,
            );
            // 批准后 child 会话进入列表；仅刷新索引，保留当前 parent 页面和其安全投影。
            if (result?.hasChildSession == true) {
              await sessions.refreshSessions();
            }
          },
          onOpenChild: (childSessionId) async {
            // selectSession 会清掉 parent lease；child 的写操作必须重新获取自己的 fencing epoch。
            await sessions.selectSession(childSessionId);
            if (!context.mounted) return;
            context.go('/sessions/$childSessionId');
          },
        ),
        _SessionRecoveryStrip(controller: recovery, sessionId: sessionId),
        if (sessions.errorMessage != null)
          _InlineError(
            key: const Key('session-detail-error-message'),
            message: sessions.errorMessage!,
            onRetry: sessions.clearError,
          ),
      ],
    );
  }
}

class _ConversationEmptyHero extends StatelessWidget {
  const _ConversationEmptyHero({required this.session});

  final MobileSession? session;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      key: const Key('happy-session-empty-state'),
      children: [
        const SizedBox(height: 24),
        Icon(
          Icons.computer_outlined,
          size: 44,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(height: 12),
        Text(
          session?.workspaceLabel ?? '绑定的工作区',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          session?.workspaceLabel == 'fixture-workspace'
              ? '~/code/agentProject/agent-sessions'
              : (session?.workspaceLabel ??
                    '~/code/agentProject/agent-sessions'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 18),
        Text(
          'No messages yet',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// v0.5/P6：Trajectory 基础 ledger 视图。
///
/// 只消费 `SessionProjectionController` 的 `trajectoryRecords`（display-safe），
/// 不改变 Chat projection；提供 toolbar（搜索 / 折叠 turn / 折叠 assistant call /
/// duration/equal-width 模式）与 record inspector 展示。真实 timeline 缩放/虚拟化
/// 与选区重映射仍在 P6 后续阶段，本切片先固化「按投影渲染 + 搜索 + 折叠」契约。
class SessionTrajectoryView extends StatefulWidget {
  const SessionTrajectoryView({
    required this.records,
    required this.inspectTarget,
    required this.onInspectConsumed,
    super.key,
  });

  final List<TrajectoryRecord> records;
  final String? inspectTarget;
  final VoidCallback onInspectConsumed;

  @override
  State<SessionTrajectoryView> createState() => _SessionTrajectoryViewState();
}

class _SessionTrajectoryViewState extends State<SessionTrajectoryView> {
  final _ledgerController = ScrollController();
  String _query = '';
  String _appliedQuery = '';
  Timer? _searchDebounce;
  bool _equalWidth = false;
  bool _foldTurns = false;
  bool _foldAssistantCalls = false;
  int _visibleLimit = 10;
  double _rangeStart = 0;
  double _rangeEnd = 1;
  bool _rangeActive = false;
  String? _selectedKey;

  @override
  void dispose() {
    _searchDebounce?.cancel();
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
    _resetLedgerOffset();
  }

  void _setFoldTurns(bool value) {
    setState(() => _foldTurns = value);
    _resetLedgerOffset();
  }

  void _setFoldAssistantCalls(bool value) {
    setState(() => _foldAssistantCalls = value);
    _resetLedgerOffset();
  }

  /// 按当前 toolbar / timeline 过滤后的全量 records；范围选择用 fraction 过滤。
  List<TrajectoryRecord> get _filtered {
    final q = _appliedQuery.trim().toLowerCase();
    final records = widget.records.where((record) {
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
    }).toList(growable: false);
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
    _resetLedgerOffset();
  }

  void _clearRangeSelection() {
    _rangeActive = false;
    _rangeStart = 0;
    _rangeEnd = 1;
  }

  void _selectRecord(String key) {
    setState(() => _selectedKey = key);
    _resetLedgerOffset();
  }

  void _closeInspector() {
    setState(() => _selectedKey = null);
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
    final itemCount = headers.length + (_hasOlder ? 1 : 0) + visibleItems.length;
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
              child: Text('${record.sequence}', style: theme.textTheme.labelSmall),
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
                        child: Text(record.label, style: theme.textTheme.titleSmall),
                      ),
                      if (record.isStreaming) ...[
                        const SizedBox(width: 6),
                        Icon(Icons.sync, size: 12, color: theme.colorScheme.primary),
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
      style: Theme.of(context).textTheme.labelMedium?.copyWith(
        fontWeight: FontWeight.bold,
      ),
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
                    color: theme.colorScheme.surfaceContainerHighest.withValues(
                      alpha: 0.45,
                    ),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
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
              Expanded(
                child: Text(
                  '记录检查器',
                  style: theme.textTheme.labelLarge,
                ),
              ),
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

class SessionDetailScreen extends ConsumerStatefulWidget {
  const SessionDetailScreen({required this.sessionId, super.key});

  final String sessionId;

  @override
  ConsumerState<SessionDetailScreen> createState() =>
      _SessionDetailScreenState();
}

class _SessionDetailScreenState extends ConsumerState<SessionDetailScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _selectCurrentSession(),
    );
  }

  @override
  void didUpdateWidget(covariant SessionDetailScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessionId != widget.sessionId) {
      // go_router 更新同一详情 State 时仍处于 build；下一帧再通知 delegation provider，
      // 防止 child 切入触发 Riverpod 的 build 期状态修改断言。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_selectCurrentSession());
      });
    }
  }

  Future<void> _selectCurrentSession({bool force = false}) async {
    final controller = ref.read(sessionControllerProvider);
    if (force || controller.selectedSessionId != widget.sessionId) {
      await controller.selectSession(widget.sessionId);
    }
    // delegation 只按当前 parent session 拉取，不能从 timeline 反推或复制 child 内容。
    await ref
        .read(delegationControllerProvider)
        .loadForParent(widget.sessionId, force: force);
  }

  @override
  Widget build(BuildContext context) {
    final app = ref.watch(appControllerProvider);
    final sessions = ref.watch(sessionControllerProvider);
    final delegations = ref.watch(delegationControllerProvider);
    final recovery = ref.watch(sessionRecoveryControllerProvider);
    final viewController = ref.watch(sessionViewControllerProvider);
    final viewMode = viewController.modeFor(widget.sessionId);
    final session = sessions.selectedSession;
    return Scaffold(
      key: const Key('session-detail-screen'),
      resizeToAvoidBottomInset: true,
      body: SessionConversationRoot(
        header: SessionHeader(
          title: _HappySessionHeaderTitle(session: session),
          status: _SessionStatusStrip(
            session: session,
            hasLease: sessions.hasSelectedLease,
            canWrite: app.canManageDevices,
            provider: sessions.selectedProviderCapabilities,
            onAcquireLease: app.canManageDevices && !sessions.isBusy
                ? () => sessions.acquireSelectedLease(
                    deviceId: app.currentDevice?.id,
                    canWrite: app.canManageDevices,
                  )
                : null,
          ),
          mode: viewMode,
          onModeChanged: (mode) {
            // v0.5/P1：tab 切换只写本地 view store，不触发会话命令或清空 composer。
            ref
                .read(sessionViewControllerProvider)
                .setMode(widget.sessionId, mode);
          },
          onBack: () => context.go('/home'),
          actions: _SessionQuickMenu(
            sessions: sessions,
            canWrite: app.canManageDevices,
            deviceId: app.currentDevice?.id,
            sessionId: widget.sessionId,
            onRefresh: sessions.isDetailLoading || delegations.isLoading
                ? null
                : () => unawaited(_selectCurrentSession(force: true)),
          ),
          utilities: _SessionControlPanel(
            sessions: sessions,
            canWrite: app.canManageDevices,
            deviceId: app.currentDevice?.id,
          ),
        ),
        activeView: viewMode == SessionViewMode.chat
            ? _SessionChatView(
                sessions: sessions,
                recovery: recovery,
                delegations: delegations,
                canWrite: app.canManageDevices,
                deviceId: app.currentDevice?.id,
                sessionId: widget.sessionId,
                onInspectTarget: (target) {
                  ref
                      .read(sessionViewControllerProvider)
                      .setInspectTarget(widget.sessionId, target);
                },
              )
            : SessionTrajectoryView(
                // v0.5/P6：Trajectory 消费 projection 的 display-safe records，不读 raw events。
                records: const SessionProjectionController()
                    .buildSnapshot(
                      timeline: sessions.timeline,
                      controls: sessions.controls,
                    )
                    .trajectoryRecords,
                inspectTarget: viewController.inspectTargetFor(
                  widget.sessionId,
                ),
                onInspectConsumed: () {
                  final target = viewController.inspectTargetFor(
                    widget.sessionId,
                  );
                  if (target == null) return;
                  ref
                      .read(sessionViewControllerProvider)
                      .clearInspectTarget(widget.sessionId, target);
                },
              ),
        composer: _SessionComposer(
          sessions: sessions,
          canWrite: app.canManageDevices,
          deviceId: app.currentDevice?.id,
          interactionEvents: sessions.timeline,
          // v0.5/P5：busy Enter 偏好来自用户级设置（默认 Queue），与设置页同一事实来源。
          enterBehavior: ref
              .watch(composerPreferenceControllerProvider)
              .enterBehavior,
          fileCompletionCatalog: () async {
            try {
              final entries = await ref
                  .read(workspaceFilesRepositoryProvider)
                  .listDirectory('');
              return entries.map((entry) => entry.name).toList();
            } catch (_) {
              return const [];
            }
          },
        ),
      ),
    );
  }
}

/// Happy 风格会话快捷菜单：details / resume / fork / archive。
/// 入口按 capability 显示或禁用（fail-closed）；resume 只提交带 lease 与幂等键的命令。
class _SessionQuickMenu extends StatelessWidget {
  const _SessionQuickMenu({
    required this.sessions,
    required this.canWrite,
    required this.deviceId,
    required this.sessionId,
    required this.onRefresh,
  });

  final SessionController sessions;
  final bool canWrite;
  final String? deviceId;
  final String sessionId;
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    final startBlocked = sessions.controlBlockedReason(
      'start',
      canWrite: canWrite,
    );
    final resumeBlocked = sessions.resumeBlockedReason(canWrite: canWrite);
    final killBlocked = sessions.killBlockedReason(canWrite: canWrite);
    return PopupMenuButton<String>(
      key: const Key('session-quick-menu-button'),
      tooltip: '会话操作',
      icon: _HappyProviderAvatar(provider: sessions.selectedSession?.provider),
      onSelected: (value) {
        switch (value) {
          case 'lease':
            sessions.acquireSelectedLease(
              deviceId: deviceId,
              canWrite: canWrite,
            );
          case 'refresh':
            onRefresh?.call();
          case 'git':
            context.push('/sessions/$sessionId/git');
          case 'observation':
            context.push('/sessions/$sessionId/observation');
          case 'details':
            _showDetailsSheet(context, sessions);
          case 'info':
            // P3 会话 info 是独立只读页面，展示机器/Provider/终止恢复能力三态。
            context.push('/sessions/${sessions.selectedSessionId}/info');
          case 'resume':
            sessions.resumeSelectedSession(
              deviceId: deviceId,
              canWrite: canWrite,
            );
          case 'start':
            sessions.startSelectedSession(
              deviceId: deviceId,
              canWrite: canWrite,
            );
          case 'kill':
            _confirmKill(context, sessions);
          case 'files':
            // 文件浏览是只读页面，与 Git 入口一样不依赖 lease。
            context.push('/sessions/${sessions.selectedSessionId}/files');
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          key: const Key('session-acquire-lease-button'),
          value: 'lease',
          enabled: canWrite && !sessions.isBusy,
          child: ListTile(
            leading: Icon(
              sessions.hasSelectedLease
                  ? Icons.lock_open_outlined
                  : Icons.lock_outline,
            ),
            title: Text(sessions.hasSelectedLease ? '已获得控制权' : '获取会话控制权'),
            dense: true,
            contentPadding: EdgeInsets.zero,
          ),
        ),
        PopupMenuItem(
          key: const Key('session-refresh-button'),
          value: 'refresh',
          enabled: onRefresh != null,
          child: const ListTile(
            leading: Icon(Icons.refresh),
            title: Text('刷新会话'),
            dense: true,
            contentPadding: EdgeInsets.zero,
          ),
        ),
        const PopupMenuItem(
          key: Key('session-open-git-button'),
          value: 'git',
          child: ListTile(
            leading: Icon(Icons.difference_outlined),
            title: Text('查看 Git 变更'),
            dense: true,
            contentPadding: EdgeInsets.zero,
          ),
        ),
        const PopupMenuItem(
          key: Key('session-open-daemon-observation-button'),
          value: 'observation',
          child: ListTile(
            leading: Icon(Icons.visibility_outlined),
            title: Text('查看 Daemon 观察'),
            dense: true,
            contentPadding: EdgeInsets.zero,
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          key: Key('session-quick-details'),
          value: 'details',
          child: ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('会话详情'),
            dense: true,
            contentPadding: EdgeInsets.zero,
          ),
        ),
        const PopupMenuItem(
          key: Key('session-quick-info'),
          value: 'info',
          child: ListTile(
            leading: Icon(Icons.description_outlined),
            title: Text('会话信息'),
            dense: true,
            contentPadding: EdgeInsets.zero,
          ),
        ),
        PopupMenuItem(
          key: const Key('session-start-button'),
          value: 'start',
          enabled: startBlocked == null && !sessions.isBusy,
          child: ListTile(
            leading: Icon(
              Icons.play_arrow_outlined,
              color: startBlocked == null
                  ? null
                  : Theme.of(context).disabledColor,
            ),
            title: const Text('启动会话'),
            subtitle: startBlocked == null
                ? null
                : Text(
                    startBlocked,
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
            dense: true,
            contentPadding: EdgeInsets.zero,
          ),
        ),
        PopupMenuItem(
          key: const Key('session-quick-resume'),
          value: 'resume',
          enabled: resumeBlocked == null && !sessions.isBusy,
          child: ListTile(
            leading: Icon(
              Icons.play_circle_outline,
              color: resumeBlocked == null
                  ? null
                  : Theme.of(context).disabledColor,
            ),
            title: Text('恢复会话'),
            subtitle: resumeBlocked == null
                ? null
                : Text(
                    resumeBlocked,
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
            dense: true,
            contentPadding: EdgeInsets.zero,
          ),
        ),
        PopupMenuItem(
          key: const Key('session-kill-button'),
          value: 'kill',
          enabled: killBlocked == null && !sessions.isBusy,
          child: ListTile(
            leading: Icon(
              Icons.stop_circle_outlined,
              color: killBlocked == null
                  ? null
                  : Theme.of(context).disabledColor,
            ),
            title: const Text('结束本机进程'),
            subtitle: killBlocked == null
                ? const Text('需要二次确认')
                : Text(
                    killBlocked,
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
            dense: true,
            contentPadding: EdgeInsets.zero,
          ),
        ),
        PopupMenuItem(
          key: const Key('session-quick-files'),
          value: 'files',
          child: const ListTile(
            leading: Icon(Icons.folder_open_outlined),
            title: Text('浏览工作区文件'),
            dense: true,
            contentPadding: EdgeInsets.zero,
          ),
        ),
        const PopupMenuItem(
          key: Key('session-quick-fork'),
          value: 'fork',
          enabled: false,
          child: ListTile(
            leading: Icon(Icons.copy_outlined),
            title: Text('Fork 会话'),
            subtitle: Text(
              'Provider 未声明 fork 能力',
              style: TextStyle(fontSize: 11),
            ),
            dense: true,
            contentPadding: EdgeInsets.zero,
          ),
        ),
        // v0.3/P2：duplicate 与 fork/archive 同规则——capability 未声明时 fail-closed。
        const PopupMenuItem(
          key: Key('session-quick-duplicate'),
          value: 'duplicate',
          enabled: false,
          child: ListTile(
            leading: Icon(Icons.copy_all_outlined),
            title: Text('Duplicate 会话'),
            subtitle: Text(
              'Provider 未声明 duplicate 能力',
              style: TextStyle(fontSize: 11),
            ),
            dense: true,
            contentPadding: EdgeInsets.zero,
          ),
        ),
        const PopupMenuItem(
          key: Key('session-quick-archive'),
          value: 'archive',
          enabled: false,
          child: ListTile(
            leading: Icon(Icons.archive_outlined),
            title: Text('归档会话'),
            subtitle: Text('Provider 未声明归档能力', style: TextStyle(fontSize: 11)),
            dense: true,
            contentPadding: EdgeInsets.zero,
          ),
        ),
      ],
    );
  }

  Future<void> _confirmKill(
    BuildContext context,
    SessionController sessions,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('结束本机进程？'),
        content: const Text('这会结束当前会话的受控本地进程，已提交的事件不会被删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('session-kill-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('结束进程'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await sessions.killSelectedSession(
        deviceId: deviceId,
        canWrite: canWrite,
      );
    }
  }

  /// 详情底表只展示 Relay 白名单元数据，不读取、不展示密文正文。
  void _showDetailsSheet(BuildContext context, SessionController sessions) {
    final session = sessions.selectedSession;
    if (session == null) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Column(
            key: const Key('session-details-sheet'),
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('会话详情', style: Theme.of(sheetContext).textTheme.titleMedium),
              const SizedBox(height: 12),
              _DetailRow(label: '会话 ID', value: session.id),
              _DetailRow(label: 'Provider', value: session.provider),
              _DetailRow(label: '工作区', value: session.workspaceLabel),
              _DetailRow(
                label: '状态',
                value: _sessionStatusPresentation(session.status).label,
              ),
              _DetailRow(label: '事件序号', value: '${session.lastSequence}'),
              const SizedBox(height: 12),
              // v0.3/P2：复制只包含白名单元数据（会话 ID/Provider/工作区），不复制密文或正文。
              Wrap(
                spacing: 8,
                children: [
                  OutlinedButton.icon(
                    key: const Key('session-copy-id-button'),
                    onPressed: () =>
                        Clipboard.setData(ClipboardData(text: session.id)),
                    icon: const Icon(Icons.copy_outlined, size: 16),
                    label: const Text('复制会话 ID'),
                  ),
                  OutlinedButton.icon(
                    key: const Key('session-copy-provider-button'),
                    onPressed: () => Clipboard.setData(
                      ClipboardData(text: session.provider),
                    ),
                    icon: const Icon(Icons.copy_outlined, size: 16),
                    label: const Text('复制 Provider'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '展示内容仅来自 Relay 白名单元数据；消息正文与密文不会显示。',
                style: Theme.of(sheetContext).textTheme.labelSmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 详情底表的单行字段。
class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 72,
          child: Text(label, style: Theme.of(context).textTheme.labelMedium),
        ),
        Expanded(
          child: Text(
            value,
            style: Theme.of(context).textTheme.bodyMedium,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    ),
  );
}

/// Happy 风格父子图保持为一条紧凑控制带：父页只展示安全摘要与状态，child 正文永不嵌入这里。
// ignore: unused_element
class _DelegationPanel extends StatelessWidget {
  const _DelegationPanel({
    required this.controller,
    required this.sessions,
    required this.canWrite,
    required this.deviceId,
    required this.onDecision,
    required this.onOpenChild,
  });

  final DelegationController controller;
  final SessionController sessions;
  final bool canWrite;
  final String? deviceId;
  final Future<void> Function(SessionDelegation, DelegationDecision) onDecision;
  final Future<void> Function(String childSessionId) onOpenChild;

  @override
  Widget build(BuildContext context) {
    if (controller.isLoading && controller.delegations.isEmpty) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: LinearProgressIndicator(key: Key('delegation-loading')),
      );
    }
    // v0.2/P2：父 Provider 声明 delegate_session 时即使无节点也保留“新建子会话”入口；
    // 未声明且无节点时整条控制带隐藏（fail-closed）。
    final parentCapability = sessions.selectedProviderCapabilities.capability(
      'delegate_session',
    );
    final hasProposeEntry = parentCapability.isSupported;
    if (controller.delegations.isEmpty &&
        controller.message == null &&
        !hasProposeEntry) {
      return const SizedBox.shrink();
    }
    return Container(
      key: const Key('delegation-panel'),
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.account_tree_outlined, size: 17),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  '子会话',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
              Text(
                '${controller.delegations.length} 个节点',
                style: Theme.of(context).textTheme.labelMedium,
              ),
              // v0.2/P2：可见派发入口。按下后由底表按 capability 选目标 Provider。
              IconButton(
                key: const Key('delegation-propose-button'),
                tooltip: '新建子会话',
                iconSize: 19,
                onPressed: () => _showDelegationProposalSheet(context),
                icon: const Icon(Icons.add_circle_outline),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text('父会话只保留状态和加密摘要', key: Key('delegation-security-boundary')),
          for (final delegation in controller.delegations) ...[
            const Divider(height: 18),
            _DelegationNode(
              delegation: delegation,
              controller: controller,
              capabilities: sessions.capabilityMatrix,
              canWrite: canWrite,
              deviceId: deviceId,
              parentLease: sessions.selectedLease,
              onDecision: onDecision,
              onOpenChild: onOpenChild,
            ),
          ],
          if (controller.message != null) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: Text(
                    controller.message!,
                    key: const Key('delegation-message'),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '关闭提示',
                  onPressed: controller.clearMessage,
                  icon: const Icon(Icons.close, size: 18),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// 打开“新建子会话”底表：目标 Provider 只从 capability matrix 中筛选可派发项，
  /// 提交走 parent lease + 幂等键；任务摘要正文绝不会变成密文或进入 Relay。
  void _showDelegationProposalSheet(BuildContext context) {
    final parentSession = sessions.selectedSession;
    if (parentSession == null) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => _DelegationProposalSheet(
        parentSession: parentSession,
        parentProvider: parentSession.provider,
        capabilities: sessions.capabilityMatrix,
        controller: controller,
        canWrite: canWrite,
        deviceId: deviceId,
        parentLease: sessions.selectedLease,
        onProposed: (delegation) {
          if (delegation.hasChildSession == true) {
            unawaited(sessions.refreshSessions());
          }
        },
      ),
    );
  }
}

/// 新建子会话派发底表：只提交密文 envelope 与目标 Provider。
class _DelegationProposalSheet extends ConsumerStatefulWidget {
  const _DelegationProposalSheet({
    required this.parentSession,
    required this.parentProvider,
    required this.capabilities,
    required this.controller,
    required this.canWrite,
    required this.deviceId,
    required this.parentLease,
    required this.onProposed,
  });

  final MobileSession parentSession;
  final String parentProvider;
  final CapabilityMatrix capabilities;
  final DelegationController controller;
  final bool canWrite;
  final String? deviceId;
  final SessionLease? parentLease;
  final void Function(SessionDelegation) onProposed;

  @override
  ConsumerState<_DelegationProposalSheet> createState() =>
      _DelegationProposalSheetState();
}

class _DelegationProposalSheetState
    extends ConsumerState<_DelegationProposalSheet> {
  final _summaryController = TextEditingController();
  String? _targetProvider;

  @override
  void initState() {
    super.initState();
    _targetProvider = _selectableProviders().firstOrNull;
  }

  @override
  void dispose() {
    _summaryController.dispose();
    super.dispose();
  }

  /// 可派发目标：父 Provider 必须声明 delegate_session；跨 Provider 还要求目标声明 delegate_cross_provider。
  List<String> _selectableProviders() {
    final parentCapability = widget.capabilities
        .provider(widget.parentProvider)
        .capability('delegate_session');
    if (!parentCapability.isSupported) return const [];
    final cross = widget.capabilities
        .provider(widget.parentProvider)
        .capability('delegate_cross_provider');
    final supportsCross = cross.isSupported;
    return widget.capabilities.providers
        .map((profile) => profile.kind)
        .where((kind) => kind == widget.parentProvider || supportsCross)
        .toList(growable: false);
  }

  String? get _blockedReason => widget.controller.proposeBlockedReason(
    targetProvider: _targetProvider ?? widget.parentProvider,
    capabilities: widget.capabilities,
    canWrite: widget.canWrite,
    deviceId: widget.deviceId,
    parentLease: widget.parentLease,
    parentProvider: widget.parentProvider,
  );

  Future<void> _submit() async {
    if (_targetProvider == null || _summaryController.text.trim().isEmpty) {
      return;
    }
    // 任务书/摘要都是 opaque 密文 envelope；摘要正文只用于本地 UX，绝不进入 ciphertext。
    final taskEnvelope = _opaqueDelegationEnvelope(
      'task:${widget.parentSession.id}:$_targetProvider',
    );
    final summaryEnvelope = _opaqueDelegationEnvelope(
      'summary:${widget.parentSession.id}:$_targetProvider',
    );
    final delegation = await widget.controller.propose(
      parentSessionId: widget.parentSession.id,
      targetWorkspaceId: widget.parentSession.workspaceId,
      targetProvider: _targetProvider!,
      parentProvider: widget.parentProvider,
      taskEnvelope: taskEnvelope,
      summaryEnvelope: summaryEnvelope,
      capabilities: widget.capabilities,
      canWrite: widget.canWrite,
      deviceId: widget.deviceId,
      parentLease: widget.parentLease,
    );
    if (delegation == null || !mounted) return;
    widget.onProposed(delegation);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final providers = _selectableProviders();
    final blocked = _blockedReason;
    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          20,
          16,
          20,
          24 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          key: const Key('delegation-proposal-sheet'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('新建子会话', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              '任务书将加密提交给已授权 Daemon；当前界面只展示状态与摘要指纹。',
              style: Theme.of(context).textTheme.labelSmall,
            ),
            const SizedBox(height: 12),
            if (blocked != null) ...[
              Text(
                blocked,
                key: const Key('delegation-propose-blocked'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              const SizedBox(height: 8),
            ],
            DropdownButtonFormField<String>(
              key: const Key('delegation-target-provider'),
              initialValue: _targetProvider,
              decoration: const InputDecoration(
                labelText: '目标 Provider',
                border: OutlineInputBorder(),
              ),
              items: [
                for (final kind in providers)
                  DropdownMenuItem(value: kind, child: Text(kind)),
              ],
              onChanged: providers.isEmpty
                  ? null
                  : (value) => setState(() => _targetProvider = value),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('delegation-task-summary-input'),
              controller: _summaryController,
              maxLines: 3,
              // 输入变化时刷新提交按钮可用态。
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: '任务摘要（仅用于本地确认）',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 14),
            FilledButton(
              key: const Key('delegation-propose-submit'),
              onPressed:
                  blocked == null && _summaryController.text.trim().isNotEmpty
                  ? () => unawaited(_submit())
                  : null,
              child: const Text('创建子会话'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 构造 opaque 派发 envelope：只含固定结构的占位密文，不含摘要正文。
Map<String, dynamic> _opaqueDelegationEnvelope(String seed) => {
  'alg': 'v1-aes256gcm-hkdfsha256',
  'key_id': 'client-opaque-dek',
  'nonce': 'client-nonce',
  'ciphertext': 'client-opaque-$seed',
  'aad_hash': 'client-aad-hash',
  'payload_version': 1,
};

class _DelegationNode extends StatelessWidget {
  const _DelegationNode({
    required this.delegation,
    required this.controller,
    required this.capabilities,
    required this.canWrite,
    required this.deviceId,
    required this.parentLease,
    required this.onDecision,
    required this.onOpenChild,
  });

  final SessionDelegation delegation;
  final DelegationController controller;
  final CapabilityMatrix capabilities;
  final bool canWrite;
  final String? deviceId;
  final SessionLease? parentLease;
  final Future<void> Function(SessionDelegation, DelegationDecision) onDecision;
  final Future<void> Function(String childSessionId) onOpenChild;

  @override
  Widget build(BuildContext context) {
    final pending = controller.isDecisionPending(delegation.id);
    final approveBlocked = controller.decisionBlockedReason(
      delegation: delegation,
      decision: DelegationDecision.approve,
      capabilities: capabilities,
      canWrite: canWrite,
      deviceId: deviceId,
      parentLease: parentLease,
    );
    final cancelBlocked = controller.decisionBlockedReason(
      delegation: delegation,
      decision: DelegationDecision.cancel,
      capabilities: capabilities,
      canWrite: canWrite,
      deviceId: deviceId,
      parentLease: parentLease,
    );
    final childSessionId = delegation.childSessionId;
    final statusColor = _delegationStatusColor(delegation.status, context);
    // 全局 Happy 图标主题默认使用高对比前景色；派发被 capability 或 lease 拦截时，
    // 必须在节点内覆写 disabled 色，避免“不能点击”仍被误认为是可执行操作。
    final decisionActionStyle = _delegationActionStyle(context);
    return Semantics(
      container: true,
      label: '子会话派发 ${delegation.status.label}',
      child: Column(
        key: Key('delegation-node-${delegation.id}'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const _DelegationGraphLabel(label: '父会话', detail: '当前会话'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Icon(Icons.arrow_forward, size: 18, color: statusColor),
              ),
              Expanded(
                child: _DelegationGraphLabel(
                  label: '子会话',
                  detail: delegation.targetProvider,
                ),
              ),
              Text(
                delegation.status.label,
                key: Key('delegation-status-${delegation.id}'),
                style: Theme.of(
                  context,
                ).textTheme.labelMedium?.copyWith(color: statusColor),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '加密摘要 ${delegation.summaryFingerprint}',
            key: Key('delegation-summary-${delegation.id}'),
            style: Theme.of(context).textTheme.labelMedium,
          ),
          if (delegation.canApproveOrReject) ...[
            const SizedBox(height: 3),
            Text(
              approveBlocked ?? '请使用父会话控制权确认派发。',
              key: Key('delegation-blocked-${delegation.id}'),
              style: Theme.of(context).textTheme.labelMedium,
            ),
            Align(
              alignment: Alignment.centerRight,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    key: Key('delegation-reject-${delegation.id}'),
                    tooltip: '拒绝派发',
                    style: decisionActionStyle,
                    onPressed: pending || approveBlocked != null
                        ? null
                        : () =>
                              onDecision(delegation, DelegationDecision.reject),
                    icon: const Icon(Icons.close),
                  ),
                  IconButton(
                    key: Key('delegation-approve-${delegation.id}'),
                    tooltip: '批准派发',
                    style: decisionActionStyle,
                    onPressed: pending || approveBlocked != null
                        ? null
                        : () => onDecision(
                            delegation,
                            DelegationDecision.approve,
                          ),
                    icon: pending
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.check),
                  ),
                ],
              ),
            ),
          ],
          if (delegation.canCancel) ...[
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerRight,
              child: IconButton(
                key: Key('delegation-cancel-${delegation.id}'),
                tooltip: '取消子会话',
                style: decisionActionStyle,
                onPressed: pending || cancelBlocked != null
                    ? null
                    : () => onDecision(delegation, DelegationDecision.cancel),
                icon: const Icon(Icons.stop_circle_outlined),
              ),
            ),
          ],
          if (childSessionId != null && childSessionId.isNotEmpty) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                const Expanded(child: Text('子会话使用独立控制权')),
                IconButton(
                  key: Key('delegation-open-child-${delegation.id}'),
                  tooltip: '打开子会话',
                  onPressed: () => onOpenChild(childSessionId),
                  icon: const Icon(Icons.arrow_forward_ios, size: 17),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _DelegationGraphLabel extends StatelessWidget {
  const _DelegationGraphLabel({required this.label, required this.detail});

  final String label;
  final String detail;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(label, style: Theme.of(context).textTheme.labelMedium),
      Text(detail, maxLines: 1, overflow: TextOverflow.ellipsis),
    ],
  );
}

Color _delegationStatusColor(DelegationStatus status, BuildContext context) =>
    switch (status) {
      DelegationStatus.completed => context.appColors.success,
      DelegationStatus.failed ||
      DelegationStatus.cancelled ||
      DelegationStatus.rejected => Theme.of(context).colorScheme.error,
      DelegationStatus.proposed => context.appColors.warning,
      DelegationStatus.approved ||
      DelegationStatus.running => Theme.of(context).colorScheme.primary,
      DelegationStatus.unknown => Theme.of(
        context,
      ).colorScheme.onSurfaceVariant,
    };

/// capability、角色或 lease 阻断时使用显式弱化图标，避免全局 IconButton 主题掩盖禁用状态。
ButtonStyle _delegationActionStyle(BuildContext context) {
  final active = Theme.of(context).colorScheme.onSurface;
  final disabled = active.withAlpha(92);
  return ButtonStyle(
    foregroundColor: WidgetStateProperty.resolveWith(
      (states) => states.contains(WidgetState.disabled) ? disabled : active,
    ),
  );
}

/// P3 控制面保持为紧凑、可扫描的 Happy 风格状态条；所有可执行图标都受 capability + role + lease 同一门控。
class _SessionControlPanel extends StatelessWidget {
  const _SessionControlPanel({
    required this.sessions,
    required this.canWrite,
    required this.deviceId,
  });

  final SessionController sessions;
  final bool canWrite;
  final String? deviceId;

  @override
  Widget build(BuildContext context) {
    final provider = sessions.selectedProviderCapabilities;
    final controls = sessions.controls;
    final plan = controls.plan;
    final goal = controls.goal;
    final skill = controls.skills.where((item) => item.risk == SkillRisk.high);
    final planBlocked = sessions.controlBlockedReason(
      'plan',
      canWrite: canWrite,
    );
    final goalBlocked = sessions.controlBlockedReason(
      'goal',
      canWrite: canWrite,
    );
    final skillBlocked = sessions.controlBlockedReason(
      'invoke_skill',
      canWrite: canWrite,
    );
    return Container(
      key: const Key('session-capability-panel'),
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.tune_outlined, size: 17),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  provider.kind,
                  key: const Key('session-capability-provider'),
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
              Text(
                controls.model ?? '等待模型事件',
                key: const Key('session-control-model'),
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelMedium,
              ),
              const SizedBox(width: 8),
              Text(
                controls.effort ?? '--',
                key: const Key('session-control-effort'),
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            key: const Key('session-capability-states'),
            spacing: 10,
            runSpacing: 5,
            children: [
              for (final name in const [
                'model_select',
                'effort_select',
                'plan',
                'goal',
                'invoke_skill',
                'attachments',
              ])
                _CapabilityStateLabel(entry: provider.capability(name)),
            ],
          ),
          const Divider(height: 17),
          _ControlSummaryRow(
            key: const Key('session-plan-summary'),
            icon: Icons.account_tree_outlined,
            title: plan?.title ?? 'Plan',
            subtitle: plan == null
                ? '等待已解密 Plan 事件'
                : '${plan.phase.label} · ${plan.summary}',
            action: IconButton(
              key: const Key('session-plan-approve-button'),
              tooltip: '确认 Plan',
              onPressed:
                  plan?.phase == PlanPhase.awaitingApproval &&
                      planBlocked == null &&
                      !sessions.isBusy
                  ? () => sessions.approvePlan(
                      deviceId: deviceId,
                      canWrite: canWrite,
                    )
                  : null,
              icon: const Icon(Icons.check_circle_outline),
            ),
          ),
          const SizedBox(height: 3),
          _ControlSummaryRow(
            key: const Key('session-goal-summary'),
            icon: Icons.flag_outlined,
            title: goal?.title ?? 'Goal',
            subtitle: goal == null
                ? '等待已解密 Goal 事件'
                : '${goal.phase.label} · ${goal.progressLabel}',
            action: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // v0.3/P0：goal 文本编辑（Happy AgentGoalBar 对齐）。
                IconButton(
                  key: const Key('session-goal-edit-button'),
                  tooltip: '编辑目标',
                  onPressed:
                      goal != null && goalBlocked == null && !sessions.isBusy
                      ? () => _showGoalEditDialog(
                          context,
                          sessions,
                          goal.title,
                          deviceId: deviceId,
                          canWrite: canWrite,
                        )
                      : null,
                  icon: const Icon(Icons.edit_outlined, size: 20),
                ),
                IconButton(
                  key: const Key('session-goal-toggle-button'),
                  tooltip: goal?.phase == GoalPhase.active
                      ? '暂停 Goal'
                      : '恢复 Goal',
                  onPressed:
                      goal != null &&
                          goal.phase != GoalPhase.completed &&
                          goalBlocked == null &&
                          !sessions.isBusy
                      ? () => sessions.toggleGoal(
                          deviceId: deviceId,
                          canWrite: canWrite,
                        )
                      : null,
                  icon: Icon(
                    goal?.phase == GoalPhase.active
                        ? Icons.pause_circle_outline
                        : Icons.play_circle_outline,
                  ),
                ),
              ],
            ),
          ),
          if (skill.isNotEmpty) ...[
            const SizedBox(height: 3),
            _ControlSummaryRow(
              key: const Key('session-skill-summary'),
              icon: Icons.security_outlined,
              title: skill.first.title,
              subtitle:
                  '${skill.first.risk.label} Skill · ${skill.first.summary}',
              action: IconButton(
                key: const Key('session-skill-open-button'),
                tooltip: '确认高风险 Skill',
                onPressed: skillBlocked == null && !sessions.isBusy
                    ? () => sessions.requestSkillConfirmation(
                        skill.first,
                        canWrite: canWrite,
                      )
                    : null,
                icon: const Icon(Icons.warning_amber_outlined),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// v0.3/P0：goal 编辑对话框入口。只提交目标文本，不读取、不展示密文正文。
Future<void> _showGoalEditDialog(
  BuildContext context,
  SessionController sessions,
  String currentTitle, {
  required String? deviceId,
  required bool canWrite,
}) async {
  final objective = await showDialog<Object>(
    context: context,
    builder: (dialogContext) => _GoalEditDialog(initialTitle: currentTitle),
  );
  if (objective is String && objective.isNotEmpty) {
    sessions.editGoal(
      objective: objective,
      deviceId: deviceId,
      canWrite: canWrite,
    );
  }
}

/// goal 编辑对话框：controller 生命周期由 State 管理，避免对话框退场动画期被 dispose。
class _GoalEditDialog extends StatefulWidget {
  const _GoalEditDialog({required this.initialTitle});

  final String initialTitle;

  @override
  State<_GoalEditDialog> createState() => _GoalEditDialogState();
}

class _GoalEditDialogState extends State<_GoalEditDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialTitle);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    key: const Key('goal-edit-dialog'),
    title: const Text('编辑目标'),
    content: TextField(
      key: const Key('goal-edit-input'),
      controller: _controller,
      maxLines: 3,
      decoration: const InputDecoration(
        labelText: '目标文本',
        border: OutlineInputBorder(),
      ),
    ),
    actions: [
      TextButton(
        key: const Key('goal-edit-cancel'),
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('取消'),
      ),
      FilledButton(
        key: const Key('goal-edit-submit'),
        onPressed: () {
          final value = _controller.text.trim();
          if (value.isEmpty) return;
          Navigator.of(context).pop(value);
        },
        child: const Text('保存'),
      ),
    ],
  );
}

class _CapabilityStateLabel extends StatelessWidget {
  const _CapabilityStateLabel({required this.entry});

  final CapabilityEntry entry;

  @override
  Widget build(BuildContext context) {
    final presentation = switch (entry.availability) {
      CapabilityAvailability.native => (
        Icons.check_circle_outline,
        context.appColors.success,
      ),
      CapabilityAvailability.emulated => (
        Icons.auto_awesome_outlined,
        context.appColors.warning,
      ),
      CapabilityAvailability.unsupported => (
        Icons.block_outlined,
        context.appColors.neutral,
      ),
    };
    return Semantics(
      label:
          '${entry.name} ${entry.availability.label}${entry.reason == null ? '' : '，${entry.reason}'}',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(presentation.$1, size: 13, color: presentation.$2),
          const SizedBox(width: 4),
          Text(
            '${entry.name} ${entry.availability.label}',
            style: Theme.of(
              context,
            ).textTheme.labelMedium?.copyWith(color: presentation.$2),
          ),
        ],
      ),
    );
  }
}

class _ControlSummaryRow extends StatelessWidget {
  const _ControlSummaryRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.action,
    super.key,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget action;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(icon, size: 17),
      const SizedBox(width: 8),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ],
        ),
      ),
      action,
    ],
  );
}

/// 确认卡是会话详情的一部分，而非 Provider 结果。拒绝只清空本地状态，确认才进入带 lease 的命令链路。
class _SkillConfirmationCard extends StatelessWidget {
  const _SkillConfirmationCard({
    required this.confirmation,
    required this.sessions,
    required this.canWrite,
    required this.deviceId,
  });

  final SkillConfirmation confirmation;
  final SessionController sessions;
  final bool canWrite;
  final String? deviceId;

  @override
  Widget build(BuildContext context) {
    final blocked = sessions.controlBlockedReason(
      'invoke_skill',
      canWrite: canWrite,
    );
    return Container(
      key: const Key('skill-confirmation-card'),
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        border: Border.all(color: context.appColors.warning),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              Icons.warning_amber_outlined,
              color: context.appColors.warning,
            ),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  confirmation.skill.title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 2),
                Text(
                  confirmation.skill.summary,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                if (blocked != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      blocked,
                      key: const Key('skill-confirmation-blocked-reason'),
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            key: const Key('skill-confirmation-reject-button'),
            tooltip: '拒绝 Skill',
            onPressed: sessions.isBusy
                ? null
                : sessions.rejectSkillConfirmation,
            icon: const Icon(Icons.close),
          ),
          IconButton(
            key: const Key('skill-confirmation-approve-button'),
            tooltip: '确认 Skill',
            onPressed: blocked == null && !sessions.isBusy
                ? () => sessions.confirmSkill(
                    deviceId: deviceId,
                    canWrite: canWrite,
                  )
                : null,
            icon: const Icon(Icons.check),
          ),
        ],
      ),
    );
  }
}

class _PermissionRequestItem extends StatelessWidget {
  const _PermissionRequestItem({
    required this.event,
    required this.canWrite,
    required this.hasLease,
    required this.sessions,
    required this.deviceId,
  });

  final SessionTimelineEvent event;
  final bool canWrite;
  final bool hasLease;
  final SessionController sessions;
  final String? deviceId;

  @override
  Widget build(BuildContext context) {
    final permission = event.permission;
    if (permission == null) return _SystemNotice(event: event);
    final resolved =
        permission.resolved == true ||
        sessions.isRequestResolved('permission', permission.requestId);
    final pending = sessions.isRequestPending(permission.requestId);
    final enabled = canWrite && hasLease && !resolved && !pending;
    return Container(
      key: Key('permission-card-${permission.requestId}'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.tertiaryContainer,
        border: Border.all(color: Theme.of(context).colorScheme.tertiary),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            key: Key('permission-waiting-strip-${permission.requestId}'),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.tertiary,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.circle,
                  size: 8,
                  color: Theme.of(context).colorScheme.onTertiary,
                ),
                const SizedBox(width: 8),
                Text(
                  '等待确认',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onTertiary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (pending) ...[
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Theme.of(context).colorScheme.onTertiary,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Icon(Icons.shield_outlined),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  permission.title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // v0.5/P4-D：理由和命令可能是模型生成的长文本；滚动区只包住正文，
          // 决策按钮留在外层，避免命令过长时 allow/reject 不可达。
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 140),
            child: SingleChildScrollView(
              key: Key('permission-command-scroll-${permission.requestId}'),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(permission.summary),
                  if (permission.command != null) ...[
                    const SizedBox(height: 8),
                    Container(
                      key: Key(
                        'permission-command-text-${permission.requestId}',
                      ),
                      width: double.infinity,
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surface,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: Theme.of(context).dividerColor,
                        ),
                      ),
                      child: Text(
                        permission.command!,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              IconButton(
                key: Key('permission-reject-${permission.requestId}'),
                tooltip: '拒绝',
                onPressed: enabled
                    ? () => sessions.resolvePermission(
                        requestId: permission.requestId,
                        approved: false,
                        deviceId: deviceId,
                        canWrite: canWrite,
                      )
                    : null,
                icon: const Icon(Icons.close),
              ),
              IconButton(
                key: Key('permission-approve-${permission.requestId}'),
                tooltip: '允许',
                onPressed: enabled
                    ? () => sessions.resolvePermission(
                        requestId: permission.requestId,
                        approved: true,
                        deviceId: deviceId,
                        canWrite: canWrite,
                      )
                    : null,
                icon: const Icon(Icons.check),
              ),
            ],
          ),
          if (resolved)
            Text(
              '已处理',
              key: Key('permission-resolved-${permission.requestId}'),
              style: Theme.of(context).textTheme.labelMedium,
            ),
        ],
      ),
    );
  }
}

class _QuestionRequestItem extends StatefulWidget {
  const _QuestionRequestItem({
    required this.event,
    required this.canWrite,
    required this.hasLease,
    required this.sessions,
    required this.deviceId,
  });

  final SessionTimelineEvent event;
  final bool canWrite;
  final bool hasLease;
  final SessionController sessions;
  final String? deviceId;

  @override
  State<_QuestionRequestItem> createState() => _QuestionRequestItemState();
}

class _QuestionRequestItemState extends State<_QuestionRequestItem> {
  final Map<String, TextEditingController> _customAnswerControllers = {};
  final Map<String, Set<String>> _selectedAnswers = {};
  final Set<String> _skippedStepIds = {};
  String? _activeRequestId;
  String? _validationError;
  String? _submissionError;
  bool _minimized = false;
  bool _locallyCancelled = false;
  int _questionIndex = 0;

  @override
  void initState() {
    super.initState();
    _activeRequestId = widget.event.question?.requestId;
  }

  @override
  void didUpdateWidget(covariant _QuestionRequestItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextRequestId = widget.event.question?.requestId;
    if (_activeRequestId == nextRequestId) return;
    // v0.5/P4-B/P4-E：同一 request replay 保留每题草稿；新的 request/key 必须重置本地状态。
    _activeRequestId = nextRequestId;
    _resetDraftState();
  }

  @override
  void dispose() {
    for (final controller in _customAnswerControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final question = widget.event.question;
    if (question == null) return _SystemNotice(event: widget.event);
    final steps = _stepsFor(question);
    final currentIndex = _questionIndex.clamp(0, steps.length - 1).toInt();
    final currentStep = steps[currentIndex];
    final stepKey = _stepKey(question, currentStep, currentIndex, steps.length);
    final controller = _controllerFor(currentStep.id);
    final selected = _selectedAnswers[currentStep.id] ?? const <String>{};
    final resolved =
        question.resolved == true ||
        widget.sessions.isRequestResolved('question', question.requestId);
    final pending = widget.sessions.isRequestPending(question.requestId);
    final enabled = widget.canWrite && widget.hasLease && !resolved && !pending;
    final answered = _answered(currentStep);
    if (_locallyCancelled && !resolved) {
      return Container(
        key: Key('question-card-${question.requestId}'),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          border: Border.all(color: Theme.of(context).dividerColor),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          key: Key('question-local-cancelled-${question.requestId}'),
          children: [
            const Icon(Icons.close),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '已在本机关闭此问题，未向 Host 发送取消命令。',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            TextButton(
              key: Key('question-cancel-restore-${question.requestId}'),
              onPressed: () => setState(() => _locallyCancelled = false),
              child: const Text('恢复'),
            ),
          ],
        ),
      );
    }
    if (_minimized) {
      return Container(
        key: Key('question-card-${question.requestId}'),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          border: Border.all(color: Theme.of(context).dividerColor),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          key: Key('question-minimized-${question.requestId}'),
          children: [
            const Icon(Icons.help_outline),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                currentStep.prompt,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            TextButton(
              key: Key('question-restore-${question.requestId}'),
              onPressed: () => setState(() => _minimized = false),
              child: const Text('展开'),
            ),
          ],
        ),
      );
    }
    return Container(
      key: Key('question-card-${question.requestId}'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.help_outline),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (steps.length > 1)
                      Text(
                        '${currentIndex + 1} / ${steps.length}',
                        key: Key('question-progress-${question.requestId}'),
                        style: Theme.of(context).textTheme.labelMedium,
                      ),
                    Text(
                      currentStep.prompt,
                      key: Key('question-prompt-$stepKey'),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ],
                ),
              ),
              IconButton(
                key: Key('question-minimize-${question.requestId}'),
                tooltip: '最小化问题',
                onPressed: () => setState(() => _minimized = true),
                icon: const Icon(Icons.expand_more),
              ),
              IconButton(
                key: Key('question-cancel-${question.requestId}'),
                tooltip: '本机关闭问题',
                onPressed: pending
                    ? null
                    // v0.5/P4-C：本地关闭只退出当前可见面板，不伪造 Relay/Host cancel。
                    : () => setState(() {
                        _locallyCancelled = true;
                        _validationError = null;
                        _submissionError = null;
                      }),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          if (currentStep.detail != null) ...[
            const SizedBox(height: 8),
            Text(currentStep.detail!),
          ],
          if (currentStep.options.isNotEmpty) ...[
            const SizedBox(height: 12),
            if (currentStep.multiSelect)
              Column(
                key: Key('question-options-$stepKey'),
                children: [
                  for (
                    var index = 0;
                    index < currentStep.options.length;
                    index += 1
                  )
                    Material(
                      type: MaterialType.transparency,
                      child: CheckboxListTile(
                        key: Key('question-option-$stepKey-$index'),
                        value: selected.contains(
                          currentStep.options[index].label,
                        ),
                        onChanged: enabled
                            ? (checked) => setState(() {
                                final next = {...selected};
                                if (checked == true) {
                                  next.add(currentStep.options[index].label);
                                } else {
                                  next.remove(currentStep.options[index].label);
                                }
                                _selectedAnswers[currentStep.id] = next;
                                _skippedStepIds.remove(currentStep.id);
                                _validationError = null;
                                _submissionError = null;
                              })
                            : null,
                        title: Text(
                          _displayOptionLabel(currentStep.options[index].label),
                        ),
                        subtitle: currentStep.options[index].description == null
                            ? null
                            : Text(currentStep.options[index].description!),
                        controlAffinity: ListTileControlAffinity.leading,
                      ),
                    ),
                ],
              )
            else
              DropdownButtonFormField<String>(
                key: Key('question-options-$stepKey'),
                initialValue: selected.isEmpty ? null : selected.first,
                decoration: const InputDecoration(labelText: '选择回答'),
                items: currentStep.options
                    .map(
                      (option) => DropdownMenuItem(
                        value: option.label,
                        child: Text(_displayOptionLabel(option.label)),
                      ),
                    )
                    .toList(growable: false),
                onChanged: enabled
                    ? (value) => setState(() {
                        _selectedAnswers[currentStep.id] = {?value};
                        _controllerFor(currentStep.id).clear();
                        _skippedStepIds.remove(currentStep.id);
                        _validationError = null;
                        _submissionError = null;
                      })
                    : null,
              ),
          ],
          if (currentStep.allowsFreeform || currentStep.options.isEmpty) ...[
            const SizedBox(height: 8),
            TextField(
              key: Key('question-freeform-$stepKey'),
              controller: controller,
              enabled: enabled,
              maxLines: currentStep.options.isEmpty ? 3 : 2,
              onChanged: (_) => setState(() {
                // v0.5/P4-E：单选 custom 替换已选项；多选 custom 可与已选项并存。
                if (!currentStep.multiSelect) {
                  _selectedAnswers[currentStep.id] = <String>{};
                }
                _skippedStepIds.remove(currentStep.id);
                _validationError = null;
                _submissionError = null;
              }),
              decoration: InputDecoration(
                labelText: currentStep.options.isEmpty ? '输入回答' : '或输入回答',
              ),
            ),
          ],
          if (_validationError != null) ...[
            const SizedBox(height: 6),
            Text(
              _validationError!,
              key: Key('question-validation-${question.requestId}'),
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ],
          if (_submissionError != null) ...[
            const SizedBox(height: 6),
            Text(
              _submissionError!,
              key: Key('question-submit-error-${question.requestId}'),
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ],
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerRight,
            child: Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (steps.length > 1)
                  TextButton(
                    key: Key('question-prev-${question.requestId}'),
                    onPressed: enabled && currentIndex > 0
                        ? () => setState(() {
                            _questionIndex = currentIndex - 1;
                            _validationError = null;
                            _submissionError = null;
                          })
                        : null,
                    child: const Text('上一题'),
                  ),
                TextButton(
                  key: Key('question-skip-${question.requestId}'),
                  onPressed: enabled
                      ? () => _skipCurrentStep(question, steps, currentIndex)
                      : null,
                  child: const Text('跳过'),
                ),
                TextButton(
                  key: Key('question-next-${question.requestId}'),
                  onPressed: enabled
                      ? () => _continueQuestion(
                          question,
                          steps,
                          currentIndex,
                          answered,
                        )
                      : null,
                  child: Text(currentIndex == steps.length - 1 ? '提交' : '下一题'),
                ),
                IconButton(
                  key: Key('question-submit-${question.requestId}'),
                  tooltip: '提交回答',
                  onPressed: enabled
                      ? () => _submitQuestionBatch(question, steps)
                      : null,
                  icon: pending
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.send),
                ),
              ],
            ),
          ),
          if (resolved)
            Text(
              '已回答',
              key: Key('question-resolved-${question.requestId}'),
              style: Theme.of(context).textTheme.labelMedium,
            ),
        ],
      ),
    );
  }

  Future<void> _continueQuestion(
    TimelineQuestionRequest question,
    List<TimelineQuestionStep> steps,
    int currentIndex,
    bool answered,
  ) async {
    final currentStep = steps[currentIndex];
    if (!answered && !_skippedStepIds.contains(currentStep.id)) {
      setState(() => _validationError = '请选择、输入或跳过当前问题。');
      return;
    }
    if (currentIndex < steps.length - 1) {
      setState(() {
        _questionIndex = currentIndex + 1;
        _validationError = null;
        _submissionError = null;
      });
      return;
    }
    await _submitQuestionBatch(question, steps);
  }

  Future<void> _skipCurrentStep(
    TimelineQuestionRequest question,
    List<TimelineQuestionStep> steps,
    int currentIndex,
  ) async {
    final currentStep = steps[currentIndex];
    setState(() {
      _selectedAnswers[currentStep.id] = <String>{};
      _controllerFor(currentStep.id).clear();
      _skippedStepIds.add(currentStep.id);
      _validationError = null;
      _submissionError = null;
    });
    if (steps.length == 1) {
      await _skipQuestion(question.requestId);
      return;
    }
    if (currentIndex < steps.length - 1) {
      setState(() => _questionIndex = currentIndex + 1);
      return;
    }
    await _submitQuestionBatch(question, steps);
  }

  Future<void> _submitQuestionBatch(
    TimelineQuestionRequest question,
    List<TimelineQuestionStep> steps,
  ) async {
    final missingIndex = steps.indexWhere(
      (step) => !_answered(step) && !_skippedStepIds.contains(step.id),
    );
    if (missingIndex >= 0) {
      setState(() {
        _questionIndex = missingIndex;
        _validationError = '请选择、输入或跳过当前问题。';
        _submissionError = null;
      });
      return;
    }
    setState(() {
      _validationError = null;
      _submissionError = null;
    });
    final accepted = await widget.sessions.answerQuestionBatch(
      requestId: question.requestId,
      answers: steps.map(_answerForStep).toList(growable: false),
      deviceId: widget.deviceId,
      canWrite: widget.canWrite,
    );
    if (!accepted && mounted && _activeRequestId == question.requestId) {
      setState(() {
        _submissionError = widget.sessions.errorMessage ?? '提交失败，请重试。';
      });
    }
  }

  Future<void> _skipQuestion(String requestId) async {
    setState(() {
      _validationError = null;
      _submissionError = null;
    });
    final accepted = await widget.sessions.skipQuestion(
      requestId: requestId,
      deviceId: widget.deviceId,
      canWrite: widget.canWrite,
    );
    if (!accepted && mounted && _activeRequestId == requestId) {
      setState(() {
        _submissionError = widget.sessions.errorMessage ?? '跳过失败，请重试。';
      });
    }
  }

  bool _answered(TimelineQuestionStep step) {
    final selected = _selectedAnswers[step.id] ?? const <String>{};
    return selected.isNotEmpty ||
        _controllerFor(step.id).text.trim().isNotEmpty;
  }

  Map<String, dynamic> _answerForStep(TimelineQuestionStep step) {
    final custom = _controllerFor(step.id).text.trim();
    return {
      'id': step.id,
      'selected': _skippedStepIds.contains(step.id)
          ? const <String>[]
          : (_selectedAnswers[step.id] ?? const <String>{}).toList(
              growable: false,
            ),
      if (custom.isNotEmpty && !_skippedStepIds.contains(step.id))
        'custom': custom,
    };
  }

  TextEditingController _controllerFor(String stepId) =>
      _customAnswerControllers.putIfAbsent(stepId, TextEditingController.new);

  List<TimelineQuestionStep> _stepsFor(TimelineQuestionRequest question) {
    if (question.steps.isNotEmpty) return question.steps;
    return [
      TimelineQuestionStep(
        id: question.requestId,
        prompt: question.prompt,
        options: question.options
            .map((label) => TimelineQuestionOption(label: label))
            .toList(growable: false),
        allowsFreeform: question.allowsFreeform,
      ),
    ];
  }

  String _stepKey(
    TimelineQuestionRequest question,
    TimelineQuestionStep step,
    int index,
    int count,
  ) => count == 1 ? question.requestId : '${question.requestId}-${step.id}';

  String _displayOptionLabel(String label) => label
      .replaceFirst(
        RegExp(
          r'\s*(\((recommended|推荐)\)|（(recommended|推荐)）)\s*$',
          caseSensitive: false,
        ),
        '',
      )
      .trim();

  void _resetDraftState() {
    for (final controller in _customAnswerControllers.values) {
      controller.dispose();
    }
    _customAnswerControllers.clear();
    _selectedAnswers.clear();
    _skippedStepIds.clear();
    _validationError = null;
    _submissionError = null;
    _minimized = false;
    _locallyCancelled = false;
    _questionIndex = 0;
  }
}

class _PlanReviewPanel extends StatefulWidget {
  const _PlanReviewPanel({
    required this.question,
    required this.sessions,
    required this.canWrite,
    required this.deviceId,
    required this.hasLease,
  });

  final TimelineQuestionRequest question;
  final SessionController sessions;
  final bool canWrite;
  final String? deviceId;
  final bool hasLease;

  @override
  State<_PlanReviewPanel> createState() => _PlanReviewPanelState();
}

/// v0.5/P4-F：PlanReview 专用接管面板，对照 DeepSeek Harness `PlanReviewPanel`。
///
/// 计划评审是"一个决策 + 一段 markdown plan"，不是被打分的选择题，因此采用
/// 带色条的审批卡形态：等待条 + 可滚动 plan + 右对齐动作区。三个动作是完整决策面：
/// approve / decline 用提问方给出的真实选项 label 回传；discuss 只本机关闭并恢复
/// 输入上下文（不伪造 Host cancel）。approve/decline 是一次性动作，失败时 re-arm。
class _PlanReviewPanelState extends State<_PlanReviewPanel> {
  String? _submissionError;
  bool _busy = false;
  bool _locallyDismissed = false;

  TimelineQuestionStep get _review {
    final steps = widget.question.steps;
    final first = steps.isNotEmpty ? steps.first : _fallbackStep();
    // 单题 plan-review：steps 只存单个意图 step。
    return first;
  }

  TimelineQuestionStep _fallbackStep() => TimelineQuestionStep(
    id: widget.question.requestId,
    prompt: widget.question.prompt,
    detail: null,
  );

  TimelineQuestionOption? get _approve {
    final label = _review.intentApproveLabel;
    if (label == null) return null;
    for (final option in _review.options) {
      if (option.label == label) return option;
    }
    return null;
  }

  TimelineQuestionOption? get _decline {
    final approveLabel = _review.intentApproveLabel;
    if (approveLabel == null) return null;
    for (final option in _review.options) {
      if (option.label != approveLabel) return option;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final question = widget.question;
    final resolved =
        question.resolved == true ||
        widget.sessions.isRequestResolved('question', question.requestId);
    final enabled = widget.canWrite && widget.hasLease && !resolved && !_busy;
    final plan = _review.detail;
    final approve = _approve;
    if (_locallyDismissed && !resolved) {
      return Container(
        key: Key('plan-review-card-${question.requestId}'),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          border: Border.all(color: Theme.of(context).dividerColor),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          key: Key('plan-review-dismissed-${question.requestId}'),
          children: [
            const Icon(Icons.chat_bubble_outline),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '已在本地关闭计划评审，可继续输入讨论。',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            TextButton(
              key: Key('plan-review-restore-${question.requestId}'),
              onPressed: () => setState(() => _locallyDismissed = false),
              child: const Text('恢复'),
            ),
          ],
        ),
      );
    }
    return Container(
      key: Key('plan-review-card-${question.requestId}'),
      margin: const EdgeInsets.fromLTRB(4, 4, 4, 0),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 等待/意图条：对齐 DeepSeek Harness 审批卡的 tinted strip。
          Container(
            key: Key('plan-review-strip-${question.requestId}'),
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(8),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.rule,
                  size: 16,
                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                ),
                const SizedBox(width: 8),
                Text(
                  '计划评审',
                  key: Key('plan-review-header-${question.requestId}'),
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
            child: Text(
              _review.prompt,
              key: Key('plan-review-question-${question.requestId}'),
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          // plan markdown 在卡内独立滚动（cap 120），按钮始终常驻可达。
          if (plan != null) ...[
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Container(
                key: Key('plan-review-scroll-${question.requestId}'),
                constraints: const BoxConstraints(maxHeight: 120),
                // 内部纵向滚动：长 plan 在卡内独立滚动，按钮始终常驻可达。
                child: SingleChildScrollView(
                  child: Text(
                    plan,
                    key: Key('plan-review-body-${question.requestId}'),
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 13,
                    ),
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(height: 8),
          if (_submissionError != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                _submissionError!,
                key: Key('plan-review-error-${question.requestId}'),
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ),
          // 动作区：discuss / decline(可选) / approve。按钮常驻可达。
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 10),
            child: Align(
              alignment: Alignment.centerRight,
              child: Wrap(
                spacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  TextButton(
                    key: Key('plan-review-discuss-${question.requestId}'),
                    onPressed: enabled
                        ? () => setState(() {
                            // 只本机关闭，不伪造 Host cancel；恢复后仍可继续输入。
                            _locallyDismissed = true;
                            _submissionError = null;
                          })
                        : null,
                    child: const Text('讨论'),
                  ),
                  if (_decline != null) ...[
                    const SizedBox(width: 4),
                    Tooltip(
                      message: _decline!.description ?? '',
                      child: TextButton(
                        key: Key('plan-review-decline-${question.requestId}'),
                        onPressed: enabled
                            ? () => _decide(_decline!.label)
                            : null,
                        child: Text('需要修改'),
                      ),
                    ),
                  ],
                  if (approve != null) ...[
                    const SizedBox(width: 4),
                    Tooltip(
                      message: approve.description ?? '',
                      child: FilledButton(
                        key: Key('plan-review-approve-${question.requestId}'),
                        onPressed: enabled
                            ? () => _decide(approve.label)
                            : null,
                        child: _busy
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text('批准执行'),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (resolved)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Text(
                '已评审',
                key: Key('plan-review-resolved-${question.requestId}'),
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _decide(String label) async {
    setState(() {
      _busy = true;
      _submissionError = null;
    });
    // approve/decline 都以提问方给出的真实选项 label 回传 answer，与 Harness 一致。
    final accepted = await widget.sessions.answerQuestionBatch(
      requestId: widget.question.requestId,
      answers: [
        {
          'id': _review.id,
          'selected': [label],
        },
      ],
      deviceId: widget.deviceId,
      canWrite: widget.canWrite,
    );
    if (!accepted && mounted) {
      setState(() {
        _busy = false;
        _submissionError = widget.sessions.errorMessage ?? '提交失败，请重试。';
      });
    }
  }
}

class _ComposerChain extends StatelessWidget {
  const _ComposerChain({
    required this.pendingQuestion,
    required this.pendingPermission,
    required this.canWrite,
    required this.hasLease,
    required this.sessions,
    required this.deviceId,
  });

  final SessionTimelineEvent? pendingQuestion;
  final SessionTimelineEvent? pendingPermission;
  final bool canWrite;
  final bool hasLease;
  final SessionController sessions;
  final String? deviceId;

  @override
  Widget build(BuildContext context) {
    // v0.5/P4-A/P4-F：composer chain 是 pending interaction 的唯一 carrier。
    // Question 优先于 approval；question 完成后，外层 projection 重算并 re-arm approval。
    // 普通 question 走 _QuestionRequestItem；plan-review 走专用卡片形态，避免把
    // "一个决策 + 一段 plan" 渲染成被打分的选择题（对照 Harness PlanReviewPanel）。
    final question = pendingQuestion;
    final permission = pendingPermission;
    final planReview = _planReviewStep(question);
    return Padding(
      key: const Key('session-composer-chain'),
      padding: const EdgeInsets.only(bottom: 8),
      child: question != null
          ? KeyedSubtree(
              key: const Key('session-question-panel'),
              child: planReview != null
                  ? _PlanReviewPanel(
                      question: question.question!,
                      sessions: sessions,
                      canWrite: canWrite,
                      deviceId: deviceId,
                      hasLease: hasLease,
                    )
                  : _QuestionRequestItem(
                      event: question,
                      canWrite: canWrite,
                      hasLease: hasLease,
                      sessions: sessions,
                      deviceId: deviceId,
                    ),
            )
          : KeyedSubtree(
              key: const Key('session-approval-panel'),
              child: _PermissionRequestItem(
                event: permission!,
                canWrite: canWrite,
                hasLease: hasLease,
                sessions: sessions,
                deviceId: deviceId,
              ),
            ),
    );
  }

  /// 从 pending question 事件提取 plan-review step；非 plan-review 返回 null。
  /// 对齐 DeepSeek Harness `planReviewOf()`：单题、带 detail、非多选、最多两个选项、
  /// 且必须存在意图指定 approve 选项，否则交给普通 question 流程。
  TimelineQuestionStep? _planReviewStep(SessionTimelineEvent? event) {
    final question = event?.question;
    if (question == null) return null;
    final steps = question.steps;
    if (steps.length != 1) return null;
    final step = steps.first;
    return step.isPlanReview ? step : null;
  }
}

class _SystemNotice extends StatelessWidget {
  const _SystemNotice({required this.event});

  final SessionTimelineEvent event;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Align(
      key: Key('timeline-notice-${event.sequence}'),
      alignment: Alignment.centerLeft,
      child: Text(
        event.text == null ? event.label : '${event.label} · ${event.text}',
        style: Theme.of(context).textTheme.bodyMedium,
      ),
    ),
  );
}

class _SessionComposer extends StatefulWidget {
  const _SessionComposer({
    required this.sessions,
    required this.canWrite,
    required this.deviceId,
    required this.interactionEvents,
    this.enterBehavior = ComposerEnterBehavior.queue,
    this.fileCompletionCatalog,
  });

  final SessionController sessions;
  final bool canWrite;
  final String? deviceId;
  final List<SessionTimelineEvent> interactionEvents;

  /// v0.5/P5：busy Enter 分流偏好（用户级设置，默认 Queue）。composer 与设置页
  /// 读取同一个 [composerPreferenceControllerProvider] 事实来源。
  final ComposerEnterBehavior enterBehavior;

  /// v0.2/P3：@ 补全的文件名目录；fixture 返回安全名，真实 Daemon RPC 未部署时为空（fail-closed）。
  final Future<List<String>> Function()? fileCompletionCatalog;

  @override
  State<_SessionComposer> createState() => _SessionComposerState();
}

/// 补全候选：type 区分文件与 Skill。
enum _CompletionKind { file, skill }

class _CompletionSuggestion {
  const _CompletionSuggestion({
    required this.kind,
    required this.label,
    required this.insertText,
  });

  final _CompletionKind kind;
  final String label;
  final String insertText;
}

class _SessionComposerState extends State<_SessionComposer> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  String? _draftSessionId;
  SessionComposerInputMachine _inputMachine = SessionComposerInputMachine();
  int _queueSeq = 0;
  bool _commandMenuOpen = false;
  // v0.2/P3：@ 与 / 自动补全只在内存生成；候选为空或查询越权时展示空态（fail-closed）。
  List<_CompletionSuggestion> _suggestions = const [];
  bool _suggestionsLoading = false;
  // 最近一次输入是否以 @ 或 / 触发补全；即使候选为空也展示空态说明（fail-closed）。
  bool _completionActive = false;
  // v0.5/P5：增量输入 revision；每次草稿变化 +1，供异步候选 CAS 判断是否过期。
  int _draftRev = 0;
  // 异步候选 generation：旧请求返回时若 generation 已变则 no-op，避免 stale pick 写入。
  int _suggestionsGeneration = 0;
  // 最近一次 selection-based 探测到的活跃 trigger（用于 span 替换与键盘导航）。
  InputTriggerHit? _activeTrigger;
  // 键盘导航中高亮的候选下标（-1 = 未选中）。
  int _selectedSuggestionIndex = -1;
  // 上次触发重新探测时的 caret 位置，用于 selection 变化去重。
  int? _lastCaret;

  /// v0.5/P5：把用户级 Enter 偏好映射为 InputMachine 的 busy enter 策略。
  BusyEnterMode get _enterBusyMode => switch (widget.enterBehavior) {
    ComposerEnterBehavior.queue => BusyEnterMode.queue,
    ComposerEnterBehavior.steer => BusyEnterMode.steer,
  };

  @override
  void initState() {
    super.initState();
    _focusNode.onKeyEvent = (_, event) => _handleComposerKey(event);
    // v0.5/P5：光标移动（selection 变化）也要按新位置重新探测 trigger，
    // 满足「候选按 selection + draft revision 定位」契约；借助 controller listener。
    _controller.addListener(_onControllerSelectionChanged);
    // 切换会话后恢复该会话的跨页内存草稿（不落明文盘）。
    _restoreDraft();
  }

  @override
  void didUpdateWidget(covariant _SessionComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessions.selectedSessionId !=
        widget.sessions.selectedSessionId) {
      // v0.5/P3-A：queue 是会话级 transient 输入状态；切会话时重建本地 machine，
      // 但不在 streaming 结束时隐式 flush，所有 queue 提交都必须来自显式用户动作。
      _inputMachine = SessionComposerInputMachine();
      _restoreDraft();
      _commandMenuOpen = false;
    }
  }

  void _restoreDraft() {
    final sessionId = widget.sessions.selectedSessionId;
    if (sessionId == null) {
      _draftSessionId = null;
      return;
    }
    if (_draftSessionId == sessionId) return;
    _draftSessionId = sessionId;
    final draft = widget.sessions.composerDraftFor(sessionId) ?? '';
    _inputMachine.setDraft(draft);
    if (draft != _controller.text) {
      _setControllerText(draft);
    }
  }

  void _setControllerText(String text) {
    _controller.text = text;
    // 光标移到末尾，让用户直接继续输入。
    _controller.selection = TextSelection.fromPosition(
      TextPosition(offset: _controller.text.length),
    );
  }

  @override
  void dispose() {
    // 页面销毁前把当前输入保存为内存草稿，保证跨页返回后内容不丢失。
    final sessionId = widget.sessions.selectedSessionId;
    if (sessionId != null) {
      widget.sessions.saveComposerDraft(sessionId, _controller.text);
    }
    _controller.removeListener(_onControllerSelectionChanged);
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  KeyEventResult _handleComposerKey(KeyEvent event) {
    final enter =
        event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter;

    // v0.5/P5：候选菜单键盘导航（up/down 移动、Escape 关闭、Enter 应用高亮项）。
    // 只在候选打开且 trigger 仍活跃时接管方向键/Escape/Enter；焦点保持在输入上下文。
    if (_completionActive &&
        _suggestions.isNotEmpty &&
        _activeTrigger != null) {
      if (event.logicalKey == LogicalKeyboardKey.arrowDown ||
          event.logicalKey == LogicalKeyboardKey.arrowUp) {
        if (event is KeyDownEvent) {
          final delta = event.logicalKey == LogicalKeyboardKey.arrowDown
              ? 1
              : -1;
          setState(() {
            _selectedSuggestionIndex += delta;
            if (_selectedSuggestionIndex >= _suggestions.length) {
              _selectedSuggestionIndex = 0;
            } else if (_selectedSuggestionIndex < 0) {
              _selectedSuggestionIndex = _suggestions.length - 1;
            }
          });
        }
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.escape) {
        if (event is KeyDownEvent) _updateSuggestions();
        return KeyEventResult.handled;
      }
      if (enter && event is KeyDownEvent) {
        // 高亮项存在时 Enter 应用候选；否则交回普通提交路径。
        if (_selectedSuggestionIndex >= 0 &&
            _selectedSuggestionIndex < _suggestions.length) {
          _applySuggestion(_suggestions[_selectedSuggestionIndex]);
          _selectedSuggestionIndex = -1;
          return KeyEventResult.handled;
        }
      }
    } else if (event.logicalKey == LogicalKeyboardKey.escape &&
        event is KeyDownEvent) {
      // 非候选场景：Escape 先关闭 command launcher 菜单，再交给输入状态机。
      if (_commandMenuOpen) {
        setState(() {
          _commandMenuOpen = false;
          _updateSuggestions();
        });
        return KeyEventResult.handled;
      }
    }

    if (!enter) return KeyEventResult.ignored;
    if (event is KeyUpEvent) return KeyEventResult.ignored;

    // Shift+Enter 永远留给 TextField 原生换行，优先级高于 IME 和提交锁。
    if (HardwareKeyboard.instance.isShiftPressed) {
      return KeyEventResult.ignored;
    }
    // 长按 Enter 的 repeat 事件只消费不提交，避免重复写入 Relay 或 queue。
    if (event is KeyRepeatEvent) {
      return KeyEventResult.handled;
    }
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    final composing = _controller.value.composing;
    // IME 候选确认期间 Enter 只能交给输入法，不触发会话提交。
    if (composing.isValid && !composing.isCollapsed) {
      return KeyEventResult.handled;
    }

    final snapshot = _inputMachine.snapshot;
    final machineBusy =
        snapshot.phase == SessionInputPhase.adjudicating ||
        snapshot.phase == SessionInputPhase.submitting;
    final blocked = widget.sessions.composerBlockedReason(
      canWrite: widget.canWrite,
    );
    if (blocked != null || widget.sessions.isBusy || machineBusy) {
      return KeyEventResult.handled;
    }

    final accelerated =
        HardwareKeyboard.instance.isMetaPressed ||
        HardwareKeyboard.instance.isControlPressed;
    final mode = _inputMachine.submit(
      running: widget.sessions.isStreaming,
      accelerated: accelerated,
      busyEnter: _enterBusyMode,
    );
    if (mode == null) return KeyEventResult.handled;

    unawaited(_submitComposer(accelerated: accelerated));
    return KeyEventResult.handled;
  }

  /// caret 移动监听：文本未变但 selection 变化时，也按新位置重新探测 trigger。
  /// 只在确实发生 selection 变化时才刷新，避免应用补全时的重复触发。
  void _onControllerSelectionChanged() {
    if (!mounted) return;
    final selection = _controller.selection;
    final caret = selection.isValid ? selection.end : null;
    if (caret == null || caret == _lastCaret) return;
    _lastCaret = caret;
    _updateSuggestions();
  }

  /// v0.5/P5：基于 caret（selection）+ draftRev 重新探测 Input Trigger。
  ///
  /// 由 TextField onChanged / 光标移动触发；不再按最后一个空格截 token。
  /// - 命中 trigger：`/` 走 skill 源，`@` 走文件目录源（异步 + CAS）；
  /// - 未命中或 caret 移出 token：静默关闭候选（outside dismiss）；
  /// - 源不可用 / 源被移除：静默移除对应候选组并刷新 lexicon，不展示伪错误项。
  void _updateSuggestions() {
    if (!mounted) return;
    final text = _controller.text;
    final selection = _controller.selection;
    final caret = selection.isValid ? selection.end : text.length;
    _draftRev += 1;
    final hit = detectInputTrigger(
      text,
      caret,
      claimed: _inputMachine.snapshot.claimToken != null,
    );
    _activeTrigger = hit;
    if (hit == null) {
      _completionActive = false;
      _suggestionsGeneration += 1;
      _setSuggestions(const []);
      _selectedSuggestionIndex = -1;
      setState(() => {});
      return;
    }
    _completionActive = true;
    _selectedSuggestionIndex = -1;
    if (hit.isSlash) {
      // Skill 建议：只使用 controls.skills 的标题，不读取任何参数或 Provider payload。
      final query = hit.query.toLowerCase();
      final skills = widget.sessions.controls.skills
          .where((skill) => skill.title.toLowerCase().contains(query))
          .map(
            (skill) => _CompletionSuggestion(
              kind: _CompletionKind.skill,
              label: 'Skill · ${skill.title}',
              insertText: '/${skill.title} ',
            ),
          )
          .toList(growable: false);
      _setSuggestions(skills);
      return;
    }
    // `@` 引用：越权路径（绝对路径、..、路径分隔、隐藏）不产生任何建议。
    final query = hit.query;
    if (!_isSafeSuggestionName(query)) {
      _setSuggestions(const []);
      return;
    }
    final catalog = widget.fileCompletionCatalog;
    if (catalog == null) {
      // 源未注册/被移除：静默关闭，不展示伪错误候选。
      _setSuggestions(const []);
      return;
    }
    _suggestionsGeneration += 1;
    final generation = _suggestionsGeneration;
    final rev = _draftRev;
    _suggestionsLoading = true;
    setState(() {});
    unawaited(_loadFileSuggestions(query, generation: generation, rev: rev));
  }

  /// 异步加载文件补全候选（目录不可用或越权查询时返回空）。
  ///
  /// 用 [generation] / [rev] CAS：过期请求（draft 已变或已切源）返回时 no-op，
  /// 避免 stale pick 写入新位置。
  Future<void> _loadFileSuggestions(
    String query, {
    required int generation,
    required int rev,
  }) async {
    List<String> names = const [];
    final catalog = widget.fileCompletionCatalog;
    if (catalog != null) {
      try {
        names = await catalog();
      } catch (_) {
        names = const [];
      }
    }
    if (!mounted) return;
    // CAS：只有仍是同一 generation 且 draftRev 未变迁时才允许落地候选。
    if (generation != _suggestionsGeneration || rev != _draftRev) return;
    final filtered = names
        .where(
          (name) =>
              name.toLowerCase().contains(query) && _isSafeSuggestionName(name),
        )
        .map(
          (name) => _CompletionSuggestion(
            kind: _CompletionKind.file,
            label: '文件 · $name',
            insertText: '@$name ',
          ),
        )
        .toList(growable: false);
    _suggestionsLoading = false;
    _setSuggestions(filtered);
  }

  /// 补全候选名安全校验：拒绝绝对路径、分隔符、隐藏与形如 `user@host` 的查询。
  bool _isSafeSuggestionName(String name) {
    if (name.trim().isEmpty || name.startsWith('/') || name.contains(':')) {
      return false;
    }
    if (name.contains('/') || name.contains('..')) return false;
    if (name.startsWith('.')) return false;
    return true;
  }

  void _setSuggestions(List<_CompletionSuggestion> next) {
    if (!mounted) return;
    setState(() => _suggestions = next);
  }

  /// 应用补全：只替换 [activeTrigger] 的 span，不做全文 token 重建。
  void _applySuggestion(_CompletionSuggestion suggestion) {
    final text = _controller.text;
    final hit = _activeTrigger;
    if (hit == null) {
      _updateSuggestions();
      return;
    }
    var replacement = suggestion.insertText;
    // 行内补全时若插入文本自带尾随空格、且目标位置后紧跟空白，去掉一个尾部空格，
    // 避免「@README.md + 原有空格」重复成两个空格（span 替换仍只动 trigger 段）。
    if (hit.end < text.length) {
      final after = text[hit.end];
      if (replacement.endsWith(' ') &&
          (after == ' ' || after == '\t' || after == '\n')) {
        replacement = replacement.substring(0, replacement.length - 1);
      }
    }
    final next = text.replaceRange(hit.start, hit.end, replacement);
    _inputMachine.setDraft(next);
    // 光标定位到插入内容末尾。
    _controller.text = next;
    _controller.selection = TextSelection.collapsed(
      offset: hit.start + replacement.length,
    );
    setState(() {});
    widget.sessions.saveComposerDraft(
      widget.sessions.selectedSessionId ?? '',
      next,
    );
    _updateSuggestions();
  }

  @override
  Widget build(BuildContext context) {
    final blocked = widget.sessions.composerBlockedReason(
      canWrite: widget.canWrite,
    );
    final streaming = widget.sessions.isStreaming;
    final input = _inputMachine.snapshot;
    final submitMode = _inputMachine.submit(
      running: streaming,
      busyEnter: _enterBusyMode,
    );
    final machineBusy =
        input.phase == SessionInputPhase.adjudicating ||
        input.phase == SessionInputPhase.submitting;
    final canSubmit =
        blocked == null &&
        submitMode != null &&
        !widget.sessions.isBusy &&
        !machineBusy;
    final primaryTooltip = switch (submitMode) {
      SessionSubmitMode.queue => '排队消息',
      SessionSubmitMode.steer => '插话',
      SessionSubmitMode.send || null => '发送消息',
    };
    final canStop = blocked == null && streaming && !widget.sessions.isBusy;
    final pendingPermission = widget.interactionEvents
        .where((event) => event.kind == SessionTimelineKind.permissionRequest)
        .cast<SessionTimelineEvent?>()
        .firstWhere(
          (event) =>
              event?.permission != null &&
              !widget.sessions.isRequestResolved(
                'permission',
                event!.permission!.requestId,
              ) &&
              !widget.sessions.isRequestPending(event.permission!.requestId),
          orElse: () => null,
        );
    final pendingQuestion = widget.interactionEvents
        .where((event) => event.kind == SessionTimelineKind.questionRequest)
        .cast<SessionTimelineEvent?>()
        .firstWhere(
          (event) =>
              event?.question != null &&
              !widget.sessions.isRequestResolved(
                'question',
                event!.question!.requestId,
              ) &&
              !widget.sessions.isRequestPending(event.question!.requestId),
          orElse: () => null,
        );
    // v0.5/P4/P5：Question/Approval 接管整个 composer seat；
    // input.dock（Todo/Goal/Queue）必须让位，避免长 takeover 面板被 dock 挤出可触达区域。
    final hasComposerTakeover =
        pendingQuestion != null || pendingPermission != null;
    return SafeArea(
      top: false,
      child: Container(
        key: const Key('session-composer'),
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
        decoration: BoxDecoration(
          color: Theme.of(context).scaffoldBackgroundColor,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.sessions.skillConfirmation != null)
              _SkillConfirmationCard(
                confirmation: widget.sessions.skillConfirmation!,
                sessions: widget.sessions,
                canWrite: widget.canWrite,
                deviceId: widget.deviceId,
              ),
            if (pendingQuestion != null || pendingPermission != null)
              _ComposerChain(
                pendingQuestion: pendingQuestion,
                pendingPermission: pendingPermission,
                canWrite: widget.canWrite,
                hasLease: widget.sessions.hasSelectedLease,
                sessions: widget.sessions,
                deviceId: widget.deviceId,
              ),
            if (!hasComposerTakeover)
              SessionTodoDock(todos: widget.sessions.controls.todos),
            if (!hasComposerTakeover)
              SessionGoalDock(
                goal: widget.sessions.controls.goal,
                blockedReason: widget.sessions.controlBlockedReason(
                  'goal',
                  canWrite: widget.canWrite,
                ),
                busy: widget.sessions.isBusy,
                onSave: (objective) async {
                  await widget.sessions.editGoal(
                    objective: objective,
                    deviceId: widget.deviceId,
                    canWrite: widget.canWrite,
                  );
                  return widget.sessions.errorMessage;
                },
                onToggle: () async {
                  await widget.sessions.toggleGoal(
                    deviceId: widget.deviceId,
                    canWrite: widget.canWrite,
                  );
                  return widget.sessions.errorMessage;
                },
                onClear: () async {
                  await widget.sessions.clearGoal(
                    deviceId: widget.deviceId,
                    canWrite: widget.canWrite,
                  );
                  return widget.sessions.errorMessage;
                },
              ),
            if (input.queue.isNotEmpty)
              SessionQueueDock(
                messages: input.queue,
                onRemove: (id) =>
                    setState(() => _inputMachine.removeQueuedMessage(id)),
                onEdit: (id, text) =>
                    setState(() => _inputMachine.editQueuedMessage(id, text)),
                onSteer: (id) => unawaited(_steerQueuedMessages(id)),
                onSendAll: _sendQueuedMessages,
                running: widget.sessions.isStreaming,
              ),
            if (_commandMenuOpen)
              _CommandLauncherMenu(
                onSelect: (command) {
                  final next = '/$command ';
                  _inputMachine.setDraft(next);
                  _setControllerText(next);
                  _commandMenuOpen = false;
                  final sessionId = widget.sessions.selectedSessionId;
                  if (sessionId != null) {
                    widget.sessions.saveComposerDraft(sessionId, next);
                  }
                  _updateSuggestions();
                  setState(() {});
                },
              ),
            if (widget.sessions.attachments.isNotEmpty ||
                widget.sessions.attachmentRejections.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _AttachmentQueue(
                  sessions: widget.sessions,
                  canWrite: widget.canWrite,
                  deviceId: widget.deviceId,
                ),
              ),
            if (_completionActive || _suggestionsLoading)
              _ComposerSuggestions(
                suggestions: _suggestions,
                loading: _suggestionsLoading,
                onApply: _applySuggestion,
                onDismiss: () => _setSuggestions(const []),
                selectedIndex: _selectedSuggestionIndex,
              ),
            if (blocked != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  blocked,
                  key: const Key('session-composer-blocked-reason'),
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ),
            if (input.notice != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  input.notice!,
                  key: const Key('session-composer-machine-notice'),
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
            Container(
              key: const Key('happy-session-composer'),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                border: Border.all(
                  color: Theme.of(context).dividerColor.withValues(alpha: 0.7),
                ),
                borderRadius: BorderRadius.circular(22),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x12000000),
                    blurRadius: 12,
                    offset: Offset(0, 3),
                  ),
                ],
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  IconButton(
                    key: const Key('session-command-launcher'),
                    tooltip: '命令',
                    onPressed: () =>
                        setState(() => _commandMenuOpen = !_commandMenuOpen),
                    icon: const Icon(Icons.add),
                  ),
                  IconButton(
                    key: const Key('session-attachment-add-button'),
                    tooltip:
                        widget.sessions.attachmentPickBlockedReason(
                          canWrite: widget.canWrite,
                        ) ??
                        '选择图片或文本附件',
                    // v0.2/P3：capability + 会话 DEK 均就绪后启用真实选附件；
                    // 无 DEK 时保持 fail-closed，不允许把明文文件或显示名放进 Relay。
                    onPressed:
                        widget.sessions.attachmentPickBlockedReason(
                                  canWrite: widget.canWrite,
                                ) ==
                                null &&
                            !widget.sessions.isBusy
                        ? () => widget.sessions.pickAttachment(
                            deviceId: widget.deviceId,
                            canWrite: widget.canWrite,
                          )
                        : null,
                    icon: const Icon(Icons.attach_file),
                  ),
                  Expanded(
                    child: TextField(
                      key: const Key('session-composer-input'),
                      controller: _controller,
                      focusNode: _focusNode,
                      enabled: blocked == null,
                      readOnly: machineBusy,
                      minLines: 1,
                      maxLines: 5,
                      textInputAction: TextInputAction.newline,
                      onChanged: (value) {
                        _inputMachine.setDraft(value);
                        setState(() {});
                        // 每次输入都写内存草稿；发送成功后由 controller 清除。
                        final sessionId = widget.sessions.selectedSessionId;
                        if (sessionId != null) {
                          widget.sessions.saveComposerDraft(sessionId, value);
                        }
                        _updateSuggestions();
                      },
                      decoration: const InputDecoration(
                        hintText: '输入消息...',
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                      ),
                    ),
                  ),
                  IconButton(
                    key: const Key('session-composer-primary-action'),
                    tooltip: primaryTooltip,
                    onPressed: canSubmit ? _submitComposer : null,
                    style: IconButton.styleFrom(
                      backgroundColor: canSubmit
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(
                              context,
                            ).colorScheme.surfaceContainerHighest,
                      foregroundColor: canSubmit
                          ? Theme.of(context).colorScheme.onPrimary
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    icon: Icon(
                      submitMode == SessionSubmitMode.send
                          ? Icons.arrow_upward
                          : Icons.schedule_send_outlined,
                    ),
                  ),
                  if (streaming)
                    IconButton(
                      key: const Key('session-stop-button'),
                      tooltip: '停止生成',
                      onPressed: canStop ? _stop : null,
                      icon: const Icon(Icons.stop_circle_outlined),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 5),
            _HappyComposerMetaRow(sessions: widget.sessions),
            const SizedBox(height: 5),
            // v0.5/P7：StatsLine / ContextMeter 只读投影，缺字段显示不可用。
            SessionStatsLine(
              stats: SessionStatsLineProjection.fromUsage(
                widget.sessions.controls.usage,
              ),
            ),
            SessionContextMeter(
              meter: SessionContextMeterProjection.fromUsage(
                widget.sessions.controls.usage,
              ),
            ),
            const SizedBox(height: 5),
            _ComposerControlStrip(
              sessions: widget.sessions,
              canWrite: widget.canWrite,
              deviceId: widget.deviceId,
            ),
          ],
        ),
      ),
    );
  }

  bool _isGoalCommand(String message) {
    final trimmed = message.trimLeft();
    return trimmed == '/goal' || trimmed.startsWith('/goal ');
  }

  /// P5-E3：`/goal ...` 是 command-input 创建链路，不能走普通消息发送。
  ///
  /// 成功后 fixture 会先追加 `goal.command_input`，投影为 Chat command node；
  /// 再追加 `goal.created` 并更新 input.dock。失败时保留原草稿与 claim。
  Future<void> _submitGoalCommand(String message, String? sessionId) async {
    final objective = message.trimLeft().substring('/goal'.length).trim();
    if (objective.isEmpty) {
      _inputMachine.settleSubmit(success: false, error: '请输入 /goal 后的目标文本。');
      _setControllerText(message);
      setState(() {});
      return;
    }
    await widget.sessions.createGoal(
      objective: objective,
      deviceId: widget.deviceId,
      canWrite: widget.canWrite,
    );
    if (!mounted) return;
    final error = widget.sessions.errorMessage;
    if (error != null) {
      _inputMachine.settleSubmit(success: false, error: error);
      if (sessionId != null) {
        widget.sessions.saveComposerDraft(sessionId, message);
      }
      _setControllerText(message);
      setState(() {});
      return;
    }
    _inputMachine.settleSubmit(success: true);
    if (sessionId != null) widget.sessions.clearComposerDraft(sessionId);
    _setControllerText('');
    _setSuggestions(const []);
    setState(() {});
  }

  Future<void> _submitComposer({bool accelerated = false}) async {
    final snapshot = _inputMachine.snapshot;
    if (snapshot.phase == SessionInputPhase.adjudicating ||
        snapshot.phase == SessionInputPhase.submitting) {
      return;
    }
    final message = snapshot.draft.trim();
    final mode = _inputMachine.submit(
      running: widget.sessions.isStreaming,
      accelerated: accelerated,
      busyEnter: _enterBusyMode,
    );
    if (mode == null || message.isEmpty && mode != SessionSubmitMode.steer) {
      return;
    }
    final sessionId = widget.sessions.selectedSessionId;
    switch (mode) {
      case SessionSubmitMode.queue:
        // v0.5/P3-A：Queue 是显式 transient inbox；入队后只清本地草稿，
        // 不向 Relay 发 send，也不在 streaming 结束后自动 flush。
        _queueSeq += 1;
        _inputMachine.addQueuedMessage('queue-$_queueSeq', message);
        _inputMachine.settleSubmit(success: true);
        if (sessionId != null) widget.sessions.clearComposerDraft(sessionId);
        _setControllerText('');
        _setSuggestions(const []);
        setState(() {});
      case SessionSubmitMode.send:
        // v0.5/P5-E5：已知 slash command 若带图片且没有 images 能力，
        // 整次提交在进入 submitting 前拒绝，保留 draft、引用和图片。
        final imageError = widget.sessions.commandImageAdmissionError(message);
        if (imageError != null) {
          _inputMachine.setNotice(imageError);
          if (sessionId != null) {
            widget.sessions.saveComposerDraft(sessionId, message);
          }
          setState(() {});
          return;
        }
        _inputMachine.enterSubmitting();
        setState(() {});
        if (_isGoalCommand(message)) {
          await _submitGoalCommand(message, sessionId);
          return;
        }
        await widget.sessions.sendMessage(
          message: message,
          deviceId: widget.deviceId,
          canWrite: widget.canWrite,
        );
        if (!mounted) return;
        final error = widget.sessions.errorMessage;
        if (error != null) {
          _inputMachine.settleSubmit(success: false, error: error);
          if (sessionId != null) {
            widget.sessions.saveComposerDraft(sessionId, message);
          }
          _setControllerText(message);
          setState(() {});
          return;
        }
        _inputMachine.settleSubmit(success: true);
        _setControllerText('');
        _setSuggestions(const []);
        setState(() {});
      case SessionSubmitMode.steer:
        // v0.5/P3-A 暂不伪造 Host strict-steer；真实 placement/steer action
        // 会在 QueueDock 阶段接入。当前只保留显式 queue 语义。
        if (message.isEmpty) return;
        _queueSeq += 1;
        _inputMachine.addQueuedMessage('queue-$_queueSeq', message);
        _inputMachine.settleSubmit(success: true);
        if (sessionId != null) widget.sessions.clearComposerDraft(sessionId);
        _setControllerText('');
        _setSuggestions(const []);
        setState(() {});
    }
  }

  Future<void> _stop() => widget.sessions.stopStreaming(
    deviceId: widget.deviceId,
    canWrite: widget.canWrite,
  );

  Future<void> _sendQueuedMessages() async {
    if (widget.sessions.isStreaming) return;
    final queued = List<QueuedComposerMessage>.from(
      _inputMachine.snapshot.queue,
    );
    if (queued.isEmpty) return;
    for (final item in queued) {
      if (widget.sessions.isStreaming) break;
      await widget.sessions.sendMessage(
        message: item.text,
        deviceId: widget.deviceId,
        canWrite: widget.canWrite,
      );
      if (!mounted) return;
      if (widget.sessions.errorMessage != null) break;
      setState(() => _inputMachine.removeQueuedMessage(item.id));
      if (widget.sessions.isStreaming) break;
    }
  }

  /// v0.5/P5：逐条 strict steer——只把指定排队项作为显式动作发送，
  /// 其余队列保留；发送成功才移除该项，失败保留并在 composer notice 呈现。
  Future<void> _steerQueuedMessages(String id) async {
    if (widget.sessions.isStreaming) return;
    final queued = List<QueuedComposerMessage>.from(
      _inputMachine.snapshot.queue,
    );
    final item = queued.where((entry) => entry.id == id).firstOrNull;
    if (item == null || !item.steerable) return;
    await widget.sessions.sendMessage(
      message: item.text,
      deviceId: widget.deviceId,
      canWrite: widget.canWrite,
    );
    if (!mounted) return;
    final error = widget.sessions.errorMessage;
    if (error != null) {
      setState(
        () => _inputMachine.setNotice(
          '只发送 '
          '$item.text'
          ' 失败：$error',
        ),
      );
      return;
    }
    setState(() => _inputMachine.removeQueuedMessage(item.id));
  }
}

class _CommandLauncherMenu extends StatelessWidget {
  const _CommandLauncherMenu({required this.onSelect});

  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    const commands = <(String, String)>[
      ('export', '导出当前会话日志'),
      ('feedback', '提交消息反馈'),
      ('goal', '查看或更新 Goal'),
      ('permission', '选择权限 preset'),
      ('model', '切换模型'),
    ];
    return Container(
      key: const Key('session-command-launcher-menu'),
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        children: [
          for (final command in commands)
            ListTile(
              dense: true,
              leading: const Icon(Icons.chevron_right, size: 18),
              title: Text('/${command.$1}'),
              subtitle: Text(command.$2),
              onTap: () => onSelect(command.$1),
            ),
        ],
      ),
    );
  }
}

/// v0.5/P5：danger-full-access 权限预设的风险确认对话框。
///
/// 未勾选确认前「提交」不可用；取消按钮、遮罩点击与 Escape 都不提交任何命令。
/// 确认后调用 [SessionController.selectPermissionMode] 提交真实 preset。
Future<void> _confirmDangerPermission(
  BuildContext context, {
  required SessionController sessions,
  required String? deviceId,
  required bool canWrite,
}) async {
  var confirmed = false;
  final action = await showDialog<bool>(
    context: context,
    barrierDismissible: true,
    builder: (dialogContext) {
      return StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          return AlertDialog(
            key: const Key('session-permission-risk-confirm'),
            title: const Text('确认授予完全访问权限'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '“danger-full-access” 将授予 Host 完全访问权限。请确认你了解风险后再提交。',
                ),
                const SizedBox(height: 8),
                CheckboxListTile(
                  key: const Key('session-permission-risk-checkbox'),
                  value: confirmed,
                  onChanged: (value) =>
                      setDialogState(() => confirmed = value ?? false),
                  title: const Text('我已了解并确认授予完全访问权限'),
                  controlAffinity: ListTileControlAffinity.leading,
                ),
              ],
            ),
            actions: [
              TextButton(
                key: const Key('session-permission-risk-cancel'),
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                key: const Key('session-permission-risk-submit'),
                onPressed: confirmed
                    ? () => Navigator.of(dialogContext).pop(true)
                    : null,
                child: const Text('确认提交'),
              ),
            ],
          );
        },
      );
    },
  );
  // 弹窗关闭后只对「确认并提交」走真实写命令；取消/遮罩/Escape 返回 null 或 false。
  if (action == true && context.mounted) {
    await sessions.selectPermissionMode(
      mode: 'danger-full-access',
      deviceId: deviceId,
      canWrite: canWrite,
    );
  }
}

/// v0.2/P3：composer 控制条：模型/effort 选择器与脱敏 usage 计数。
/// 所有入口按 capability fail-closed；无 capability 时禁用并展示中文原因。
class _ComposerControlStrip extends StatelessWidget {
  const _ComposerControlStrip({
    required this.sessions,
    required this.canWrite,
    required this.deviceId,
  });

  final SessionController sessions;
  final bool canWrite;
  final String? deviceId;

  @override
  Widget build(BuildContext context) {
    final controls = sessions.controls;
    final modelBlocked = sessions.controlBlockedReason(
      'model_select',
      canWrite: canWrite,
    );
    final effortBlocked = sessions.controlBlockedReason(
      'effort_select',
      canWrite: canWrite,
    );
    final permissionModeBlocked = sessions.controlBlockedReason(
      'permission_mode',
      canWrite: canWrite,
    );
    final usageSupported = sessions.selectedProviderCapabilities
        .capability('usage')
        .isSupported;
    // 四种能力都不可用时整条控制条隐藏，避免无意义的禁用控件占满输入区。
    final hasContent =
        controls.models.isNotEmpty ||
        controls.efforts.isNotEmpty ||
        controls.availablePermissionModes.isNotEmpty ||
        controls.usage != null ||
        usageSupported;
    if (!hasContent) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SessionModelSeat(
            key: const Key('composer-control-strip'),
            model: controls.model,
            effort: controls.effort,
            models: controls.models,
            efforts: controls.efforts,
            modelBlockedReason: modelBlocked,
            effortBlockedReason: effortBlocked,
            busy: sessions.isBusy,
            onRefresh: sessions.refreshSelectedControls,
            onSelectModel: (model) async {
              await sessions.selectModel(
                model: model,
                deviceId: deviceId,
                canWrite: canWrite,
              );
              return sessions.errorMessage;
            },
            onSelectEffort: (effort) async {
              await sessions.selectEffort(
                effort: effort,
                deviceId: deviceId,
                canWrite: canWrite,
              );
              return sessions.errorMessage;
            },
          ),
          const SizedBox(height: 6),
          Wrap(
            key: const Key('composer-control-strip-row2'),
            spacing: 8,
            runSpacing: 6,
            children: [
              SizedBox(
                width: 190,
                child: DropdownButtonFormField<String>(
                  key: const Key('composer-permission-mode-select'),
                  initialValue: controls.permissionMode,
                  isDense: true,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: '权限',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                  ),
                  items: [
                    for (final mode in controls.availablePermissionModes)
                      DropdownMenuItem(value: mode, child: Text(mode)),
                  ],
                  onChanged:
                      permissionModeBlocked == null &&
                          controls.availablePermissionModes.isNotEmpty
                      ? (value) {
                          if (value == null) return;
                          // v0.5/P5：danger-full-access 必须先弹风险确认，
                          // 勾选确认前不可提交；取消/遮罩/Escape 不提交；
                          // custom 预设不作为可点菜单项渲染（不在 available 列表）。
                          if (value == 'danger-full-access') {
                            _confirmDangerPermission(
                              context,
                              sessions: sessions,
                              deviceId: deviceId,
                              canWrite: canWrite,
                            );
                            return;
                          }
                          sessions.selectPermissionMode(
                            mode: value,
                            deviceId: deviceId,
                            canWrite: canWrite,
                          );
                        }
                      : null,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// v0.2/P3：@ / 自动补全面板。候选为空时展示空态说明（fail-closed）。
/// v0.5/P5：候选高度锚定在 composer 上方（max-height），支持键盘高亮下标。
class _ComposerSuggestions extends StatelessWidget {
  const _ComposerSuggestions({
    required this.suggestions,
    required this.loading,
    required this.onApply,
    required this.onDismiss,
    this.selectedIndex = -1,
  });

  final List<_CompletionSuggestion> suggestions;
  final bool loading;
  final void Function(_CompletionSuggestion suggestion) onApply;
  final VoidCallback onDismiss;
  final int selectedIndex;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 240),
      child: Container(
        key: const Key('composer-suggestions'),
        margin: const EdgeInsets.only(bottom: 6),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHigh,
          border: Border.all(color: theme.dividerColor),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (loading)
              const Padding(
                padding: EdgeInsets.all(8),
                child: Row(
                  children: [
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: 8),
                    Text('正在加载建议…'),
                  ],
                ),
              )
            else if (suggestions.isEmpty)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  '没有可用的补全建议（目录不可用或查询越权）。',
                  key: const Key('composer-suggestions-empty'),
                  style: theme.textTheme.labelSmall,
                ),
              )
            else
              Expanded(
                child: ListView(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  children: [
                    for (var index = 0; index < suggestions.length; index += 1)
                      Material(
                        color: index == selectedIndex
                            ? theme.colorScheme.primaryContainer.withValues(
                                alpha: 0.4,
                              )
                            : Colors.transparent,
                        child: ListTile(
                          key: Key(
                            'completion-suggestion-${suggestions[index].label}',
                          ),
                          dense: true,
                          selected: index == selectedIndex,
                          leading: Icon(
                            suggestions[index].kind == _CompletionKind.skill
                                ? Icons.bolt_outlined
                                : Icons.description_outlined,
                            size: 18,
                          ),
                          title: Text(suggestions[index].label),
                          onTap: () => onApply(suggestions[index]),
                        ),
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

/// 附件队列只绘制内存中的 localName 和最小进度；密文、元数据和原始文件不会被放入 Widget 文本或日志。
class _AttachmentQueue extends StatelessWidget {
  const _AttachmentQueue({
    required this.sessions,
    required this.canWrite,
    required this.deviceId,
  });

  final SessionController sessions;
  final bool canWrite;
  final String? deviceId;

  @override
  Widget build(BuildContext context) {
    final blocked = sessions.controlBlockedReason(
      'attachments',
      canWrite: canWrite,
    );
    return Semantics(
      label: '附件上传队列',
      child: Wrap(
        key: const Key('session-attachment-queue'),
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final transfer in sessions.attachments)
            _AttachmentChip(
              transfer: transfer,
              pending: sessions.isAttachmentPending(transfer.draft.id),
              uploadEnabled: blocked == null,
              onUpload: () => sessions.uploadAttachment(
                attachmentId: transfer.draft.id,
                deviceId: deviceId,
                canWrite: canWrite,
              ),
              onRemove: () => sessions.removeAttachment(transfer.draft.id),
            ),
          for (final rejection in sessions.attachmentRejections)
            _AttachmentRejectedChip(
              rejection: rejection,
              onDismiss: () =>
                  sessions.dismissAttachmentRejection(rejection.localName),
            ),
        ],
      ),
    );
  }
}

class _AttachmentChip extends StatelessWidget {
  const _AttachmentChip({
    required this.transfer,
    required this.pending,
    required this.uploadEnabled,
    required this.onUpload,
    required this.onRemove,
  });

  final AttachmentTransfer transfer;
  final bool pending;
  final bool uploadEnabled;
  final VoidCallback onUpload;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final presentation = switch (transfer.phase) {
      AttachmentTransferPhase.queued => ('待上传', Icons.schedule_outlined),
      AttachmentTransferPhase.uploading => ('上传中', Icons.cloud_upload_outlined),
      AttachmentTransferPhase.failed => ('需重试', Icons.error_outline),
      AttachmentTransferPhase.completed => ('已完成', Icons.check_circle_outline),
    };
    final canUpload =
        uploadEnabled &&
        !pending &&
        transfer.phase != AttachmentTransferPhase.completed;
    return Container(
      key: Key('attachment-chip-${transfer.draft.id}'),
      constraints: const BoxConstraints(minWidth: 172, maxWidth: 218),
      padding: const EdgeInsets.fromLTRB(8, 5, 2, 5),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(
            transfer.draft.isImage
                ? Icons.image_outlined
                : Icons.article_outlined,
            size: 18,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  transfer.draft.localName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                Text(
                  '${presentation.$1} · ${transfer.completedChunks}/${transfer.draft.totalChunks}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelMedium,
                ),
                if (transfer.phase == AttachmentTransferPhase.uploading)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: LinearProgressIndicator(value: transfer.progress),
                  ),
                if (transfer.errorMessage != null)
                  Text(
                    transfer.errorMessage!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            key: Key('attachment-upload-${transfer.draft.id}'),
            tooltip: transfer.phase == AttachmentTransferPhase.failed
                ? '重试附件上传'
                : '上传附件',
            onPressed: canUpload ? onUpload : null,
            icon: pending
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(
                    transfer.phase == AttachmentTransferPhase.failed
                        ? Icons.refresh
                        : presentation.$2,
                    size: 18,
                  ),
          ),
          IconButton(
            key: Key('attachment-remove-${transfer.draft.id}'),
            tooltip: '移除附件',
            onPressed: pending ? null : onRemove,
            icon: const Icon(Icons.close, size: 18),
          ),
        ],
      ),
    );
  }
}

class _AttachmentRejectedChip extends StatelessWidget {
  const _AttachmentRejectedChip({
    required this.rejection,
    required this.onDismiss,
  });

  final AttachmentRejection rejection;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) => Container(
    key: Key('attachment-rejected-${rejection.localName}'),
    constraints: const BoxConstraints(minWidth: 172, maxWidth: 228),
    padding: const EdgeInsets.fromLTRB(8, 5, 2, 5),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.errorContainer,
      border: Border.all(color: Theme.of(context).colorScheme.error),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Row(
      children: [
        const Icon(Icons.block_outlined, size: 18),
        const SizedBox(width: 6),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                rejection.localName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelLarge,
              ),
              Text(
                rejection.reason,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ],
          ),
        ),
        IconButton(
          tooltip: '关闭附件拒绝提示',
          onPressed: onDismiss,
          icon: const Icon(Icons.close, size: 18),
        ),
      ],
    ),
  );
}

class _SecurityControls extends StatelessWidget {
  const _SecurityControls({required this.app});

  final AppController app;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const _SectionLabel('控制端'),
      Container(
        key: const Key('mobile-control-status'),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          border: Border.all(color: Theme.of(context).dividerColor),
          borderRadius: BorderRadius.circular(8),
        ),
        child: app.requiresRecovery
            ? const ListTile(
                key: Key('identity-recovery-required-state'),
                leading: Icon(Icons.key_off_outlined),
                title: Text('需要恢复本机身份'),
              )
            : app.needsOwnerBootstrap
            ? ListTile(
                leading: const Icon(Icons.admin_panel_settings_outlined),
                title: const Text('完成此设备的 owner 安全初始化'),
                subtitle: const Text('Relay 已建立 owner 绑定，等待写入此设备公钥。'),
                trailing: IconButton(
                  key: const Key('owner-bootstrap-button'),
                  tooltip: '建立 owner',
                  onPressed: app.isBusy ? null : app.bootstrapOwner,
                  icon: const Icon(Icons.verified_user_outlined),
                ),
              )
            : app.canManageDevices
            ? const ListTile(
                key: Key('owner-ready-state'),
                leading: Icon(Icons.verified_user_outlined),
                title: Text('Owner 设备已连接'),
                subtitle: Text('此 Android 可获取会话控制权。'),
              )
            : app.hasOwner
            ? const ListTile(
                key: Key('readonly-auth-state'),
                leading: Icon(Icons.lock_outline),
                title: Text('当前设备没有 Android 写权限'),
                subtitle: Text('使用恢复码接管此设备。'),
              )
            : const ListTile(
                key: Key('unprovisioned-auth-state'),
                leading: Icon(Icons.info_outline),
                title: Text('尚未连接 Android owner'),
                subtitle: Text('初始化此设备或使用恢复码接管。'),
              ),
      ),
      const SizedBox(height: 4),
      ListTile(
        key: const Key('recovery-code-page-link'),
        enabled: app.canManageDevices && !app.isBusy,
        leading: const Icon(Icons.password_outlined),
        title: const Text('恢复码'),
        trailing: const Icon(Icons.chevron_right),
        onTap: app.canManageDevices && !app.isBusy
            ? () => context.go('/recovery-code')
            : null,
      ),
      const Divider(height: 1),
      ListTile(
        key: const Key('pairing-page-link'),
        enabled: app.canManageDevices && !app.isBusy,
        leading: const Icon(Icons.qr_code_scanner),
        title: const Text('二维码配对'),
        trailing: const Icon(Icons.chevron_right),
        onTap: app.canManageDevices && !app.isBusy
            ? () => context.go('/pairing')
            : null,
      ),
      const Divider(height: 1),
      ListTile(
        key: const Key('devices-page-link'),
        enabled: app.canManageDevices && !app.isBusy,
        leading: const Icon(Icons.devices_other_outlined),
        title: const Text('设备管理'),
        trailing: Text('${app.devices.length}'),
        onTap: app.canManageDevices && !app.isBusy
            ? () => context.go('/devices')
            : null,
      ),
      const Divider(height: 1),
      ListTile(
        key: const Key('terminal-status-page-link'),
        enabled: !app.isBusy,
        leading: const Icon(Icons.terminal_outlined),
        title: const Text('终端状态'),
        subtitle: const Text('查看已确认终端的在线状态与版本'),
        trailing: const Icon(Icons.chevron_right),
        onTap: app.isBusy ? null : () => context.go('/terminals'),
      ),
      if (app.requiresRecovery) ...[
        const Divider(height: 1),
        ListTile(
          key: const Key('identity-recovery-page-link'),
          leading: const Icon(Icons.restore_outlined),
          title: const Text('使用恢复码'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.go('/recovery'),
        ),
      ],
    ],
  );
}

class _SessionListItem extends StatelessWidget {
  const _SessionListItem({
    required this.session,
    required this.selected,
    required this.onTap,
  });

  final MobileSession session;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final status = _sessionStatusPresentation(session.status);
    final statusColor = _sessionStatusColor(context, status.tone);
    return Container(
      key: Key('session-row-${session.id}'),
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: selected
            ? Theme.of(context).colorScheme.surfaceContainerHighest
            : Theme.of(context).colorScheme.surfaceContainer,
        border: Border.all(
          color: selected
              ? Theme.of(context).colorScheme.secondary
              : Theme.of(context).dividerColor,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(status.icon, color: statusColor),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            session.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _relativeTime(session.updatedAt),
                          style: Theme.of(context).textTheme.labelMedium,
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      session.workspaceLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Container(
                          key: Key('session-status-dot-${session.id}'),
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            color: statusColor,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          status.label,
                          style: Theme.of(
                            context,
                          ).textTheme.labelMedium?.copyWith(color: statusColor),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SessionEmptyState extends StatelessWidget {
  const _SessionEmptyState({required this.canWrite});

  final bool canWrite;

  @override
  Widget build(BuildContext context) => Container(
    key: const Key('session-empty-state'),
    padding: const EdgeInsets.symmetric(vertical: 44, horizontal: 28),
    child: Column(
      children: [
        Icon(
          Icons.forum_outlined,
          size: 42,
          color: Theme.of(context).colorScheme.secondary,
        ),
        const SizedBox(height: 16),
        Text('还没有会话', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 6),
        Text(
          canWrite ? '通过右上角的新建图标开始一个会话。' : '恢复 Android owner 后可创建会话。',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ],
    ),
  );
}

class _ReadOnlyBanner extends StatelessWidget {
  const _ReadOnlyBanner();

  @override
  Widget build(BuildContext context) => Container(
    key: const Key('session-readonly-banner'),
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      border: Border.all(color: Theme.of(context).dividerColor),
      borderRadius: BorderRadius.circular(8),
    ),
    child: const Row(
      children: [
        Icon(Icons.visibility_outlined, size: 18),
        SizedBox(width: 8),
        Expanded(child: Text('当前设备为只读状态，仍可查看会话。')),
      ],
    ),
  );
}

class _SessionStatusStrip extends StatelessWidget {
  const _SessionStatusStrip({
    required this.session,
    required this.hasLease,
    required this.canWrite,
    required this.provider,
    required this.onAcquireLease,
  });

  final MobileSession? session;
  final bool hasLease;
  final bool canWrite;

  /// v0.3/P1：Provider 能力快照（version/available/reason 白名单），用于连接态与版本提示。
  final ProviderCapabilityProfile provider;
  final VoidCallback? onAcquireLease;

  @override
  Widget build(BuildContext context) {
    final status = _sessionStatusPresentation(session?.status);
    final statusColor = _sessionStatusColor(context, status.tone);
    final leaseText = !canWrite
        ? '只读'
        : hasLease
        ? '已获得控制权'
        : '未获取控制权';
    // v0.3/P1：Provider 连接态与版本只来自 capability 白名单；探测失败时展示 fail-closed 原因。
    final providerConnected = provider.available;
    final providerVersion = provider.version.trim();
    final providerReason = provider.capabilities
        .where((entry) => entry.name == 'start')
        .map((entry) => entry.reason)
        .whereType<String>()
        .firstOrNull;
    final providerLabel = !providerConnected
        ? '未连接'
        : providerVersion.isNotEmpty
        ? '已连接 · v$providerVersion'
        : '已连接';
    final providerTooltip = !providerConnected
        ? (providerReason ?? 'Provider 当前不可用。')
        : 'Provider 版本仅来自探测结果。';
    return Container(
      key: const Key('session-status-strip'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: statusColor,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              status.label,
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ),
          Tooltip(
            message: providerTooltip,
            child: Container(
              key: const Key('session-provider-version-chip'),
              margin: const EdgeInsets.only(right: 8),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: providerConnected
                    ? Theme.of(context).colorScheme.surfaceContainerHighest
                    : Theme.of(context).colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                providerLabel,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: providerConnected
                      ? null
                      : Theme.of(context).colorScheme.error,
                ),
              ),
            ),
          ),
          Text(leaseText, style: Theme.of(context).textTheme.labelMedium),
          IconButton(
            key: const Key('session-acquire-lease-button'),
            tooltip: leaseText,
            visualDensity: VisualDensity.compact,
            onPressed: canWrite && !hasLease ? onAcquireLease : null,
            icon: Icon(
              hasLease ? Icons.lock_open_outlined : Icons.lock_outline,
              size: 18,
            ),
          ),
        ],
      ),
    );
  }
}

/// 生命周期恢复状态只展示脱敏计数和连接阶段；不把通知正文、密文或 Relay 错误原文画入界面。
class _SessionRecoveryStrip extends StatelessWidget {
  const _SessionRecoveryStrip({
    required this.controller,
    required this.sessionId,
  });

  final SessionRecoveryController controller;
  final String sessionId;

  @override
  Widget build(BuildContext context) {
    final notice = controller.latestNotice;
    final isCurrentNotice = notice?.sessionId == sessionId;
    final shouldShow =
        controller.phase != SessionRecoveryPhase.idle || isCurrentNotice;
    if (!shouldShow) return const SizedBox.shrink();
    final presentation = _recoveryPresentation(controller.phase, context);
    return Container(
      key: const Key('session-recovery-banner'),
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
      decoration: BoxDecoration(
        color: presentation.color.withValues(alpha: 0.1),
        border: Border.all(color: presentation.color.withValues(alpha: 0.45)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(presentation.icon, size: 18, color: presentation.color),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  presentation.label,
                  style: Theme.of(
                    context,
                  ).textTheme.labelLarge?.copyWith(color: presentation.color),
                ),
                if (controller.message != null)
                  Text(
                    controller.message!,
                    key: const Key('session-recovery-message'),
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                if (isCurrentNotice)
                  Text(
                    '应用内通知：本会话新增 ${notice!.eventCount} 条事件',
                    key: const Key('session-recovery-notice'),
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
              ],
            ),
          ),
          if (controller.phase == SessionRecoveryPhase.unavailable)
            IconButton(
              key: const Key('session-recovery-retry'),
              tooltip: '重试恢复',
              onPressed: controller.isRecovering
                  ? null
                  : () => controller.retryRecovery(),
              icon: const Icon(Icons.refresh, size: 18),
            ),
          if (isCurrentNotice)
            IconButton(
              key: const Key('session-recovery-notice-dismiss'),
              tooltip: '关闭通知',
              onPressed: () => controller.dismissNotice(notice!.id),
              icon: const Icon(Icons.close, size: 18),
            ),
        ],
      ),
    );
  }
}

class _RecoveryPresentation {
  const _RecoveryPresentation({
    required this.label,
    required this.icon,
    required this.color,
  });

  final String label;
  final IconData icon;
  final Color color;
}

_RecoveryPresentation _recoveryPresentation(
  SessionRecoveryPhase phase,
  BuildContext context,
) => switch (phase) {
  SessionRecoveryPhase.paused => _RecoveryPresentation(
    label: '后台暂停',
    icon: Icons.pause_circle_outline,
    color: context.appColors.warning,
  ),
  SessionRecoveryPhase.waitingForNetwork => _RecoveryPresentation(
    label: '等待网络',
    icon: Icons.cloud_off_outlined,
    color: context.appColors.warning,
  ),
  SessionRecoveryPhase.recovering => _RecoveryPresentation(
    label: '正在恢复',
    icon: Icons.sync,
    color: Theme.of(context).colorScheme.secondary,
  ),
  SessionRecoveryPhase.recovered => _RecoveryPresentation(
    label: '恢复完成',
    icon: Icons.cloud_done_outlined,
    color: context.appColors.success,
  ),
  SessionRecoveryPhase.unavailable => _RecoveryPresentation(
    label: '恢复未完成',
    icon: Icons.error_outline,
    color: Theme.of(context).colorScheme.error,
  ),
  SessionRecoveryPhase.idle => _RecoveryPresentation(
    label: '恢复状态',
    icon: Icons.sync_disabled_outlined,
    color: Theme.of(context).colorScheme.onSurfaceVariant,
  ),
};

class _InlineError extends StatelessWidget {
  const _InlineError({required this.message, required this.onRetry, super.key});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.errorContainer,
      border: Border.all(color: Theme.of(context).colorScheme.error),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Row(
      children: [
        const Icon(Icons.error_outline),
        const SizedBox(width: 8),
        Expanded(child: Text(message)),
        IconButton(
          tooltip: '关闭提示',
          onPressed: onRetry,
          icon: const Icon(Icons.close),
        ),
      ],
    ),
  );
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 10, bottom: 6),
    child: Text(text, style: Theme.of(context).textTheme.labelMedium),
  );
}

class _ProjectGroupHeader extends StatelessWidget {
  const _ProjectGroupHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 6, bottom: 6),
    child: Text(title, style: Theme.of(context).textTheme.labelLarge),
  );
}

class _SessionHeaderTitle extends StatelessWidget {
  const _SessionHeaderTitle({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) => Semantics(
    label: title,
    child: Row(
      key: const Key('mobile-header-title'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        const SizedBox(width: 8),
        Container(
          key: const Key('mobile-header-status'),
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            color: context.appColors.success,
            shape: BoxShape.circle,
          ),
        ),
      ],
    ),
  );
}

/// Happy 的会话标题：标题和项目名分两行居中，避免把项目名挤进操作按钮。
class _HappySessionHeaderTitle extends StatelessWidget {
  const _HappySessionHeaderTitle({required this.session});

  final MobileSession? session;

  @override
  Widget build(BuildContext context) => Column(
    key: const Key('happy-session-header'),
    mainAxisAlignment: MainAxisAlignment.center,
    crossAxisAlignment: CrossAxisAlignment.center,
    children: [
      Text(
        '新对话',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(
          context,
        ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
      ),
      Text(
        session?.projectName?.trim().isNotEmpty == true
            ? session!.projectName!.trim()
            : 'agent-sessions',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    ],
  );
}

class _HappyProviderAvatar extends StatelessWidget {
  const _HappyProviderAvatar({required this.provider});

  final String? provider;

  @override
  Widget build(BuildContext context) {
    final normalized = provider?.toLowerCase() ?? '';
    final icon = switch (normalized) {
      'codex' => Icons.auto_awesome,
      'claude' => Icons.psychology_outlined,
      'opencode' => Icons.terminal_outlined,
      _ => Icons.smart_toy_outlined,
    };
    return Container(
      key: const Key('happy-session-provider-avatar'),
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.secondaryContainer,
        shape: BoxShape.circle,
      ),
      child: Icon(
        icon,
        size: 18,
        color: Theme.of(context).colorScheme.onSecondaryContainer,
      ),
    );
  }
}

class _HappyComposerMetaRow extends StatelessWidget {
  const _HappyComposerMetaRow({required this.sessions});

  final SessionController sessions;

  @override
  Widget build(BuildContext context) {
    final controls = sessions.controls;
    final model =
        controls.model ?? sessions.selectedSession?.provider ?? 'gpt-5.5';
    final effort = controls.effort ?? 'Medium';
    return Row(
      key: const Key('happy-session-model-row'),
      children: [
        Icon(
          Icons.account_tree_outlined,
          size: 14,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 4),
        Text('main', style: Theme.of(context).textTheme.labelSmall),
        const Spacer(),
        Text(model, style: Theme.of(context).textTheme.labelSmall),
        const SizedBox(width: 12),
        Text(effort, style: Theme.of(context).textTheme.labelSmall),
      ],
    );
  }
}

class _SessionStatusPresentation {
  const _SessionStatusPresentation({
    required this.label,
    required this.tone,
    required this.icon,
  });

  final String label;
  final _SessionStatusTone tone;
  final IconData icon;
}

enum _SessionStatusTone { info, warning, neutral, error, success }

Color _sessionStatusColor(BuildContext context, _SessionStatusTone tone) =>
    switch (tone) {
      _SessionStatusTone.info => context.appColors.info,
      _SessionStatusTone.warning => context.appColors.warning,
      _SessionStatusTone.neutral => context.appColors.neutral,
      _SessionStatusTone.error => Theme.of(context).colorScheme.error,
      _SessionStatusTone.success => context.appColors.success,
    };

_SessionStatusPresentation _sessionStatusPresentation(
  MobileSessionStatus? status,
) => switch (status) {
  MobileSessionStatus.streaming => const _SessionStatusPresentation(
    label: '生成中',
    tone: _SessionStatusTone.info,
    icon: Icons.auto_awesome_outlined,
  ),
  MobileSessionStatus.waitingPermission => const _SessionStatusPresentation(
    label: '等待确认',
    tone: _SessionStatusTone.warning,
    icon: Icons.shield_outlined,
  ),
  MobileSessionStatus.waitingQuestion => const _SessionStatusPresentation(
    label: '等待回答',
    tone: _SessionStatusTone.warning,
    icon: Icons.help_outline,
  ),
  MobileSessionStatus.stopped => const _SessionStatusPresentation(
    label: '已停止',
    tone: _SessionStatusTone.neutral,
    icon: Icons.stop_circle_outlined,
  ),
  MobileSessionStatus.errored => const _SessionStatusPresentation(
    label: '出现错误',
    tone: _SessionStatusTone.error,
    icon: Icons.error_outline,
  ),
  MobileSessionStatus.offline => const _SessionStatusPresentation(
    label: '离线',
    tone: _SessionStatusTone.neutral,
    icon: Icons.cloud_off_outlined,
  ),
  _ => const _SessionStatusPresentation(
    label: '在线',
    tone: _SessionStatusTone.success,
    icon: Icons.forum_outlined,
  ),
};

String _relativeTime(DateTime? value) {
  if (value == null) return '';
  final difference = DateTime.now().difference(value).abs();
  if (difference.inMinutes < 1) return '刚刚';
  if (difference.inHours < 1) return '${difference.inMinutes} 分钟';
  if (difference.inDays < 1) return '${difference.inHours} 小时';
  return '${difference.inDays} 天';
}
