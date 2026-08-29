import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../attachments/attachment_picker.dart';
import '../domain/control_models.dart';
import '../domain/models.dart';
import '../domain/session_models.dart';
import '../relay/relay_repository.dart';
import 'session_composer_controller.dart';

enum SessionListPhase { loading, ready, error }

enum WorkspaceListPhase { loading, ready, error }

/// 会话状态与认证状态分离：认证控制器只负责设备身份，本文控制器只负责用户可见的会话旅程。
class SessionController extends ChangeNotifier {
  /// 保持公开依赖参数为 relay，避免私有字段名成为外部调用契约。
  factory SessionController({
    required RelayRepository relay,
    DateTime Function()? clock,
    Random? random,
    AttachmentPicker? picker,
  }) =>
      SessionController._(relay, clock: clock, random: random, picker: picker);

  SessionController._(
    this._relay, {
    DateTime Function()? clock,
    Random? random,
    this._picker,
  }) : _clock = clock ?? DateTime.now,
       _random = random ?? Random.secure();

  final RelayRepository _relay;
  final DateTime Function() _clock;
  final Random _random;
  final AttachmentPicker? _picker;

  SessionListPhase _phase = SessionListPhase.loading;
  List<MobileSession> _sessions = const [];
  WorkspaceListPhase _workspacePhase = WorkspaceListPhase.loading;
  List<MobileWorkspace> _workspaces = const [];
  String? _workspaceErrorMessage;
  String? _pendingWorkspaceId;
  String? _pendingWorkspaceCommandId;
  bool _workspaceSettling = false;
  String? _selectedSessionId;
  List<SessionTimelineEvent> _timeline = const [];
  final Map<String, List<SessionTimelineEvent>> _timelineWindows = {};
  bool _historyLoading = false;
  String? _historyErrorMessage;
  SessionLease? _selectedLease;
  CapabilityMatrix _capabilities = CapabilityMatrix.empty;
  SessionControlState _controls = const SessionControlState.empty();

  /// 已提交但 canonical user.message 事件尚未回传的出站文本，按会话隔离。
  /// 非空时该会话的 Chat 时间线尾部渲染乐观回显气泡；规范化事件合并后立即清账，
  /// 会话切换互不泄漏。
  final Map<String, String> _pendingOutgoingBySession = <String, String>{};

  /// 当前选中会话尚未被规范化事件确认的本机回显文本；null 表示无待确认出站消息。
  String? get pendingOutgoingMessage =>
      _selectedSessionId == null ? null : _pendingOutgoingBySession[_selectedSessionId!];
  SkillConfirmation? _skillConfirmation;
  List<AttachmentTransfer> _attachments = const [];
  List<AttachmentRejection> _attachmentRejections = const [];
  bool _isDetailLoading = false;
  bool _isCapabilitiesLoading = false;
  final Set<String> _pendingActionKeys = {};
  final Set<String> _resolvedRequestKeys = {};
  final Map<String, String> _idempotencyKeys = {};
  // cursor 只在内存保存为会话序号；生命周期恢复不接触消息正文、密文或待发送内容。
  final Map<String, int> _sessionCursors = {};
  // v0.2/P2：composer 草稿只保存在内存（不落明文盘）；按会话隔离，切换页面/会话后仍可恢复。
  final Map<String, String> _composerDrafts = {};
  // v0.5：reference occurrences 与 transient queue 也按 session 隔离，不能随 widget 重建丢失。
  final Map<String, SessionComposerSessionState> _composerStates = {};
  // 附件句柄只在内存保存；切换会话时暂存，发送时才绑定目标 session。
  final Map<String, List<AttachmentTransfer>> _attachmentsBySession = {};
  // v0.2/P3：会话内容密钥（DEK）可用性；false 时附件选文件入口 fail-closed。
  bool _contentKeyAvailable = false;
  String? _errorMessage;
  int _idempotencyCounter = 0;
  int _selectionGeneration = 0;
  int _runtimeLeaseGeneration = 0;
  bool _initializing = false;

  SessionListPhase get phase => _phase;
  List<MobileSession> get sessions =>
      List<MobileSession>.unmodifiable(_sessions);
  WorkspaceListPhase get workspacePhase => _workspacePhase;
  List<MobileWorkspace> get workspaces =>
      List<MobileWorkspace>.unmodifiable(_workspaces);
  String? get workspaceErrorMessage => _workspaceErrorMessage;
  String? get pendingWorkspaceId => _pendingWorkspaceId;
  String? get pendingWorkspaceCommandId => _pendingWorkspaceCommandId;
  bool get workspaceSettling => _workspaceSettling;
  List<SessionTimelineEvent> get timeline =>
      List<SessionTimelineEvent>.unmodifiable(_timeline);
  bool get historyLoading => _historyLoading;
  String? get historyErrorMessage => _historyErrorMessage;
  bool get canLoadOlder {
    final sessionId = _selectedSessionId;
    if (sessionId == null) return false;
    return (_timelineWindows[sessionId]?.length ?? 0) > _timeline.length;
  }

  String? get selectedSessionId => _selectedSessionId;
  MobileSession? get selectedSession => _sessionById(_selectedSessionId);
  SessionLease? get selectedLease => _selectedLease;
  CapabilityMatrix get capabilities => _capabilities;

  /// Delegation 等独立控制器消费同一份 Relay capability 快照，避免按 Provider 名称猜测可用性。
  CapabilityMatrix get capabilityMatrix => _capabilities;
  ProviderCapabilityProfile get selectedProviderCapabilities =>
      _capabilities.provider(selectedSession?.provider ?? 'unknown');
  SessionControlState get controls => _controls;
  SkillConfirmation? get skillConfirmation => _skillConfirmation;
  List<AttachmentTransfer> get attachments =>
      List<AttachmentTransfer>.unmodifiable(_attachments);
  List<AttachmentRejection> get attachmentRejections =>
      List<AttachmentRejection>.unmodifiable(_attachmentRejections);
  bool get isDetailLoading => _isDetailLoading;
  bool get isCapabilitiesLoading => _isCapabilitiesLoading;
  bool get isBusy => _pendingActionKeys.isNotEmpty;
  String? get errorMessage => _errorMessage;
  bool get hasSelectedLease =>
      _selectedLease != null && _selectedLease!.epoch > 0;
  bool get isStreaming =>
      selectedSession?.status == MobileSessionStatus.streaming;
  bool get isEmpty => _phase == SessionListPhase.ready && _sessions.isEmpty;
  int get selectedCursor => _cursorFor(_selectedSessionId);

  /// 仅在首次消费 provider 时拉取列表，避免页面 rebuild 时重复请求 Relay。
  Future<void> initialize() async {
    if (_initializing || _phase == SessionListPhase.ready) return;
    _initializing = true;
    try {
      await Future.wait([
        refreshSessions(),
        refreshWorkspaces(),
        refreshCapabilities(),
      ]);
    } finally {
      _initializing = false;
    }
  }

  /// capability 失败时采取 fail-closed：已有会话仍可读，但所有 P3 写入口保持禁用。
  Future<void> refreshCapabilities() async {
    _isCapabilitiesLoading = true;
    notifyListeners();
    try {
      _capabilities = await _relay.getCapabilities();
    } on RelayFailure catch (failure) {
      _capabilities = CapabilityMatrix.empty;
      _errorMessage = failure.message;
    } catch (_) {
      _capabilities = CapabilityMatrix.empty;
      _errorMessage = '能力矩阵暂时不可用，控制入口已安全禁用。';
    } finally {
      _isCapabilitiesLoading = false;
      notifyListeners();
    }
  }

  Future<void> refreshSessions() async {
    _errorMessage = null;
    _phase = SessionListPhase.loading;
    notifyListeners();
    try {
      final loaded = await _relay.listSessions();
      // 按最后活动时间稳定排序（服务端同样排序，这里兜底合并/刷新路径）。
      _sessions = [...loaded]..sort(MobileSession.compareByLastActivity);
      _phase = SessionListPhase.ready;
      if (_selectedSessionId != null &&
          _sessionById(_selectedSessionId) == null) {
        _clearSelection();
      }
    } on RelayFailure catch (failure) {
      _phase = SessionListPhase.error;
      _errorMessage = failure.message;
    } catch (_) {
      _phase = SessionListPhase.error;
      _errorMessage = '会话列表暂时不可用，请稍后重试。';
    }
    notifyListeners();
  }

  Future<void> refreshWorkspaces() async {
    _workspaceErrorMessage = null;
    _workspacePhase = WorkspaceListPhase.loading;
    notifyListeners();
    try {
      _workspaces = await _relay.listWorkspaces();
      _workspacePhase = WorkspaceListPhase.ready;
    } on RelayFailure catch (failure) {
      _workspacePhase = WorkspaceListPhase.error;
      _workspaceErrorMessage = failure.message;
    } catch (_) {
      _workspacePhase = WorkspaceListPhase.error;
      _workspaceErrorMessage = '工作区列表暂时不可用，请稍后重试。';
    }
    notifyListeners();
  }

