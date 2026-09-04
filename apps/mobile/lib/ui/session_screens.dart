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
import '../domain/terminal_models.dart';
import '../relay/fixture_relay_repository.dart';
import '../state/app_controller.dart';
import '../state/delegation_controller.dart';
import '../state/lifecycle_recovery_controller.dart';
import '../state/session_composer_controller.dart';
import '../state/session_controller.dart';
import '../state/session_message_feedback_controller.dart';
import '../state/session_projection_controller.dart';
import '../state/session_view_controller.dart';
import '../state/terminal_status_controller.dart';
import 'appearance_controls.dart';
import 'app_theme.dart';
import 'session/chat/session_chat_node_seat.dart';
import 'session/chat/session_chat_view.dart';
import 'session/trajectory/session_trajectory_view.dart';
import 'session/composer/session_queue_dock.dart';
import 'session/composer/session_model_seat.dart';

import 'session/composer/session_composer_chain.dart';
import 'session/composer/session_todo_dock.dart';
import 'session/session_conversation_root.dart';
import 'session/session_agent_preset.dart';
import 'session/session_header.dart';
import 'session/session_subagent_chrome.dart';
import 'session/session_workspace_picker.dart';

/// Happy 风格会话首页：优先呈现会话工作流，同时将 owner 安全入口保留在轻量控制区。
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
        title: const _SessionHeaderTitle(title: 'DSH 工作区'),
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
  String _workspaceSearch = '';
  String? _selectedWorkspaceId;
  bool _openingSyncSheet = false;

  @override
  void dispose() {
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
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
        children: [
          _InlineError(
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
        _DSHWorkspaceToolbar(
          searchController: _searchController,
          canSync: app.canManageDevices && !app.isBusy,
          syncing: sessions.workspaceSyncWaiting,
          onSearchChanged: (value) => setState(() => _workspaceSearch = value),
          onSync: () => _openSyncSheet(terminalStatus),
        ),
        const SizedBox(height: 12),
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
          const SizedBox(height: 12),
        if (dshWorkspaces.isEmpty)
          _DSHWorkspaceEmptyState(canSync: app.canManageDevices)
        else if (filteredWorkspaces.isEmpty)
          const _DSHWorkspaceSearchEmptyState()
        else
          for (final workspace in filteredWorkspaces) ...[
            _DSHWorkspaceGroup(
              workspace: workspace,
              sessions: _dshSessionsForWorkspace(
                sessions.sessions,
                workspace.id,
              ),
              expanded: _expandedWorkspaceIds.contains(workspace.id),
              selected: _selectedWorkspaceId == workspace.id,
              selectedSessionId: sessions.selectedSessionId,
              onToggle: () => setState(() {
                if (!_expandedWorkspaceIds.add(workspace.id)) {
                  _expandedWorkspaceIds.remove(workspace.id);
                }
              }),
              onSelectWorkspace: () {
                if (isWide) {
                  setState(() {
                    _selectedWorkspaceId = workspace.id;
                    _expandedWorkspaceIds.add(workspace.id);
                  });
                } else if (GoRouter.maybeOf(context) != null) {
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
            const SizedBox(height: 8),
          ],
      ],
    );
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
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
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
                    padding: const EdgeInsets.all(12),
                    child: ListView(
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
                        _DSHWorkspaceToolbar(
                          searchController: _searchController,
                          canSync: app.canManageDevices && !app.isBusy,
                          syncing: sessions.workspaceSyncWaiting,
                          onSearchChanged: (value) =>
                              setState(() => _workspaceSearch = value),
                          onSync: () => _openSyncSheet(terminalStatus),
                        ),
                        const SizedBox(height: 12),
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
                          const SizedBox(height: 12),
                        if (dshWorkspaces.isEmpty)
                          _DSHWorkspaceEmptyState(canSync: app.canManageDevices)
                        else if (filteredWorkspaces.isEmpty)
                          const _DSHWorkspaceSearchEmptyState()
                        else
                          for (final workspace in filteredWorkspaces) ...[
                            _DSHWorkspaceGroup(
                              workspace: workspace,
                              sessions: _dshSessionsForWorkspace(
                                sessions.sessions,
                                workspace.id,
                              ),
                              expanded: _expandedWorkspaceIds.contains(
                                workspace.id,
                              ),
                              selected: _selectedWorkspaceId == workspace.id,
                              selectedSessionId: sessions.selectedSessionId,
                              onToggle: () => setState(() {
                                if (!_expandedWorkspaceIds.add(workspace.id)) {
                                  _expandedWorkspaceIds.remove(workspace.id);
                                }
                              }),
                              onSelectWorkspace: () => setState(() {
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
                            const SizedBox(height: 8),
                          ],
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
                        ),
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
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('导入历史 DSH 会话？'),
        content: const Text('仅导入会话元数据，不读取或上传消息正文。导入结果会按当前工作区显示。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('dsh-workspace-import-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('确认导入'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await sessions.importDSHSessions(
      workspaceId: workspace.id,
      deviceId: app.currentDevice?.id,
      canWrite: app.canManageDevices,
      terminalId: workspace.terminalId,
    );
  }

  Future<void> _openSyncSheet(TerminalStatusController terminalStatus) async {
    if (_openingSyncSheet) return;
    setState(() => _openingSyncSheet = true);
    // 终端 capability 会在 Daemon 重启后的 hello/heartbeat 中更新。同步弹窗必须
    // 立即打开并在其中呈现刷新状态，不能把用户留在无反馈的图标按钮上等待网络。
    unawaited(terminalStatus.refresh());
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (context) => _DSHWorkspaceSyncSheet(
          sessions: widget.sessions,
          terminals: terminalStatus,
        ),
      );
    } finally {
      if (mounted && _openingSyncSheet) {
        setState(() => _openingSyncSheet = false);
      }
    }
  }
}

List<MobileSession> _dshSessionsForWorkspace(
  List<MobileSession> sessions,
  String workspaceId,
) => sessions
    .where(
      (session) =>
          session.workspaceId == workspaceId && session.provider == 'dsh',
    )
    .toList(growable: false);

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
    return 'DSH 历史会话';
  }
  if (candidate.runes.any((rune) => rune < 0x20 || rune == 0x7f)) {
    return 'DSH 历史会话';
  }
  return candidate;
}

class _DSHWorkspaceToolbar extends StatelessWidget {
  const _DSHWorkspaceToolbar({
    required this.searchController,
    required this.canSync,
    required this.syncing,
    required this.onSearchChanged,
    required this.onSync,
  });

  final TextEditingController searchController;
  final bool canSync;
  final bool syncing;
  final ValueChanged<String> onSearchChanged;
  final VoidCallback onSync;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      // The desktop workspace sidebar is deliberately narrow.  Choose the
      // toolbar arrangement from the viewport, not this local sidebar width.
      final compact = MediaQuery.sizeOf(context).width < 600;
      final search = TextField(
        key: const Key('dsh-workspace-search-input'),
        controller: searchController,
        onChanged: onSearchChanged,
        maxLines: 1,
        decoration: const InputDecoration(
          prefixIcon: Icon(Icons.search),
          hintText: '搜索工作区或会话',
          isDense: true,
        ),
      );
      final sync = canSync
          ? IconButton(
              key: const Key('dsh-workspace-sync-button'),
              tooltip: syncing ? '正在同步 DSH 工作区' : '同步本机 DSH 项目',
              onPressed: syncing ? null : onSync,
              icon: syncing
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.sync),
            )
          : null;
      if (compact) {
        return Column(
          key: const Key('dsh-workspace-toolbar-compact'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            search,
            if (sync != null)
              Align(alignment: Alignment.centerRight, child: sync),
          ],
        );
      }
      return Row(
        key: const Key('dsh-workspace-toolbar-wide'),
        children: [
          Expanded(child: search),
          if (sync != null) ...[const SizedBox(width: 8), sync],
        ],
      );
    },
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
  });

  final MobileWorkspace workspace;
  final List<MobileSession> sessions;
  final bool expanded;
  final bool selected;
  final String? selectedSessionId;
  final VoidCallback onToggle;
  final VoidCallback onSelectWorkspace;
  final ValueChanged<MobileSession> onOpenSession;

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
                      borderRadius: BorderRadius.circular(4),
                      onTap: onSelectWorkspace,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Row(
                          children: [
                            const Icon(Icons.folder_outlined, size: 20),
                            const SizedBox(width: 8),
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
                                  const SizedBox(height: 2),
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
                    padding: const EdgeInsets.only(right: 12),
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
                  padding: EdgeInsets.fromLTRB(52, 14, 12, 14),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text('尚无 DSH 会话'),
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 8, 8, 2),
                  child: Column(
                    children: [
                      for (final session in sessions)
                        _DSHWorkspaceSessionItem(
                          session: session,
                          selected: session.id == selectedSessionId,
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
  });

  final MobileSession session;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final status = _sessionStatusPresentation(session);
    return Material(
      color: Colors.transparent,
      child: ListTile(
        key: Key('dsh-workspace-session-${session.id}'),
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 8),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(4),
          side: BorderSide(
            color: selected
                ? Theme.of(context).colorScheme.primary
                : Colors.transparent,
          ),
        ),
        selected: selected,
        selectedTileColor: Theme.of(context).colorScheme.surfaceContainerHigh,
        leading: const Icon(Icons.terminal_outlined, size: 18),
        title: Text(
          _dshSessionLabel(session),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          _sessionStatusLineText(session),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Semantics(
          label: status.label,
          child: Icon(
            Icons.circle,
            size: 10,
            color: _sessionStatusColor(context, status.tone),
          ),
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
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      border: Border.all(color: Theme.of(context).dividerColor),
      borderRadius: BorderRadius.circular(AppRadius.card),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.folder_off_outlined),
        const SizedBox(height: 10),
        Text('尚未同步本机 DSH 项目', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 4),
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
    padding: EdgeInsets.symmetric(vertical: 24),
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
          size: 48,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        const SizedBox(height: 12),
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
  });

  final MobileWorkspace workspace;
  final List<MobileSession> sessions;
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
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
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
                    const SizedBox(height: 6),
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
                      title: const Text('导入历史会话'),
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
          const SizedBox(height: 20),
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
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(AppRadius.card),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.computer_outlined),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('home Terminal'),
                            const SizedBox(height: 2),
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
          const SizedBox(height: 20),
          if (createReason != null && !canCreate)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
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
            const SizedBox(height: 12),
            _InlineError(message: error!, onRetry: onDismissError),
          ],
          if (importWaiting || importState != null) ...[
            const SizedBox(height: 16),
            Container(
              key: const Key('dsh-workspace-import-status'),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                border: Border.all(color: Theme.of(context).dividerColor),
                borderRadius: BorderRadius.circular(AppRadius.card),
              ),
              child: Row(
                children: [
                  if (importWaiting)
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else
                    Icon(
                      importState?.isSucceeded == true
                          ? Icons.check_circle_outline
                          : Icons.error_outline,
                    ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      importWaiting
                          ? '正在导入历史会话…'
                          : importState?.isSucceeded == true
                          ? importState!.sessionIds.isEmpty
                                ? '未发现可导入会话。'
                                : '已导入 ${importState!.sessionIds.length} 个会话。'
                          : '历史会话导入未完成。',
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
          const SizedBox(height: 24),
          Text('会话', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (sessions.isEmpty)
            Container(
              key: const Key('dsh-workspace-detail-empty'),
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 28),
              child: const Column(
                children: [
                  Icon(Icons.chat_bubble_outline),
                  SizedBox(height: 8),
                  Text('尚无 DSH 会话'),
                  SizedBox(height: 4),
                  Text('从上方创建会话，或在更多操作中导入历史元数据。'),
                ],
              ),
            )
          else
            for (final session in sessions) ...[
              _DSHWorkspaceSessionItem(
                session: session,
                selected: false,
                onTap: () => onOpenSession(session),
              ),
              const SizedBox(height: 4),
            ],
          if (!canImport &&
              importTerminalState == false &&
              importReason != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
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
class DSHWorkspaceDetailScreen extends ConsumerWidget {
  const DSHWorkspaceDetailScreen({required this.workspaceId, super.key});

  final String workspaceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final app = ref.watch(appControllerProvider);
    final sessionsController = ref.watch(sessionControllerProvider);
    final terminals = ref.watch(terminalStatusControllerProvider);
    MobileWorkspace? workspace;
    for (final candidate in sessionsController.workspaces) {
      if (candidate.id == workspaceId && candidate.isDsh) {
        workspace = candidate;
        break;
      }
    }
    if (workspace == null) {
      return Scaffold(
        appBar: AppBar(title: const _SessionHeaderTitle(title: 'DSH 工作区')),
        body: const Center(child: Text('工作区不存在或尚未同步。')),
      );
    }
    final selectedWorkspace = workspace;
    final workspaceSessions = _dshSessionsForWorkspace(
      sessionsController.sessions,
      selectedWorkspace.id,
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
      ),
      body: _DSHWorkspaceDetailPane(
        workspace: selectedWorkspace,
        sessions: workspaceSessions,
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
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('导入历史 DSH 会话？'),
        content: const Text('仅导入会话元数据，不读取或上传消息正文。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('dsh-workspace-import-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('确认导入'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    await sessions.importDSHSessions(
      workspaceId: workspace.id,
      deviceId: app.currentDevice?.id,
      canWrite: app.canManageDevices,
      terminalId: workspace.terminalId,
    );
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
      padding: const EdgeInsets.all(12),
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
              height: 16,
              width: 16,
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
          const SizedBox(width: 8),
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

class _DSHWorkspaceSyncSheet extends StatefulWidget {
  const _DSHWorkspaceSyncSheet({
    required this.sessions,
    required this.terminals,
  });

  final SessionController sessions;
  final TerminalStatusController terminals;

  @override
  State<_DSHWorkspaceSyncSheet> createState() => _DSHWorkspaceSyncSheetState();
}

class _DSHWorkspaceSyncSheetState extends State<_DSHWorkspaceSyncSheet> {
  String? _terminalId;

  List<TerminalSummary> get _eligibleTerminals => widget.terminals.terminals
      .where(
        (terminal) =>
            widget.terminals.availabilityFor(terminal) ==
                TerminalAvailability.online &&
            terminal.hasCapability('dsh_workspace_sync'),
      )
      .toList(growable: false);

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([widget.sessions, widget.terminals]),
      builder: (context, _) {
        final candidates = _eligibleTerminals;
        TerminalSummary? selected;
        for (final terminal in candidates) {
          if (terminal.id == _terminalId) {
            selected = terminal;
            break;
          }
        }
        if (selected == null && candidates.length == 1) {
          selected = candidates.single;
        }
        final terminalsRefreshing = widget.terminals.isRefreshing;
        final waiting = widget.sessions.workspaceSyncWaiting;
        final state = widget.sessions.workspaceSyncState;
        final completed = state?.isTerminal == true && !waiting;
        return SafeArea(
          top: false,
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              20,
              20,
              20,
              20 + MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: Column(
              key: const Key('dsh-workspace-sync-sheet'),
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '同步 DSH 工作区',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 6),
                const Text('只会同步终端已授权的工作区名称和状态。'),
                const SizedBox(height: 16),
                if (candidates.isEmpty && terminalsRefreshing)
                  const _DSHWorkspaceSyncTerminalLoading()
                else if (candidates.isEmpty)
                  _DSHWorkspaceSyncNoTerminal(
                    error: widget.terminals.errorMessage,
                  )
                else ...[
                  RadioGroup<String>(
                    groupValue: selected?.id,
                    onChanged: (value) {
                      if (!waiting) setState(() => _terminalId = value);
                    },
                    child: Column(
                      children: [
                        for (final terminal in candidates)
                          RadioListTile<String>(
                            key: Key(
                              'dsh-workspace-terminal-option-${terminal.id}',
                            ),
                            value: terminal.id,
                            enabled: !waiting,
                            title: Text(
                              terminal.hostname,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text('${terminal.platform} · 在线'),
                          ),
                      ],
                    ),
                  ),
                  if (selected != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text('将从 ${selected.hostname} 同步。'),
                    ),
                  if (terminalsRefreshing)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 8),
                      child: Text('正在更新本机终端状态…'),
                    ),
                ],
                if (waiting) ...[
                  const SizedBox(height: 8),
                  const Text('同步请求已提交，正在等待终端响应。'),
                ] else if (state?.isPending == true) ...[
                  const SizedBox(height: 8),
                  const Text('请求仍在等待终端响应，可关闭此窗口后下拉刷新查看结果。'),
                ] else if (completed) ...[
                  const SizedBox(height: 8),
                  Text(state!.isSucceeded ? '同步完成。' : '同步未完成，请检查终端状态。'),
                ],
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      key: const Key('dsh-workspace-sync-cancel'),
                      onPressed: waiting
                          ? widget.sessions.stopWaitingForDSHWorkspaceSync
                          : () => Navigator.of(context).pop(),
                      child: Text(waiting ? '停止等待' : '取消'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      key: const Key('dsh-workspace-sync-confirm'),
                      onPressed:
                          selected == null || waiting || terminalsRefreshing
                          ? null
                          : () => widget.sessions.syncDSHWorkspaces(
                              terminalId: selected!.id,
                            ),
                      child: const Text('确认同步'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _DSHWorkspaceSyncTerminalLoading extends StatelessWidget {
  const _DSHWorkspaceSyncTerminalLoading();

  @override
  Widget build(BuildContext context) => const Row(
    key: Key('dsh-workspace-sync-terminal-loading'),
    children: [
      SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
      SizedBox(width: 12),
      Expanded(child: Text('正在读取本机终端状态…')),
    ],
  );
}

class _DSHWorkspaceSyncNoTerminal extends StatelessWidget {
  const _DSHWorkspaceSyncNoTerminal({this.error});

  final String? error;

  @override
  Widget build(BuildContext context) => Column(
    key: const Key('dsh-workspace-sync-no-terminal'),
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text('没有可同步的本机终端。'),
      const SizedBox(height: 6),
      Text(
        error ??
            '需要一台在线且声明 DSH 工作区同步能力的 Agent Sessions Daemon。重启本机 Daemon 后再试。',
      ),
      const SizedBox(height: 12),
      OutlinedButton.icon(
        key: const Key('dsh-workspace-sync-open-terminals'),
        onPressed: () {
          Navigator.of(context).pop();
          if (GoRouter.maybeOf(context) != null) {
            context.push('/terminals');
          }
        },
        icon: const Icon(Icons.computer_outlined),
        label: const Text('查看终端状态'),
      ),
    ],
  );
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
  final _workspaceNameController = TextEditingController();
  String _provider = 'codex';
  String _agentPresetId = fixtureAgentPresetOptions.first.id;

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    _workspaceController.dispose();
    _workspaceNameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = ref.watch(appControllerProvider);
    final sessions = ref.watch(sessionControllerProvider);
    final fixtureMode =
        ref.read(relayRepositoryProvider) is FixtureRelayRepository;
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
                      SessionWorkspacePicker(
                        controller: sessions,
                        selectedId: _workspaceController.text,
                        canWrite: app.canManageDevices,
                        deviceId: app.currentDevice?.id,
                        directoryFlow: fixtureMode
                            ? showFixtureWorkspaceDirectoryFlow
                            : null,
                        onPick: (workspaceId) async {
                          setState(
                            () => _workspaceController.text = workspaceId,
                          );
                          return true;
                        },
                      ),
                      if (app.canManageDevices) ...[
                        const SizedBox(height: 12),
                        TextFormField(
                          key: const Key('new-session-workspace-name-input'),
                          controller: _workspaceNameController,
                          maxLength: 64,
                          decoration: const InputDecoration(
                            labelText: '新建工作区名称',
                            hintText: '例如 demo-project',
                            helperText: '仅允许授权根下的直接子目录名',
                          ),
                          validator: (value) {
                            final name = value?.trim() ?? '';
                            if (name.isEmpty) return null;
                            if (name != value ||
                                !RegExp(
                                  r'^[a-zA-Z0-9._-]{1,64}$',
                                ).hasMatch(name) ||
                                name == '.' ||
                                name == '..' ||
                                name.startsWith('.')) {
                              return '请输入合法工作区名称。';
                            }
                            return null;
                          },
                        ),
                        OutlinedButton.icon(
                          key: const Key('new-session-create-workspace-button'),
                          onPressed: sessions.isBusy
                              ? null
                              : () => _createWorkspaceByName(app, sessions),
                          icon: const Icon(Icons.create_new_folder_outlined),
                          label: const Text('新建工作区'),
                        ),
                        if (sessions.workspaceSettling) ...[
                          const SizedBox(height: 8),
                          const Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              '正在创建工作区…',
                              key: Key('new-session-workspace-pending'),
                            ),
                          ),
                        ],
                      ],
                      const SizedBox(height: 12),
                      TextFormField(
                        key: const Key('new-session-workspace-input'),
                        controller: _workspaceController,
                        decoration: const InputDecoration(labelText: '工作区 ID'),
                        validator: (value) => value?.trim().isNotEmpty == true
                            ? null
                            : '请输入工作区 ID。',
                      ),
                      const SizedBox(height: 12),
                      SessionAgentPresetSeat(
                        options: fixtureMode
                            ? fixtureAgentPresetOptions
                            : const [],
                        selectedId: _agentPresetId,
                        enabled: app.canManageDevices && !sessions.isBusy,
                        onSelected: (value) =>
                            setState(() => _agentPresetId = value),
                      ),
                      if (fixtureMode) const SizedBox(height: 12),
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

  Future<void> _createWorkspaceByName(
    AppController app,
    SessionController sessions,
  ) async {
    // 名称按钮与会话创建共用 Form 校验；先在输入层阻断路径字符，避免无效值
    // 进入异步命令队列后才显示错误，也保证 widget 回归能观察到 fail-closed 状态。
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final name = _workspaceNameController.text.trim();
    if (name.isEmpty) {
      setState(() {});
      return;
    }
    final workspace = await sessions.createWorkspaceWithName(
      name: name,
      deviceId: app.currentDevice?.id,
      canWrite: app.canManageDevices,
    );
    if (!mounted || workspace == null) return;
    setState(() {
      _workspaceController.text = workspace.id;
      _workspaceNameController.clear();
    });
  }

  Future<void> _create(AppController app, SessionController sessions) async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final session = await sessions.createSession(
      workspaceId: _workspaceController.text,
      provider: _provider,
      deviceId: app.currentDevice?.id,
      canWrite: app.canManageDevices,
      agentPresetId: ref.read(relayRepositoryProvider) is FixtureRelayRepository
          ? _agentPresetId
          : null,
      autoStart:
          ref.read(relayRepositoryProvider) is! FixtureRelayRepository &&
          // 真实链路下 opencode/dsh 都由 Daemon 在创建后自动 acquire lease 并
          // session.start（dsh 为 per-session spawn ACP 桥，见 ADR-013 §3）；
          // fixture 仓库保持手动状态机，不自动启动。
          (_provider == 'opencode' || _provider == 'dsh'),
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
    this.feedbackController,
    this.onFork,
    this.directoryFlow,
    this.initialScrollOffset = 0,
    this.onScrollOffsetChanged,
  });

  final SessionController sessions;
  final SessionRecoveryController recovery;
  final DelegationController delegations;
  final bool canWrite;
  final String? deviceId;
  final String sessionId;
  final void Function(String target) onInspectTarget;
  final SessionMessageFeedbackController? feedbackController;
  final SessionForkHandler? onFork;
  final WorkspaceDirectoryFlow? directoryFlow;
  final double initialScrollOffset;
  final ValueChanged<double>? onScrollOffsetChanged;

  @override
  Widget build(BuildContext context) {
    final projection = const SessionProjectionController().buildSnapshot(
      timeline: sessions.timeline,
      controls: sessions.controls,
    );
    // 乐观回显：canonical user.message 回传前，先把待确认的出站文本挂在时间线尾部，
    // 让发送的内容立刻可见；规范化事件合并后由 controller 清账，本节点随之消失。
    final pendingOutgoing = sessions.pendingOutgoingMessage;
    final chatNodes = [
      ...projection.chatNodes,
      if ((pendingOutgoing ?? '').isNotEmpty)
        ConversationNode(
          key: 'session-chat-pending-user',
          kind: ConversationNodeKind.user,
          sequence: 0x7fffffff,
          label: '你',
          text: pendingOutgoing,
          copyText: pendingOutgoing,
          isStreaming: true,
        ),
    ];
    // v0.5/P2：Chat 只消费 projection nodes；permission/question pending 已被投影层排除，
    // 后续由 composer chain 接管，避免消息流和 composer 双重渲染同一交互。
    final hasConversationContent =
        chatNodes.any(
          (node) =>
              node.kind == ConversationNodeKind.user ||
              node.kind == ConversationNodeKind.assistant ||
              node.kind == ConversationNodeKind.reasoning,
        ) ||
        ((pendingOutgoing ?? '').isNotEmpty);
    return SessionChatView(
      nodes: chatNodes,
      // 乐观回显挂出即视为进行中：状态行立刻出现，不等 daemon 事件回传。
      running:
          sessions.isStreaming || (sessions.pendingOutgoingMessage != null),
      // v0.8.4（ADR-015 §3）：phase-aware 状态行文案。
      turnPhase: projection.turnPhase,
      // v0.8.6 A①：客户端回合超时标记——超时横幅替代无限转圈。
      turnTimedOut: sessions.isTurnTimedOut(sessionId),
      leading: _SessionRecoveryStrip(
        controller: recovery,
        sessionId: sessionId,
      ),
      initialScrollOffset: initialScrollOffset,
      onScrollOffsetChanged: onScrollOffsetChanged,
      onInspectTarget: onInspectTarget,
      onFork: onFork,
      feedbackController: feedbackController,
      historyLoading: sessions.historyLoading,
      historyError: sessions.historyErrorMessage,
      canLoadOlder: sessions.canLoadOlder,
      onLoadOlder: sessions.loadOlderHistory,
      emptyHero: hasConversationContent
          ? null
          : _ConversationEmptyHero(
              sessions: sessions,
              canWrite: canWrite,
              deviceId: deviceId,
              directoryFlow: directoryFlow,
              onWorkspaceOpened: (sessionId) =>
                  context.go('/sessions/$sessionId'),
            ),
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
  const _ConversationEmptyHero({
    required this.sessions,
    required this.canWrite,
    required this.deviceId,
    required this.onWorkspaceOpened,
    this.directoryFlow,
  });

  final SessionController sessions;
  final bool canWrite;
  final String? deviceId;
  final ValueChanged<String> onWorkspaceOpened;
  final WorkspaceDirectoryFlow? directoryFlow;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final session = sessions.selectedSession;
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
          '从下方选择工作区开始会话',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 18),
        SessionWorkspacePicker(
          controller: sessions,
          selectedId: session?.workspaceId,
          canWrite: canWrite,
          deviceId: deviceId,
          directoryFlow: directoryFlow,
          markMissingAsDeleted: true,
          label: '选择工作区开始会话',
          onPick: (workspaceId) async {
            final opened = await sessions.openWorkspace(
              workspaceId: workspaceId,
              provider: session?.provider ?? 'codex',
              deviceId: deviceId,
              canWrite: canWrite,
              agentPresetId: session?.agentPresetId,
              autoStart: directoryFlow == null,
            );
            if (opened == null) return false;
            onWorkspaceOpened(opened.id);
            return true;
          },
        ),
        if (session?.agentPresetId != null) ...[
          const SizedBox(height: 8),
          SessionAgentPresetLabel(presetId: session?.agentPresetId),
        ],
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
class SessionDetailScreen extends ConsumerStatefulWidget {
  const SessionDetailScreen({required this.sessionId, super.key});

  final String sessionId;

  @override
  ConsumerState<SessionDetailScreen> createState() =>
      _SessionDetailScreenState();
}

class _SessionDetailScreenState extends ConsumerState<SessionDetailScreen> {
  late SessionMessageFeedbackController _feedbackController;

  @override
  void initState() {
    super.initState();
    _feedbackController = _createFeedbackController(widget.sessionId);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _selectCurrentSession(),
    );
  }

  @override
  void didUpdateWidget(covariant SessionDetailScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessionId != widget.sessionId) {
      _feedbackController.dispose();
      _feedbackController = _createFeedbackController(widget.sessionId);
      // go_router 更新同一详情 State 时仍处于 build；下一帧再通知 delegation provider，
      // 防止 child 切入触发 Riverpod 的 build 期状态修改断言。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_selectCurrentSession());
      });
    }
  }

  @override
  void dispose() {
    _feedbackController.dispose();
    super.dispose();
  }

  SessionMessageFeedbackController _createFeedbackController(String sessionId) {
    final relay = ref.read(relayRepositoryProvider);
    return SessionMessageFeedbackController(
      reader: (messageId) => relay.getMessageFeedback(sessionId, messageId),
      writer:
          ({
            required messageId,
            required rating,
            required note,
            required version,
          }) {
            if (rating == null) {
              if (version == null) {
                return Future.value(const ConversationFeedbackResult.success());
              }
              return relay.deleteMessageFeedback(
                sessionId,
                messageId: messageId,
                version: version,
              );
            }
            return relay.putMessageFeedback(
              sessionId,
              messageId: messageId,
              rating: rating,
              note: note,
              version: version,
            );
          },
    );
  }

  Future<void> _selectCurrentSession({bool force = false}) async {
    final controller = ref.read(sessionControllerProvider);
    if (force || controller.selectedSessionId != widget.sessionId) {
      await controller.selectSession(widget.sessionId);
    }
    // 打开会话即静默获取单写者租约：正常路径用户不需要感知控制权存在；
    // 失败不打断会话浏览（灰色芯片与 composer 拦截兜底），因此不上报错误。
    if (controller.selectedSessionId == widget.sessionId &&
        !controller.hasSelectedLease) {
      final app = ref.read(appControllerProvider);
      await controller.acquireSelectedLease(
        deviceId: app.currentDevice?.id,
        canWrite: app.canManageDevices,
        reportFailure: false,
      );
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
          title: _HappySessionHeaderTitle(
            session: session,
            onOpenParent: session?.parentSessionId == null
                ? null
                : () => context.go('/sessions/${session!.parentSessionId}'),
          ),
          status: _SessionStatusStrip(
            session: session,
            // v0.8.6 A③：回合在途时 header 显示"执行中"，与状态条同源，
            // 不再出现"空闲"与"处理中"并存的矛盾。
            turnInFlight: sessions.isTurnInFlight,
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
          actions: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SessionAgentPresetLabel(presetId: session?.agentPresetId),
              SessionSubagentCatalogAction(
                controller: delegations,
                parentSessionId: widget.sessionId,
                available: sessions.selectedProviderCapabilities
                    .capability('delegate_session')
                    .isSupported,
                onOpenChild: (childSessionId) async {
                  await sessions.selectSession(childSessionId);
                  if (!context.mounted) return;
                  context.go('/sessions/$childSessionId');
                },
              ),
              _SessionQuickMenu(
                sessions: sessions,
                canWrite: app.canManageDevices,
                deviceId: app.currentDevice?.id,
                sessionId: widget.sessionId,
                onRefresh: sessions.isDetailLoading || delegations.isLoading
                    ? null
                    : () => unawaited(_selectCurrentSession(force: true)),
              ),
            ],
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
                directoryFlow:
                    ref.read(relayRepositoryProvider) is FixtureRelayRepository
                    ? showFixtureWorkspaceDirectoryFlow
                    : null,
                initialScrollOffset: viewController.chatScrollOffsetFor(
                  widget.sessionId,
                ),
                onScrollOffsetChanged: (offset) => viewController
                    .setChatScrollOffset(widget.sessionId, offset),
                onInspectTarget: (target) {
                  viewController.setInspectTarget(widget.sessionId, target);
                },
                feedbackController: _feedbackController,
                onFork:
                    sessions.selectedProviderCapabilities
                        .capability('fork')
                        .isSupported
                    ? (messageId) async {
                        final child = await sessions.forkFromMessage(
                          messageId: messageId,
                          deviceId: app.currentDevice?.id,
                          canWrite: app.canManageDevices,
                        );
                        if (child == null || !context.mounted) return;
                        context.go('/sessions/${child.id}');
                      }
                    : null,
              )
            : SessionTrajectoryView(
                initialState: viewController.trajectoryStateFor(
                  widget.sessionId,
                ),
                onStateChanged: (state) =>
                    viewController.setTrajectoryState(widget.sessionId, state),
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
                  viewController.clearInspectTarget(widget.sessionId, target);
                },
              ),
        composer: session?.subagentReadOnlyReason != null
            ? SessionSubagentReadOnlyComposer(
                reason: session!.subagentReadOnlyReason!,
              )
            : _SessionComposer(
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
          case 'archive':
            _confirmArchive(
              context,
              sessions,
              canWrite: canWrite,
              deviceId: deviceId,
            );
          case 'files':
            // 文件浏览是只读页面，与 Git 入口一样不依赖 lease。
            context.push('/sessions/${sessions.selectedSessionId}/files');
        }
      },
      itemBuilder: (context) => [
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
        PopupMenuItem(
          key: Key('session-quick-fork'),
          value: 'fork',
          enabled: false,
          child: ListTile(
            leading: Icon(Icons.copy_outlined),
            title: Text('Fork 会话'),
            subtitle: Text(
              'Provider 未声明 fork 能力',
              style: Theme.of(context).textTheme.labelSmall,
            ),
            dense: true,
            contentPadding: EdgeInsets.zero,
          ),
        ),
        // v0.3/P2：duplicate 与 fork/archive 同规则——capability 未声明时 fail-closed。
        PopupMenuItem(
          key: Key('session-quick-duplicate'),
          value: 'duplicate',
          enabled: false,
          child: ListTile(
            leading: Icon(Icons.copy_all_outlined),
            title: Text('Duplicate 会话'),
            subtitle: Text(
              'Provider 未声明 duplicate 能力',
              style: Theme.of(context).textTheme.labelSmall,
            ),
            dense: true,
            contentPadding: EdgeInsets.zero,
          ),
        ),
        PopupMenuItem(
          key: Key('session-quick-archive'),
          value: 'archive',
          enabled: canWrite && !sessions.isBusy,
          child: ListTile(
            leading: Icon(Icons.archive_outlined),
            title: Text('归档会话'),
            subtitle: Text(
              '从列表隐藏，数据仍保留',
              style: Theme.of(context).textTheme.labelSmall,
            ),
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

  Future<void> _confirmArchive(
    BuildContext context,
    SessionController sessions, {
    required bool canWrite,
    required String? deviceId,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('归档会话？'),
        content: const Text('会话会从列表隐藏，但消息、事件和附件数据都会保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('session-archive-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('归档'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await sessions.archiveSelectedSession(
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
                value: _sessionStatusPresentation(session).label,
              ),
              _DetailRow(
                label: '最后活动',
                value: _relativeTime(
                  session.lastActivityAt ?? session.updatedAt,
                ),
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
              approveBlocked ?? '请先在父会话中确认可操作后重试。',
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
                const Expanded(child: Text('子会话使用独立可操作状态')),
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

/// 会话级 Plan/Goal/Skill 控制区。它只在模型设置详情中渲染，避免把任务状态
/// 挤在对话页 Header 和输入区之间；控制器变化时弹窗内仍会实时刷新。
class _SessionTaskControls extends StatelessWidget {
  const _SessionTaskControls({
    required this.sessions,
    required this.canWrite,
    required this.deviceId,
  });

  final SessionController sessions;
  final bool canWrite;
  final String? deviceId;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: sessions,
    builder: (context, _) {
      final controls = sessions.controls;
      final plan = controls.plan;
      final goal = controls.goal;
      final skill = controls.skills.where(
        (item) => item.risk == SkillRisk.high,
      );
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
      return Column(
        key: const Key('session-task-controls'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
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
                IconButton(
                  key: const Key('session-goal-clear-button'),
                  tooltip: '清除 Goal',
                  onPressed:
                      goal != null && goalBlocked == null && !sessions.isBusy
                      ? () => sessions.clearGoal(
                          deviceId: deviceId,
                          canWrite: canWrite,
                        )
                      : null,
                  icon: const Icon(Icons.clear_outlined, size: 20),
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
                    ? () {
                        sessions.requestSkillConfirmation(
                          skill.first,
                          canWrite: canWrite,
                        );
                        // 确认卡位于 composer seat；关闭详情弹窗后才可操作拒绝/确认。
                        Navigator.of(context).pop();
                      }
                    : null,
                icon: const Icon(Icons.warning_amber_outlined),
              ),
            ),
          ],
        ],
      );
    },
  );
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
  final _inputScrollController = ScrollController();
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
      // Persist the complete session-scoped input before switching. In-flight
      // attempts are intentionally discarded by the new machine instance.
      final priorSessionId = _draftSessionId;
      if (priorSessionId != null) {
        widget.sessions.saveComposerState(
          priorSessionId,
          _inputMachine.sessionState,
        );
      }
      _inputMachine = SessionComposerInputMachine();
      _restoreDraft();
      _commandMenuOpen = false;
    }
  }

  void _restoreDraft() {
    final sessionId = widget.sessions.selectedSessionId;
    if (sessionId == null) {
      _draftSessionId = null;
      _inputMachine.restoreSessionState(
        const SessionComposerSessionState.empty(),
      );
      _setControllerText('');
      return;
    }
    if (_draftSessionId == sessionId) return;
    _draftSessionId = sessionId;
    final state = widget.sessions.composerStateFor(sessionId);
    _inputMachine.restoreSessionState(state);
    if (state.draft != _controller.text) {
      _setControllerText(state.draft);
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
    final sessionId = widget.sessions.selectedSessionId ?? _draftSessionId;
    if (sessionId != null) {
      widget.sessions.saveComposerState(sessionId, _inputMachine.sessionState);
    }
    _controller.removeListener(_onControllerSelectionChanged);
    _focusNode.dispose();
    _inputScrollController.dispose();
    _controller.dispose();
    super.dispose();
  }

  KeyEventResult _handleComposerKey(KeyEvent event) {
    final enter =
        event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter;
    final shortcut =
        HardwareKeyboard.instance.isMetaPressed ||
        HardwareKeyboard.instance.isControlPressed;

    if (event is KeyDownEvent && shortcut) {
      if (event.logicalKey == LogicalKeyboardKey.keyZ) {
        final changed = HardwareKeyboard.instance.isShiftPressed
            ? _inputMachine.redo()
            : _inputMachine.undo();
        if (changed) _syncControllerFromMachine();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.keyC ||
          event.logicalKey == LogicalKeyboardKey.keyX) {
        final selection = _controller.selection;
        if (!selection.isValid || selection.isCollapsed) {
          return KeyEventResult.ignored;
        }
        unawaited(
          _copyOrCutSelection(cut: event.logicalKey == LogicalKeyboardKey.keyX),
        );
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.keyV) {
        unawaited(_pasteClipboard());
        return KeyEventResult.handled;
      }
    }

    if (event is KeyDownEvent &&
        !shortcut &&
        (event.logicalKey == LogicalKeyboardKey.backspace ||
            event.logicalKey == LogicalKeyboardKey.delete)) {
      final selection = _controller.selection;
      if (selection.isValid &&
          selection.isCollapsed &&
          _inputMachine.deleteReferenceNearCaret(
            caret: selection.extentOffset,
            backwards: event.logicalKey == LogicalKeyboardKey.backspace,
          )) {
        _syncControllerFromMachine(caret: selection.extentOffset);
        return KeyEventResult.handled;
      }
    }

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
    _revealCaret(caret);
    _updateSuggestions();
  }

  void _revealCaret(int caret) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_inputScrollController.hasClients) return;
      if (caret >= _controller.text.length) {
        _inputScrollController.jumpTo(
          _inputScrollController.position.maxScrollExtent,
        );
      }
    });
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
    var caret = hit.start + replacement.length;
    if (suggestion.kind == _CompletionKind.file) {
      final label = replacement.trim().replaceFirst('@', '');
      final inserted = _inputMachine.insertReference(
        label: label,
        clipboardText: '@file:$label',
        start: hit.start,
        end: hit.end,
        draftRevision: _inputMachine.snapshot.draftRevision,
      );
      if (!inserted) return;
      final reference = _inputMachine.snapshot.references
          .where((item) => item.offset == hit.start)
          .firstOrNull;
      caret = reference?.end ?? caret;
      final draft = _inputMachine.snapshot.draft;
      if (caret < draft.length && draft[caret] == ' ') caret += 1;
    } else {
      final claimed = _inputMachine.beginCommand(
        token: replacement,
        start: hit.start,
        end: hit.end,
        draftRevision: _inputMachine.snapshot.draftRevision,
      );
      if (!claimed) {
        _inputMachine.setDraft(
          text.replaceRange(hit.start, hit.end, replacement),
        );
      }
    }
    final next = _inputMachine.snapshot.draft;
    _controller.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: caret.clamp(0, next.length)),
    );
    setState(() {});
    final sessionId = widget.sessions.selectedSessionId;
    if (sessionId != null) {
      widget.sessions.saveComposerState(sessionId, _inputMachine.sessionState);
    }
    _updateSuggestions();
  }

  void _syncControllerFromMachine({int? caret}) {
    final draft = _inputMachine.snapshot.draft;
    final offset = (caret ?? draft.length).clamp(0, draft.length);
    _controller.value = TextEditingValue(
      text: draft,
      selection: TextSelection.collapsed(offset: offset),
    );
    final sessionId = widget.sessions.selectedSessionId;
    if (sessionId != null) {
      widget.sessions.saveComposerState(sessionId, _inputMachine.sessionState);
    }
    _updateSuggestions();
    setState(() {});
  }

  Future<void> _copyOrCutSelection({required bool cut}) async {
    final selection = _controller.selection;
    if (!selection.isValid || selection.isCollapsed) return;
    final start = selection.start;
    final end = selection.end;
    final text = cut
        ? _inputMachine.cutRange(start, end)
        : _inputMachine.projectClipboard(start: start, end: end);
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted || !cut) return;
    _syncControllerFromMachine(caret: start);
  }

  Future<void> _pasteClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    final pasted = data?.text;
    if (pasted == null || pasted.isEmpty) return;
    final selection = _controller.selection;
    final start = selection.isValid ? selection.start : _controller.text.length;
    final end = selection.isValid ? selection.end : _controller.text.length;
    var upgraded = false;
    if (pasted.startsWith('@file:') && pasted.length > '@file:'.length) {
      final target = pasted.substring('@file:'.length);
      final label = target
          .split('/')
          .where((part) => part.isNotEmpty)
          .lastOrNull;
      if (label != null) {
        upgraded = _inputMachine.pasteUpgradeReference(
          label: label,
          clipboardText: pasted,
          start: start,
          end: end,
          draftRevision: _inputMachine.snapshot.draftRevision,
        );
      }
    }
    if (!upgraded) {
      final current = _inputMachine.snapshot.draft;
      _inputMachine.setDraft(
        current.replaceRange(start, end, pasted),
        start: start,
        end: end,
        insertedLength: pasted.length,
      );
    }
    _syncControllerFromMachine(caret: start + pasted.length);
  }

  void _focusComposer() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _focusNode.canRequestFocus) _focusNode.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    final blocked = widget.sessions.composerBlockedReason(
      canWrite: widget.canWrite,
    );
    final streaming = widget.sessions.isStreaming;
    // 回合在途（send 受理即置位，终态/中断/切会话才清除）+ 乐观回显窗口，
    // 两者共同决定"运行中"；不受 status 尚未翻到 streaming 的受理窗口影响。
    final running =
        streaming ||
        widget.sessions.isTurnInFlight ||
        widget.sessions.pendingOutgoingMessage != null;
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
    final canStop = blocked == null && running && !widget.sessions.isBusy;
    // 运行中且草稿已清空：主按钮即中断按钮（用户请求：发送后可一键中断当前
    // 任务）。草稿非空时保留 queue/steer 语义，中断走独立停止按钮。
    final primaryIsStop = running && input.draft.trim().isEmpty && canStop;
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
    // input.dock（Todo/Queue）必须让位，避免长 takeover 面板被 dock 挤出可触达区域。
    final hasComposerTakeover =
        pendingQuestion != null || pendingPermission != null;
    return SafeArea(
      top: false,
      child: Container(
        key: const Key('session-composer'),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
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
              SessionComposerChain(
                pendingQuestion: pendingQuestion,
                pendingPermission: pendingPermission,
                canWrite: widget.canWrite,
                hasLease: widget.sessions.hasSelectedLease,
                sessions: widget.sessions,
                deviceId: widget.deviceId,
              ),
            if (!hasComposerTakeover)
              SessionTodoDock(todos: widget.sessions.controls.todos),
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
                    widget.sessions.saveComposerState(
                      sessionId,
                      _inputMachine.sessionState,
                    );
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
                // 胶囊圆角与投影收口为全局 token，避免第二处硬编码扩散。
                borderRadius: BorderRadius.circular(AppRadius.pill),
                boxShadow: AppShadows.composerPill,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  IconButton(
                    key: const Key('session-command-launcher'),
                    tooltip: '命令',
                    onPressed: () {
                      setState(() => _commandMenuOpen = !_commandMenuOpen);
                      _focusComposer();
                    },
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
                        ? () async {
                            await widget.sessions.pickAttachment(
                              deviceId: widget.deviceId,
                              canWrite: widget.canWrite,
                            );
                            _focusComposer();
                          }
                        : null,
                    icon: const Icon(Icons.attach_file),
                  ),
                  Expanded(
                    child: TextField(
                      key: const Key('session-composer-input'),
                      controller: _controller,
                      focusNode: _focusNode,
                      scrollController: _inputScrollController,
                      enabled: blocked == null,
                      readOnly: machineBusy,
                      minLines: 1,
                      maxLines: 5,
                      textInputAction: TextInputAction.newline,
                      scrollPadding: const EdgeInsets.only(bottom: 120),
                      onTapOutside: (_) {
                        if (_commandMenuOpen || _completionActive) {
                          setState(() {
                            _commandMenuOpen = false;
                            _completionActive = false;
                            _suggestions = const [];
                          });
                        }
                        _focusNode.unfocus();
                      },
                      onChanged: (value) {
                        _inputMachine.setDraft(value);
                        setState(() {});
                        // 每次输入都写内存草稿；发送成功后由 controller 清除。
                        final sessionId = widget.sessions.selectedSessionId;
                        if (sessionId != null) {
                          widget.sessions.saveComposerState(
                            sessionId,
                            _inputMachine.sessionState,
                          );
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
                    tooltip: primaryIsStop ? '中断当前任务' : primaryTooltip,
                    onPressed: primaryIsStop
                        ? () async {
                            await _stop();
                            _focusComposer();
                          }
                        : canSubmit
                        ? () async {
                            await _submitComposer();
                            _focusComposer();
                          }
                        : null,
                    style: IconButton.styleFrom(
                      backgroundColor: primaryIsStop
                          ? Theme.of(context).colorScheme.errorContainer
                          : canSubmit
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(
                              context,
                            ).colorScheme.surfaceContainerHighest,
                      foregroundColor: primaryIsStop
                          ? Theme.of(context).colorScheme.error
                          : canSubmit
                          ? Theme.of(context).colorScheme.onPrimary
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    icon: Icon(
                      primaryIsStop
                          ? Icons.stop
                          : submitMode == SessionSubmitMode.send
                          ? Icons.arrow_upward
                          : Icons.schedule_send_outlined,
                    ),
                  ),
                  if (running && input.draft.trim().isNotEmpty)
                    IconButton(
                      key: const Key('session-stop-button'),
                      tooltip: '停止生成',
                      onPressed: canStop
                          ? () async {
                              await _stop();
                              _focusComposer();
                            }
                          : null,
                      icon: const Icon(Icons.stop_circle_outlined),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 5),
            _HappyComposerMetaRow(
              sessions: widget.sessions,
              canWrite: widget.canWrite,
              deviceId: widget.deviceId,
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
  /// 再追加 `goal.created` 并更新模型设置中的 Goal 投影。失败时保留原草稿与 claim。
  Future<void> _submitGoalCommand(
    String message,
    String? sessionId,
    String attemptToken,
  ) async {
    final objective = message.trimLeft().substring('/goal'.length).trim();
    if (objective.isEmpty) {
      _inputMachine.settleSubmit(
        success: false,
        error: '请输入 /goal 后的目标文本。',
        attemptToken: attemptToken,
      );
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
      final settled = _inputMachine.settleSubmit(
        success: false,
        error: error,
        attemptToken: attemptToken,
      );
      if (sessionId != null) {
        widget.sessions.saveComposerState(
          sessionId,
          _inputMachine.sessionState,
        );
      }
      _setControllerText(settled ? message : _inputMachine.snapshot.draft);
      setState(() {});
      return;
    }
    final settled = _inputMachine.settleSubmit(
      success: true,
      attemptToken: attemptToken,
    );
    if (!settled) {
      _setControllerText(_inputMachine.snapshot.draft);
      setState(() {});
      return;
    }
    if (sessionId != null) {
      widget.sessions.saveComposerState(sessionId, _inputMachine.sessionState);
    }
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
        if (sessionId != null) {
          widget.sessions.saveComposerState(
            sessionId,
            _inputMachine.sessionState,
          );
        }
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
        final attemptToken = _inputMachine.beginAdjudication();
        if (attemptToken == null ||
            !_inputMachine.enterSubmitting(attemptToken: attemptToken)) {
          return;
        }
        setState(() {});
        if (_isGoalCommand(message)) {
          await _submitGoalCommand(message, sessionId, attemptToken);
          return;
        }
        // 受理即返回（awaitTurnCompletion=false）：命令确认 + 首批快照后
        // 立刻清空输入框并把主按钮切换为"中断"；回合完成由后台轮询收敛。
        await widget.sessions.sendMessage(
          message: message,
          deviceId: widget.deviceId,
          canWrite: widget.canWrite,
          awaitTurnCompletion: false,
        );
        if (!mounted) return;
        final error = widget.sessions.errorMessage;
        if (error != null) {
          final settled = _inputMachine.settleSubmit(
            success: false,
            error: error,
            attemptToken: attemptToken,
          );
          if (sessionId != null) {
            widget.sessions.saveComposerState(
              sessionId,
              _inputMachine.sessionState,
            );
          }
          _setControllerText(settled ? message : _inputMachine.snapshot.draft);
          setState(() {});
          return;
        }
        final settled = _inputMachine.settleSubmit(
          success: true,
          attemptToken: attemptToken,
        );
        if (!settled) {
          _setControllerText(_inputMachine.snapshot.draft);
          setState(() {});
          return;
        }
        _setControllerText('');
        _setSuggestions(const []);
        setState(() {});
      case SessionSubmitMode.steer:
        // Strict steer is an explicit placement into the active provider turn.
        // The existing session.send relay path carries the opaque message and
        // lets the adapter decide whether the provider accepts steering.
        if (message.isEmpty) return;
        final attemptToken = _inputMachine.beginAdjudication();
        if (attemptToken == null ||
            !_inputMachine.enterSubmitting(attemptToken: attemptToken)) {
          return;
        }
        setState(() {});
        await widget.sessions.sendMessage(
          message: message,
          deviceId: widget.deviceId,
          canWrite: widget.canWrite,
        );
        if (!mounted) return;
        final error = widget.sessions.errorMessage;
        if (error != null) {
          final settled = _inputMachine.settleSubmit(
            success: false,
            error: error,
            attemptToken: attemptToken,
          );
          if (sessionId != null) {
            widget.sessions.saveComposerState(
              sessionId,
              _inputMachine.sessionState,
            );
          }
          _setControllerText(settled ? message : _inputMachine.snapshot.draft);
          setState(() {});
          return;
        }
        final settled = _inputMachine.settleSubmit(
          success: true,
          attemptToken: attemptToken,
        );
        if (!settled) {
          _setControllerText(_inputMachine.snapshot.draft);
          setState(() {});
          return;
        }
        _setControllerText('');
        _setSuggestions(const []);
        setState(() {});
    }
  }

  void _persistComposerState() {
    final sessionId = widget.sessions.selectedSessionId ?? _draftSessionId;
    if (sessionId == null) return;
    widget.sessions.saveComposerState(sessionId, _inputMachine.sessionState);
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
      setState(() {
        _inputMachine.removeQueuedMessage(item.id);
        _persistComposerState();
      });
      if (widget.sessions.isStreaming) break;
    }
  }

  /// v0.5/P5：逐条 strict steer——只把指定排队项作为显式动作发送，
  /// 其余队列保留；发送成功才移除该项，失败保留并在 composer notice 呈现。
  Future<void> _steerQueuedMessages(String id) async {
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
    setState(() {
      _inputMachine.removeQueuedMessage(item.id);
      _persistComposerState();
    });
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
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        key: const Key('session-command-launcher-menu'),
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        shape: RoundedRectangleBorder(
          side: BorderSide(color: Theme.of(context).dividerColor),
          borderRadius: BorderRadius.circular(8),
        ),
        clipBehavior: Clip.antiAlias,
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

/// v0.2/P3：模型与推理等级由 Composer 单行状态入口承载；此处只保留权限模式。
/// 所有写入口继续按 capability、设备角色和 lease fail-closed。
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
    final permissionCapability = sessions.selectedProviderCapabilities
        .capability('permission_mode');
    final shouldShow =
        controls.availablePermissionModes.isNotEmpty ||
        permissionCapability.isSupported;
    if (!shouldShow) return const SizedBox.shrink();
    final permissionModeBlocked = sessions.controlBlockedReason(
      'permission_mode',
      canWrite: canWrite,
    );
    return Padding(
      key: const Key('composer-control-strip'),
      padding: const EdgeInsets.only(bottom: 6),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 190),
        child: DropdownButtonFormField<String>(
          key: const Key('composer-permission-mode-select'),
          initialValue: controls.permissionMode,
          isDense: true,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: '权限',
            // v0.8.6 B：目录为空时的禁用必须附原因——不再渲染无解释空壳
            //（目录未同步时提示恢复路径：启动会话后自动获取）。
            helperText: sessions.permissionDirectoryHint ?? ' ',
            helperMaxLines: 2,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
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

class _ReadOnlyBanner extends StatelessWidget {
  const _ReadOnlyBanner();

  @override
  Widget build(BuildContext context) => Container(
    key: const Key('session-readonly-banner'),
    // 提示条统一 note 档 padding=12。
    padding: const EdgeInsets.all(12),
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
    required this.turnInFlight,
    required this.hasLease,
    required this.canWrite,
    required this.provider,
    required this.onAcquireLease,
  });

  final MobileSession? session;

  /// v0.8.6 A③：回合在途（客户端视角）。session.status 投影只由 canonical
  /// 事件驱动，回合启动后到首个 step 事件之间恒为 idle——这里用它把 header
  /// 状态行同源收敛为"执行中"。
  final bool turnInFlight;
  final bool hasLease;
  final bool canWrite;

  /// v0.3/P1：Provider 能力快照（version/available/reason 白名单），用于连接态与版本提示。
  final ProviderCapabilityProfile provider;
  final VoidCallback? onAcquireLease;

  @override
  Widget build(BuildContext context) {
    final status = _sessionStatusPresentation(session, turnInFlight: turnInFlight);
    final statusColor = _sessionStatusColor(context, status.tone);
    // v0.9：lease 在写操作时自动获取（见 SessionController._submitCommand），
    // 不再是需要用户手动点按的前置状态；这里只区分只读与可写。
    final leaseText = !canWrite ? '只读' : '可操作';
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
      padding: EdgeInsets.zero,
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
        child: Row(
          children: [
            Container(
              width: AppSizes.statusDot,
              height: AppSizes.statusDot,
              decoration: BoxDecoration(
                color: statusColor,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                status.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ),
            Flexible(
              fit: FlexFit.loose,
              child: Tooltip(
                message: providerTooltip,
                child: Container(
                  key: const Key('session-provider-version-chip'),
                  constraints: const BoxConstraints(maxWidth: 142),
                  margin: const EdgeInsets.only(right: 6),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: providerConnected
                        ? Theme.of(context).colorScheme.surfaceContainerHigh
                        : Theme.of(context).colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(AppRadius.small),
                  ),
                  child: Text(
                    providerLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: providerConnected
                          ? null
                          : Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ),
            ),
            Flexible(
              fit: FlexFit.loose,
              child: Container(
                constraints: const BoxConstraints(maxWidth: 108),
                margin: const EdgeInsets.only(right: 2),
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                decoration: BoxDecoration(
                  color: hasLease
                      ? context.appColors.success.withValues(alpha: 0.14)
                      : Theme.of(context).colorScheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(AppRadius.small),
                ),
                child: Text(
                  leaseText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: hasLease ? context.appColors.success : null,
                  ),
                ),
              ),
            ),
            // v0.9：写权（lease）在提交命令时自动获取；此处保留可点入口仅作
            // 兜底（行为与打开会话时自动获取一致），不再显示“暂不可操作”提示。
            IconButton(
              key: const Key('session-acquire-lease-button'),
              tooltip: hasLease ? '会话可操作' : '获取会话操作权',
              visualDensity: VisualDensity.compact,
              onPressed: canWrite && !hasLease ? onAcquireLease : null,
              icon: Icon(
                hasLease
                    ? Icons.check_circle_outline
                    : canWrite
                    ? Icons.autorenew
                    : Icons.lock_outline,
                size: 18,
                color: hasLease
                    ? context.appColors.success
                    : Theme.of(context).colorScheme.outline,
              ),
            ),
          ],
        ),
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
    label: '已同步',
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
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.errorContainer,
      border: Border.all(color: Theme.of(context).colorScheme.error),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Row(
      children: [
        const Icon(Icons.error_outline),
        const SizedBox(width: 12),
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
          width: AppSizes.statusDot,
          height: AppSizes.statusDot,
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
  const _HappySessionHeaderTitle({
    required this.session,
    required this.onOpenParent,
  });

  final MobileSession? session;
  final VoidCallback? onOpenParent;

  @override
  Widget build(BuildContext context) => Column(
    key: const Key('happy-session-header'),
    mainAxisAlignment: MainAxisAlignment.center,
    crossAxisAlignment: CrossAxisAlignment.center,
    children: [
      Row(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (session?.parentSessionId != null && onOpenParent != null) ...[
            SessionSubagentBreadcrumb(
              parentSessionId: session?.parentSessionId,
              onOpenParent: onOpenParent!,
            ),
            const SizedBox(width: 4),
          ],
          Flexible(
            child: Text(
              '新对话',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
      // v0.8.5 §1.3 修复：副标题第二行显示真实工作区显示名（Relay 下发的
      // workspace_name）。workspace 缺失/为空时显示占位文案，绝不回退到写死的
      // 'agent-sessions' 或伪造本地路径（旧版恒显示错误名字的根因）。
      Text(
        session?.workspaceName?.trim().isNotEmpty == true
            ? session!.workspaceName!.trim()
            : '未知工作区',
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
      // DeepSeek Harness：ACP 桥接入，使用 hub 图形区分于终端形态的 OpenCode。
      'dsh' => Icons.hub_outlined,
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
  const _HappyComposerMetaRow({
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
    final capabilities = sessions.selectedProviderCapabilities;
    final modelCapability = capabilities.capability('model_select');
    // 新会话刚启动时 usage 投影可能尚未落库；此时只采用 Host 在能力矩阵中
    // 明确声明且属于目录的默认项，不根据 Provider 名称猜测付费模型。
    final modelOptions = controls.models.isNotEmpty
        ? controls.models
        : modelCapability.options;
    final modelGroups = controls.modelGroups.isNotEmpty
        ? controls.modelGroups
        : modelCapability.modelGroups;
    final selectedModel =
        controls.model ??
        controls.defaultModel ??
        modelCapability.defaultOption;
    final modelDetail = selectedModel == null
        ? null
        : capabilities.modelDetailFor('model_select', selectedModel);
    return SessionModelSeat(
      key: const Key('happy-session-model-row'),
      provider: sessions.selectedSession?.provider,
      providerVersion: capabilities.version,
      providerAvailable: capabilities.available,
      capabilities: [
        for (final name in const [
          'model_select',
          'effort_select',
          'plan',
          'goal',
          'invoke_skill',
          'attachments',
        ])
          capabilities.capability(name),
      ],
      catalog: SessionModelCatalog(
        model: selectedModel,
        effort: controls.effort,
        models: modelOptions,
        efforts: controls.efforts,
        groups: modelGroups,
      ),
      modelCapability: modelCapability,
      effortCapability: capabilities.capability('effort_select'),
      modelBlockedReason: sessions.controlBlockedReason(
        'model_select',
        canWrite: canWrite,
      ),
      effortBlockedReason: sessions.controlBlockedReason(
        'effort_select',
        canWrite: canWrite,
      ),
      busy: sessions.isBusy,
      modelDetail: modelDetail,
      usage: controls.usage,
      effortsByModel: sessions.modelEffortsMemory,
      taskControls: _SessionTaskControls(
        sessions: sessions,
        canWrite: canWrite,
        deviceId: deviceId,
      ),
      onRefresh: () async {
        final error = await sessions.refreshSelectedControls();
        final refreshed = sessions.controls;
        return SessionModelCatalogRefresh(
          catalog: SessionModelCatalog(
            model:
                refreshed.model ??
                refreshed.defaultModel ??
                modelCapability.defaultOption,
            effort: refreshed.effort,
            models: refreshed.models.isNotEmpty
                ? refreshed.models
                : modelCapability.options,
            efforts: refreshed.efforts,
            groups: refreshed.modelGroups.isNotEmpty
                ? refreshed.modelGroups
                : modelCapability.modelGroups,
          ),
          error: error,
        );
      },
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

/// 会话卡片状态行：状态仅来自 Relay/Terminal，会附上可选的最后活动相对时间。
String _sessionStatusLineText(MobileSession session) {
  final presentation = _sessionStatusPresentation(session);
  final time = _relativeTime(session.lastActivityAt ?? session.updatedAt);
  return time.isEmpty ? presentation.label : '${presentation.label} · $time';
}

/// 会话状态完全来自 Relay/Terminal，上次活动时间不参与状态推断。
/// v0.8.6 A③：回合在途而 status 投影尚未收到任何 step 事件时（恒 idle 的
/// 窗口期），header 显示"执行中"——与状态条/相位行同源，消除矛盾表面。
_SessionStatusPresentation _sessionStatusPresentation(
  MobileSession? session, {
  bool turnInFlight = false,
}) {
  final status = session?.status;
  if (turnInFlight && status == MobileSessionStatus.idle) {
    return const _SessionStatusPresentation(
      label: '执行中',
      tone: _SessionStatusTone.info,
      icon: Icons.autorenew_outlined,
    );
  }
  return switch (status) {
    MobileSessionStatus.idle => const _SessionStatusPresentation(
      label: '空闲',
      tone: _SessionStatusTone.neutral,
      icon: Icons.pause_circle_outline,
    ),
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
}

String _relativeTime(DateTime? value) {
  if (value == null) return '';
  final difference = DateTime.now().difference(value).abs();
  if (difference.inMinutes < 1) return '刚刚';
  if (difference.inHours < 1) return '${difference.inMinutes} 分钟';
  if (difference.inDays < 1) return '${difference.inHours} 小时';
  return '${difference.inDays} 天';
}
