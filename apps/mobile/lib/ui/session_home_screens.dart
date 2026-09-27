import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../app/providers.dart';
import 'appearance_controls.dart';
import '../domain/session_models.dart';
import '../domain/terminal_models.dart';
import '../state/app_controller.dart';
import '../state/session_controller.dart';
import '../state/terminal_status_controller.dart';
import 'app_theme.dart';
import 'session/session_status_presentation.dart';

/// 会话首页家族：DSH 工作区主模式首页、工作区详情、终端卡片化分组。
/// 从 session_screens.dart 拆出（架构收口）；路由与测试经本文件消费
/// SessionHomeScreen / DSHWorkspaceDetailScreen。
class SessionHomeScreen extends ConsumerStatefulWidget {
  const SessionHomeScreen({super.key});

  @override
  ConsumerState<SessionHomeScreen> createState() => _SessionHomeScreenState();
}

class _SessionHomeScreenState extends ConsumerState<SessionHomeScreen> {
  @override
  Widget build(BuildContext context) {
    final app = ref.watch(appControllerProvider);
    final sessions = ref.watch(sessionControllerProvider);
    final terminals = ref.watch(terminalStatusControllerProvider);
    return Scaffold(
      key: const Key('session-home-screen'),
      appBar: AppBar(
        title: const SessionHeaderTitle(title: 'DSH 工作区'),
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
            constraints: const BoxConstraints(maxWidth: 1280),
            child: RefreshIndicator(
              onRefresh: () async {
                await Future.wait([
                  sessions.refreshSessions(),
                  sessions.refreshWorkspaces(),
                  ref.read(terminalStatusControllerProvider).refresh(),
                ]);
              },
              child: _DSHWorkspaceHome(
                app: app,
                sessions: sessions,
                deviceId: app.currentDevice?.id,
                terminalStatus: terminals,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DSHWorkspaceHome extends StatefulWidget {
  const _DSHWorkspaceHome({
    required this.app,
    required this.sessions,
    required this.deviceId,
    required this.terminalStatus,
  });

  final AppController app;
  final SessionController sessions;
  final String? deviceId;
  final TerminalStatusController terminalStatus;

  @override
  State<_DSHWorkspaceHome> createState() => _DSHWorkspaceHomeState();
}

class _DSHWorkspaceHomeState extends State<_DSHWorkspaceHome> {
  final Set<String> _expandedWorkspaceIds = <String>{};
  final TextEditingController _searchController = TextEditingController();

  // v0.9.4（用户需求）：默认只加载活跃会话；「显示全部」解除过滤。
  bool _showAllDshSessions = false;
  String _workspaceSearch = '';
  String? _selectedWorkspaceId;

  @override
  void initState() {
    super.initState();
    // v0.9.1 P2：主页是终端同步的活跃 surface。挂载即递增 surface 代际并按资格
    // 触发去重首拍（认证+前台+在线），后台/离线/注销/dispose 后不再发起新请求；
    // 周期保活由控制器内部 45-60s jitter safety reconcile 承担。
    // postFrame：避免在 widget 构建期改动 Riverpod provider（会抛
    // "modify a provider while the widget tree was building"）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.terminalStatus.attachSurface();
    });
  }

  @override
  void dispose() {
    widget.terminalStatus.detachSurface();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final sessions = widget.sessions;
    final terminalStatus = widget.terminalStatus;
    final dshWorkspaces =
        sessions.workspaces.where((workspace) => workspace.isDsh).toList()
          ..sort(
            (left, right) =>
                left.label.toLowerCase().compareTo(right.label.toLowerCase()),
          );
    if (sessions.phase == SessionListPhase.loading &&
        sessions.workspacePhase == WorkspaceListPhase.loading &&
        sessions.sessions.isEmpty &&
        sessions.workspaces.isEmpty) {
      return const Center(
        key: Key('dsh-workspace-loading'),
        child: CircularProgressIndicator(),
      );
    }
    if (sessions.workspacePhase == WorkspaceListPhase.error &&
        sessions.workspaces.isEmpty) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.xxl, AppSpacing.lg, AppSpacing.xxl),
        children: [
          InlineError(
            key: const Key('dsh-workspace-list-error'),
            message: sessions.workspaceErrorMessage ?? '工作区列表暂时不可用。',
            onRetry: sessions.refreshWorkspaces,
          ),
        ],
      );
    }

    final filteredWorkspaces = dshWorkspaces
        .where((workspace) {
          final sessionItems = _dshSessionsForWorkspace(
            sessions.sessions,
            workspace.id,
            // 搜索时显示全部匹配（找历史会话不需要先切开关）。
            activeOnly: !_showAllDshSessions && _workspaceSearch.isEmpty,
          );
          return _matchesWorkspaceSearch(
            workspace: workspace,
            sessions: sessionItems,
            query: _workspaceSearch,
          );
        })
        .toList(growable: false);

    final isWide = MediaQuery.sizeOf(context).width >= 900;
    if (isWide) {
      return _buildWideWorkspaceView(
        context,
        app: app,
        sessions: sessions,
        terminalStatus: terminalStatus,
        dshWorkspaces: dshWorkspaces,
        filteredWorkspaces: filteredWorkspaces,
      );
    }

    return ListView(
      key: const Key('dsh-workspace-list-scroll'),
      padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.xxl),
      children: [
        if (sessions.errorMessage != null) ...[
          InlineError(
            key: const Key('session-error-message'),
            message: sessions.errorMessage!,
            onRetry: sessions.clearError,
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
        if (!app.canManageDevices) ...[
          const ReadOnlyBanner(),
          const SizedBox(height: AppSpacing.md),
        ],
        _DSHWorkspaceToolbar(
          searchController: _searchController,
          onSearchChanged: (value) => setState(() => _workspaceSearch = value),
          showAll: _showAllDshSessions,
          onToggleShowAll: () =>
              setState(() => _showAllDshSessions = !_showAllDshSessions),
        ),
        const SizedBox(height: AppSpacing.md),
        if (sessions.workspaceSyncState != null ||
            sessions.workspaceSyncWaiting)
          _DSHWorkspaceSyncNotice(
            state: sessions.workspaceSyncState,
            waiting: sessions.workspaceSyncWaiting,
            error: sessions.workspaceErrorMessage,
            onStopWaiting: sessions.stopWaitingForDSHWorkspaceSync,
          ),
        if (sessions.workspaceSyncState != null ||
            sessions.workspaceSyncWaiting)
          const SizedBox(height: AppSpacing.md),
        // v0.8.6 C：无工作区但存在可同步终端时也渲染终端空卡（卡内同步直发），
        // 保证首次使用场景有同步入口；搜索无命中时展示空态。
        // v0.8.6 C：空态仅在"既无工作区也无已知终端"时展示；终端刷新挂起时
        // 先给出页面级加载反馈。
        // 文本型加载态：无限旋转的 spinner 会让 pumpAndSettle 永不收敛。
        if (terminalStatus.isRefreshing && terminalStatus.terminals.isEmpty)
          const Padding(
            key: Key('terminal-sync-loading'),
            padding: EdgeInsets.symmetric(vertical: AppSpacing.lg),
            child: Center(child: Text('正在读取本机终端状态…')),
          )
        else if (dshWorkspaces.isEmpty && terminalStatus.terminals.isEmpty)
          _DSHWorkspaceEmptyState(canSync: app.canManageDevices)
        else if (dshWorkspaces.isNotEmpty && filteredWorkspaces.isEmpty)
          const _DSHWorkspaceSearchEmptyState()
        else
          ..._buildTerminalCardItems(
            context,
            sessions: sessions,
            terminalStatus: terminalStatus,
            filteredWorkspaces: filteredWorkspaces,
            onSelectWorkspace: (workspace) {
              if (GoRouter.maybeOf(context) != null) {
                context.push('/workspaces/${workspace.id}');
              } else {
                // 纯 widget fixture 没有路由宿主时仍保留选中态，便于测试交互契约。
                setState(() {
                  _selectedWorkspaceId = workspace.id;
                  _expandedWorkspaceIds.add(workspace.id);
                });
              }
            },
            onOpenSession: (session) async {
              await sessions.selectSession(session.id);
              if (!context.mounted) return;
              if (GoRouter.maybeOf(context) != null) {
                context.push('/sessions/${session.id}');
              }
            },
          ),
      ],
    );
  }

  /// 构造终端卡片列表（每卡一台终端 + 卡内工作区；串行单槽：同一时间只允许
  /// 一张卡发起同步，其余卡的同步按钮禁用并提示"同步进行中"）。
  List<Widget> _buildTerminalCardItems(
    BuildContext context, {
    required SessionController sessions,
    required TerminalStatusController terminalStatus,
    required List<MobileWorkspace> filteredWorkspaces,
    required void Function(MobileWorkspace workspace) onSelectWorkspace,
    required ValueChanged<MobileSession> onOpenSession,
  }) {
    final groups = _terminalGroups(
      filteredWorkspaces,
      terminalStatus,
      canManageDevices: widget.app.canManageDevices,
    );
    return [
      for (final group in groups)
        _TerminalWorkspaceCard(
          key: Key('terminal-card-${group.terminal?.id ?? 'orphan'}'),
          group: group,
          sessions: sessions,
          selectedWorkspaceId: _selectedWorkspaceId,
          selectedSessionId: sessions.selectedSessionId,
          expandedWorkspaceIds: _expandedWorkspaceIds,
          onToggle: (workspaceId) => setState(() {
            if (!_expandedWorkspaceIds.add(workspaceId)) {
              _expandedWorkspaceIds.remove(workspaceId);
            }
          }),
          onSelectWorkspace: onSelectWorkspace,
          onOpenSession: onOpenSession,
          onSync: group.canSync && group.terminal != null && !_syncBusy
              ? () => unawaited(
                  widget.sessions.syncDSHWorkspaces(
                    terminalId: group.terminal!.id,
                  ),
                )
              : null,
          syncBusy: _syncBusy,
          terminalsRefreshing: terminalStatus.isRefreshing,
        ),
      const SizedBox(height: AppSpacing.sm),
    ];
  }

  Widget _buildWideWorkspaceView(
    BuildContext context, {
    required AppController app,
    required SessionController sessions,
    required TerminalStatusController terminalStatus,
    required List<MobileWorkspace> dshWorkspaces,
    required List<MobileWorkspace> filteredWorkspaces,
  }) {
    final panelHeight = (MediaQuery.sizeOf(context).height - 120)
        .clamp(600.0, 960.0)
        .toDouble();
    final selected = _selectedWorkspaceId == null
        ? null
        : dshWorkspaces
              .where((workspace) => workspace.id == _selectedWorkspaceId)
              .firstOrNull;
    final visibleSelection = selected ?? filteredWorkspaces.firstOrNull;
    if (visibleSelection != null && _selectedWorkspaceId == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _selectedWorkspaceId == null) {
          setState(() {
            _selectedWorkspaceId = visibleSelection.id;
            _expandedWorkspaceIds.add(visibleSelection.id);
          });
        }
      });
    }
    return ListView(
      key: const Key('dsh-workspace-master-detail-scroll'),
      padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.xxl),
      children: [
        SizedBox(
          height: panelHeight,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 344,
                child: Material(
                  color: Theme.of(context).colorScheme.surface,
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpacing.md),
                    child: ListView(
                      children: [
                        if (sessions.errorMessage != null) ...[
                          InlineError(
                            key: const Key('session-error-message'),
                            message: sessions.errorMessage!,
                            onRetry: sessions.clearError,
                          ),
                          const SizedBox(height: AppSpacing.sm),
                        ],
                        if (!app.canManageDevices) ...[
                          const ReadOnlyBanner(),
                          const SizedBox(height: AppSpacing.md),
                        ],
                        _DSHWorkspaceToolbar(
                          searchController: _searchController,
                          onSearchChanged: (value) =>
                              setState(() => _workspaceSearch = value),
                          showAll: _showAllDshSessions,
                          onToggleShowAll: () => setState(
                            () => _showAllDshSessions = !_showAllDshSessions,
                          ),
                        ),
                        const SizedBox(height: AppSpacing.md),
                        if (sessions.workspaceSyncState != null ||
                            sessions.workspaceSyncWaiting)
                          _DSHWorkspaceSyncNotice(
                            state: sessions.workspaceSyncState,
                            waiting: sessions.workspaceSyncWaiting,
                            error: sessions.workspaceErrorMessage,
                            onStopWaiting:
                                sessions.stopWaitingForDSHWorkspaceSync,
                          ),
                        if (sessions.workspaceSyncState != null ||
                            sessions.workspaceSyncWaiting)
                          const SizedBox(height: AppSpacing.md),
                        if (terminalStatus.isRefreshing &&
                            terminalStatus.terminals.isEmpty)
                          const Padding(
                            key: Key('terminal-sync-loading'),
                            padding: EdgeInsets.symmetric(vertical: AppSpacing.lg),
                            child: Center(child: Text('正在读取本机终端状态…')),
                          )
                        else if (dshWorkspaces.isEmpty &&
                            terminalStatus.terminals.isEmpty)
                          _DSHWorkspaceEmptyState(canSync: app.canManageDevices)
                        else if (dshWorkspaces.isNotEmpty &&
                            filteredWorkspaces.isEmpty)
                          const _DSHWorkspaceSearchEmptyState()
                        else
                          ..._buildTerminalCardItems(
                            context,
                            sessions: sessions,
                            terminalStatus: terminalStatus,
                            filteredWorkspaces: filteredWorkspaces,
                            onSelectWorkspace: (workspace) => setState(() {
                              _selectedWorkspaceId = workspace.id;
                              _expandedWorkspaceIds.add(workspace.id);
                            }),
                            onOpenSession: (session) async {
                              await sessions.selectSession(session.id);
                              if (!context.mounted) return;
                              if (GoRouter.maybeOf(context) != null) {
                                context.push('/sessions/${session.id}');
                              }
                            },
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              const VerticalDivider(width: 24, thickness: 1),
              Expanded(
                child: visibleSelection == null
                    ? const _DSHWorkspaceNoSelectionPane()
                    : _DSHWorkspaceDetailPane(
                        workspace: visibleSelection,
                        sessions: _dshSessionsForWorkspace(
                          sessions.sessions,
                          visibleSelection.id,
                          activeOnly: !_showAllDshSessions,
                        ),
                        unseenCompletedSessionIds:
                            sessions.unseenCompletedSessionIds,
                        app: app,
                        terminals: terminalStatus,
                        importState:
                            sessions.workspaceImportWorkspaceId ==
                                visibleSelection.id
                            ? sessions.workspaceImportState
                            : null,
                        importWaiting:
                            sessions.workspaceImportWaiting &&
                            sessions.workspaceImportWorkspaceId ==
                                visibleSelection.id,
                        busy: sessions.isBusy,
                        error: sessions.workspaceErrorMessage,
                        onCreate: () => _createDshSession(
                          context,
                          app,
                          sessions,
                          visibleSelection,
                        ),
                        onImport: () => _confirmImport(
                          context,
                          app,
                          sessions,
                          visibleSelection,
                        ),
                        onStopImportWaiting: sessions.stopWaitingForDSHImport,
                        onDismissError: sessions.clearWorkspaceError,
                        onOpenSession: (session) async {
                          await sessions.selectSession(session.id);
                          if (!context.mounted) return;
                          context.push('/sessions/${session.id}');
                        },
                      ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _createDshSession(
    BuildContext context,
    AppController app,
    SessionController sessions,
    MobileWorkspace workspace,
  ) async {
    // 与通用新建表单同口径：dsh 为 per-session spawn ACP 桥（ADR-013 §3），
    // 创建后必须立刻 acquire lease 并 session.start；否则首条 session.send
    // 会被 Daemon 以 local_state_missing fail-closed，客户端无限停留在生成中。
    final created = await sessions.createSession(
      workspaceId: workspace.id,
      provider: 'dsh',
      deviceId: app.currentDevice?.id,
      canWrite: app.canManageDevices,
      autoStart: true,
    );
    if (!mounted || created == null) return;
    this.context.push('/sessions/${created.id}');
  }

  Future<void> _confirmImport(
    BuildContext context,
    AppController app,
    SessionController sessions,
    MobileWorkspace workspace,
  ) {
    return confirmDSHHistoryContinuation(context, app, sessions, workspace);
  }

  // ---- v0.8.6 C（G9）：主页终端卡片化 ----
  // 全局同步按钮 + 选择抽屉被"终端卡片 + 卡内同步直发"取代：每张卡对应一台
  // 终端机器，点卡内同步按钮直接对该终端发起工作区同步（无抽屉）。
  bool get _syncBusy =>
      widget.sessions.workspaceSyncWaiting ||
      (widget.sessions.workspaceSyncState?.isPending == true);

  /// 按终端把工作区分组。组键 = workspace.terminalId；找不到对应终端（或
  /// terminalId 为空）的工作区归入"未归属"组（排序末尾，同步禁用并给原因）。
  List<_TerminalGroup> _terminalGroups(
    List<MobileWorkspace> workspaces,
    TerminalStatusController terminalStatus, {
    required bool canManageDevices,
  }) {
    final terminals = {
      for (final terminal in terminalStatus.terminals) terminal.id: terminal,
    };
    final buckets = <String, List<MobileWorkspace>>{};
    final order = <String>[];
    for (final workspace in workspaces) {
      final key = workspace.terminalId.isEmpty ? '' : workspace.terminalId;
      if (!buckets.containsKey(key)) order.add(key);
      buckets.putIfAbsent(key, () => []).add(workspace);
    }
    // 每台已知终端都出一张卡（有工作区的携带工作区；暂无工作区的出空卡，
    // 保证首次使用也有同步入口；离线/无能力卡灰态带原因）。
    for (final terminal in terminalStatus.terminals) {
      if (!buckets.containsKey(terminal.id)) {
        order.insert(order.length, terminal.id);
        buckets[terminal.id] = const [];
      }
    }
    // 未归属组永远排在已识别终端之后。
    order.sort((left, right) {
      if (left.isEmpty) return 1;
      if (right.isEmpty) return -1;
      return 0;
    });
    return [
      for (final key in order)
        () {
          final terminal = key.isEmpty ? null : terminals[key];
          // v0.9.1 C4：availability 只取一次（Relay 投影），标题/门控/原因共用；
          // unknown 表示事实不可确认，不向用户报告成执行端离线（裁决 T5）。
          final availability = terminal == null
              ? TerminalAvailability.unknown
              : terminalStatus.availabilityFor(terminal);
          final online = availability == TerminalAvailability.online;
          final capable =
              terminal?.hasCapability('dsh_workspace_sync') ?? false;
          String? blockedReason;
          if (terminal == null) {
            blockedReason = '工作区未归属已知终端（终端离线或已更换设备）。';
          } else if (!online) {
            blockedReason = switch (availability) {
              TerminalAvailability.offline => '终端离线，无法请求同步。',
              TerminalAvailability.unsupported => '终端协议不兼容，无法请求同步。',
              _ => '终端状态未确认，稍后自动重试。',
            };
          } else if (!capable) {
            blockedReason = '终端未声明 DSH 工作区同步能力。';
          } else if (!widget.app.canManageDevices) {
            blockedReason = '当前设备只读，无法请求同步。';
          }
          return _TerminalGroup(
            terminal: terminal,
            availability: availability,
            canSync: blockedReason == null,
            blockedReason: blockedReason,
            workspaces: buckets[key] ?? const [],
          );
        }(),
    ];
  }
}

/// v0.9.4（用户需求：每个工作区只加载最近三天还在更新的会话）：默认只显示
/// 活跃窗口内的会话；与 daemon 导入侧的 72h 过滤窗口保持一致。
const Duration dshActiveSessionWindow = Duration(hours: 72);

List<MobileSession> _dshSessionsForWorkspace(
  List<MobileSession> sessions,
  String workspaceId, {
  bool activeOnly = false,
  DateTime? now,
}) {
  final cutoff = (now ?? DateTime.now()).subtract(dshActiveSessionWindow);
  return sessions.where((session) {
    // 72h 只是时间筛选；历史来源与重复副本由服务端 visibility 决定，
    // 时间筛选、搜索或「显示全部」都不能解除隐藏。
    if (!session.isVisible ||
        session.workspaceId != workspaceId ||
        session.provider != 'dsh') {
      return false;
    }
    if (activeOnly) {
      // 无活动时间的会话（旧数据未知）按不活跃处理；「显示全部」可解除过滤。
      final last = session.lastActivityAt;
      if (last == null || last.isBefore(cutoff)) return false;
    }
    return true;
  }).toList(growable: false);
}

bool _matchesWorkspaceSearch({
  required MobileWorkspace workspace,
  required List<MobileSession> sessions,
  required String query,
}) {
  final normalized = query.trim().toLowerCase();
  if (normalized.isEmpty) return true;
  return workspace.label.toLowerCase().contains(normalized) ||
      sessions.any(
        (session) =>
            _dshSessionLabel(session).toLowerCase().contains(normalized),
      );
}

/// DSH 导入回执只保证 session id；缺少由 Agent Sessions 主动命名的安全标题时，
/// 统一使用固定标签，绝不把 DSH session id、路径或正文片段回退到 UI。
String _dshSessionLabel(MobileSession session) {
  final candidate = session.displayName?.trim() ?? '';
  if (candidate.isEmpty ||
      candidate.contains('/') ||
      candidate.contains('\\')) {
    return '未命名 DSH 会话';
  }
  if (candidate.runes.any((rune) => rune < 0x20 || rune == 0x7f)) {
    return '未命名 DSH 会话';
  }
  return candidate;
}

/// 显式历史接续：确认 → 发现候选 → 用户单选 → 纳入日常列表。
/// 不做批量接续；取消或未选择都不会改变日常列表。
Future<void> confirmDSHHistoryContinuation(
  BuildContext context,
  AppController app,
  SessionController sessions,
  MobileWorkspace workspace,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('选择历史会话接续？'),
      content: const Text(
          '将按当前工作区列出历史候选，由你逐条选择接续；未选中的历史不会进入日常列表。接续会读取该会话的真实标题与最近上下文，内容只经过你自己的 Relay。'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('dsh-workspace-import-confirm'),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('查看历史候选'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;
  final state = await sessions.importDSHSessions(
    workspaceId: workspace.id,
    deviceId: app.currentDevice?.id,
    canWrite: app.canManageDevices,
    terminalId: workspace.terminalId,
  );
  if (state != null && !state.isSucceeded) return;
  if (!context.mounted) return;
  final candidates = await sessions.historyCandidatesForWorkspace(workspace.id);
  if (candidates == null || !context.mounted) return;
  if (candidates.isEmpty) {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('暂无历史候选'),
        content: const Text('当前工作区没有可接续的历史会话。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('好的'),
          ),
        ],
      ),
    );
    return;
  }
  final selected = await showDialog<MobileSession>(
    context: context,
    builder: (context) => SimpleDialog(
      key: const Key('dsh-history-picker'),
      title: const Text('选择要接续的历史会话'),
      children: [
        for (final candidate in candidates)
          ListTile(
            key: Key('dsh-history-option-${candidate.id}'),
            title: Text(_dshSessionLabel(candidate)),
            subtitle: candidate.lastActivityAt == null
                ? null
                : Text(_sessionTimestamp(candidate.lastActivityAt!)),
            onTap: () => Navigator.of(context).pop(candidate),
          ),
      ],
    ),
  );
  if (selected == null || !context.mounted) return;
  final managed = await sessions.manageHistorySession(
    candidate: selected,
    deviceId: app.currentDevice?.id,
    canWrite: app.canManageDevices,
  );
  if (managed == null || !context.mounted) return;
  if (GoRouter.maybeOf(context) != null) {
    context.push('/sessions/${managed.id}');
  }
}

String _sessionTimestamp(DateTime time) {
  final local = time.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}

/// v0.8.6 C（G9）：主页工具栏只保留搜索。原全局"同步本机 DSH 项目"按钮已被
/// 终端卡片的卡内同步按钮取代（点卡片同步直接对该终端发起，无需选择抽屉）。
class _DSHWorkspaceToolbar extends StatelessWidget {
  const _DSHWorkspaceToolbar({
    required this.searchController,
    required this.onSearchChanged,
    required this.showAll,
    required this.onToggleShowAll,
  });

  final TextEditingController searchController;
  final ValueChanged<String> onSearchChanged;
  // v0.9.4（用户需求）：默认只加载活跃会话；true 表示已解除过滤显示全部。
  final bool showAll;
  final VoidCallback onToggleShowAll;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      TextField(
        key: const Key('dsh-workspace-search-input'),
        controller: searchController,
        onChanged: onSearchChanged,
        maxLines: 1,
        decoration: const InputDecoration(
          prefixIcon: Icon(Icons.search),
          hintText: '搜索工作区或会话',
          isDense: true,
        ),
      ),
      const SizedBox(height: AppSpacing.xs),
      // 时间筛选开关：默认只看最近三天还在更新的已管理会话；
      // 解除筛选只扩大时间范围，历史候选/重复副本的隐藏边界不变。
      Align(
        alignment: Alignment.centerLeft,
        child: FilterChip(
          key: const Key('dsh-workspace-active-only-chip'),
          selected: !showAll,
          onSelected: (_) => onToggleShowAll(),
          label: const Text('只看活跃（最近 3 天）'),
        ),
      ),
    ],
  );
}
class _DSHWorkspaceGroup extends StatelessWidget {
  const _DSHWorkspaceGroup({
    required this.workspace,
    required this.sessions,
    required this.expanded,
    required this.selected,
    required this.selectedSessionId,
    required this.onToggle,
    required this.onSelectWorkspace,
    required this.onOpenSession,
    this.unseenCompletedSessionIds = const {},
  });

  final MobileWorkspace workspace;
  final List<MobileSession> sessions;
  final bool expanded;
  final bool selected;
  final String? selectedSessionId;
  final VoidCallback onToggle;
  final VoidCallback onSelectWorkspace;
  final ValueChanged<MobileSession> onOpenSession;

  /// v0.9.0 C4：完成角标集合（来自 SessionController）。
  final Set<String> unseenCompletedSessionIds;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sessionCount = sessions.length;
    final statusLabel = sessionCount == 0 ? '尚无会话' : '$sessionCount 个 DSH 会话';
    return Semantics(
      selected: selected,
      label: '${workspace.label}，$statusLabel${selected ? '，已选中' : ''}',
      child: Container(
        key: Key('dsh-workspace-${workspace.id}'),
        decoration: BoxDecoration(
          color: selected
              ? theme.colorScheme.surfaceContainerHigh
              : Colors.transparent,
          // Keep the workspace browser as a continuous sidebar list rather
          // than turning every local project into an isolated card.
          border: Border(
            left: BorderSide(
              color: selected ? theme.colorScheme.primary : Colors.transparent,
              width: 3,
            ),
            bottom: BorderSide(color: theme.dividerColor),
          ),
        ),
        child: Column(
          children: [
            Row(
              children: [
                Semantics(
                  button: true,
                  expanded: expanded,
                  label: expanded
                      ? '收起 ${workspace.label}'
                      : '展开 ${workspace.label}',
                  child: IconButton(
                    key: Key('dsh-workspace-expand-${workspace.id}'),
                    tooltip: expanded
                        ? '收起 ${workspace.label}'
                        : '展开 ${workspace.label}',
                    onPressed: onToggle,
                    icon: Icon(
                      expanded ? Icons.expand_more : Icons.chevron_right,
                    ),
                  ),
                ),
                Expanded(
                  child: Semantics(
                    button: true,
                    selected: selected,
                    child: InkWell(
                      key: Key('dsh-workspace-select-${workspace.id}'),
                      borderRadius: BorderRadius.circular(AppRadius.micro),
                      onTap: onSelectWorkspace,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
                        child: Row(
                          children: [
                            const Icon(Icons.folder_outlined, size: AppSizes.iconLg),
                            const SizedBox(width: AppSpacing.sm),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    workspace.label,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.titleSmall,
                                  ),
                                  const SizedBox(height: AppSpacing.micro),
                                  Text(
                                    statusLabel,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodySmall,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                if (selected)
                  Padding(
                    padding: const EdgeInsets.only(right: AppSpacing.md),
                    child: Icon(
                      Icons.check_circle_outline,
                      color: theme.colorScheme.primary,
                      semanticLabel: '已选中工作区',
                    ),
                  ),
              ],
            ),
            if (expanded) ...[
              const Divider(height: 1),
              if (sessions.isEmpty)
                const Padding(
                  padding: EdgeInsets.fromLTRB(
                    AppLayout.workspaceHeaderIndent,
                    AppSpacing.lg, AppSpacing.md, AppSpacing.lg),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text('尚无 DSH 会话'),
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.fromLTRB(AppSpacing.sm, AppSpacing.sm, AppSpacing.sm, AppSpacing.micro),
                  child: Column(
                    children: [
                      for (final session in sessions)
                        _DSHWorkspaceSessionItem(
                          session: session,
                          selected: session.id == selectedSessionId,
                          hasUnseenCompletion:
                              unseenCompletedSessionIds.contains(session.id),
                          onTap: () => onOpenSession(session),
                        ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _DSHWorkspaceSessionItem extends StatelessWidget {
  const _DSHWorkspaceSessionItem({
    required this.session,
    required this.selected,
    required this.onTap,
    this.hasUnseenCompletion = false,
  });

  final MobileSession session;
  final bool selected;
  final VoidCallback onTap;

  /// v0.9.0 C4：非当前会话「有新完成结果」角标（快照确认真实终态后置位）。
  final bool hasUnseenCompletion;

  @override
  Widget build(BuildContext context) {
    final status = sessionStatusPresentation(session);
    return Material(
      color: Colors.transparent,
      child: ListTile(
        key: Key('dsh-workspace-session-${session.id}'),
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.micro),
          side: BorderSide(
            color: selected
                ? Theme.of(context).colorScheme.primary
                : Colors.transparent,
          ),
        ),
        selected: selected,
        selectedTileColor: Theme.of(context).colorScheme.surfaceContainerHigh,
        leading: const Icon(Icons.terminal_outlined, size: AppSizes.iconMd),
        title: Text(
          _dshSessionLabel(session),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          sessionStatusLineText(session),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (hasUnseenCompletion)
              Semantics(
                label: '有新完成结果',
                child: Padding(
                  key: Key('session-completion-badge-${session.id}'),
                  padding: const EdgeInsets.only(right: AppSpacing.sm),
                  child: Icon(
                    Icons.mark_chat_unread_outlined,
                    size: AppSizes.iconSm,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
            Semantics(
              label: status.label,
              child: Icon(
                Icons.circle,
                size: AppSizes.indicatorDot,
                color: sessionStatusColor(context, status.tone),
              ),
            ),
          ],
        ),
        onTap: onTap,
      ),
    );
  }
}

class _DSHWorkspaceEmptyState extends StatelessWidget {
  const _DSHWorkspaceEmptyState({required this.canSync});

  final bool canSync;

  @override
  Widget build(BuildContext context) => Container(
    key: const Key('dsh-workspace-empty'),
    padding: const EdgeInsets.all(AppSpacing.lg),
    decoration: BoxDecoration(
      border: Border.all(color: Theme.of(context).dividerColor),
      borderRadius: BorderRadius.circular(AppRadius.card),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.folder_off_outlined),
        const SizedBox(height: AppSpacing.sm),
        Text('尚未同步本机 DSH 项目', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: AppSpacing.xs),
        Text(
          canSync ? '选择在线终端后同步其已授权的项目。' : '当前设备只读，无法请求同步。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    ),
  );
}

class _DSHWorkspaceSearchEmptyState extends StatelessWidget {
  const _DSHWorkspaceSearchEmptyState();

  @override
  Widget build(BuildContext context) => const Padding(
    key: Key('dsh-workspace-search-empty'),
    padding: EdgeInsets.symmetric(vertical: AppSpacing.xxl),
    child: Center(child: Text('没有匹配的工作区或会话。')),
  );
}

TerminalSummary? _homeTerminalForWorkspace(
  MobileWorkspace workspace,
  TerminalStatusController terminals,
) {
  for (final terminal in terminals.terminals) {
    if (terminal.id == workspace.terminalId) return terminal;
  }
  return null;
}

String _terminalAvailabilityLabel(
  TerminalSummary? terminal,
  TerminalAvailability? availability,
) => switch ((terminal, availability)) {
  (null, _) => '未找到归属 Terminal',
  (_, TerminalAvailability.online) => '在线',
  (_, TerminalAvailability.offline) => '离线',
  (_, TerminalAvailability.stale) => '状态过期',
  (_, TerminalAvailability.unsupported) => '协议不兼容',
  _ => '状态未知',
};

class _DSHWorkspaceNoSelectionPane extends StatelessWidget {
  const _DSHWorkspaceNoSelectionPane();

  @override
  Widget build(BuildContext context) => Center(
    key: const Key('dsh-workspace-no-selection'),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.folder_open_outlined,
          size: AppSizes.emptyStateIcon,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        const SizedBox(height: AppSpacing.md),
        const Text('选择一个工作区查看详情'),
      ],
    ),
  );
}

class _DSHWorkspaceDetailPane extends StatelessWidget {
  const _DSHWorkspaceDetailPane({
    required this.workspace,
    required this.sessions,
    required this.app,
    required this.terminals,
    required this.importState,
    required this.importWaiting,
    required this.busy,
    required this.error,
    required this.onCreate,
    required this.onImport,
    required this.onStopImportWaiting,
    required this.onDismissError,
    required this.onOpenSession,
    this.unseenCompletedSessionIds = const {},
  });

  final MobileWorkspace workspace;
  final List<MobileSession> sessions;

  /// v0.9.0 C4：完成角标集合（来自 SessionController）。
  final Set<String> unseenCompletedSessionIds;
  final AppController app;
  final TerminalStatusController terminals;
  final WorkspaceImportState? importState;
  final bool importWaiting;
  final bool busy;
  final String? error;
  final VoidCallback onCreate;
  final VoidCallback onImport;
  final VoidCallback onStopImportWaiting;
  final VoidCallback onDismissError;
  final ValueChanged<MobileSession> onOpenSession;

  @override
  Widget build(BuildContext context) {
    final terminal = _homeTerminalForWorkspace(workspace, terminals);
    final availability = terminal == null
        ? null
        : terminals.availabilityFor(terminal);
    final terminalOnline = availability == TerminalAvailability.online;
    final canCreate =
        app.canManageDevices &&
        terminalOnline &&
        terminal!.hasCapability('start') &&
        !busy;
    final canImport =
        app.canManageDevices &&
        terminalOnline &&
        terminal!.hasCapability('dsh_session_import') &&
        !busy;
    final createReason = !app.canManageDevices
        ? '当前设备只读，无法创建会话。'
        : terminal == null
        ? '未找到工作区归属 Terminal。'
        : !terminalOnline
        ? 'home Terminal 当前${_terminalAvailabilityLabel(terminal, availability)}。'
        : !terminal.hasCapability('start')
        ? 'home Terminal 未声明 DSH 启动能力。'
        : busy
        ? '正在处理工作区操作。'
        : null;
    final importReason = !app.canManageDevices
        ? '当前设备只读，无法导入。'
        : terminal == null
        ? '未找到工作区归属 Terminal。'
        : !terminalOnline
        ? 'home Terminal 当前${_terminalAvailabilityLabel(terminal, availability)}。'
        : !terminal.hasCapability('dsh_session_import')
        ? 'home Terminal 未声明历史会话导入能力。'
        : busy
        ? '正在处理工作区操作。'
        : null;
    final importTerminalState =
        importState?.isTerminal == true && !importWaiting;

    return SingleChildScrollView(
      key: const Key('dsh-workspace-detail-pane'),
      padding: const EdgeInsets.fromLTRB(AppSpacing.xxl, AppSpacing.xl, AppSpacing.xxl, AppSpacing.xxl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      workspace.label,
                      key: const Key('dsh-workspace-detail-title'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    Text(
                      'DSH 工作区',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                key: const Key('dsh-workspace-more-menu'),
                tooltip: '工作区更多操作',
                onSelected: (value) {
                  if (value == 'import') onImport();
                },
                itemBuilder: (context) => [
                  PopupMenuItem<String>(
                    key: const Key('dsh-workspace-import-button'),
                    value: 'import',
                    enabled: canImport && !importWaiting,
                    child: ListTile(
                      leading: const Icon(Icons.history),
                      title: const Text('选择历史会话接续'),
                      subtitle: importReason == null
                          ? null
                          : Text(importReason),
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xl),
          Semantics(
            button: GoRouter.maybeOf(context) != null,
            label:
                'home Terminal，${terminal == null ? '未连接' : _terminalAvailabilityLabel(terminal, availability)}',
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                key: const Key('dsh-workspace-terminal-status'),
                borderRadius: BorderRadius.circular(AppRadius.card),
                onTap: GoRouter.maybeOf(context) == null
                    ? null
                    : () => context.push('/terminals'),
                child: Ink(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(AppRadius.card),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.computer_outlined),
                      const SizedBox(width: AppSpacing.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('home Terminal'),
                            const SizedBox(height: AppSpacing.micro),
                            Text(
                              terminal == null
                                  ? '未连接'
                                  : '${terminal.hostname} · ${_terminalAvailabilityLabel(terminal, availability)}',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      if (GoRouter.maybeOf(context) != null)
                        const Icon(
                          Icons.chevron_right,
                          semanticLabel: '查看终端状态',
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.xl),
          if (createReason != null && !canCreate)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: Text(
                createReason,
                key: const Key('dsh-workspace-create-disabled-reason'),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              key: const Key('dsh-workspace-create-session-button'),
              onPressed: canCreate ? onCreate : null,
              icon: const Icon(Icons.add_comment_outlined),
              label: const Text('新建 DSH 会话'),
            ),
          ),
          if (error != null) ...[
            const SizedBox(height: AppSpacing.md),
            InlineError(message: error!, onRetry: onDismissError),
          ],
          if (importWaiting || importState != null) ...[
            const SizedBox(height: AppSpacing.lg),
            Container(
              key: const Key('dsh-workspace-import-status'),
              padding: const EdgeInsets.all(AppSpacing.md),
              decoration: BoxDecoration(
                border: Border.all(color: Theme.of(context).dividerColor),
                borderRadius: BorderRadius.circular(AppRadius.card),
              ),
              child: Row(
                children: [
                  if (importWaiting)
                    const SizedBox(
                      width: AppSpacing.lg,
                      height: AppSpacing.lg,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else
                    Icon(
                      importState?.isSucceeded == true
                          ? Icons.check_circle_outline
                          : Icons.error_outline,
                    ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      // v0.9.7：discover 语义收敛后这里描述的是受管同步结果，
                      // 不再是「导入历史会话」——空增量是常态而非异常。
                      importWaiting
                          ? '正在同步已管理会话…'
                          : importState?.isSucceeded == true
                          ? importState!.sessionIds.isEmpty
                                ? '已同步，无增量。'
                                : '已同步 ${importState!.sessionIds.length} 个受管会话的增量。'
                          : '受管会话同步未完成。',
                    ),
                  ),
                  if (importWaiting)
                    TextButton(
                      key: const Key('dsh-workspace-import-stop-waiting'),
                      onPressed: onStopImportWaiting,
                      child: const Text('停止等待'),
                    ),
                ],
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.xxl),
          Text('会话', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: AppSpacing.sm),
          if (sessions.isEmpty)
            Container(
              key: const Key('dsh-workspace-detail-empty'),
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.xxl),
              child: const Column(
                children: [
                  Icon(Icons.chat_bubble_outline),
                  SizedBox(height: AppSpacing.sm),
                  Text('尚无 DSH 会话'),
                  SizedBox(height: AppSpacing.xs),
                  Text('从上方创建会话，或在更多操作中导入历史元数据。'),
                ],
              ),
            )
          else
            for (final session in sessions) ...[
              _DSHWorkspaceSessionItem(
                session: session,
                selected: false,
                hasUnseenCompletion: unseenCompletedSessionIds.contains(
                  session.id,
                ),
                onTap: () => onOpenSession(session),
              ),
              const SizedBox(height: AppSpacing.xs),
            ],
          if (!canImport &&
              importTerminalState == false &&
              importReason != null)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.sm),
              child: Text(
                importReason,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 窄屏工作区详情页；工作区 ID 只来自已同步的 DSH 投影，不能由输入框改写。
/// v0.9.4（用户需求）：默认只加载活跃会话（最近三天），appbar 可切换「显示全部」。
class DSHWorkspaceDetailScreen extends ConsumerStatefulWidget {
  const DSHWorkspaceDetailScreen({required this.workspaceId, super.key});

  final String workspaceId;

  @override
  ConsumerState<DSHWorkspaceDetailScreen> createState() =>
      _DSHWorkspaceDetailScreenState();
}

class _DSHWorkspaceDetailScreenState
    extends ConsumerState<DSHWorkspaceDetailScreen> {
  // v0.9.4（用户需求）：默认只加载活跃会话；appbar 按钮切换「显示全部」。
  bool _showAllDshSessions = false;

  // v0.9.5 P1（持续同步）：进入工作区即静默节流刷新一次（增量导入：只拉取
  // watermark 之后的新正文）。控制器侧 60s 节流兜底；失败静默不打扰用户；
  // 只读设备不触发（与手动导入同一 canWrite 口径）。
  bool _autoRefreshScheduled = false;

  void _scheduleAutoRefresh(
    AppController app,
    SessionController sessions,
    MobileWorkspace workspace,
  ) {
    if (_autoRefreshScheduled || !app.canManageDevices) return;
    _autoRefreshScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      sessions.refreshDSHSessionsSilently(
        workspaceId: workspace.id,
        terminalId: workspace.terminalId,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = ref.watch(appControllerProvider);
    final sessionsController = ref.watch(sessionControllerProvider);
    final terminals = ref.watch(terminalStatusControllerProvider);
    MobileWorkspace? workspace;
    for (final candidate in sessionsController.workspaces) {
      if (candidate.id == widget.workspaceId && candidate.isDsh) {
        workspace = candidate;
        break;
      }
    }
    if (workspace == null) {
      return Scaffold(
        appBar: AppBar(title: const SessionHeaderTitle(title: 'DSH 工作区')),
        body: const Center(child: Text('工作区不存在或尚未同步。')),
      );
    }
    final selectedWorkspace = workspace;
    _scheduleAutoRefresh(app, sessionsController, selectedWorkspace);
    final workspaceSessions = _dshSessionsForWorkspace(
      sessionsController.sessions,
      widget.workspaceId,
      activeOnly: !_showAllDshSessions,
    );
    return Scaffold(
      key: const Key('dsh-workspace-detail-screen'),
      appBar: AppBar(
        title: Text(selectedWorkspace.label),
        leading: IconButton(
          key: const Key('dsh-workspace-detail-back'),
          tooltip: '返回工作区',
          onPressed: () => context.pop(),
          icon: const Icon(Icons.arrow_back),
        ),
        actions: [
          IconButton(
            key: const Key('dsh-workspace-detail-show-all'),
            tooltip: _showAllDshSessions ? '只看活跃会话' : '显示全部已管理会话',
            onPressed: () {
              // 只解除 72h 时间筛选；历史候选与重复副本的可见性边界不变，
              // 这里绝不触发历史发现（接续只经「选择历史会话接续」逐条完成）。
              setState(() => _showAllDshSessions = !_showAllDshSessions);
            },
            icon: Icon(
              _showAllDshSessions
                  ? Icons.filter_alt_outlined
                  : Icons.filter_alt,
            ),
          ),
        ],
      ),
      body: _DSHWorkspaceDetailPane(
        workspace: selectedWorkspace,
        sessions: workspaceSessions,
        unseenCompletedSessionIds: sessionsController.unseenCompletedSessionIds,
        app: app,
        terminals: terminals,
        importState:
            sessionsController.workspaceImportWorkspaceId ==
                selectedWorkspace.id
            ? sessionsController.workspaceImportState
            : null,
        importWaiting:
            sessionsController.workspaceImportWaiting &&
            sessionsController.workspaceImportWorkspaceId ==
                selectedWorkspace.id,
        busy: sessionsController.isBusy,
        // autoStart 失败（lease/start 链路）写入 errorMessage 而非 workspaceErrorMessage；
        // 详情页必须两者都浮出，否则创建失败会表现为“按钮无响应”。
        error:
            sessionsController.workspaceErrorMessage ??
            sessionsController.errorMessage,
        onCreate: () => _createSession(
          context,
          ref,
          app,
          sessionsController,
          selectedWorkspace,
        ),
        onImport: () => _confirmImport(
          context,
          ref,
          app,
          sessionsController,
          selectedWorkspace,
        ),
        onStopImportWaiting: sessionsController.stopWaitingForDSHImport,
        onDismissError: () {
          sessionsController.clearWorkspaceError();
          sessionsController.clearError();
        },
        onOpenSession: (session) async {
          await sessionsController.selectSession(session.id);
          if (!context.mounted) return;
          if (GoRouter.maybeOf(context) != null) {
            context.go('/sessions/${session.id}');
          }
        },
      ),
    );
  }

  Future<void> _createSession(
    BuildContext context,
    WidgetRef ref,
    AppController app,
    SessionController sessions,
    MobileWorkspace workspace,
  ) async {
    // 与通用新建表单同口径：dsh 为 per-session spawn ACP 桥（ADR-013 §3），
    // 创建后必须立刻 acquire lease 并 session.start；否则首条 session.send
    // 会被 Daemon 以 local_state_missing fail-closed，客户端无限停留在生成中。
    final created = await sessions.createSession(
      workspaceId: workspace.id,
      provider: 'dsh',
      deviceId: app.currentDevice?.id,
      canWrite: app.canManageDevices,
      autoStart: true,
    );
    if (!context.mounted || created == null) return;
    if (GoRouter.maybeOf(context) != null) {
      context.go('/sessions/${created.id}');
    }
  }

  Future<void> _confirmImport(
    BuildContext context,
    WidgetRef ref,
    AppController app,
    SessionController sessions,
    MobileWorkspace workspace,
  ) {
    return confirmDSHHistoryContinuation(context, app, sessions, workspace);
  }
}

class _DSHWorkspaceSyncNotice extends StatelessWidget {
  const _DSHWorkspaceSyncNotice({
    required this.state,
    required this.waiting,
    required this.error,
    required this.onStopWaiting,
  });

  final WorkspaceSyncState? state;
  final bool waiting;
  final String? error;
  final VoidCallback onStopWaiting;

  @override
  Widget build(BuildContext context) {
    final succeeded = state?.isSucceeded == true;
    final pending = state?.isPending == true;
    final message = waiting
        ? '正在同步本机 DSH 项目…'
        : succeeded
        ? '已同步 ${state!.workspaceIds.length} 个 DSH 工作区。'
        : pending
        ? error ?? '同步请求仍在等待终端响应。'
        : error ?? 'DSH 工作区同步未完成。';
    return Container(
      key: const Key('dsh-workspace-sync-pending'),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: succeeded
            ? Theme.of(context).colorScheme.secondaryContainer
            : Theme.of(context).colorScheme.surfaceContainerHigh,
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: Row(
        children: [
          if (waiting)
            const SizedBox(
              height: AppSpacing.lg,
              width: AppSpacing.lg,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            Icon(
              succeeded
                  ? Icons.check_circle_outline
                  : pending
                  ? Icons.schedule_outlined
                  : Icons.error_outline,
            ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(child: Text(message)),
          if (waiting)
            TextButton(
              key: const Key('dsh-workspace-sync-stop-waiting'),
              onPressed: onStopWaiting,
              child: const Text('停止等待'),
            ),
        ],
      ),
    );
  }
}

/// v0.8.6 C（G9）：一个终端分组 = 一台终端（或未归属组）+ 其名下工作区。
class _TerminalGroup {
  const _TerminalGroup({
    required this.terminal,
    required this.availability,
    required this.canSync,
    required this.blockedReason,
    required this.workspaces,
  });

  /// null 表示"未归属"组（terminalId 为空或终端不在已知列表）。
  final TerminalSummary? terminal;
  /// v0.9.1 G5/C4：组内唯一在线态事实（Relay availability 投影）。
  /// 标题、正文、按钮门控与禁用原因全部由本字段派生，杜绝"标题在线、
  /// 正文离线"的多事实源矛盾卡片。
  final TerminalAvailability availability;
  final bool canSync;
  final String? blockedReason;
  final List<MobileWorkspace> workspaces;
}

/// v0.8.6 C（G9）：主页终端卡片。头部为终端名/平台/在线态与卡内"同步"按钮
/// （点击直接对该终端发起工作区同步，不再弹出选择抽屉）；卡片体按既有
/// 工作区分组语义列出该终端名下的工作区。不可同步的卡整体灰态并给出原因，
/// 保持 fail-closed：绝不渲染可点却必败的同步按钮。
class _TerminalWorkspaceCard extends StatelessWidget {
  const _TerminalWorkspaceCard({
    required this.group,
    required this.sessions,
    required this.selectedWorkspaceId,
    required this.selectedSessionId,
    required this.expandedWorkspaceIds,
    required this.onToggle,
    required this.onSelectWorkspace,
    required this.onOpenSession,
    required this.onSync,
    required this.syncBusy,
    required this.terminalsRefreshing,
    super.key,
  });

  final _TerminalGroup group;
  final SessionController sessions;
  final String? selectedWorkspaceId;
  final String? selectedSessionId;
  final Set<String> expandedWorkspaceIds;
  final ValueChanged<String> onToggle;
  final ValueChanged<MobileWorkspace> onSelectWorkspace;
  final ValueChanged<MobileSession> onOpenSession;
  final VoidCallback? onSync;
  final bool syncBusy;
  final bool terminalsRefreshing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final terminal = group.terminal;
    return Container(
      key: Key('terminal-card-${terminal?.id ?? 'orphan'}'),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(AppRadius.large),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.sm, AppSpacing.sm),
            child: Row(
              children: [
                Icon(
                  terminal == null
                      ? Icons.help_outline
                      : Icons.computer_outlined,
                  size: AppSizes.iconMd,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    terminal?.hostname ?? '未归属终端',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                // v0.9.1 G5：标题在线态与正文/按钮门控消费同一 availability，
                // 不再硬编码「在线」。
                Text(
                  terminal == null
                      ? '${group.workspaces.length} 个工作区'
                      : '${terminal.platform} · ${_terminalAvailabilityLabel(terminal, group.availability)}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (terminal != null && group.canSync)
                  _buildSyncButton(context),
              ],
            ),
          ),
          if (group.blockedReason != null)
            Padding(
              key: Key('terminal-unsyncable-reason-${terminal?.id ?? 'orphan'}'),
              padding: const EdgeInsets.fromLTRB(AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.sm),
              child: Text(
                group.blockedReason!,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          if (terminal != null && terminalsRefreshing && group.canSync)
            const Padding(
              key: Key('terminal-sync-loading'),
              padding: EdgeInsets.fromLTRB(AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.sm),
              child: Row(
                children: [
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: AppSpacing.sm),
                  Text('正在更新终端状态…'),
                ],
              ),
            ),
          const Divider(height: 1),
          // 卡内工作区沿用既有分组语义（展开/会话数/进入详情）。
          // 计数与子项与详情页同一可见边界：默认受管 DSH 会话，非 DSH 不混入。
          for (final workspace in group.workspaces) ...[
            _DSHWorkspaceGroup(
              workspace: workspace,
              sessions: sessions.sessions
                  .where(
                    (item) =>
                        item.isVisible &&
                        item.workspaceId == workspace.id &&
                        item.provider == 'dsh',
                  )
                  .toList(growable: false),
              expanded: expandedWorkspaceIds.contains(workspace.id),
              selected: selectedWorkspaceId == workspace.id,
              selectedSessionId: selectedSessionId,
              unseenCompletedSessionIds: sessions.unseenCompletedSessionIds,
              onToggle: () => onToggle(workspace.id),
              onSelectWorkspace: () => onSelectWorkspace(workspace),
              onOpenSession: onOpenSession,
            ),
            const SizedBox(height: AppSpacing.xs),
          ],
        ],
      ),
    );
  }

  Widget _buildSyncButton(BuildContext context) {
    // 调用点保证 terminal 非空且可同步（group.canSync）。
    final terminal = group.terminal!;
    return IconButton(
      key: Key('terminal-sync-${terminal.id}'),
      tooltip: syncBusy ? '同步进行中，请稍候' : '同步该终端下的工作区',
      onPressed: syncBusy ? null : onSync,
      icon: syncBusy
          ? const SizedBox(
              width: AppSpacing.lg,
              height: AppSpacing.lg,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.sync),
    );
  }
}