  bool get selectedWorkspaceDeleted {
    final workspaceId = selectedSession?.workspaceId;
    if (workspaceId == null || _workspacePhase != WorkspaceListPhase.ready) {
      return false;
    }
    return !_workspaces.any((workspace) => workspace.id == workspaceId);
  }

  Future<MobileWorkspace?> createWorkspaceFromDirectory({
    required String canonicalRoot,
    required String? deviceId,
    required bool canWrite,
    String terminalId = '',
  }) async {
    if (!_ensureWriteAccess(canWrite: canWrite, deviceId: deviceId)) {
      return null;
    }
    final root = canonicalRoot.trim();
    if (root.isEmpty) {
      _workspaceErrorMessage = '没有选择工作区目录。';
      notifyListeners();
      return null;
    }
    final projectId = _projectIdForRoot(root);
    final created = await _runAction<MobileWorkspace?>(
      'workspace-create:$projectId',
      () => _relay.createWorkspace(
        CreateMobileWorkspaceInput(
          projectId: projectId,
          canonicalRoot: root,
          terminalId: terminalId,
          deviceId: deviceId!,
        ),
      ),
    );
    if (created != null) {
      _workspaces = [
        created,
        ..._workspaces.where((workspace) => workspace.id != created.id),
      ];
      _workspacePhase = WorkspaceListPhase.ready;
      _workspaceErrorMessage = null;
      notifyListeners();
    } else {
      _workspaceErrorMessage = _errorMessage ?? '工作区创建失败，请重新选择目录。';
      notifyListeners();
    }
    return created;
  }

  /// 真实 Relay 工作区创建只接受名称，并等待 Terminal Daemon 的异步回执。
  /// 轮询期间保留 pending 状态；成功后把脱敏 Workspace 投影放入列表，绝不接触
  /// canonical root 或把移动端路径当成 Host 路径。
  Future<MobileWorkspace?> createWorkspaceWithName({
    required String name,
    required String? deviceId,
    required bool canWrite,
    String terminalId = '',
  }) async {
    if (!_ensureWriteAccess(canWrite: canWrite, deviceId: deviceId)) {
      return null;
    }
    final input = CreateMobileWorkspaceWithFolderInput(
      name: name,
      deviceId: deviceId!,
      terminalId: terminalId,
    );
    try {
      input.validate();
    } on RelayFailure catch (failure) {
      _workspaceErrorMessage = failure.message;
      notifyListeners();
      return null;
    }
    final normalizedName = name.trim();
    // workspace.create 是异步 Terminal 命令；显式暴露 settling 状态让页面禁用
    // 重复点击，并让回归测试能区分 pending 与已完成投影。
    _workspaceSettling = true;
    notifyListeners();
    try {
      final created = await _runAction<MobileWorkspace?>(
        'workspace-create-name:$normalizedName',
        () async {
          var state = await _relay.createWorkspaceWithFolder(input);
          if (state.isPending) {
            final commandID = state.commandId;
            if (commandID == null || commandID.trim().isEmpty) {
              throw const RelayFailure(
                RelayFailureKind.protocol,
                'Relay 未返回工作区创建命令标识。',
              );
            }
            _pendingWorkspaceCommandId = commandID;
            _pendingWorkspaceId = state.workspaceId;
            notifyListeners();
            // Daemon 创建目录是异步的；有限次轮询避免网络异常时永久占住 UI。
            for (var attempt = 0; attempt < 40 && state.isPending; attempt++) {
              await Future<void>.delayed(const Duration(milliseconds: 250));
              state = await _relay.getWorkspaceCreateState(commandID);
              notifyListeners();
            }
          }
          if (!state.isSucceeded) {
            throw RelayFailure(
              RelayFailureKind.unavailable,
              _workspaceCreateFailureMessage(state.errorCode),
            );
          }
          var workspace = state.workspace;
          if (workspace == null) {
            await refreshWorkspaces();
            workspace = _workspaces
                .where((item) => item.id == state.workspaceId)
                .firstOrNull;
          }
          if (workspace == null) {
            throw const RelayFailure(
              RelayFailureKind.protocol,
              'Relay 已完成工作区创建，但未返回工作区。',
            );
          }
          _workspaces = [
            workspace,
            ..._workspaces.where((item) => item.id != workspace!.id),
          ];
          _workspacePhase = WorkspaceListPhase.ready;
          _workspaceErrorMessage = null;
          return workspace;
        },
      );
      if (created == null && _errorMessage != null) {
        _workspaceErrorMessage = _errorMessage;
      }
      return created;
    } finally {
      _pendingWorkspaceCommandId = null;
      _pendingWorkspaceId = null;
      _workspaceSettling = false;
      notifyListeners();
    }
  }

  String _workspaceCreateFailureMessage(String? errorCode) =>
      switch (errorCode) {
        'WORKSPACE_PATH_DENIED' => '工作区名称或授权路径不允许。',
        'WORKSPACE_MOVED' => '工作区授权根已移动，请重新连接 Terminal。',
        'TERMINAL_OFFLINE' => '没有在线且支持新建工作区的 Terminal。',
        'CAPABILITY_UNSUPPORTED' => '当前 Terminal 不支持新建工作区。',
        _ => '工作区创建失败，请稍后重试。',
      };

  /// Reuse an empty session for the workspace or create one. Session-scoped
  /// input and opaque attachment handles move only after the destination has
  /// opened; any failure leaves the source untouched.
  Future<MobileSession?> openWorkspace({
    required String workspaceId,
    required String provider,
    required String? deviceId,
    required bool canWrite,
    String? agentPresetId,
    bool autoStart = false,
  }) async {
    final normalized = workspaceId.trim();
    if (normalized.isEmpty) return null;
    final sourceSessionId = _selectedSessionId;
    final sourceState = sourceSessionId == null
        ? const SessionComposerSessionState.empty()
        : composerStateFor(sourceSessionId);
    final sourceAttachments = List<AttachmentTransfer>.of(_attachments);
    _pendingWorkspaceId = normalized;
    _workspaceSettling = true;
    _workspaceErrorMessage = null;
    notifyListeners();
    try {
      MobileSession? target;
      for (final session in _sessions) {
        if (session.workspaceId == normalized &&
            session.status == MobileSessionStatus.idle &&
            session.lastSequence <= 1) {
          target = session;
          break;
        }
      }
      if (target != null) {
        await _loadSelectedSession(target.id);
        if (_selectedSessionId != target.id || _isDetailLoading) return null;
      } else {
        target = await createSession(
          workspaceId: normalized,
          provider: provider,
          deviceId: deviceId,
          canWrite: canWrite,
          agentPresetId: agentPresetId,
          autoStart: autoStart,
        );
      }
      if (target == null || _selectedSessionId != target.id) return null;
      if (sourceSessionId != null && sourceSessionId != target.id) {
        if (sourceAttachments.any((item) => item.draft.isImage) &&
            _controls.imageLimits == null) {
          _workspaceErrorMessage = '目标会话未声明图片接收能力，源草稿和图片已保留。';
          await _loadSelectedSession(sourceSessionId);
          return null;
        }
        if (sourceState.draft.isNotEmpty ||
            sourceState.references.isNotEmpty ||
            sourceState.queue.isNotEmpty) {
          saveComposerState(target.id, sourceState);
        }
        if (sourceAttachments.isNotEmpty) {
          _attachments = List.unmodifiable(sourceAttachments);
          _rememberSelectedAttachments();
        }
        _composerStates.remove(sourceSessionId);
        _composerDrafts.remove(sourceSessionId);
        _attachmentsBySession.remove(sourceSessionId);
        notifyListeners();
      }
      return target;
    } finally {
      _pendingWorkspaceId = null;
      _workspaceSettling = false;
      notifyListeners();
    }
  }

  /// 新会话尚未有可 fencing 的 session id，因此这里只校验 owner 身份；后续控制命令再要求 lease。
  Future<MobileSession?> createSession({
    required String workspaceId,
    required String provider,
    required String? deviceId,
    required bool canWrite,
    String? agentPresetId,
    bool autoStart = false,
  }) async {
    if (!_ensureWriteAccess(canWrite: canWrite, deviceId: deviceId)) {
      return null;
    }
    final actionKey = 'create:${workspaceId.trim()}:${provider.trim()}';
    return _runAction<MobileSession?>(actionKey, () async {
      final created = await _relay.createSession(
        CreateMobileSessionInput(
          workspaceId: workspaceId,
          provider: provider,
          deviceId: deviceId!,
          agentPresetId: agentPresetId,
        ),
      );
      _sessions = [
        created,
        ..._sessions.where((item) => item.id != created.id),
      ];
      _phase = SessionListPhase.ready;
      if (!_workspaces.any(
        (workspace) => workspace.id == created.workspaceId,
      )) {
        await refreshWorkspaces();
      }
      await _loadSelectedSession(created.id);
      if (autoStart) {
        await acquireSelectedLease(deviceId: deviceId, canWrite: canWrite);
        final started = await startSelectedSession(
          deviceId: deviceId,
          canWrite: canWrite,
        );
        if (!started) return null;
      }
      return created;
    });
  }

