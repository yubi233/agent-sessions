import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../app/providers.dart';
import '../domain/control_models.dart';
import '../domain/session_models.dart';
import '../state/app_controller.dart';
import '../state/session_controller.dart';

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
      _selectCurrentSession();
    }
  }

  void _selectCurrentSession() {
    final controller = ref.read(sessionControllerProvider);
    if (controller.selectedSessionId != widget.sessionId) {
      unawaited(controller.selectSession(widget.sessionId));
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = ref.watch(appControllerProvider);
    final sessions = ref.watch(sessionControllerProvider);
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
            onPressed: sessions.isDetailLoading
                ? null
                : () => sessions.selectSession(widget.sessionId),
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
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
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
            action: IconButton(
              key: const Key('session-goal-toggle-button'),
              tooltip: goal?.phase == GoalPhase.active ? '暂停 Goal' : '恢复 Goal',
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

class _CapabilityStateLabel extends StatelessWidget {
  const _CapabilityStateLabel({required this.entry});

  final CapabilityEntry entry;

  @override
  Widget build(BuildContext context) {
    final presentation = switch (entry.availability) {
      CapabilityAvailability.native => (
        Icons.check_circle_outline,
        const Color(0xff86e0bf),
      ),
      CapabilityAvailability.emulated => (
        Icons.auto_awesome_outlined,
        const Color(0xffffbe5c),
      ),
      CapabilityAvailability.unsupported => (
        Icons.block_outlined,
        const Color(0xffa4a4af),
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
        border: Border.all(color: const Color(0xffffbe5c)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: Icon(Icons.warning_amber_outlined, color: Color(0xffffbe5c)),
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
  });

  final SessionController sessions;
  final bool canWrite;
  final String? deviceId;

  @override
  State<_SessionComposer> createState() => _SessionComposerState();
}

class _SessionComposerState extends State<_SessionComposer> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
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
                        widget.sessions.controlBlockedReason(
                          'attachments',
                          canWrite: widget.canWrite,
                        ) ??
                        '等待会话附件密钥',
                    // 文件选择后的 session DEK 密封必须由安全密钥链路提供；当前没有 DEK 时 fail-closed，
                    // 不允许把未加密文件或显示名偷塞进 Relay。fixture 场景通过 controller 预置密文 draft。
                    onPressed: null,
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
                      onChanged: (_) => setState(() {}),
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
    setState(() {});
  }

  Future<void> _stop() => widget.sessions.stopStreaming(
    deviceId: widget.deviceId,
    canWrite: widget.canWrite,
  );
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
                  color: status.color.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(status.icon, color: status.color),
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
                            color: status.color,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          status.label,
                          style: Theme.of(context).textTheme.labelMedium
                              ?.copyWith(color: status.color),
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
  });

  final MobileSession? session;
  final bool hasLease;
  final bool canWrite;

  @override
  Widget build(BuildContext context) {
    final status = _sessionStatusPresentation(session?.status);
    final leaseText = !canWrite
        ? '只读'
        : hasLease
        ? '已获得控制权'
        : '未获取控制权';
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
              color: status.color,
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
          Text(leaseText, style: Theme.of(context).textTheme.labelMedium),
        ],
      ),
    );
  }
}

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
          decoration: const BoxDecoration(
            color: Color(0xff86e0bf),
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
    required this.color,
    required this.icon,
  });

  final String label;
  final Color color;
  final IconData icon;
}

_SessionStatusPresentation _sessionStatusPresentation(
  MobileSessionStatus? status,
) => switch (status) {
  MobileSessionStatus.streaming => const _SessionStatusPresentation(
    label: '生成中',
    color: Color(0xff61a7ff),
    icon: Icons.auto_awesome_outlined,
  ),
  MobileSessionStatus.waitingPermission => const _SessionStatusPresentation(
    label: '等待确认',
    color: Color(0xffffbe5c),
    icon: Icons.shield_outlined,
  ),
  MobileSessionStatus.waitingQuestion => const _SessionStatusPresentation(
    label: '等待回答',
    color: Color(0xffffbe5c),
    icon: Icons.help_outline,
  ),
  MobileSessionStatus.stopped => const _SessionStatusPresentation(
    label: '已停止',
    color: Color(0xffa4a4af),
    icon: Icons.stop_circle_outlined,
  ),
  MobileSessionStatus.errored => const _SessionStatusPresentation(
    label: '出现错误',
    color: Color(0xffff8b83),
    icon: Icons.error_outline,
  ),
  MobileSessionStatus.offline => const _SessionStatusPresentation(
    label: '离线',
    color: Color(0xffa4a4af),
    icon: Icons.cloud_off_outlined,
  ),
  _ => const _SessionStatusPresentation(
    label: '在线',
    color: Color(0xff86e0bf),
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
