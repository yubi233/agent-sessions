import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../app/providers.dart';
import '../domain/control_models.dart';
import '../domain/delegation_models.dart';
import '../domain/session_models.dart';
import '../domain/session_projection_models.dart';
import '../relay/fixture_relay_repository.dart';
import '../state/app_controller.dart';
import '../state/delegation_controller.dart';
import '../state/lifecycle_recovery_controller.dart';
import '../state/session_controller.dart';
import '../state/session_presentation_state.dart';
import '../state/session_message_feedback_controller.dart';
import '../state/session_projection_controller.dart';
import '../state/session_view_controller.dart';
import 'app_theme.dart';
import 'session/session_status_presentation.dart';
import 'session/chat/session_chat_node_seat.dart';
import 'session/chat/session_chat_view.dart';
import 'session/trajectory/session_trajectory_view.dart';
import 'session/composer/session_composer_panel.dart';

import 'session/session_conversation_root.dart';
import 'session/session_agent_preset.dart';
import 'session/session_header.dart';
import 'session/session_subagent_chrome.dart';
import 'session/session_workspace_picker.dart';

/// Happy 风格会话首页：优先呈现会话工作流，同时将 owner 安全入口保留在轻量控制区。
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
        title: const SessionHeaderTitle(title: '新建会话'),
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
              padding: const EdgeInsets.all(AppSpacing.lg),
              children: [
                Text('开始一个会话', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  '会话会绑定到已授权的工作区；实际 Provider 调度不在本地 fixture 中执行。',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: AppSpacing.xl),
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
                        const SizedBox(height: AppSpacing.md),
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
                          const SizedBox(height: AppSpacing.sm),
                          const Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              '正在创建工作区…',
                              key: Key('new-session-workspace-pending'),
                            ),
                          ),
                        ],
                      ],
                      const SizedBox(height: AppSpacing.md),
                      TextFormField(
                        key: const Key('new-session-workspace-input'),
                        controller: _workspaceController,
                        decoration: const InputDecoration(labelText: '工作区 ID'),
                        validator: (value) => value?.trim().isNotEmpty == true
                            ? null
                            : '请输入工作区 ID。',
                      ),
                      const SizedBox(height: AppSpacing.md),
                      SessionAgentPresetSeat(
                        options: fixtureMode
                            ? fixtureAgentPresetOptions
                            : const [],
                        selectedId: _agentPresetId,
                        enabled: app.canManageDevices && !sessions.isBusy,
                        onSelected: (value) =>
                            setState(() => _agentPresetId = value),
                      ),
                      if (fixtureMode) const SizedBox(height: AppSpacing.md),
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
                      const SizedBox(height: AppSpacing.xl),
                      if (!app.canManageDevices) const ReadOnlyBanner(),
                      if (!app.canManageDevices) const SizedBox(height: AppSpacing.md),
                      FilledButton.icon(
                        key: const Key('new-session-create-button'),
                        onPressed: app.canManageDevices && !sessions.isBusy
                            ? () => _create(app, sessions)
                            : null,
                        icon: const Icon(Icons.play_arrow),
                        label: const Text('创建会话'),
                      ),
                      if (sessions.errorMessage != null) ...[
                        const SizedBox(height: AppSpacing.md),
                        InlineError(
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
    // V094-06：气泡出现 ≠ 已送达——节点挂载事务的阶段状态（正在提交/已受理/
    // 处理中/恢复中/正在重发/结果待确认/发送失败），canonical 历史节点保持无状态。
    final pendingOutgoing = sessions.pendingOutgoingMessage;
    final activeTx = sessions.activeSendTransaction;
    final pendingIsTxText =
        activeTx != null &&
        (pendingOutgoing ?? '').isNotEmpty &&
        activeTx.text == pendingOutgoing;
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
          isStreaming: activeTx == null || !activeTx.isTerminal,
          // 消息级状态只在"回显属于当前事务"时展示；回显被其它来源
          // 复用时不给节点安状态，避免把旧文本误标成新事务。
          deliveryStatus: pendingIsTxText ? activeTx.phase.userLabel : null,
          deliveryDetail: pendingIsTxText ? activeTx.errorDetail : null,
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
      // v0.9.3 P2（T4 / V093-04）：自动恢复提示行——恢复期间可见，非静默。
      recoveryNotice: sessions.recoveryNotice,
      // v0.9.0 C3：事件新鲜度次级行 + 「查看结果」手动出口（强制快照同步，
      // 成功只在真实事实到达时清横幅）。
      timeoutFreshnessText: formatTimeoutFreshness(
        sessions.lastMergedAtFor(sessionId),
      ),
      onViewResult: () => sessions.refreshTurnResult(),
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
          InlineError(
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
        const SizedBox(height: AppSpacing.xxl),
        Icon(
          Icons.computer_outlined,
          size: AppSizes.emptyStateIcon,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(height: AppSpacing.md),
        Text(
          session?.workspaceLabel ?? '绑定的工作区',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          '从下方选择工作区开始会话',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
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
          const SizedBox(height: AppSpacing.sm),
          SessionAgentPresetLabel(presetId: session?.agentPresetId),
        ],
        const SizedBox(height: AppSpacing.lg),
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
  /// V087-12 诊断：会话详情页 build 计数（localdev 钩子据此确认导航落地）。
  static int pageBuilds = 0;


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
    // V087-12/V088-13 诊断：详情页 build 计数（localdev 钩子据此确认导航落地）。
    // 计数在 build 内自增——此前只有声明无递增，钩子的「计数增长」判定恒假，
    // 真实栈只能靠 30s 超时兜底（navigate-timeout 误报）。
    SessionDetailScreen.pageBuilds += 1;
    // ignore: avoid_print
    print('V087PAGE build session=${widget.sessionId} viewMode=$viewMode timeline=${sessions.timeline.length}');
    final session = sessions.selectedSession;
    return Scaffold(
      key: const Key('session-detail-screen'),
      resizeToAvoidBottomInset: true,
      body: SessionConversationRoot(
        header: SessionHeader(
          title: HappySessionHeaderTitle(
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
            // V094-01/02：单一主状态与分维度事实标签由同一投影派生，
            // 状态条/composer/状态槽不再各自拼状态。
            presentation: sessions.buildPresentationState(
              canWrite: app.canManageDevices,
              hasLease: sessions.hasSelectedLease,
            ),
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
            : SessionComposerPanel(
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
    // v0.8.8 P2（V088-07 门控）：Git 只读入口按矩阵 git_read 放行——capability
    // unsupported 时禁用入口（只读视图不要求 canWrite，只看矩阵声明）。
    final gitReadSupported = sessions.selectedProviderCapabilities
        .capability('git_read')
        .isSupported;
    final filesReadSupported = sessions.selectedProviderCapabilities
        .capability('file_read')
        .isSupported;
    return PopupMenuButton<String>(
      key: const Key('session-quick-menu-button'),
      tooltip: '会话操作',
      icon: HappyProviderAvatar(provider: sessions.selectedSession?.provider),
      onSelected: (value) {
        switch (value) {
          case 'refresh':
            onRefresh?.call();
          case 'git':
            if (!gitReadSupported) return;
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
            // 文件浏览是只读页面，与 Git 入口一样不依赖 lease；
            // v0.8.8 P3：按矩阵 file_read 门控（未声明时入口禁用）。
            if (!filesReadSupported) return;
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
        PopupMenuItem(
          key: const Key('session-open-git-button'),
          value: 'git',
          enabled: gitReadSupported,
          child: ListTile(
            leading: Icon(Icons.difference_outlined),
            // 矩阵未声明 git_read 时如实展示阻断事实（能力卡与入口双面一致）。
            title: Text(gitReadSupported ? '查看 Git 变更' : '查看 Git 变更（当前 Provider 未启用）'),
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
          // v0.8.8 P3：文件入口按矩阵 file_read 门控（与 Git 入口同面）。
          enabled: filesReadSupported,
          child: ListTile(
            leading: const Icon(Icons.folder_open_outlined),
            title: Text(filesReadSupported ? '浏览工作区文件' : '浏览工作区文件（当前 Provider 未启用）'),
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
          padding: const EdgeInsets.fromLTRB(AppSpacing.xl, AppSpacing.lg, AppSpacing.xl, AppSpacing.xxl),
          child: Column(
            key: const Key('session-details-sheet'),
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('会话详情', style: Theme.of(sheetContext).textTheme.titleMedium),
              const SizedBox(height: AppSpacing.md),
              _DetailRow(label: '会话 ID', value: session.id),
              _DetailRow(label: 'Provider', value: session.provider),
              _DetailRow(label: '工作区', value: session.workspaceLabel),
              _DetailRow(
                label: '状态',
                value: sessionStatusPresentation(session).label,
              ),
              _DetailRow(
                label: '最后活动',
                value: relativeTime(
                  session.lastActivityAt ?? session.updatedAt,
                ),
              ),
              _DetailRow(label: '事件序号', value: '${session.lastSequence}'),
              const SizedBox(height: AppSpacing.md),
              // v0.3/P2：复制只包含白名单元数据（会话 ID/Provider/工作区），不复制密文或正文。
              Wrap(
                spacing: 8,
                children: [
                  OutlinedButton.icon(
                    key: const Key('session-copy-id-button'),
                    onPressed: () =>
                        Clipboard.setData(ClipboardData(text: session.id)),
                    icon: const Icon(Icons.copy_outlined, size: AppSizes.iconSm),
                    label: const Text('复制会话 ID'),
                  ),
                  OutlinedButton.icon(
                    key: const Key('session-copy-provider-button'),
                    onPressed: () => Clipboard.setData(
                      ClipboardData(text: session.provider),
                    ),
                    icon: const Icon(Icons.copy_outlined, size: AppSizes.iconSm),
                    label: const Text('复制 Provider'),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
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
    padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
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
        padding: EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, 0),
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
      margin: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.md, 0),
      padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.sm, AppSpacing.sm),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.account_tree_outlined, size: AppSizes.iconMd),
              const SizedBox(width: AppSpacing.sm),
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
                iconSize: AppSizes.iconMd,
                onPressed: () => _showDelegationProposalSheet(context),
                icon: const Icon(Icons.add_circle_outline),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
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
            const SizedBox(height: AppSpacing.sm),
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
                  icon: const Icon(Icons.close, size: AppSizes.iconMd),
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
          AppSpacing.xl,
          AppSpacing.lg,
          AppSpacing.xxl,
          AppSpacing.xxl + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          key: const Key('delegation-proposal-sheet'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('新建子会话', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: AppSpacing.sm),
            Text(
              '任务书将加密提交给已授权 Daemon；当前界面只展示状态与摘要指纹。',
              style: Theme.of(context).textTheme.labelSmall,
            ),
            const SizedBox(height: AppSpacing.md),
            if (blocked != null) ...[
              Text(
                blocked,
                key: const Key('delegation-propose-blocked'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              const SizedBox(height: AppSpacing.sm),
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
            const SizedBox(height: AppSpacing.md),
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
            const SizedBox(height: AppSpacing.lg),
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
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
                child: Icon(Icons.arrow_forward, size: AppSizes.iconMd, color: statusColor),
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
          const SizedBox(height: AppSpacing.sm),
          Text(
            '加密摘要 ${delegation.summaryFingerprint}',
            key: Key('delegation-summary-${delegation.id}'),
            style: Theme.of(context).textTheme.labelMedium,
          ),
          if (delegation.canApproveOrReject) ...[
            const SizedBox(height: AppSpacing.xs),
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
                            width: AppSpacing.lg,
                            height: AppSpacing.lg,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.check),
                  ),
                ],
              ),
            ),
          ],
          if (delegation.canCancel) ...[
            const SizedBox(height: AppSpacing.xs),
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
            const SizedBox(height: AppSpacing.xs),
            Row(
              children: [
                const Expanded(child: Text('子会话使用独立可操作状态')),
                IconButton(
                  key: Key('delegation-open-child-${delegation.id}'),
                  tooltip: '打开子会话',
                  onPressed: () => onOpenChild(childSessionId),
                  icon: const Icon(Icons.arrow_forward_ios, size: AppSizes.iconMd),
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
class _SessionStatusStrip extends StatelessWidget {
  const _SessionStatusStrip({
    required this.session,
    required this.turnInFlight,
    required this.hasLease,
    required this.canWrite,
    required this.provider,
    required this.presentation,
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

  /// V094-01/02：单一主状态与分维度事实标签（可控制/只读、执行服务可用性、
  /// 真实连接）。本组件不再自行拼接状态语义。
  final SessionPresentationState presentation;
  final VoidCallback? onAcquireLease;

  @override
  Widget build(BuildContext context) {
    // V094-01：主状态唯一来源是展示投影（不再与下方 Provider/角色/lease
    // 标签各自表述）；V094-02：角色表述为"可控制/只读"，不承诺"可操作"。
    final status = SessionStatusPresentation(
      label: presentation.primaryLabel,
      // V094-17：状态图标随主状态语义（不只是颜色表达）。
      icon: switch (presentation.tone) {
        SessionPresentationTone.error => Icons.error_outline,
        SessionPresentationTone.attention => Icons.priority_high_outlined,
        SessionPresentationTone.busy => Icons.autorenew_outlined,
        SessionPresentationTone.success => Icons.check_circle_outline,
        SessionPresentationTone.neutral => Icons.radio_button_unchecked,
      },
      tone: switch (presentation.tone) {
        SessionPresentationTone.neutral => SessionStatusTone.neutral,
        SessionPresentationTone.busy => SessionStatusTone.info,
        SessionPresentationTone.success => SessionStatusTone.success,
        SessionPresentationTone.attention => SessionStatusTone.warning,
        SessionPresentationTone.error => SessionStatusTone.error,
      },
    );
    final statusColor = sessionStatusColor(context, status.tone);
    final leaseText = presentation.roleLabel;
    // V094-02：provider.available 是执行能力可用性（探测结果），不是实时
    // 连接；能力标签写"执行服务可用/不可用"，真实连接单独由投影表达。
    final providerConnected = provider.available;
    final providerVersion = provider.version.trim();
    final providerReason = provider.capabilities
        .where((entry) => entry.name == 'start')
        .map((entry) => entry.reason)
        .whereType<String>()
        .firstOrNull;
    final providerLabel = !providerConnected
        ? '执行服务不可用'
        : providerVersion.isNotEmpty
        ? '执行服务可用 · v$providerVersion'
        : '执行服务可用';
    final providerTooltip = !providerConnected
        ? (providerReason ?? 'Provider 当前不可用。')
        : 'Provider 版本仅来自探测结果；实时连接单独显示。';
    // V094-20（收口）：状态条主体按文本缩放二选一（局部函数以闭包捕获 build 事实）。
    final largeText = MediaQuery.textScalerOf(context).scale(14) > 18;
    Widget leaseButton() {    return IconButton(
              key: const Key('session-acquire-lease-button'),
              tooltip: hasLease ? '会话可控制' : '获取会话控制权',
              visualDensity: VisualDensity.compact,
              // V094-08：状态行按钮内衬收紧（图标 16 + 32dp 命中），
              // 不让单个兜底按钮撑高整条状态行。
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              padding: EdgeInsets.zero,
              onPressed: canWrite && !hasLease ? onAcquireLease : null,
              icon: Icon(
                hasLease
                    ? Icons.check_circle_outline
                    : canWrite
                    ? Icons.autorenew
                    : Icons.lock_outline,
                size: AppSizes.iconMd,
                color: hasLease
                    ? context.appColors.success
                    : Theme.of(context).colorScheme.outline,
              ),
            );
    }


    Widget largeTextLayout() {    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: AppSizes.statusDot,
              height: AppSizes.statusDot,
              decoration: BoxDecoration(
                color: statusColor,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                status.label,
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ),
          ],
        ),
        Row(
          children: [
            Expanded(
              child: Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.micro,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (presentation.actionHint != null)
                    Text(
                      presentation.actionHint!,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  Tooltip(
                    message: providerTooltip,
                    child: Container(
                      key: const Key('session-provider-version-chip'),
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.sm,
                        vertical: AppSpacing.micro,
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
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.sm,
                      vertical: AppSpacing.micro,
                    ),
                    decoration: BoxDecoration(
                      color: hasLease
                          ? context.appColors.success.withValues(alpha: 0.14)
                          : Theme.of(context).colorScheme.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(AppRadius.small),
                    ),
                    child: Text(
                      leaseText,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: hasLease ? context.appColors.success : null,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            leaseButton(),
          ],
        ),
      ],
    );
    }

    Widget compactLayout() {    return Row(
          children: [
            Container(
              width: AppSizes.statusDot,
              height: AppSizes.statusDot,
              decoration: BoxDecoration(
                color: statusColor,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      status.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                  ),
                  // V094 §2.1：stopped 可写时的行动提示，独立词渲染。
                  if (presentation.actionHint != null) ...[
                    const SizedBox(width: AppSpacing.xs),
                    Flexible(
                      child: Text(
                        presentation.actionHint!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelSmall
                            ?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Flexible(
              fit: FlexFit.loose,
              child: Tooltip(
                message: providerTooltip,
                child: Container(
                  key: const Key('session-provider-version-chip'),
                  constraints: const BoxConstraints(maxWidth: 142),
                  margin: const EdgeInsets.only(right: AppSpacing.sm),
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.sm,
                    vertical: AppSpacing.micro,
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
                margin: const EdgeInsets.only(right: AppSpacing.micro),
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: AppSpacing.micro),
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
            leaseButton(),
          ],
        );
    }

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
        // V094-08：状态条垂直内衬收紧（基准 2dp），预算给标题行与 tabs。
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.micro),
        // V094-20（收口）：大字（textScale > 1.3）切换为两行堆叠布局——
        // 主状态允许两行不截字（计划 §3.2「大字优先不截字」，预算仅在
        // textScale 1.0 断言）；chips 沉到第二行保持完整可读。
        child: largeText ? largeTextLayout() : compactLayout(),
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
      margin: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.md, 0),
      padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.sm, AppSpacing.sm),
      decoration: BoxDecoration(
        color: presentation.color.withValues(alpha: 0.1),
        border: Border.all(color: presentation.color.withValues(alpha: 0.45)),
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: Row(
        children: [
          Icon(presentation.icon, size: AppSizes.iconMd, color: presentation.color),
          const SizedBox(width: AppSpacing.sm),
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
              icon: const Icon(Icons.refresh, size: AppSizes.iconMd),
            ),
          if (isCurrentNotice)
            IconButton(
              key: const Key('session-recovery-notice-dismiss'),
              tooltip: '关闭通知',
              onPressed: () => controller.dismissNotice(notice!.id),
              icon: const Icon(Icons.close, size: AppSizes.iconMd),
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

