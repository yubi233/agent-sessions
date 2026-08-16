import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../app/providers.dart';
import '../domain/control_models.dart';
import '../domain/delegation_models.dart';
import '../domain/session_models.dart';
import '../state/app_controller.dart';
import '../state/delegation_controller.dart';
import '../state/lifecycle_recovery_controller.dart';
import '../state/session_controller.dart';
import 'appearance_controls.dart';
import 'app_theme.dart';

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
            tooltip: '退出登录',
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
  final _formKey = GlobalKey<FormState>();
  final _workspaceController = TextEditingController(text: 'fixture-workspace');
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
    final session = sessions.selectedSession;
    return Scaffold(
      key: const Key('session-detail-screen'),
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        title: _SessionHeaderTitle(title: session?.title ?? '会话'),
        leading: IconButton(
          key: const Key('session-detail-back-button'),
          tooltip: '返回会话列表',
          onPressed: () => context.go('/home'),
          icon: const Icon(Icons.arrow_back),
        ),
        actions: [
          const AppearanceMenu(),
          // Git 入口始终只读，不依赖 Android lease；实际数据读取仍由独立 Daemon Git RPC 边界裁决。
          IconButton(
            key: const Key('session-open-git-button'),
            tooltip: '查看 Git 变更',
            onPressed: () => context.push('/sessions/${widget.sessionId}/git'),
            icon: const Icon(Icons.difference_outlined),
          ),
          _SessionQuickMenu(
            sessions: sessions,
            canWrite: app.canManageDevices,
            deviceId: app.currentDevice?.id,
          ),
          IconButton(
            key: const Key('session-acquire-lease-button'),
            tooltip: sessions.hasSelectedLease ? '已获得控制权' : '获取会话控制权',
            onPressed: app.canManageDevices && !sessions.isBusy
                ? () => sessions.acquireSelectedLease(
                    deviceId: app.currentDevice?.id,
                    canWrite: app.canManageDevices,
                  )
                : null,
            icon: Icon(
              sessions.hasSelectedLease
                  ? Icons.lock_open_outlined
                  : Icons.lock_outline,
            ),
          ),
          IconButton(
            key: const Key('session-refresh-button'),
            tooltip: '刷新会话',
            onPressed: sessions.isDetailLoading || delegations.isLoading
                ? null
                : () => unawaited(_selectCurrentSession(force: true)),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Column(
              children: [
                // 顶部控制面和 composer 都可能随 capability/附件状态增长；将顶部限制为可滚动区域，
                // 保证 480x960 与键盘压缩后的窗口仍保留时间线和输入入口，不发生纵向溢出。
                Flexible(
                  fit: FlexFit.loose,
                  child: SingleChildScrollView(
                    key: const Key('session-detail-controls-scroll'),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _SessionStatusStrip(
                          session: session,
                          hasLease: sessions.hasSelectedLease,
                          canWrite: app.canManageDevices,
                          provider: sessions.selectedProviderCapabilities,
                        ),
                        _SessionRecoveryStrip(
                          controller: recovery,
                          sessionId: widget.sessionId,
                        ),
                        _DelegationPanel(
                          controller: delegations,
                          sessions: sessions,
                          canWrite: app.canManageDevices,
                          deviceId: app.currentDevice?.id,
                          onDecision: (delegation, decision) async {
                            final result = await delegations.decide(
                              delegation: delegation,
                              decision: decision,
                              capabilities: sessions.capabilityMatrix,
                              canWrite: app.canManageDevices,
                              deviceId: app.currentDevice?.id,
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
                        _SessionControlPanel(
                          sessions: sessions,
                          canWrite: app.canManageDevices,
                          deviceId: app.currentDevice?.id,
                        ),
                        if (sessions.skillConfirmation != null)
                          _SkillConfirmationCard(
                            confirmation: sessions.skillConfirmation!,
                            sessions: sessions,
                            canWrite: app.canManageDevices,
                            deviceId: app.currentDevice?.id,
                          ),
                        if (sessions.errorMessage != null)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                            child: _InlineError(
                              key: const Key('session-detail-error-message'),
                              message: sessions.errorMessage!,
                              onRetry: sessions.clearError,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: sessions.isDetailLoading && session == null
                      ? const Center(child: CircularProgressIndicator())
                      : _SessionTimelineList(
                          events: sessions.timeline,
                          canWrite: app.canManageDevices,
                          hasLease: sessions.hasSelectedLease,
                          sessions: sessions,
                          deviceId: app.currentDevice?.id,
                        ),
                ),
                _SessionComposer(
                  sessions: sessions,
                  canWrite: app.canManageDevices,
                  deviceId: app.currentDevice?.id,
                  // @ 补全的文件名目录：只读 repository 根列表；失败返回空（fail-closed）。
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
              ],
            ),
          ),
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
  });

  final SessionController sessions;
  final bool canWrite;
  final String? deviceId;

  @override
  Widget build(BuildContext context) {
    final resumeBlocked = sessions.resumeBlockedReason(canWrite: canWrite);
    return PopupMenuButton<String>(
      key: const Key('session-quick-menu-button'),
      tooltip: '会话操作',
      onSelected: (value) {
        switch (value) {
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
          case 'files':
            // 文件浏览是只读页面，与 Git 入口一样不依赖 lease。
            context.push('/sessions/${sessions.selectedSessionId}/files');
        }
      },
      itemBuilder: (context) => [
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

class _SessionTimelineList extends StatefulWidget {
  const _SessionTimelineList({
    required this.events,
    required this.canWrite,
    required this.hasLease,
    required this.sessions,
    required this.deviceId,
  });

  final List<SessionTimelineEvent> events;
  final bool canWrite;
  final bool hasLease;
  final SessionController sessions;
  final String? deviceId;

  @override
  State<_SessionTimelineList> createState() => _SessionTimelineListState();
}

class _SessionTimelineListState extends State<_SessionTimelineList> {
  final _scrollController = ScrollController();

  @override
  void didUpdateWidget(covariant _SessionTimelineList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.events.length != widget.events.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scrollController.hasClients) return;
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
        );
      });
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.events.isEmpty) {
      return const _TimelineEmptyState();
    }
    return ListView.separated(
      key: const Key('session-timeline-scroll'),
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      itemCount: widget.events.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final event = widget.events[index];
        return _TimelineEventItem(
          event: event,
          canWrite: widget.canWrite,
          hasLease: widget.hasLease,
          sessions: widget.sessions,
          deviceId: widget.deviceId,
        );
      },
    );
  }
}

class _TimelineEventItem extends StatelessWidget {
  const _TimelineEventItem({
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
    return switch (event.kind) {
      SessionTimelineKind.userMessage => _MessageBubble(
        key: Key('timeline-user-${event.sequence}'),
        event: event,
        isUser: true,
      ),
      SessionTimelineKind.assistantMessage => _MessageBubble(
        key: Key('timeline-assistant-${event.sequence}'),
        event: event,
        isUser: false,
      ),
      SessionTimelineKind.toolActivity => _ToolActivityItem(event: event),
      SessionTimelineKind.permissionRequest => _PermissionRequestItem(
        event: event,
        canWrite: canWrite,
        hasLease: hasLease,
        sessions: sessions,
        deviceId: deviceId,
      ),
      SessionTimelineKind.questionRequest => _QuestionRequestItem(
        event: event,
        canWrite: canWrite,
        hasLease: hasLease,
        sessions: sessions,
        deviceId: deviceId,
      ),
      SessionTimelineKind.systemNotice ||
      SessionTimelineKind.encryptedPlaceholder => _SystemNotice(event: event),
    };
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.event, required this.isUser, super.key});

  final SessionTimelineEvent event;
  final bool isUser;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final background = isUser
        ? scheme.secondaryContainer
        : scheme.surfaceContainerHigh;
    final foreground = isUser ? scheme.onSecondaryContainer : scheme.onSurface;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 382),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              event.label,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: foreground.withValues(alpha: 0.72),
              ),
            ),
            if (event.text != null) ...[
              const SizedBox(height: 4),
              Text(event.text!, style: TextStyle(color: foreground)),
            ],
            if (event.isStreaming) ...[
              const SizedBox(height: 8),
              const _StreamingIndicator(),
            ],
          ],
        ),
      ),
    );
  }
}