  String _projectIdForRoot(String root) {
    var hash = 0x811c9dc5;
    for (final unit in root.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return 'mobile-${hash.toRadixString(16).padLeft(8, '0')}';
  }

  Future<void> selectSession(String sessionId) =>
      _loadSelectedSession(sessionId);

  /// 归档当前会话：数据保留，仅从默认列表隐藏。
  Future<bool> archiveSelectedSession({
    required String? deviceId,
    required bool canWrite,
  }) async {
    final sessionId = _selectedSessionId;
    if (sessionId == null ||
        !_ensureWriteAccess(canWrite: canWrite, deviceId: deviceId)) {
      return false;
    }
    final archived = await _runAction<MobileSession?>(
      'archive-session:$sessionId',
      () => _relay.archiveSession(sessionId),
    );
    if (archived == null) return false;
    await refreshSessions();
    return _sessionById(sessionId) == null;
  }

  /// 取消归档当前会话；仅用于已归档会话列表的恢复入口。
  Future<bool> unarchiveSelectedSession({
    required String? deviceId,
    required bool canWrite,
  }) async {
    final sessionId = _selectedSessionId;
    if (sessionId == null ||
        !_ensureWriteAccess(canWrite: canWrite, deviceId: deviceId)) {
      return false;
    }
    final restored = await _runAction<MobileSession?>(
      'unarchive-session:$sessionId',
      () => _relay.unarchiveSession(sessionId),
    );
    if (restored == null) return false;
    await refreshSessions();
    return _sessionById(sessionId) != null;
  }

  Future<void> loadOlderHistory() async {
    final sessionId = _selectedSessionId;
    if (sessionId == null || _historyLoading) return;
    final window = _timelineWindows[sessionId] ?? const [];
    final hidden = window.length - _timeline.length;
    if (hidden <= 0) return;
    _historyLoading = true;
    _historyErrorMessage = null;
    notifyListeners();
    try {
      final take = hidden > 25 ? 25 : hidden;
      final start = hidden - take;
      final older = window.sublist(start, hidden);
      _timeline = List.unmodifiable([...older, ..._timeline]);
    } catch (_) {
      _historyErrorMessage = '更早的会话记录暂时不可用，请重试。';
    } finally {
      _historyLoading = false;
      notifyListeners();
    }
  }

  /// 获取 lease 是显式操作，UI 可以准确呈现“只读”与“等待控制权”而不伪造可发送状态。
  Future<void> acquireSelectedLease({
    required String? deviceId,
    required bool canWrite,
    bool reportFailure = true,
  }) async {
    final sessionId = _selectedSessionId;
    if (sessionId == null ||
        !_ensureWriteAccess(canWrite: canWrite, deviceId: deviceId)) {
      return;
    }
    final runtimeLeaseGeneration = _runtimeLeaseGeneration;
    await _runAction<void>(
      'lease:$sessionId',
      reportFailure: reportFailure,
      () async {
      final lease = await _relay.acquireSessionLease(sessionId);
      if (lease.sessionId != sessionId || lease.epoch <= 0) {
        throw const RelayFailure(RelayFailureKind.protocol, 'Relay 返回了无效可操作状态。');
      }
      // 后台/离线后才返回的旧 lease 不能重新解锁 composer；用户必须显式获取新的 fencing epoch。
      if (runtimeLeaseGeneration != _runtimeLeaseGeneration ||
          _selectedSessionId != sessionId) {
        return;
      }
      _selectedLease = lease;
    });
  }

  Future<bool> startSelectedSession({
    required String? deviceId,
    required bool canWrite,
  }) async {
    final sessionId = _selectedSessionId;
    final blocked = controlBlockedReason('start', canWrite: canWrite);
    if (sessionId == null || blocked != null) {
      if (blocked != null) _setError(blocked);
      return false;
    }
    return _submitCommand(
      sessionId: sessionId,
      operation: 'start:$sessionId:${selectedSession?.lastSequence ?? 0}',
      kind: SessionCommandKind.start,
      deviceId: deviceId!,
      ciphertext: {
        'fixture_payload': {
          'session_id': sessionId,
          'provider': selectedSession?.provider ?? 'unknown',
          'model': selectedSession?.model ?? '',
        },
      },
    );
  }

  String? killBlockedReason({required bool canWrite}) =>
      controlBlockedReason('kill', canWrite: canWrite);

  Future<void> killSelectedSession({
    required String? deviceId,
    required bool canWrite,
  }) async {
    final sessionId = _selectedSessionId;
    final blocked = killBlockedReason(canWrite: canWrite);
    if (sessionId == null || blocked != null) {
      if (blocked != null) _setError(blocked);
      return;
    }
    await _submitCommand(
      sessionId: sessionId,
      operation: 'kill:$sessionId:${selectedSession?.lastSequence ?? 0}',
      kind: SessionCommandKind.kill,
      deviceId: deviceId!,
      ciphertext: {
        'fixture_payload': {'session_id': sessionId},
      },
    );
  }

  /// 前后台或网络变化时本地 lease 立即失效。
  /// 已提交到 Relay 的写请求不会被这里重放；恢复阶段只会读取增量 snapshot。
  void invalidateSelectedLeaseForRuntimePause() {
    _runtimeLeaseGeneration += 1;
    if (_selectedLease == null && _skillConfirmation == null) return;
    _selectedLease = null;
    _skillConfirmation = null;
    notifyListeners();
  }

  /// 以当前已确认 cursor 拉取选中会话的增量事件。
  /// 该方法绝不调用 create/send/abort/确认/附件等写接口，生命周期恢复只能走只读路径。
  Future<SessionCursorRecovery?> recoverSelectedSessionFromCursor() async {
    final sessionId = _selectedSessionId;
    if (sessionId == null) return null;
    final selectionGeneration = _selectionGeneration;
    final requestedAfterSequence = _cursorFor(sessionId);
    final existingSequences = _timeline.map((event) => event.sequence).toSet();
    final snapshot = await _relay.getSessionSnapshot(
      sessionId,
      afterSequence: requestedAfterSequence,
    );
    // 用户已切换会话时丢弃迟到的恢复响应，不能把上一会话事件画到当前页面。
    if (_selectedSessionId != sessionId ||
        _selectionGeneration != selectionGeneration) {
      return null;
    }
    final addedEventCount = snapshot.events
        .where((event) => !existingSequences.contains(event.sequence))
        .length;
    _mergeSnapshot(snapshot, appendTimeline: true);
    final controls = await _relay.getSessionControls(sessionId);
    // 控制项读取也可能比路由切换更晚返回。此时不能向恢复控制器报告旧会话成功，
    // 否则应用内通知会指向已经离开的会话。
    if (_selectedSessionId != sessionId ||
        _selectionGeneration != selectionGeneration) {
      return null;
    }
    _controls = controls;
    notifyListeners();
    return SessionCursorRecovery(
      sessionId: sessionId,
      requestedAfterSequence: requestedAfterSequence,
      recoveredCursor: _cursorFor(sessionId),
      addedEventCount: addedEventCount,
    );
  }

  Future<void> sendMessage({
    required String message,
    required String? deviceId,
    required bool canWrite,
  }) async {
    final trimmed = message.trim();
    if (trimmed.isEmpty) {
      _setError('请输入消息后再发送。');
      return;
    }
    final sessionId = _selectedSessionId;
    if (sessionId == null ||
        !_ensureWriteAccess(canWrite: canWrite, deviceId: deviceId) ||
        !_ensureSelectedLease(sessionId)) {
      return;
    }
    // 同一条待发送内容重试复用幂等键；成功后的新输入会生成新的 action key。
    final operation =
        'send:$sessionId:${selectedSession?.lastSequence ?? 0}:$trimmed';
    // 与模型选择器同源：空模型会让 opencode 服务端回退到它的配置默认，
    // 可能命中付费订阅条目，所以发送时必须携带当前生效模型。
    final sessionModel = _controls.model ?? _controls.defaultModel ?? '';
    // 乐观回显：不等 daemon 事件回传，先在本地挂出待确认的用户气泡。
    _pendingOutgoingBySession[sessionId] = trimmed;
    notifyListeners();
    final accepted = await _submitCommand(
      sessionId: sessionId,
      operation: operation,
      kind: SessionCommandKind.send,
      deviceId: deviceId!,
      ciphertext: {
        'fixture_payload': {
          'message': trimmed,
          if (sessionModel.isNotEmpty) 'model': sessionModel,
        },
      },
    );
    if (!accepted && _pendingOutgoingBySession[sessionId] == trimmed) {
      _pendingOutgoingBySession.remove(sessionId);
      notifyListeners();
    }
    // 发送成功后清除草稿，避免页面重建时把已发送内容重新填回输入框。
    clearComposerDraft(sessionId);
  }

  Future<void> stopStreaming({
    required String? deviceId,
    required bool canWrite,
  }) async {
    final sessionId = _selectedSessionId;
    if (sessionId == null ||
        !_ensureWriteAccess(canWrite: canWrite, deviceId: deviceId) ||
        !_ensureSelectedLease(sessionId)) {
      return;
    }
    await _submitCommand(
      sessionId: sessionId,
      operation: 'abort:$sessionId:${selectedSession?.lastSequence ?? 0}',
      kind: SessionCommandKind.abort,
      deviceId: deviceId!,
    );
  }

  Future<MobileSession?> forkFromMessage({
    required String messageId,
    required String? deviceId,
    required bool canWrite,
  }) async {
    final trimmed = messageId.trim();
    final sessionId = _selectedSessionId;
    if (trimmed.isEmpty) {
      _setError('分支消息标识无效。');
      return null;
    }
    if (sessionId == null ||
        !_ensureWriteAccess(canWrite: canWrite, deviceId: deviceId) ||
        !_ensureSelectedLease(sessionId)) {
      return null;
    }
    final operation = 'fork:$sessionId:$trimmed';
    return _runAction<MobileSession?>(operation, () async {
      final lease = _selectedLease;
      if (lease == null || lease.sessionId != sessionId || lease.epoch <= 0) {
        throw const RelayFailure(
          RelayFailureKind.validation,
          '会话可操作状态已变化，请重试。',
        );
      }
      final child = await _relay.forkSession(
        sessionId,
        SessionForkInput(
          messageId: trimmed,
          idempotencyKey: _idempotencyKeyFor(operation),
          leaseEpoch: lease.epoch,
          deviceId: deviceId!,
        ),
      );
      _sessions = [child, ..._sessions.where((item) => item.id != child.id)];
      if (_selectedSessionId == sessionId) {
        final snapshot = await _relay.getSessionSnapshot(
          sessionId,
          afterSequence: _cursorFor(sessionId),
        );
        if (_selectedSessionId == sessionId) {
          _mergeSnapshot(snapshot, appendTimeline: true);
        }
      }
      return child;
    });
  }

  /// v0.2/P2：断线/离线后显式恢复 Provider 会话。
  /// 写命令仍携带正数 lease_epoch 与幂等键；唤醒结果由 Daemon 映射为
  /// resumed / restarted_with_context / unsupported，客户端不在此处伪造结果。
  Future<void> resumeSelectedSession({
    required String? deviceId,
    required bool canWrite,
  }) async {
    final sessionId = _selectedSessionId;
    final blocked = controlBlockedReason('resume', canWrite: canWrite);
    if (sessionId == null || blocked != null) {
      if (blocked != null) _setError(blocked);
      return;
    }
    await _submitCommand(
      sessionId: sessionId,
      operation: 'resume:$sessionId:${selectedSession?.lastSequence ?? 0}',
      kind: SessionCommandKind.resume,
      deviceId: deviceId!,
    );
  }

  /// resume 入口的阻断原因；离线状态也允许发起（与发送不同），只要求 capability 与 lease。
  String? resumeBlockedReason({required bool canWrite}) {
    final declared = selectedProviderCapabilities.capability('resume');
    if (!declared.isSupported) {
      return declared.reason ?? '恢复会话当前不可用。';
    }
    return controlBlockedReason('resume', canWrite: canWrite);
  }

  Future<bool> resolvePermission({
    required String requestId,
    required bool approved,
    required String? deviceId,
    required bool canWrite,
  }) async {
    final sessionId = _selectedSessionId;
    final requestKey = 'permission:$requestId';
    if (_resolvedRequestKeys.contains(requestKey) ||
        isRequestPending(requestId) ||
        sessionId == null ||
        !_ensureWriteAccess(canWrite: canWrite, deviceId: deviceId) ||
        !_ensureSelectedLease(sessionId)) {
      return false;
    }
    // v0.5/P4-D：同一 approval request 的 reject / approve 必须 one-shot。
    // 这里按 requestId 阻断交叉 pending，而不是只按按钮 operation 阻断。
    return _submitCommand(
      sessionId: sessionId,
      operation: '$requestKey:${approved ? 'approve' : 'reject'}',
      kind: approved
          ? SessionCommandKind.permissionApprove
          : SessionCommandKind.permissionReject,
      deviceId: deviceId!,
      ciphertext: {
        'fixture_payload': {'request_id': requestId},
      },
      onAccepted: () => _resolvedRequestKeys.add(requestKey),
    );
  }

  Future<bool> answerQuestion({
    required String requestId,
    required String answer,
    required String? deviceId,
    required bool canWrite,
  }) async {
    final trimmed = answer.trim();
    if (trimmed.isEmpty) {
      _setError('请选择或输入一个回答。');
      return false;
    }
    return answerQuestionBatch(
      requestId: requestId,
      answers: [
        {
          'id': requestId,
          'selected': [trimmed],
        },
      ],
      legacyAnswer: trimmed,
      deviceId: deviceId,
      canWrite: canWrite,
    );
  }

  Future<bool> answerQuestionBatch({
    required String requestId,
    required List<Map<String, dynamic>> answers,
    required String? deviceId,
    required bool canWrite,
    String? legacyAnswer,
  }) async {
    final sessionId = _selectedSessionId;
    final requestKey = 'question:$requestId';
    if (answers.isEmpty) {
      _setError('请选择或输入一个回答。');
      return false;
    }
    if (_resolvedRequestKeys.contains(requestKey) ||
        sessionId == null ||
        !_ensureWriteAccess(canWrite: canWrite, deviceId: deviceId) ||
        !_ensureSelectedLease(sessionId)) {
      return false;
    }
    // v0.5/P4-E：DeepSeek question 使用一次 respond 提交完整 answer batch；
    // Flutter 仍复用现有 question.answer 命令，只把 fixture payload 扩展为 answers[]。
    final fixturePayload = <String, dynamic>{
      'request_id': requestId,
      'answers': answers,
    };
    if (legacyAnswer != null) fixturePayload['answer'] = legacyAnswer;
    return _submitCommand(
      sessionId: sessionId,
      operation: '$requestKey:answer',
      kind: SessionCommandKind.questionAnswer,
      deviceId: deviceId!,
      ciphertext: {'fixture_payload': fixturePayload},
      onAccepted: () => _resolvedRequestKeys.add(requestKey),
    );
  }

  Future<bool> skipQuestion({
    required String requestId,
    required String? deviceId,
    required bool canWrite,
  }) async {
    final sessionId = _selectedSessionId;
    final requestKey = 'question:$requestId';
    if (_resolvedRequestKeys.contains(requestKey) ||
        sessionId == null ||
        !_ensureWriteAccess(canWrite: canWrite, deviceId: deviceId) ||
        !_ensureSelectedLease(sessionId)) {
      return false;
    }
    // v0.5/P4-C：当前 Relay 命令集没有 question.cancel；skip 按 DeepSeek
    // QuestionComposer 的“空选择提交”语义落到既有 question.answer 写链路，
    // 并只在 fixture payload 中显式标记 skipped，避免伪造 Host 取消能力。
    return _submitCommand(
      sessionId: sessionId,
      operation: '$requestKey:skip',
      kind: SessionCommandKind.questionAnswer,
      deviceId: deviceId!,
      ciphertext: {
        'fixture_payload': {'request_id': requestId, 'skipped': true},
      },
      onAccepted: () => _resolvedRequestKeys.add(requestKey),
    );
  }

  bool isRequestPending(String requestId) =>
      _pendingActionKeys.any((key) => key.contains(':$requestId'));

  bool isRequestResolved(String type, String requestId) =>
      _resolvedRequestKeys.contains('$type:$requestId');

  /// 按 Provider capability、认证角色和当前 lease 依次收口写入口；调用方直接把返回原因呈现给用户。
  String? controlBlockedReason(
    String capability, {
    required bool canWrite,
    bool requiresLease = true,
  }) {
    final declared = selectedProviderCapabilities.capability(capability);
    if (!declared.isSupported) {
      return declared.reason ?? '$capability 当前不可用。';
    }
    if (!canWrite) return '当前设备是只读状态';
    if (_selectedSessionId == null) return '请选择一个会话';
    if (requiresLease && !hasSelectedLease) return '会话暂不可操作，请稍后重试';
    return null;
  }

  /// 高风险 Skill 先进入本地确认态；这里没有任何 Relay 写入，拒绝也不会产生 Provider 命令。
  void requestSkillConfirmation(
    SessionSkillDescriptor skill, {
    required bool canWrite,
  }) {
    final blocked = controlBlockedReason('invoke_skill', canWrite: canWrite);
    if (blocked != null) {
      _setError(blocked);
      return;
    }
    _skillConfirmation = SkillConfirmation(skill: skill);
    notifyListeners();
  }

  void rejectSkillConfirmation() {
    if (_skillConfirmation == null) return;
    _skillConfirmation = null;
    notifyListeners();
  }

  Future<void> confirmSkill({
    required String? deviceId,
    required bool canWrite,
  }) async {
    final confirmation = _skillConfirmation;
    final sessionId = _selectedSessionId;
    final blocked = controlBlockedReason('invoke_skill', canWrite: canWrite);
    if (confirmation == null || sessionId == null || blocked != null) {
      if (blocked != null) _setError(blocked);
      return;
    }
    await _submitCommand(
      sessionId: sessionId,
      operation: 'skill:$sessionId:${confirmation.skill.id}',
      kind: SessionCommandKind.skillInvoke,
      deviceId: deviceId!,
      ciphertext: {
        'fixture_payload': {'skill_id': confirmation.skill.id},
      },
      onAccepted: () => _skillConfirmation = null,
    );
  }

  Future<void> approvePlan({
    required String? deviceId,
    required bool canWrite,
  }) async {
    final plan = _controls.plan;
    final sessionId = _selectedSessionId;
    final blocked = controlBlockedReason('plan', canWrite: canWrite);
    if (plan == null ||
        plan.phase != PlanPhase.awaitingApproval ||
        sessionId == null ||
        blocked != null) {
      if (blocked != null) _setError(blocked);
      return;
    }
    await _submitCommand(
      sessionId: sessionId,
      operation: 'plan:$sessionId:approve',
      kind: SessionCommandKind.planApprove,
      deviceId: deviceId!,
      ciphertext: const {
        'fixture_payload': {'action': 'approve'},
      },
      onAccepted: () => _controls = _controls.copyWith(
        plan: plan.copyWith(phase: PlanPhase.active),
      ),
    );
  }

  Future<void> toggleGoal({
    required String? deviceId,
    required bool canWrite,
  }) async {
    final goal = _controls.goal;
    final sessionId = _selectedSessionId;
    final blocked = controlBlockedReason('goal', canWrite: canWrite);
    if (goal == null ||
        goal.phase == GoalPhase.completed ||
        sessionId == null ||
        blocked != null) {
      if (blocked != null) _setError(blocked);
      return;
    }
    final next = goal.phase == GoalPhase.active
        ? GoalPhase.paused
        : GoalPhase.active;
    await _submitCommand(
      sessionId: sessionId,
      operation: 'goal:$sessionId:${next.wireValue}',
      kind: SessionCommandKind.goalToggle,
      deviceId: deviceId!,
      ciphertext: {
        'fixture_payload': {'phase': next.wireValue},
      },
      onAccepted: () =>
          _controls = _controls.copyWith(goal: goal.copyWith(phase: next)),
    );
  }

  /// v0.5/P5-E2：清除当前 Goal 只通过统一写命令完成。
  ///
  /// UI 不能直接把 Goal 从本地 state 移除；这里继续复用 capability、lease、deviceId
  /// 和幂等 key，fixture / 真实 Relay 都应只返回 receipt 后才更新展示态。
  Future<void> clearGoal({
    required String? deviceId,
    required bool canWrite,
  }) async {
    final goal = _controls.goal;
    final sessionId = _selectedSessionId;
    final blocked = controlBlockedReason('goal', canWrite: canWrite);
    if (goal == null || sessionId == null || blocked != null) {
      if (blocked != null) _setError(blocked);
      return;
    }
    await _submitCommand(
      sessionId: sessionId,
      operation: 'goal-clear:$sessionId',
      kind: SessionCommandKind.goalClear,
      deviceId: deviceId!,
      ciphertext: const {
        'fixture_payload': {'action': 'clear'},
      },
      onAccepted: () => _controls = _controls.copyWith(clearGoal: true),
    );
  }

  /// v0.5/P5-E3：通过 `/goal ...` command-input 创建当前 Goal。
  ///
  /// 这是 slash command 的专用 adjudication 结果，不走普通 `session.send`，
  /// 也不把创建动作伪装成 assistant 回复；Host/Relay receipt accepted 后才更新 dock。
  Future<void> createGoal({
    required String objective,
    required String? deviceId,
    required bool canWrite,
  }) async {
    final sessionId = _selectedSessionId;
    final blocked = controlBlockedReason('goal', canWrite: canWrite);
    if (sessionId == null || blocked != null) {
      if (blocked != null) _setError(blocked);
      return;
    }
    if (_controls.goal != null) {
      _setError('当前已有 Goal，请先编辑或清除后再创建。');
      return;
    }
    final trimmed = objective.trim();
    if (trimmed.isEmpty) {
      _setError('请输入 /goal 后的目标文本。');
      return;
    }
    await _submitCommand(
      sessionId: sessionId,
      operation: 'goal-create:$sessionId:${trimmed.hashCode}',
      kind: SessionCommandKind.goalCreate,
      deviceId: deviceId!,
      ciphertext: {
        'fixture_payload': {'objective': trimmed},
      },
      onAccepted: () => _controls = _controls.copyWith(
        goal: SessionGoalSummary(
          title: trimmed,
          progressLabel: '0 / 1',
          phase: GoalPhase.active,
        ),
      ),
    );
  }

  /// 单项入口复用批量预检，保证 picker、paste 和未来 drop 入口使用同一 oracle。
  bool addAttachmentDraft(AttachmentDraft draft) =>
      addAttachmentDrafts([draft]);

  /// 原子接纳一批附件：任何一项失败都不写入本地队列，也不生成上传请求。
  ///
  /// 图片预检顺序与 DeepSeek Harness 对齐：unsupported type -> count ->
  /// single size -> total size；之后才执行通用密文结构校验。
  bool addAttachmentDrafts(Iterable<AttachmentDraft> drafts) {
    final incoming = drafts.toList(growable: false);
    if (incoming.isEmpty) return true;
    String? reason;
    final imageIncoming = incoming.where((draft) => draft.isImage).toList();
    if (imageIncoming.isNotEmpty) {
      final limits = _controls.imageLimits;
      reason = limits == null
          ? '当前会话尚未提供图片限制，图片入口已安全禁用。'
          : limits.validateBatch(
              existing: _attachments.map((item) => item.draft),
              incoming: incoming,
            );
    }
    if (reason == null) {
      for (final draft in incoming) {
        try {
          draft.validate();
        } on RelayFailure catch (failure) {
          reason = failure.message;
          break;
        }
      }
    }
    if (reason != null) {
      _attachmentRejections = [
        ..._attachmentRejections,
        AttachmentRejection(
          localName: incoming.map((draft) => draft.localName).join('、'),
          reason: '整批拒收：$reason',
        ),
      ];
      _errorMessage = reason;
      notifyListeners();
      return false;
    }

    final incomingIds = incoming.map((draft) => draft.id).toSet();
    _attachments = [
      ..._attachments.where((item) => !incomingIds.contains(item.draft.id)),
      for (final draft in incoming)
        AttachmentTransfer(draft: draft, phase: AttachmentTransferPhase.queued),
    ];
    _rememberSelectedAttachments();
    notifyListeners();
    return true;
  }

  void removeAttachment(String attachmentId) {
    _attachments = _attachments
        .where((item) => item.draft.id != attachmentId)
        .toList(growable: false);
    _rememberSelectedAttachments();
    notifyListeners();
  }

  void dismissAttachmentRejection(String localName) {
    _attachmentRejections = _attachmentRejections
        .where((item) => item.localName != localName)
        .toList(growable: false);
    notifyListeners();
  }

  /// 一个 attachment 在同一 session 内顺序上传。每块和 complete 都复用稳定幂等键，失败后从已确认块继续。
  Future<void> uploadAttachment({
    required String attachmentId,
    required String? deviceId,
    required bool canWrite,
  }) async {
    final sessionId = _selectedSessionId;
    final blocked = controlBlockedReason('attachments', canWrite: canWrite);
    final transfer = _attachmentByID(attachmentId);
    if (sessionId == null || transfer == null || blocked != null) {
      if (blocked != null) _setError(blocked);
      return;
    }
    final actionKey = 'attachment:$sessionId:$attachmentId';
    if (_pendingActionKeys.contains(actionKey) ||
        transfer.phase == AttachmentTransferPhase.completed) {
      return;
    }
    final lease = _selectedLease;
    if (lease == null || lease.sessionId != sessionId || lease.epoch <= 0) {
      _setError('会话暂不可操作，请稍后重试。');
      return;
    }

    _errorMessage = null;
    _pendingActionKeys.add(actionKey);
    _replaceAttachment(
      attachmentId,
      transfer.copyWith(
        phase: AttachmentTransferPhase.uploading,
        clearError: true,
      ),
    );
    notifyListeners();
    try {
      var completedChunks = transfer.completedChunks;
      for (
        var index = completedChunks;
        index < transfer.draft.totalChunks;
        index += 1
      ) {
        await _relay.uploadAttachmentChunk(
          AttachmentChunkUploadInput(
            attachmentId: transfer.draft.id,
            sessionId: sessionId,
            mimeType: transfer.draft.mimeType,
            byteSize: transfer.draft.byteSize,
            compression: transfer.draft.compression,
            metadataCiphertext: transfer.draft.metadataCiphertext,
            chunkIndex: index,
            totalChunks: transfer.draft.totalChunks,
            ciphertext: transfer.draft.ciphertextChunks[index],
            idempotencyKey: _idempotencyKeyFor(
              'attachment:$sessionId:$attachmentId:chunk:$index',
            ),
            leaseEpoch: lease.epoch,
            deviceId: deviceId!,
          ),
        );
        completedChunks = index + 1;
        _replaceAttachment(
          attachmentId,
          transfer.copyWith(
            phase: AttachmentTransferPhase.uploading,
            completedChunks: completedChunks,
            clearError: true,
          ),
        );
        notifyListeners();
      }
      await _relay.completeAttachment(
        AttachmentCompleteInput(
          attachmentId: transfer.draft.id,
          sessionId: sessionId,
          totalChunks: transfer.draft.totalChunks,
          idempotencyKey: _idempotencyKeyFor(
            'attachment:$sessionId:$attachmentId:complete',
          ),
          leaseEpoch: lease.epoch,
          deviceId: deviceId!,
        ),
      );
      _replaceAttachment(
        attachmentId,
        transfer.copyWith(
          phase: AttachmentTransferPhase.completed,
          completedChunks: transfer.draft.totalChunks,
          clearError: true,
        ),
      );
    } on RelayFailure catch (failure) {
      final current = _attachmentByID(attachmentId) ?? transfer;
      _replaceAttachment(
        attachmentId,
        current.copyWith(
          phase: AttachmentTransferPhase.failed,
          errorMessage: failure.message,
        ),
      );
      _errorMessage = failure.message;
    } catch (_) {
      const message = '附件上传未完成，请稍后重试。';
      final current = _attachmentByID(attachmentId) ?? transfer;
      _replaceAttachment(
        attachmentId,
        current.copyWith(
          phase: AttachmentTransferPhase.failed,
          errorMessage: message,
        ),
      );
      _errorMessage = message;
    } finally {
      _pendingActionKeys.remove(actionKey);
      notifyListeners();
    }
  }

  bool isAttachmentPending(String attachmentId) =>
      _pendingActionKeys.any((key) => key.endsWith(':$attachmentId'));

  /// v0.2/P3：附件选文件入口的阻断原因；DEK 缺失时保持 fail-closed。
  String? attachmentPickBlockedReason({required bool canWrite}) {
    final blocked = controlBlockedReason('attachments', canWrite: canWrite);
    if (blocked != null) return blocked;
    if (!_contentKeyAvailable) return '等待会话附件密钥';
    if (_controls.imageLimits == null) return '等待图片限制投影';
    if (_picker == null) return '附件选择器不可用';
    return null;
  }

  /// v0.2/P3：真实选附件：选择 -> 本地校验 -> DEK 密封（SystemAttachmentPicker）-> 密文队列。
  /// fixture 模式由注入的确定性 picker 返回预密封草稿。
  Future<bool> pickAttachment({
    required String? deviceId,
    required bool canWrite,
  }) async {
    final sessionId = _selectedSessionId;
    final blocked = attachmentPickBlockedReason(canWrite: canWrite);
    if (sessionId == null || blocked != null) {
      if (blocked != null) _setError(blocked);
      return false;
    }
    final picker = _picker!;
    final actionKey = 'pick:$sessionId';
    if (_pendingActionKeys.contains(actionKey)) return false;
    _errorMessage = null;
    _pendingActionKeys.add(actionKey);
    notifyListeners();
    try {
      final draft = await picker.pickAttachment(
        sessionId: sessionId,
        dekId: 'session-dek:$sessionId',
      );
      if (draft == null) return false;
      return addAttachmentDraft(draft);
    } on RelayFailure catch (failure) {
      _errorMessage = failure.message;
      return false;
    } catch (_) {
      _errorMessage = '附件选择未完成，请稍后重试。';
      return false;
    } finally {
      _pendingActionKeys.remove(actionKey);
      notifyListeners();
    }
  }

  /// v0.2/P3：composer 内切换模型；目标必须在 controls.models 目录中，命令走 lease+幂等。
  Future<void> selectModel({
    required String model,
    required String? deviceId,
    required bool canWrite,
  }) async {
    final sessionId = _selectedSessionId;
    final blocked = controlBlockedReason('model_select', canWrite: canWrite);
    if (sessionId == null || blocked != null) {
      if (blocked != null) _setError(blocked);
      return;
    }
    final controls = _controls;
    final declaredModels = controls.models.isNotEmpty
        ? controls.models
        : selectedProviderCapabilities.optionsFor('model_select');
    if (!declaredModels.contains(model)) {
      _setError('目标模型不在当前目录中。');
      return;
    }
    await _submitCommand(
      sessionId: sessionId,
      operation: 'model:$sessionId:$model',
      kind: SessionCommandKind.modelSelect,
      deviceId: deviceId!,
      ciphertext: {
        'fixture_payload': {'model': model},
      },
      onAccepted: () => _controls = controls.copyWith(model: model),
    );
  }

  /// v0.2/P3：composer 内切换 effort。
  Future<void> selectEffort({
    required String effort,
    required String? deviceId,
    required bool canWrite,
  }) async {
    final sessionId = _selectedSessionId;
    final blocked = controlBlockedReason('effort_select', canWrite: canWrite);
    if (sessionId == null || blocked != null) {
      if (blocked != null) _setError(blocked);
      return;
    }
    final controls = _controls;
    if (!controls.efforts.contains(effort)) {
      _setError('目标 effort 不在当前目录中。');
      return;
    }
    await _submitCommand(
      sessionId: sessionId,
      operation: 'effort:$sessionId:$effort',
      kind: SessionCommandKind.effortSelect,
      deviceId: deviceId!,
      ciphertext: {
        'fixture_payload': {'effort': effort},
      },
      onAccepted: () => _controls = controls.copyWith(effort: effort),
    );
  }

  /// v0.3/P0：composer 内切换 permission mode（Happy sessionSetAgentModes 对齐）。
  Future<void> selectPermissionMode({
    required String mode,
    required String? deviceId,
    required bool canWrite,
  }) async {
    final sessionId = _selectedSessionId;
    final blocked = controlBlockedReason('permission_mode', canWrite: canWrite);
    if (sessionId == null || blocked != null) {
      if (blocked != null) _setError(blocked);
      return;
    }
    final controls = _controls;
    if (!controls.availablePermissionModes.contains(mode)) {
      _setError('目标 permission mode 不在当前目录中。');
      return;
    }
    await _submitCommand(
      sessionId: sessionId,
      operation: 'permission-mode:$sessionId:$mode',
      kind: SessionCommandKind.permissionModeSelect,
      deviceId: deviceId!,
      ciphertext: {
        'fixture_payload': {'permission_mode': mode},
      },
      onAccepted: () => _controls = controls.copyWith(permissionMode: mode),
    );
  }

  /// v0.3/P0：编辑当前目标文本（goal capability 门控；不泄漏密文正文）。
  Future<void> editGoal({
    required String objective,
    required String? deviceId,
    required bool canWrite,
  }) async {
    final sessionId = _selectedSessionId;
    final goal = _controls.goal;
    final blocked = controlBlockedReason('goal', canWrite: canWrite);
    if (sessionId == null || goal == null || blocked != null) {
      if (blocked != null) _setError(blocked);
      return;
    }
    final trimmed = objective.trim();
    if (trimmed.isEmpty) {
      _setError('目标文本不能为空。');
      return;
    }
    await _submitCommand(
      sessionId: sessionId,
      operation: 'goal-edit:$sessionId:${trimmed.hashCode}',
      kind: SessionCommandKind.goalEdit,
      deviceId: deviceId!,
      ciphertext: {
        'fixture_payload': {'objective': trimmed},
      },
      onAccepted: () => _controls = controls.copyWith(
        goal: SessionGoalSummary(
          title: trimmed,
          progressLabel: goal.progressLabel,
          phase: goal.phase,
        ),
      ),
    );
  }

  String? composerBlockedReason({required bool canWrite}) {
    if (!canWrite) return '当前设备是只读状态';
    if (_selectedSessionId == null) return '请选择一个会话';
    if (!hasSelectedLease) return '会话暂不可操作，请稍后重试';
    return null;
  }

  void clearError() {
    if (_errorMessage == null) return;
    _errorMessage = null;
    notifyListeners();
  }

  /// 打开模型 seat 时重新读取当前会话目录；失败只返回 notice，不清空旧目录。
  ///
  /// 这样 reconnect 或 catalog reload 失败不会把原本可用的 Host target 假装成空目录。
  Future<String?> refreshSelectedControls() async {
    final sessionId = _selectedSessionId;
    if (sessionId == null) return '请选择一个会话。';
    final refreshed = await _runAction<SessionControlState?>(
      'controls-refresh:$sessionId',
      () => _relay.getSessionControls(sessionId),
    );
    if (refreshed == null) return _errorMessage ?? '模型目录暂时不可用，请重试。';
    if (_selectedSessionId != sessionId) return '会话已切换，请重新打开模型目录。';
    _controls = refreshed;
    notifyListeners();
    return null;
  }

  /// 已知 slash command 是否声明了图片输入能力。
  ///
  /// 未知 slash 文本仍按普通消息处理；已知控制命令带图片时整次提交拒绝，
  /// 不消费 draft、引用或图片，避免命令载荷被部分提交。
  String? commandImageAdmissionError(String message) {
    if (!attachments.any((item) => item.draft.isImage)) return null;
    final token = message.trimLeft().split(RegExp(r'\s+')).first;
    const knownCommands = {
      '/goal',
      '/permission',
      '/model',
      '/export',
      '/feedback',
    };
    if (!knownCommands.contains(token)) return null;
    return '当前 $token 命令不支持图片附件，请移除图片后重试。';
  }

  /// 读取指定会话的草稿（仅内存；真实写入仍只在用户显式发送时发生）。
  String? composerDraftFor(String sessionId) => _composerDrafts[sessionId];

  SessionComposerSessionState composerStateFor(String sessionId) {
    return _composerStates[sessionId] ??
        SessionComposerSessionState(
          draft: _composerDrafts[sessionId] ?? '',
          references: const [],
          queue: const [],
        );
  }

  /// 保存完整 session-scoped input；attempt/claim 不进入 controller，避免跨路由复活。
  void saveComposerState(String sessionId, SessionComposerSessionState state) {
    if (sessionId.trim().isEmpty) return;
    final normalized = state.draft.length > 8192
        ? state.draft.substring(0, 8192)
        : state.draft;
    final next = state.copyWith(draft: normalized);
    _composerStates[sessionId] = next;
    if (normalized.isEmpty) {
      _composerDrafts.remove(sessionId);
    } else {
      _composerDrafts[sessionId] = normalized;
    }
  }

  /// 保存 composer 草稿。空文本与超过 8 KiB 的超长内容直接清除，防止内存被垃圾内容占用。
  void saveComposerDraft(String sessionId, String text) {
    if (sessionId.trim().isEmpty) return;
    final normalized = text.length > 8192 ? text.substring(0, 8192) : text;
    final prior = composerStateFor(sessionId);
    saveComposerState(sessionId, prior.copyWith(draft: normalized));
  }

  /// 发送成功后清除该会话草稿；草稿绝不落明文盘。
  void clearComposerDraft(String sessionId) {
    final prior = composerStateFor(sessionId);
    final hadDraft =
        _composerDrafts.remove(sessionId) != null ||
        prior.draft.isNotEmpty ||
        prior.references.isNotEmpty;
    if (hadDraft) {
      _composerStates[sessionId] = prior.copyWith(
        draft: '',
        references: const [],
      );
      notifyListeners();
    }
  }

  Future<void> _loadSelectedSession(String sessionId) async {
    if (_sessionById(sessionId) == null) {
      _setError('找不到所选会话。');
      return;
    }
    final previousSessionId = _selectedSessionId;
    if (previousSessionId != null && previousSessionId != sessionId) {
      _attachmentsBySession[previousSessionId] = List.unmodifiable(
        _attachments,
      );
    }
    final selectionGeneration = ++_selectionGeneration;
    _errorMessage = null;
    _historyErrorMessage = null;
    _historyLoading = false;
    _selectedSessionId = sessionId;
    _selectedLease = null;
    _contentKeyAvailable = false;
    // 在读取新会话前先清空上一会话 timeline。否则首次 snapshot 的 cursor 推导会误用旧序号，
    // 并可能遗漏新会话恢复事件或短暂展示错误的会话内容。
    _timeline = const [];
    _resolvedRequestKeys.clear();
    _skillConfirmation = null;
    _attachments = List.unmodifiable(
      _attachmentsBySession[sessionId] ?? const <AttachmentTransfer>[],
    );
    _attachmentRejections = const [];
    _controls = const SessionControlState.empty();
    _isDetailLoading = true;
    notifyListeners();
    try {
      // 会话 DEK 可用性只影响附件选文件入口；异步读取不阻塞快照。
      unawaited(_loadContentKeyAvailability(sessionId, selectionGeneration));
      final snapshot = await _relay.getSessionSnapshot(sessionId);
      if (_selectedSessionId != sessionId ||
          _selectionGeneration != selectionGeneration) {
        return;
      }
      _mergeSnapshot(snapshot);
      final controls = await _relay.getSessionControls(sessionId);
      if (_selectedSessionId == sessionId &&
          _selectionGeneration == selectionGeneration) {
        _controls = controls;
      }
    } on RelayFailure catch (failure) {
      if (_selectedSessionId == sessionId &&
          _selectionGeneration == selectionGeneration) {
        _errorMessage = failure.message;
        _historyErrorMessage = failure.message;
      }
    } catch (_) {
      if (_selectedSessionId == sessionId &&
          _selectionGeneration == selectionGeneration) {
        _errorMessage = '会话内容暂时不可用，请稍后重试。';
        _historyErrorMessage = _errorMessage;
      }
    } finally {
      if (_selectedSessionId == sessionId &&
          _selectionGeneration == selectionGeneration) {
        _isDetailLoading = false;
        notifyListeners();
      }
    }
  }

  /// 轮询命令终态。succeeded 返回 true；failed/rejected/cancelled/expired 返回
  /// false；状态查询失败或超时返回 true，避免确认链路故障阻塞既有受理语义。
  Future<bool> _awaitCommandTerminal(String commandId) async {
    for (var attempt = 0; attempt < 24; attempt += 1) {
      try {
        final receipt = await _relay.getSessionCommand(commandId);
        switch (receipt.status) {
          case 'succeeded':
            return true;
          case 'failed':
          case 'rejected':
          case 'cancelled':
          case 'expired':
            return false;
        }
      } on RelayFailure {
        return true;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return true;
  }

  Future<bool> _submitCommand({
    required String sessionId,
    required String operation,
    required SessionCommandKind kind,
    required String deviceId,
    Map<String, dynamic>? ciphertext,
    VoidCallback? onAccepted,
  }) async {
    if (!_ensureSelectedLease(sessionId)) return false;
    final accepted = await _runAction<bool>(operation, () async {
      final lease = _selectedLease;
      if (lease == null || lease.sessionId != sessionId || lease.epoch <= 0) {
        throw const RelayFailure(
          RelayFailureKind.validation,
          '会话可操作状态已变化，请重试。',
        );
      }
      final command = SessionCommandInput(
        kind: kind,
        idempotencyKey: _idempotencyKeyFor(operation),
        leaseEpoch: lease.epoch,
        deviceId: deviceId,
        ciphertext: ciphertext,
      );
      final receipt = await _relay.submitSessionCommand(sessionId, command);
      if (onAccepted != null) {
        // 执行端异步收口命令：受理（202）不代表成功。带乐观更新面的命令必须等
        // 终态确认，failed 视为失败浮出错误；确认链路不可用时退回受理即确认的
        // 旧行为，不放大故障。
        final confirmed = await _awaitCommandTerminal(receipt.id);
        if (!confirmed) {
          throw const RelayFailure(
            RelayFailureKind.protocol,
            '操作未被会话执行端接受，请重试。',
          );
        }
        onAccepted();
      }
      // 提交后模型需要数秒才产出事件；首次拉取时 message.completed 多半尚未落库。
      // 每一批都合并，直到明确的 completed_turn 或非 streaming 状态到达，
      // 否则只合并第一批会把回复显示出来却遗留“生成中”状态。
      var latest = await _relay.getSessionSnapshot(sessionId);
      if (_selectedSessionId == sessionId) _mergeSnapshot(latest);
      var completed = _snapshotCompletesTurn(latest);
      if (kind == SessionCommandKind.send && !completed) {
        const attempts = 30;
        for (var i = 0; i < attempts; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
          latest = await _relay.getSessionSnapshot(
            sessionId,
            afterSequence: latest.session.lastSequence,
          );
          if (_selectedSessionId == sessionId && latest.events.isNotEmpty) {
            _mergeSnapshot(latest, appendTimeline: true);
          }
          completed = _snapshotCompletesTurn(latest);
          if (completed) break;
        }
      }
      if (kind == SessionCommandKind.send && completed) {
        try {
          final controls = await _relay.getSessionControls(sessionId);
          if (_selectedSessionId == sessionId) {
            _controls = controls;
            notifyListeners();
          }
        } catch (_) {
          // A usage projection can lag the event upload. The next snapshot/recovery
          // will retry controls without turning a successful send into an error.
        }
      }
      return true;
    });
    return accepted == true;
  }

  bool _snapshotCompletesTurn(SessionSnapshot snapshot) {
    if (snapshot.session.status != MobileSessionStatus.streaming) return true;
    final events = snapshot.events
        .map(SessionTimelineEvent.fromRelayEvent)
        .toList(growable: false);
    // Fixture turns deliberately pause at permission/question waits. They are
    // no longer generating from the user's perspective, so do not hold the
    // command poll open while preserving the pending interaction UI.
    if (events.any(
      (event) =>
          (event.permission != null && event.permission!.resolved != true) ||
          (event.question != null && event.question!.resolved != true),
    )) {
      return true;
    }
    return events.any((event) => event.completedTurn);
  }

  /// 流式合并：连续的 assistant 流式增量坍缩为单个生长节点；非流式的
  /// message.completed 全文替换其前的流式节点，避免"生长气泡 + 完整气泡"并排。
  /// completed_turn 终态标记不参与替换（投影层本就不渲染空文本标记）。
  List<SessionTimelineEvent> _coalesceStreaming(List<SessionTimelineEvent> events) {
    final out = <SessionTimelineEvent>[];
    for (final event in events) {
      final last = out.isEmpty ? null : out.last;
      final replacesStreaming = last != null &&
          last.kind == SessionTimelineKind.assistantMessage &&
          last.isStreaming &&
          event.kind == SessionTimelineKind.assistantMessage &&
          !event.completedTurn;
      if (replacesStreaming) {
        out[out.length - 1] = event;
        continue;
      }
      out.add(event);
    }
    return out;
  }

  void _mergeSnapshot(SessionSnapshot snapshot, {bool appendTimeline = false}) {
    // 以 sequence 为唯一序：重复投递去重、乱序排序，replace 与 append 两条路径同规。
    final incoming = <int, SessionTimelineEvent>{
      for (final event in snapshot.events)
        event.sequence: SessionTimelineEvent.fromRelayEvent(event),
    }.values.toList()
      ..sort((left, right) => left.sequence.compareTo(right.sequence));
    final session =
        incoming.any((event) => event.completedTurn) &&
            snapshot.session.status == MobileSessionStatus.streaming
        ? snapshot.session.copyWith(status: MobileSessionStatus.idle)
        : snapshot.session;
    _sessions = [
      session,
      ..._sessions.where((item) => item.id != snapshot.session.id),
    ];
    final priorCursor = _cursorFor(snapshot.session.id);
    final highestIncoming = incoming.fold<int>(
      priorCursor,
      (highest, event) => event.sequence > highest ? event.sequence : highest,
    );
    _sessionCursors[snapshot.session.id] = highestIncoming;
    if (!appendTimeline) {
      _timelineWindows[snapshot.session.id] = List.unmodifiable(incoming);
      if (_selectedSessionId == snapshot.session.id) {
        final coalesced = _coalesceStreaming(incoming);
        final start = coalesced.length > 50 ? coalesced.length - 50 : 0;
        _timeline = List.unmodifiable(coalesced.sublist(start));
      }
      return;
    }
    final priorWindow = _timelineWindows[snapshot.session.id] ?? const [];
    final mergedWindow =
        <int, SessionTimelineEvent>{
            for (final event in priorWindow) event.sequence: event,
            for (final event in incoming) event.sequence: event,
          }.values.toList()
          ..sort((left, right) => left.sequence.compareTo(right.sequence));
    _timelineWindows[snapshot.session.id] = List.unmodifiable(mergedWindow);
    if (_selectedSessionId != snapshot.session.id) return;
    // Relay 的 after_seq 语义应当排除已确认事件；客户端仍按 sequence 去重并排序，
    // 防止网络重连、代理重试或重复投递把同一时间线节点展示两次。
    final merged =
        <int, SessionTimelineEvent>{
            for (final event in _timeline) event.sequence: event,
            for (final event in incoming) event.sequence: event,
          }.values.toList()
          ..sort((left, right) => left.sequence.compareTo(right.sequence));
    _timeline = List.unmodifiable(_coalesceStreaming(merged));
    // 规范化 user.message 已合并进时间线时，该会话的乐观回显完成使命，立即清账
    // 避免同一条消息渲染两个气泡。
    final pending = _pendingOutgoingBySession[snapshot.session.id];
    if (pending != null &&
        merged.any(
          (event) =>
              event.kind == SessionTimelineKind.userMessage &&
              event.text == pending,
        )) {
      _pendingOutgoingBySession.remove(snapshot.session.id);
    }
  }

  int _cursorFor(String? sessionId) {
    if (sessionId == null) return 0;
    final known = _sessionCursors[sessionId];
    if (known != null) return known;
    var highest = 0;
    if (_selectedSessionId == sessionId) {
      for (final event in _timeline) {
        if (event.sequence > highest) highest = event.sequence;
      }
    }
    return highest;
  }

  /// 会话切换后异步确认 DEK 可用性；迟到的旧会话响应会被 generation 丢弃。
  Future<void> _loadContentKeyAvailability(
    String sessionId,
    int selectionGeneration,
  ) async {
    var available = false;
    try {
      available = await _relay.sessionContentKeyAvailable(sessionId);
    } catch (_) {
      available = false;
    }
    if (_selectedSessionId != sessionId ||
        _selectionGeneration != selectionGeneration) {
      return;
    }
    _contentKeyAvailable = available;
    notifyListeners();
  }

  AttachmentTransfer? _attachmentByID(String attachmentId) {
    for (final transfer in _attachments) {
      if (transfer.draft.id == attachmentId) return transfer;
    }
    return null;
  }

  void _replaceAttachment(String attachmentId, AttachmentTransfer next) {
    _attachments = _attachments
        .map((item) => item.draft.id == attachmentId ? next : item)
        .toList(growable: false);
    _rememberSelectedAttachments();
  }

  void _rememberSelectedAttachments() {
    final sessionId = _selectedSessionId;
    if (sessionId == null) return;
    _attachmentsBySession[sessionId] = List.unmodifiable(_attachments);
  }

  MobileSession? _sessionById(String? sessionId) {
    if (sessionId == null) return null;
    for (final session in _sessions) {
      if (session.id == sessionId) return session;
    }
    return null;
  }

  bool _ensureWriteAccess({required bool canWrite, required String? deviceId}) {
    if (!canWrite || deviceId == null || deviceId.isEmpty) {
      _setError('当前设备为只读状态，没有 Android 写控制端，请使用 owner 设备继续。');
      return false;
    }
    return true;
  }

  bool _ensureSelectedLease(String sessionId) {
    final lease = _selectedLease;
    if (lease == null || lease.sessionId != sessionId || lease.epoch <= 0) {
      _setError('会话暂不可操作，请稍后重试。');
      return false;
    }
    return true;
  }

  String _idempotencyKeyFor(
    String operation,
  ) => _idempotencyKeys.putIfAbsent(operation, () {
    _idempotencyCounter += 1;
    final randomPart = _random.nextInt(1 << 32).toRadixString(16);
    return 'mobile-${_clock().toUtc().microsecondsSinceEpoch}-${_idempotencyCounter.toString().padLeft(4, '0')}-$randomPart';
  });

  Future<T?> _runAction<T>(
    String actionKey,
    Future<T> Function() action, {
    bool reportFailure = true,
  }) async {
    if (_pendingActionKeys.contains(actionKey)) return null;
    _errorMessage = null;
    _pendingActionKeys.add(actionKey);
    notifyListeners();
    try {
      return await action();
    } on RelayFailure catch (failure) {
      if (reportFailure) _errorMessage = failure.message;
      return null;
    } catch (_) {
      if (reportFailure) _errorMessage = '操作未完成，请稍后重试。';
      return null;
    } finally {
      _pendingActionKeys.remove(actionKey);
      notifyListeners();
    }
  }

  void _clearSelection() {
    _selectionGeneration += 1;
    _selectedSessionId = null;
    _selectedLease = null;
    _timeline = const [];
    _resolvedRequestKeys.clear();
    _controls = const SessionControlState.empty();
    _skillConfirmation = null;
    _attachments = const [];
    _attachmentRejections = const [];
  }

  void _setError(String message) {
    _errorMessage = message;
    notifyListeners();
  }
}