class _StreamingIndicator extends StatelessWidget {
  const _StreamingIndicator();

  @override
  Widget build(BuildContext context) => Row(
    key: const Key('assistant-streaming-indicator'),
    mainAxisSize: MainAxisSize.min,
    children: [
      SizedBox(
        width: 12,
        height: 12,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: Theme.of(context).colorScheme.secondary,
        ),
      ),
      const SizedBox(width: 8),
      const Text('生成中'),
    ],
  );
}

class _ToolActivityItem extends StatelessWidget {
  const _ToolActivityItem({required this.event});

  final SessionTimelineEvent event;

  @override
  Widget build(BuildContext context) => Material(
    key: Key('tool-activity-${event.sequence}'),
    color: Theme.of(context).colorScheme.surfaceContainer,
    shape: RoundedRectangleBorder(
      side: BorderSide(color: Theme.of(context).dividerColor),
      borderRadius: BorderRadius.circular(8),
    ),
    clipBehavior: Clip.antiAlias,
    child: ExpansionTile(
      tilePadding: const EdgeInsets.symmetric(horizontal: 12),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
      leading: const Icon(Icons.construction_outlined),
      title: Text(event.label),
      subtitle: Text(event.toolStatus ?? '处理中'),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Text(event.text ?? '工具活动不包含可展示的参数。'),
        ),
      ],
    ),
  );
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
              if (pending)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(permission.summary),
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
  final _customAnswerController = TextEditingController();
  String? _selectedAnswer;

  @override
  void dispose() {
    _customAnswerController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final question = widget.event.question;
    if (question == null) return _SystemNotice(event: widget.event);
    final resolved =
        question.resolved == true ||
        widget.sessions.isRequestResolved('question', question.requestId);
    final pending = widget.sessions.isRequestPending(question.requestId);
    final enabled = widget.canWrite && widget.hasLease && !resolved && !pending;
    final answer = _customAnswerController.text.trim().isNotEmpty
        ? _customAnswerController.text.trim()
        : _selectedAnswer;
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
                child: Text(
                  question.prompt,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ],
          ),
          if (question.options.isNotEmpty) ...[
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              key: Key('question-options-${question.requestId}'),
              initialValue: _selectedAnswer,
              decoration: const InputDecoration(labelText: '选择回答'),
              items: question.options
                  .map(
                    (option) =>
                        DropdownMenuItem(value: option, child: Text(option)),
                  )
                  .toList(growable: false),
              onChanged: enabled
                  ? (value) => setState(() => _selectedAnswer = value)
                  : null,
            ),
          ],
          if (question.allowsFreeform) ...[
            const SizedBox(height: 8),
            TextField(
              key: Key('question-freeform-${question.requestId}'),
              controller: _customAnswerController,
              enabled: enabled,
              maxLines: 2,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(labelText: '或输入回答'),
            ),
          ],
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerRight,
            child: IconButton(
              key: Key('question-submit-${question.requestId}'),
              tooltip: '提交回答',
              onPressed: enabled && answer != null
                  ? () => widget.sessions.answerQuestion(
                      requestId: question.requestId,
                      answer: answer,
                      deviceId: widget.deviceId,
                      canWrite: widget.canWrite,
                    )
                  : null,
              icon: pending
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.send),
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
    this.fileCompletionCatalog,
  });

  final SessionController sessions;
  final bool canWrite;
  final String? deviceId;

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
  String? _draftSessionId;
  // v0.2/P3：@ 与 / 自动补全只在内存生成；候选为空或查询越权时展示空态（fail-closed）。
  List<_CompletionSuggestion> _suggestions = const [];
  bool _suggestionsLoading = false;
  // 最近一次输入是否以 @ 或 / 触发补全；即使候选为空也展示空态说明（fail-closed）。
  bool _completionActive = false;

  @override
  void initState() {
    super.initState();
    // 切换会话后恢复该会话的跨页内存草稿（不落明文盘）。
    _restoreDraft();
  }

  @override
  void didUpdateWidget(covariant _SessionComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessions.selectedSessionId !=
        widget.sessions.selectedSessionId) {
      _restoreDraft();
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
    final draft = widget.sessions.composerDraftFor(sessionId);
    if (draft != null && draft != _controller.text) {
      _controller.text = draft;
      // 光标移到末尾，让用户直接继续输入。
      _controller.selection = TextSelection.fromPosition(
        TextPosition(offset: _controller.text.length),
      );
    }
  }

  @override
  void dispose() {
    // 页面销毁前把当前输入保存为内存草稿，保证跨页返回后内容不丢失。
    final sessionId = widget.sessions.selectedSessionId;
    if (sessionId != null) {
      widget.sessions.saveComposerDraft(sessionId, _controller.text);
    }
    _controller.dispose();
    super.dispose();
  }

  /// 根据输入末尾 token 更新补全候选。
  void _updateSuggestions(String value) {
    final parts = value.split(RegExp(r'\s+'));
    final token = parts.isEmpty ? '' : parts.last;
    _completionActive = token.startsWith('@') || token.startsWith('/');
    if (token.startsWith('/')) {
      // Skill 建议：只使用 controls.skills 的标题，不读取任何参数或 Provider payload。
      final query = token.substring(1).toLowerCase();
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
    } else if (token.startsWith('@')) {
      final query = token.substring(1).toLowerCase();
      // 越权路径（绝对路径、..、路径分隔）不产生任何建议。
      if (query.contains('/') ||
          query.contains('..') ||
          query.startsWith('.')) {
        _setSuggestions(const []);
        return;
      }
      final catalog = widget.fileCompletionCatalog;
      if (catalog == null) {
        _setSuggestions(const []);
        return;
      }
      _suggestionsLoading = true;
      setState(() {});
      unawaited(_loadFileSuggestions(query));
    } else {
      _setSuggestions(const []);
    }
  }

  /// 异步加载文件补全候选（目录不可用或越权查询时返回空）。
  Future<void> _loadFileSuggestions(String query) async {
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

  /// 补全候选名安全校验：拒绝绝对路径、分隔符与隐藏文件（与 Daemon workspacesafe 语义一致）。
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

  /// 应用补全：替换输入末尾的 token。
  void _applySuggestion(_CompletionSuggestion suggestion) {
    final text = _controller.text;
    final lastSpace = text.lastIndexOf(' ');
    final prefix = lastSpace < 0 ? '' : text.substring(0, lastSpace + 1);
    final next = prefix + suggestion.insertText;
    _controller.text = next;
    _controller.selection = TextSelection.fromPosition(
      TextPosition(offset: next.length),
    );
    setState(() {});
    widget.sessions.saveComposerDraft(
      widget.sessions.selectedSessionId ?? '',
      next,
    );
    _updateSuggestions(next);
  }

  @override
  Widget build(BuildContext context) {
    final blocked = widget.sessions.composerBlockedReason(
      canWrite: widget.canWrite,
    );
    final streaming = widget.sessions.isStreaming;
    final canSend =
        blocked == null &&
        !streaming &&
        _controller.text.trim().isNotEmpty &&
        !widget.sessions.isBusy;
    final canStop = blocked == null && streaming && !widget.sessions.isBusy;
    return SafeArea(
      top: false,
      child: Container(
        key: const Key('session-composer'),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        decoration: BoxDecoration(
          color: Theme.of(context).scaffoldBackgroundColor,
          border: Border(
            top: BorderSide(color: Theme.of(context).dividerColor),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
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
            _ComposerControlStrip(
              sessions: widget.sessions,
              canWrite: widget.canWrite,
              deviceId: widget.deviceId,
            ),
            if (_completionActive || _suggestionsLoading)
              _ComposerSuggestions(
                suggestions: _suggestions,
                loading: _suggestionsLoading,
                onApply: _applySuggestion,
                onDismiss: () => _setSuggestions(const []),
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
            Container(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHigh,
                border: Border.all(color: Theme.of(context).dividerColor),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
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
                      enabled: blocked == null && !streaming,
                      minLines: 1,
                      maxLines: 5,
                      textInputAction: TextInputAction.newline,
                      onChanged: (value) {
                        setState(() {});
                        // 每次输入都写内存草稿；发送成功后由 controller 清除。
                        final sessionId = widget.sessions.selectedSessionId;
                        if (sessionId != null) {
                          widget.sessions.saveComposerDraft(sessionId, value);
                        }
                        _updateSuggestions(value);
                      },
                      decoration: const InputDecoration(
                        hintText: '给会话发送消息',
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                      ),
                    ),
                  ),
                  IconButton(
                    key: const Key('session-composer-primary-action'),
                    tooltip: streaming ? '停止生成' : '发送消息',
                    onPressed: streaming
                        ? (canStop ? _stop : null)
                        : (canSend ? _send : null),
                    icon: Icon(streaming ? Icons.stop : Icons.arrow_upward),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _send() async {
    final message = _controller.text;
    await widget.sessions.sendMessage(
      message: message,
      deviceId: widget.deviceId,
      canWrite: widget.canWrite,
    );
    if (!mounted || widget.sessions.errorMessage != null) return;
    _controller.clear();
    _setSuggestions(const []);
    setState(() {});
  }

  Future<void> _stop() => widget.sessions.stopStreaming(
    deviceId: widget.deviceId,
    canWrite: widget.canWrite,
  );
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

    // v0.3/P1：上下文占用超过 80% 窗口时显示脱敏警告（MOBILE-12）。
    final usage = controls.usage;
    final ratio = usage?.contextRatio;
    final showContextWarning =
        usageSupported && usage != null && ratio != null && ratio >= 0.8;

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            key: const Key('composer-control-strip'),
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  key: const Key('composer-model-select'),
                  initialValue: controls.model,
                  isDense: true,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: '模型',
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
                    for (final model in controls.models)
                      DropdownMenuItem(value: model, child: Text(model)),
                  ],
                  onChanged: modelBlocked == null && controls.models.isNotEmpty
                      ? (value) {
                          if (value != null) {
                            sessions.selectModel(
                              model: value,
                              deviceId: deviceId,
                              canWrite: canWrite,
                            );
                          }
                        }
                      : null,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: DropdownButtonFormField<String>(
                  key: const Key('composer-effort-select'),
                  initialValue: controls.effort,
                  isDense: true,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: 'Effort',
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
                    for (final effort in controls.efforts)
                      DropdownMenuItem(value: effort, child: Text(effort)),
                  ],
                  onChanged:
                      effortBlocked == null && controls.efforts.isNotEmpty
                      ? (value) {
                          if (value != null) {
                            sessions.selectEffort(
                              effort: value,
                              deviceId: deviceId,
                              canWrite: canWrite,
                            );
                          }
                        }
                      : null,
                ),
              ),
            ],
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
                          if (value != null) {
                            sessions.selectPermissionMode(
                              mode: value,
                              deviceId: deviceId,
                              canWrite: canWrite,
                            );
                          }
                        }
                      : null,
                ),
              ),
              if (controls.usage != null && usageSupported) ...[
                Tooltip(
                  message: '仅展示脱敏计数，不包含 prompt 或回复正文。',
                  child: Container(
                    key: const Key('composer-usage-chip'),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      border: Border.all(color: Theme.of(context).dividerColor),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      controls.usage!.label,
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ),
                ),
              ],
            ],
          ),
          // v0.3/P1：上下文占用超过 80% 窗口时显示脱敏警告（MOBILE-12）。
          if (showContextWarning) ...[
            const SizedBox(height: 6),
            Row(
              key: const Key('composer-context-warning'),
              children: [
                const Icon(Icons.warning_amber_outlined, size: 15),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '上下文占用 ${(ratio * 100).toStringAsFixed(0)}%（${SessionUsageSummary.compactForDisplay(usage.contextTokens)} / ${SessionUsageSummary.compactForDisplay(usage.contextWindowTokens)}），接近窗口上限。',
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// v0.2/P3：@ / 自动补全面板。候选为空时展示空态说明（fail-closed）。
class _ComposerSuggestions extends StatelessWidget {
  const _ComposerSuggestions({
    required this.suggestions,
    required this.loading,
    required this.onApply,
    required this.onDismiss,
  });

  final List<_CompletionSuggestion> suggestions;
  final bool loading;
  final void Function(_CompletionSuggestion suggestion) onApply;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      key: const Key('composer-suggestions'),
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
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
            for (final suggestion in suggestions)
              Material(
                color: Colors.transparent,
                child: ListTile(
                  key: Key('completion-suggestion-${suggestion.label}'),
                  dense: true,
                  leading: Icon(
                    suggestion.kind == _CompletionKind.skill
                        ? Icons.bolt_outlined
                        : Icons.description_outlined,
                    size: 18,
                  ),
                  title: Text(suggestion.label),
                  onTap: () => onApply(suggestion),
                ),
              ),
        ],
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
                title: Text('Owner 已建立'),
                subtitle: Text('此设备可获取会话控制权。'),
              )
            : app.hasOwner
            ? const ListTile(
                key: Key('readonly-auth-state'),
                leading: Icon(Icons.lock_outline),
                title: Text('当前登录没有 Android 写设备'),
                subtitle: Text('使用恢复码恢复。'),
              )
            : const ListTile(
                key: Key('unprovisioned-auth-state'),
                leading: Icon(Icons.info_outline),
                title: Text('尚未建立 Android owner'),
                subtitle: Text('创建首个 owner 或恢复既有 owner。'),
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

class _TimelineEmptyState extends StatelessWidget {
  const _TimelineEmptyState();

  @override
  Widget build(BuildContext context) => Center(
    key: const Key('session-timeline-empty'),
    child: Text(
      '这个会话还没有可显示的事件。',
      style: Theme.of(context).textTheme.bodyMedium,
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
  });

  final MobileSession? session;
  final bool hasLease;
  final bool canWrite;

  /// v0.3/P1：Provider 能力快照（version/available/reason 白名单），用于连接态与版本提示。
  final ProviderCapabilityProfile provider;

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
