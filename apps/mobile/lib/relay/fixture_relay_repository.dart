import 'dart:typed_data';

import '../domain/control_models.dart';
import '../domain/daemon_observation_models.dart';
import '../domain/delegation_models.dart';
import '../domain/models.dart';
import '../domain/session_models.dart';
import '../domain/session_projection_models.dart';
import '../domain/terminal_models.dart';
import '../domain/usage_models.dart';
import 'relay_repository.dart';

/// 可重复的本地 Relay fixture。它只模拟白名单元数据，绝不生成会话正文。
class FixtureRelayRepository implements RelayRepository {
  FixtureRelayRepository({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  final List<Device> _devices = [];
  final List<TerminalSummary> _terminals = [];
  final Map<String, PairingRequest> _pairings = {};
  final Map<String, _FixtureSessionState> _sessions = {};
  final Map<String, MobileWorkspace> _workspaces = {};
  final Map<String, WorkspaceCreateState> _workspaceCreateStates = {};
  final Map<String, WorkspaceSyncState> _workspaceSyncStates = {};
  final Map<String, WorkspaceImportState> _workspaceImportStates = {};
  final Map<String, _FixtureAttachmentState> _attachments = {};
  final Map<String, _FixtureDelegationState> _delegations = {};
  final Map<String, Map<String, ConversationFeedbackItem>> _feedback = {};
  final Map<String, String> _forkIdsByParentKey = {};
  var _pairingSequence = 0;
  var _sessionSequence = 0;
  var _commandSequence = 0;
  var _delegationSequence = 0;
  var _failNextAttachmentChunk = false;
  int? _failAttachmentChunkAtIndex;
  bool _networkAvailable = true;
  // v0.9.2（V092 录屏/可见场景）：模拟"执行侧上报 DSH 不可用"的形态。
  // 开启后 getCapabilities 的 dsh 条目回到 fail-closed，且 facts_source=unavailable，
  // 用于录制"不可用 → 恢复 → 可发送"的闭环；不影响其它 Provider 条目。
  bool executionSideDshUnavailable = false;
  bool _repeatCursorEventOnNextSnapshot = false;
  final Map<String, List<int>> _snapshotAfterSequences = {};

  /// v0.8.7（V087-04）：时间释放流式回合。`timedStreamSchedule` 允许测试/可见
  /// gate 覆盖脚本；为 null 时发送 'v087 timed' 使用内置 gate 默认脚本。
  /// 已触发时间释放的会话进入 `_timedReleaseSessions`，快照按当前时钟过滤
  /// 未到期帧（对历史事件透明——它们的 createdAt 都在过去）。
  TimedStreamSchedule? timedStreamSchedule;
  final Set<String> _timedReleaseSessions = <String>{};

  /// v0.2/P3：fixture 默认模拟「本机已持有会话内容密钥」（真实 Keystore 通道未部署）。
  /// 置为 false 可复现「无 DEK」时附件入口 fail-closed 的行为。
  bool contentKeysReady = true;

  /// 仅供 deterministic fixture 控制器注入时钟；生产 Relay 不暴露该能力。
  DateTime fixtureNow() => _clock();

  /// 视觉/测试专用：改写会话的最后活动时间，模拟历史会话的排序。
  /// 真实 Relay 的 last_activity 只由状态/事件写入推导，不提供改写入口。
  void seedSessionActivity({
    required String sessionId,
    required DateTime lastActivityAt,
  }) {
    final state = _sessions[sessionId];
    if (state == null) return;
    state.session = state.session.copyWith(lastActivityAt: lastActivityAt);
  }

  /// v0.3/P1：置为 true 模拟「Provider 探测失败」——能力矩阵 available=false 且带中文原因，
  /// 用于验证状态条 fail-closed 展示（MOBILE-13）。
  bool providersUnavailable = false;

  /// 供 ATTACH-01 注入一次可恢复失败；下一次相同幂等键重试必须能够继续。
  void failNextAttachmentChunk() => _failNextAttachmentChunk = true;

  /// 可见 fixture 在首块确认后让指定块失败，用于同时展示上传进度与重试入口。
  void failAttachmentChunkAtIndex(int chunkIndex) {
    _failAttachmentChunkAtIndex = chunkIndex;
  }

  int get submittedCommandCount => _commandSequence;

  int get delegationCount => _delegations.length;

  @override
  Future<DeviceBootstrapResult> bootstrapDevice(
    BootstrapOwnerInput input,
  ) async {
    if (_devices.isNotEmpty) {
      throw const RelayFailure(
        RelayFailureKind.forbidden,
        'fixture 账号已经完成首台 Android owner 初始化。',
      );
    }
    final owner = Device(
      id: 'android-owner-fixture',
      role: DeviceRole.androidOwner,
      status: DeviceStatus.active,
      displayName: input.displayName.trim().isEmpty
          ? '此 Android 控制端'
          : input.displayName.trim(),
      platform: input.platform,
      lastSeen: _clock(),
    );
    _devices.add(owner);
    return DeviceBootstrapResult(
      tokens: _newTokens(deviceId: owner.id),
      device: owner,
    );
  }

  /// P6 测试只用这个开关模拟 Relay 不可达；远端事件注入仍可发生，表示应用离线期间服务端继续推进。
  void setNetworkAvailable(bool value) => _networkAvailable = value;

  /// 终端元数据只供 P3 状态页 fixture 使用；它不模拟 Daemon 命令、日志或工作区根。
  void replaceTerminals(Iterable<TerminalSummary> terminals) {
    _terminals
      ..clear()
      ..addAll(terminals);
  }

  /// 仅供 P1 deterministic UI fixture 注入已同步的安全 DSH 工作区投影。
  void replaceWorkspaces(Iterable<MobileWorkspace> workspaces) {
    _workspaces
      ..clear()
      ..addEntries(
        workspaces.map((workspace) => MapEntry(workspace.id, workspace)),
      );
  }

  void setWorkspaceSyncState(String commandId, WorkspaceSyncState state) {
    _workspaceSyncStates[commandId] = state;
  }

  List<int> snapshotAfterSequencesFor(String sessionId) =>
      List<int>.unmodifiable(_snapshotAfterSequences[sessionId] ?? const []);

  /// 下一次 snapshot 故意重发 cursor 边界事件，用于验证客户端恢复时的 sequence 去重保护。
  void repeatCursorEventOnNextSnapshot() =>
      _repeatCursorEventOnNextSnapshot = true;

  /// 模拟应用离线期间 Relay 收到的新事件；该入口绕过本地网络开关，不能用于普通业务写操作。
  Future<void> appendOfflineRecoveryEvent(String sessionId) async {
    final state = _sessionState(sessionId);
    state.append(
      eventType: 'session.recovery.available',
      payload: {
        'kind': 'system_notice',
        'label': '离线期间有新事件',
        'text': '已在恢复后按 cursor 补齐一条 fixture 状态事件。',
      },
      now: _clock(),
    );
    state.updateSession(status: MobileSessionStatus.idle, now: _clock());
  }

  @override
  Future<AuthTokens> register(LoginCredentials credentials) async {
    credentials.validate();
    if (_devices.isNotEmpty) {
      throw const RelayFailure(
        RelayFailureKind.forbidden,
        'fixture 账号已经完成首次注册。',
      );
    }
    // 模拟 Relay 注册时创建的初始 owner 设备；后续 bootstrap 只补齐该设备公钥。
    const ownerId = 'android-owner-fixture';
    _devices.add(
      Device(
        id: ownerId,
        role: DeviceRole.androidOwner,
        status: DeviceStatus.active,
        displayName: 'Android Owner',
        platform: 'android',
        lastSeen: _clock(),
      ),
    );
    return _newTokens(deviceId: ownerId);
  }

  @override
  Future<AuthTokens> login(LoginCredentials credentials) async {
    credentials.validate();
    if (credentials.email.trim().toLowerCase() == 'offline@fixture.test') {
      throw const RelayFailure(
        RelayFailureKind.unavailable,
        '本地 Relay fixture 当前不可用。',
      );
    }
    // 密码登录故意只返回无设备绑定 token，owner 必须使用安全保存的 refresh 或恢复码。
    return _newTokens();
  }

  @override
  Future<AuthTokens> refresh(String refreshToken) async {
    if (refreshToken.isEmpty) {
      throw const RelayFailure(RelayFailureKind.unauthorized, '设备连接已失效，请重新连接。');
    }
    return _newTokens(deviceId: _deviceIdFromRefreshToken(refreshToken));
  }

  @override
  Future<void> logout(AuthTokens tokens) async {}

  @override
  Future<Device> bootstrapOwner(BootstrapOwnerInput input) async {
    final owner = Device(
      id: 'android-owner-fixture',
      role: DeviceRole.androidOwner,
      status: DeviceStatus.active,
      displayName: input.displayName,
      platform: input.platform,
      lastSeen: _clock(),
    );
    final existing = _devices.indexWhere((device) => device.id == owner.id);
    if (existing >= 0) {
      _devices[existing] = owner;
    } else if (_devices.any((device) => device.isOwner)) {
      throw const RelayFailure(RelayFailureKind.forbidden, '账号已经有 owner 设备。');
    } else {
      _devices.add(owner);
    }
    return owner;
  }

  @override
  Future<List<Device>> listDevices() async =>
      List<Device>.unmodifiable(_devices);

  @override
  Future<void> revokeDevice(String deviceId) async {
    final index = _devices.indexWhere((device) => device.id == deviceId);
    if (index < 0) {
      throw const RelayFailure(RelayFailureKind.protocol, '找不到要撤销的设备。');
    }
    final device = _devices[index];
    _devices[index] = Device(
      id: device.id,
      role: device.role,
      status: DeviceStatus.revoked,
      displayName: device.displayName,
      platform: device.platform,
      lastSeen: device.lastSeen,
    );
  }

  @override
  Future<List<TerminalSummary>> listTerminals() async {
    _requireFixtureNetwork();
    return List<TerminalSummary>.unmodifiable(_terminals);
  }

  final List<UsageSummary> _usageSummaries = [];

  /// 预置账号用量聚合（ADR-010 白名单计数）；未预置时返回空摘要。
  void replaceUsageSummary(UsageSummary summary) {
    _usageSummaries
      ..clear()
      ..add(summary);
  }

  @override
  Future<UsageSummary> getUsageSummary({int days = 30}) async {
    _requireFixtureNetwork();
    return _usageSummaries.isEmpty ? UsageSummary.empty : _usageSummaries.first;
  }

  @override
  Future<PairingRequest> createPairing(PairingRequestInput input) async {
    if (!_devices.any((device) => device.isOwner)) {
      throw const RelayFailure(
        RelayFailureKind.forbidden,
        '必须先建立 Android owner。',
      );
    }
    _pairingSequence += 1;
    final request = PairingRequest(
      id: 'pairing-fixture-${_pairingSequence.toString().padLeft(3, '0')}',
      status: PairingStatus.pending,
      role: input.role,
      displayName: input.displayName,
      expiresAt: _clock().add(const Duration(minutes: 10)),
    );
    _pairings[request.id] = request;
    return request;
  }

  @override
  Future<PairingRequest> getPairing(String requestId) async =>
      _pairings[requestId] ??
      (throw const RelayFailure(RelayFailureKind.protocol, '找不到配对请求。'));

  @override
  Future<Device> approvePairing(String requestId) async {
    final request = await getPairing(requestId);
    if (request.status != PairingStatus.pending) {
      throw const RelayFailure(RelayFailureKind.protocol, '该配对请求不能再批准。');
    }
    final approved = PairingRequest(
      id: request.id,
      status: PairingStatus.approved,
      role: request.role,
      displayName: request.displayName,
      expiresAt: request.expiresAt,
    );
    _pairings[requestId] = approved;
    final device = Device(
      id: 'device-${request.id}',
      role: request.role,
      status: DeviceStatus.active,
      displayName: request.displayName,
      platform: 'fixture',
      lastSeen: _clock(),
    );
    _devices.add(device);
    return device;
  }

  @override
  Future<void> cancelPairing(String requestId) async {
    final request = await getPairing(requestId);
    _pairings[requestId] = PairingRequest(
      id: request.id,
      status: PairingStatus.cancelled,
      role: request.role,
      displayName: request.displayName,
      expiresAt: request.expiresAt,
    );
  }

  @override
  Future<String> generateRecoveryCode() async {
    if (!_devices.any((device) => device.isOwner)) {
      throw const RelayFailure(RelayFailureKind.forbidden, '当前设备不是 owner。');
    }
    // fixture 仅提供稳定测试值；真实实现不会把该明文写入日志、缓存或数据库。
    return 'RECOVERY-FIXTURE-0001';
  }

  @override
  Future<RecoveryResult> restoreWithRecoveryCode(
    RecoveryCodeInput input,
  ) async {
    if (input.code != 'RECOVERY-FIXTURE-0001') {
      throw const RelayFailure(RelayFailureKind.unauthorized, '恢复码无效或已过期。');
    }
    final device = Device(
      id: 'recovered-android-fixture',
      role: DeviceRole.androidOwner,
      status: DeviceStatus.active,
      displayName: input.displayName,
      platform: 'android',
      lastSeen: _clock(),
    );
    _devices
      ..clear()
      ..add(device);
    return RecoveryResult(
      tokens: _newTokens(deviceId: device.id),
      device: device,
    );
  }

  @override
  Future<List<MobileSession>> listSessions() async {
    _requireFixtureNetwork();
    final sessions = _sessions.values
        .map((state) => state.session)
        .where((session) => session.archivedAt == null)
        .toList();
    sessions.sort(MobileSession.compareByLastActivity);
    return List<MobileSession>.unmodifiable(sessions);
  }

  @override
  Future<List<MobileSession>> listArchivedSessions() async {
    _requireFixtureNetwork();
    final sessions = _sessions.values
        .map((state) => state.session)
        .where((session) => session.archivedAt != null)
        .toList();
    sessions.sort((left, right) {
      final leftTime =
          left.archivedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final rightTime =
          right.archivedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      return rightTime.compareTo(leftTime);
    });
    return List<MobileSession>.unmodifiable(sessions);
  }

  @override
  Future<List<MobileWorkspace>> listWorkspaces() async {
    _requireFixtureNetwork();
    return List<MobileWorkspace>.unmodifiable(_workspaces.values);
  }

  @override
  Future<WorkspaceSyncState> syncDSHWorkspaces({String terminalId = ''}) async {
    _requireFixtureNetwork();
    _requireFixtureOwner();
    final commandId = 'fixture-dsh-sync';
    final existing = _workspaceSyncStates[commandId];
    if (existing != null) return existing;
    final dsh = _workspaces.values
        .where((workspace) => workspace.isDsh)
        .toList(growable: false);
    final state = WorkspaceSyncState(
      status: 'succeeded',
      commandId: commandId,
      workspaceIds: dsh
          .map((workspace) => workspace.id)
          .toList(growable: false),
    );
    _workspaceSyncStates[commandId] = state;
    return state;
  }

  @override
  Future<WorkspaceSyncState> getDSHWorkspaceSyncState(String commandId) async {
    _requireFixtureNetwork();
    final state = _workspaceSyncStates[commandId.trim()];
    if (state == null) {
      throw const RelayFailure.validation('工作区同步命令不存在。');
    }
    return state;
  }

  @override
  Future<WorkspaceImportState> importDSHSessions({
    required String workspaceId,
    String terminalId = '',
    bool includeAll = false,
  }) async {
    _requireFixtureNetwork();
    _requireFixtureOwner();
    final workspace = _workspaces[workspaceId.trim()];
    if (workspace == null || !workspace.isDsh) {
      throw const RelayFailure.validation('只能导入 DSH 工作区的历史会话。');
    }
    if (terminalId.trim().isNotEmpty &&
        terminalId.trim() != workspace.terminalId) {
      throw const RelayFailure(RelayFailureKind.forbidden, '导入必须使用工作区归属终端。');
    }
    final commandId = 'fixture-dsh-import-${workspace.id}';
    final existing = _workspaceImportStates[commandId];
    if (existing != null) return existing;
    final state = WorkspaceImportState(
      status: 'succeeded',
      commandId: commandId,
      sessionIds: _sessions.values
          .map((item) => item.session)
          .where(
            (session) =>
                session.workspaceId == workspace.id &&
                session.provider == 'dsh',
          )
          .map((session) => session.id)
          .toList(growable: false),
    );
    _workspaceImportStates[commandId] = state;
    return state;
  }

  @override
  Future<WorkspaceImportState> getDSHImportState(String commandId) async {
    _requireFixtureNetwork();
    final state = _workspaceImportStates[commandId.trim()];
    if (state == null) {
      throw const RelayFailure.validation('历史会话导入命令不存在。');
    }
    return state;
  }

  @override
  Future<MobileWorkspace> createWorkspace(
    CreateMobileWorkspaceInput input,
  ) async {
    input.validate();
    _requireFixtureNetwork();
    _requireFixtureOwner();
    final id = 'ws_${input.projectId.trim()}';
    if (_workspaces.containsKey(id)) {
      throw const RelayFailure(RelayFailureKind.validation, '该目录已经登记为工作区。');
    }
    final workspace = MobileWorkspace(
      id: id,
      projectId: input.projectId.trim(),
      terminalId: input.terminalId.trim(),
      branch: input.branch.trim().isEmpty ? null : input.branch.trim(),
      status: 'active',
    );
    _workspaces[id] = workspace;
    return workspace;
  }

  @override
  Future<WorkspaceCreateState> createWorkspaceWithFolder(
    CreateMobileWorkspaceWithFolderInput input,
  ) async {
    input.validate();
    _requireFixtureNetwork();
    _requireFixtureOwner();
    final projectId = 'fixture-${input.name.trim()}';
    final workspaceID = 'ws_$projectId';
    var workspace = _workspaces[workspaceID];
    workspace ??= await createWorkspace(
      CreateMobileWorkspaceInput(
        projectId: projectId,
        canonicalRoot: '/fixture/${input.name.trim()}',
        deviceId: input.deviceId,
        terminalId: input.terminalId,
      ),
    );
    final commandID = 'fixture-workspace-create-${workspace.id}';
    final state = WorkspaceCreateState(
      status: 'succeeded',
      commandId: commandID,
      workspaceId: workspace.id,
      workspace: workspace,
    );
    // fixture 没有异步 Daemon，但仍记录 command-like key 以覆盖轮询读取契约。
    _workspaceCreateStates[commandID] = state;
    return state;
  }

  @override
  Future<WorkspaceCreateState> getWorkspaceCreateState(String commandId) async {
    _requireFixtureNetwork();
    final state = _workspaceCreateStates[commandId];
    if (state == null) {
      throw const RelayFailure(RelayFailureKind.validation, '工作区创建命令不存在。');
    }
    return state;
  }

  @override
  Future<MobileSession> createSession(CreateMobileSessionInput input) async {
    input.validate();
    _requireFixtureNetwork();
    _requireFixtureOwner();
    _sessionSequence += 1;
    final id = 'session-fixture-${_sessionSequence.toString().padLeft(3, '0')}';
    final workspaceId = input.workspaceId.trim();
    // v0.8.5 §3.4：workspace_name 与真实 Relay 对齐——由工作区表解析安全显示名
    //（display_name），而不是把 workspace_id 当名字下发。fixture 没有独立工作区行时
    // 才回退到 id（displayName 为空），保证既有测试无需预置工作区也能运行。
    _workspaces.putIfAbsent(
      workspaceId,
      () => MobileWorkspace(
        id: workspaceId,
        projectId: workspaceId,
        terminalId: '',
        status: 'active',
      ),
    );
    final workspaceRow = _workspaces[workspaceId];
    final workspaceDisplayName = workspaceRow?.displayName?.trim() ?? '';
    final workspaceName = workspaceDisplayName.isNotEmpty
        ? workspaceDisplayName
        : workspaceId;
    final session = MobileSession(
      id: id,
      workspaceId: workspaceId,
      status: MobileSessionStatus.idle,
      provider: input.provider.trim().isEmpty ? 'codex' : input.provider.trim(),
      lastSequence: 1,
      displayName: '新的会话 $_sessionSequence',
      projectName: 'Fixture Project',
      workspaceName: workspaceName,
      updatedAt: _clock(),
      lastActivityAt: _clock(),
      agentPresetId: input.agentPresetId?.trim(),
    );
    final state = _FixtureSessionState(
      session: session,
      controls: _fixtureControlsForProvider(session.provider),
    );
    state.append(
      eventType: 'session.created',
      payload: const {
        'kind': 'system_notice',
        'label': '会话已创建',
        'text': '此会话使用本地 deterministic fixture，不会请求真实 Provider。',
      },
      now: _clock(),
    );
    _sessions[id] = state;
    return state.session;
  }

  @override
  Future<MobileSession> forkSession(
    String sessionId,
    SessionForkInput input,
  ) async {
    input.validate();
    _requireFixtureNetwork();
    _requireFixtureOwner();
    final parent = _sessionState(sessionId);
    _ensureFixtureLease(parent, input.leaseEpoch);
    final forkKey = '$sessionId:${input.idempotencyKey}';
    final existingID = _forkIdsByParentKey[forkKey];
    if (existingID != null) return _sessionState(existingID).session;

    _sessionSequence += 1;
    final id = 'session-fixture-${_sessionSequence.toString().padLeft(3, '0')}';
    final child = MobileSession(
      id: id,
      workspaceId: parent.session.workspaceId,
      status: MobileSessionStatus.idle,
      provider: parent.session.provider,
      model: parent.session.model,
      lastSequence: 1,
      displayName: '分支会话 $_sessionSequence',
      projectName: parent.session.projectName,
      workspaceName: parent.session.workspaceName,
      updatedAt: _clock(),
      lastActivityAt: _clock(),
      parentSessionId: parent.session.id,
      forkedFromMessageId: input.messageId,
      agentPresetId: parent.session.agentPresetId,
    );
    final childState = _FixtureSessionState(
      session: child,
      controls: parent.controls,
    );
    childState.append(
      eventType: 'session.created',
      payload: {
        'kind': 'system_notice',
        'label': '已创建分支会话',
        'text': 'fixture 只创建 child session 元数据，不复制 parent 正文。',
        'parent_session_id': parent.session.id,
        'forked_from_message_id': input.messageId,
      },
      now: _clock(),
    );
    parent.append(
      eventType: 'session.forked',
      payload: {
        'kind': 'system_notice',
        'label': '已创建分支',
        'text': '分支会话 ${child.id} 已创建。',
        'child_session_id': child.id,
        'forked_from_message_id': input.messageId,
      },
      now: _clock(),
    );
    _sessions[id] = childState;
    _forkIdsByParentKey[forkKey] = id;
    return childState.session;
  }

  @override
  Future<MobileSession> archiveSession(String sessionId) async {
    _requireFixtureNetwork();
    _requireFixtureOwner();
    final state = _sessionState(sessionId);
    if (state.session.archivedAt != null) return state.session;
    state.session = state.session.copyWith(archivedAt: _clock());
    return state.session;
  }

  @override
  Future<MobileSession> unarchiveSession(String sessionId) async {
    _requireFixtureNetwork();
    _requireFixtureOwner();
    final state = _sessionState(sessionId);
    if (state.session.archivedAt == null) return state.session;
    state.session = state.session.copyWith(clearArchivedAt: true);
    return state.session;
  }

  @override
  Future<SessionSnapshot> getSessionSnapshot(
    String sessionId, {
    int afterSequence = 0,
    int? beforeSequence,
    int? limit,
  }) async {
    if (afterSequence < 0) {
      throw const RelayFailure(RelayFailureKind.validation, '事件游标不能为负数。');
    }
    _requireFixtureNetwork();
    final state = _sessionState(sessionId);
    _snapshotAfterSequences
        .putIfAbsent(sessionId, () => <int>[])
        .add(afterSequence);
    // v0.8.7（V087-04）：时间释放会话按当前时钟隐藏未到期帧。会话行的
    // lastSequence 同步修正为可见最大 seq——客户端把 lastSequence 当作下一轮
    // after_seq，若包含未来帧序号，未到期 delta 将永远不可见。
    final timedRelease = _timedReleaseSessions.contains(sessionId);
    final visibleBefore = _clock();
    // v0.9.5 P2：before_seq 翻页返回游标之前的最多 limit 条（升序）；fixture
    // 历史较小，全量满足窗口语义，不模拟截断。
    if (beforeSequence != null && beforeSequence >= 0) {
      final page = state.events
          .where((event) => event.sequence < beforeSequence)
          .where(
            (event) =>
                !timedRelease ||
                !(event.createdAt?.isAfter(_clock()) ?? false),
          )
          .toList(growable: false);
      return SessionSnapshot(
        session: state.session,
        events: List<RelaySessionEvent>.unmodifiable(page),
      );
    }
    final events = state.events
        .where((event) => event.sequence > afterSequence)
        .where(
          (event) =>
              !timedRelease ||
              // 无 createdAt 的历史事件视为已到期（只增不删）。
              !(event.createdAt?.isAfter(visibleBefore) ?? false),
        )
        .toList(growable: true);
    var snapshotSession = state.session;
    if (timedRelease) {
      final visibleMaxSequence = events.fold<int>(
        afterSequence,
        (highest, event) =>
            event.sequence > highest ? event.sequence : highest,
      );
      snapshotSession = snapshotSession.copyWith(
        lastSequence: visibleMaxSequence,
      );
    }
    if (_repeatCursorEventOnNextSnapshot && afterSequence > 0) {
      _repeatCursorEventOnNextSnapshot = false;
      final boundary = state.events.where(
        (event) => event.sequence == afterSequence,
      );
      if (boundary.isNotEmpty) events.insert(0, boundary.single);
    }
    return SessionSnapshot(
      session: snapshotSession,
      events: List<RelaySessionEvent>.unmodifiable(events),
    );
  }

  @override
  Future<DaemonSessionObservation> getSessionDaemonObservation(
    String sessionId, {
    int afterSequence = 0,
  }) async {
    if (afterSequence < 0) {
      throw const RelayFailure(
        RelayFailureKind.validation,
        'Daemon 观察事件游标不能为负数。',
      );
    }
    _requireFixtureNetwork();
    final state = _sessionState(sessionId);
    // fixture 只复用同一只读 DTO 以验证页面边界；它不模拟 Daemon 执行、命令回执或 E2EE 密钥。
    final receipts = state.commandReceipts.values.toList()
      ..sort((left, right) => left.id.compareTo(right.id));
    return DaemonSessionObservation(
      session: DaemonObservationSession(
        status: state.session.status,
        provider: state.session.provider,
        lastSequence: state.session.lastSequence,
      ),
      commands: List<DaemonCommandObservation>.unmodifiable([
        for (final receipt in receipts)
          DaemonCommandObservation(
            kind: DaemonObservationCommandKind.fromWire(receipt.kind),
            status: DaemonObservationCommandStatus.fromWire(receipt.status),
            // deterministic fixture 未启动 Daemon；不能把 accepted 命令伪装成已接收或已执行。
            deliveryState: DaemonDeliveryState.queued,
          ),
      ]),
      events: List<DaemonCipherEventObservation>.unmodifiable([
        for (final event in state.events.where(
          (item) => item.sequence > afterSequence,
        ))
          DaemonCipherEventObservation(
            sequence: event.sequence,
            eventType: DaemonObservationEventType.fromWire(event.eventType),
            // fixture payload 即使是测试数据也不进入观察 DTO，始终按无 DEK 的 opaque 状态渲染。
            envelope: const CipherEnvelopeMetadata(
              state: CipherEnvelopeState.opaque,
            ),
          ),
      ]),
    );
  }

  @override
  Future<SessionLease> acquireSessionLease(String sessionId) async {
    _requireFixtureNetwork();
    _requireFixtureOwner();
    final state = _sessionState(sessionId);
    // 每次显式获取都推进 fencing epoch，确保旧 UI 操作无法被 fixture 静默接受。
    state.leaseEpoch += 1;
    return SessionLease(sessionId: sessionId, epoch: state.leaseEpoch);
  }

  @override
  Future<SessionCommandReceipt> getSessionCommand(String commandId) async {
    _requireFixtureNetwork();
    // fixture 命令一律即时成功收口；时序演练由测试用 relay 子类覆写本方法。
    return SessionCommandReceipt(
      id: commandId,
      kind: '',
      status: 'succeeded',
      idempotencyKey: 'fixture-$commandId',
    );
  }

  @override
  Future<SessionCommandReceipt> submitSessionCommand(
    String sessionId,
    SessionCommandInput input,
  ) async {
    input.validate();
    _requireFixtureNetwork();
    _requireFixtureOwner();
    final state = _sessionState(sessionId);
    if (input.leaseEpoch != state.leaseEpoch) {
      throw const RelayFailure(RelayFailureKind.forbidden, '会话可操作状态已更新，请重试。');
    }
    final existing = state.commandReceipts[input.idempotencyKey];
    if (existing != null) {
      return existing;
    }

    switch (input.kind) {
      case SessionCommandKind.start:
        _appendStart(state);
      case SessionCommandKind.send:
        _appendSendConversation(state, input.ciphertext);
      case SessionCommandKind.abort:
        _appendAbort(state);
      case SessionCommandKind.kill:
        _appendKill(state);
      case SessionCommandKind.resume:
        // v0.2/P2：resume 不伪造 Provider 唤醒结果，真实三态只能来自 Daemon 的
        // Adapter 映射。v0.9.2 P2（T3 裁决）：resume 是"发送前自动恢复"的正确语义
        // （续接原 instance，不新建），真实 daemon 恢复成功后会把会话投影推进为
        // idle；fixture 必须跟随这一行为，否则恢复判定链路无法端到端验证。
        state.resumeCount += 1;
        state.append(
          eventType: 'session.resumed',
          payload: const {
            'kind': 'system_notice',
            'label': '会话已恢复',
            'text': '本地 deterministic fixture 已恢复会话执行状态（保留原实例）。',
          },
          now: _clock(),
        );
        state.updateSession(status: MobileSessionStatus.idle, now: _clock());
      case SessionCommandKind.permissionApprove:
      case SessionCommandKind.permissionReject:
        _appendPermissionDecision(state, input);
      case SessionCommandKind.questionAnswer:
        _appendQuestionAnswer(state, input);
      case SessionCommandKind.planApprove:
        _appendPlanApproval(state);
      case SessionCommandKind.goalToggle:
        _appendGoalToggle(state);
      case SessionCommandKind.goalClear:
        _appendGoalClear(state);
      case SessionCommandKind.goalCreate:
        _appendGoalCreate(state, input.ciphertext);
      case SessionCommandKind.skillInvoke:
        _appendSkillInvocation(state, input);
      case SessionCommandKind.modelSelect:
        _applyModelSelect(state, input.ciphertext);
      case SessionCommandKind.effortSelect:
        _applyEffortSelect(state, input.ciphertext);
      case SessionCommandKind.permissionModeSelect:
        _applyPermissionModeSelect(state, input.ciphertext);
      case SessionCommandKind.goalEdit:
        _applyGoalEdit(state, input.ciphertext);
      // v0.8.8 P2/P3：应用层只读命令（git/file）在 fixture 会话命令面不支持——
      // fixture 的只读视图走独立 FixtureGitDiff/FixtureWorkspaceFiles 仓库，
      // 不经会话命令链路；这里 fail-closed 拒绝，不伪造 tool_result 结果。
      case SessionCommandKind.gitStatus:
      case SessionCommandKind.gitChanges:
      case SessionCommandKind.gitDiff:
      case SessionCommandKind.fileTree:
      case SessionCommandKind.fileRead:
      case SessionCommandKind.codeRead:
        throw const RelayFailure(
          RelayFailureKind.unavailable,
          'fixture 会话命令面不支持只读命令（只读视图走独立 fixture 仓库）。',
        );
    }
    _commandSequence += 1;
    final receipt = SessionCommandReceipt(
      id: 'command-fixture-${_commandSequence.toString().padLeft(3, '0')}',
      kind: input.kind.wireValue,
      status: 'accepted',
      idempotencyKey: input.idempotencyKey,
      leaseEpoch: input.leaseEpoch,
    );
    state.commandReceipts[input.idempotencyKey] = receipt;
    return receipt;
  }

  /// 仅为 unit/widget/可见 macOS fixture 创建“来自 parent Adapter”的 proposed 节点。
  /// UI 本身不伪造任务书：真实运行必须由已授权 Adapter 提供加密 envelope 后才会出现此卡片。
  Future<SessionDelegation> seedDelegationProposal({
    required String parentSessionId,
    String targetProvider = 'codex',
  }) async {
    final parent = _sessionState(parentSessionId);
    _delegationSequence += 1;
    final sequence = _delegationSequence.toString().padLeft(3, '0');
    final delegation = SessionDelegation(
      id: 'delegation-fixture-$sequence',
      parentSessionId: parent.session.id,
      targetProvider: targetProvider,
      status: DelegationStatus.proposed,
      summaryEnvelope: _fixtureDelegationEnvelope(sequence),
      summaryEnvelopeSha256: _fixtureDelegationHash(sequence),
    );
    _delegations[delegation.id] = _FixtureDelegationState(delegation);
    _appendDelegationEvent(parent, delegation);
    return delegation;
  }

  @override
  Future<SessionDelegation> proposeDelegation(
    String parentSessionId,
    DelegationProposalInput input,
  ) async {
    input.validate();
    _requireFixtureNetwork();
    _requireFixtureOwner();
    final parent = _sessionState(parentSessionId);
    _ensureFixtureLease(parent, input.parentLeaseEpoch);
    // 幂等：相同请求键只返回首次创建的节点。
    final existing = _delegations.values
        .where(
          (state) =>
              state.delegation.parentSessionId == parentSessionId &&
              state.proposalKeys.contains(input.idempotencyKey),
        )
        .toList();
    if (existing.isNotEmpty) return existing.first.delegation;

    _delegationSequence += 1;
    final sequence = _delegationSequence.toString().padLeft(3, '0');
    final delegation = SessionDelegation(
      id: 'delegation-fixture-$sequence',
      parentSessionId: parent.session.id,
      targetProvider: input.targetProvider,
      status: DelegationStatus.proposed,
      // fixture 只使用固定加密 envelope，绝不把 UI 输入的摘要正文当作 ciphertext 落盘。
      summaryEnvelope: _fixtureDelegationEnvelope(sequence),
      summaryEnvelopeSha256: _fixtureDelegationHash(sequence),
    );
    _delegations[delegation.id] = _FixtureDelegationState(
      delegation,
      proposalKeys: {input.idempotencyKey},
    );
    _appendDelegationEvent(parent, delegation);
    return delegation;
  }

  @override
  Future<List<SessionDelegation>> listSessionDelegations(
    String parentSessionId,
  ) async {
    _sessionState(parentSessionId);
    return _delegations.values
        .map((state) => state.delegation)
        .where((delegation) => delegation.parentSessionId == parentSessionId)
        .toList(growable: false);
  }

  @override
  Future<SessionDelegation> decideDelegation(
    String delegationId,
    DelegationDecisionInput input,
  ) async {
    input.validate();
    _requireFixtureOwner();
    final state = _delegations[delegationId];
    if (state == null) {
      throw const RelayFailure(RelayFailureKind.protocol, '找不到派发节点。');
    }
    final parent = _sessionState(state.delegation.parentSessionId);
    _ensureFixtureLease(parent, input.parentLeaseEpoch);
    final previous = state.decisions[input.idempotencyKey];
    if (previous != null) return previous;

    final current = state.delegation;
    SessionDelegation next;
    switch (input.decision) {
      case DelegationDecision.approve:
        if (!current.canApproveOrReject) {
          throw const RelayFailure(RelayFailureKind.protocol, '该派发节点不能再确认。');
        }
        final target = (await getCapabilities()).provider(
          current.targetProvider,
        );
        if (!target.capability('delegate_cross_provider').isSupported) {
          throw RelayFailure(
            RelayFailureKind.forbidden,
            target.capability('delegate_cross_provider').reason ??
                '目标 Provider 不支持跨工具派发。',
          );
        }
        // Fixture child 必须走普通会话创建和独立 lease，不会继承 parent epoch 或时间线正文。
        final child = await createSession(
          CreateMobileSessionInput(
            workspaceId: parent.session.workspaceId,
            provider: current.targetProvider,
            deviceId: input.deviceId,
          ),
        );
        final childState = _sessionState(child.id);
        childState.session = childState.session.copyWith(
          parentSessionId: parent.session.id,
          subagentReadOnlyReason: 'one-shot',
        );
        await acquireSessionLease(child.id);
        _sessionState(
          child.id,
        ).updateSession(status: MobileSessionStatus.streaming, now: _clock());
        next = current.copyWith(
          childSessionId: child.id,
          status: DelegationStatus.running,
        );
      case DelegationDecision.reject:
        if (!current.canApproveOrReject) {
          throw const RelayFailure(RelayFailureKind.protocol, '该派发节点不能再拒绝。');
        }
        next = current.copyWith(status: DelegationStatus.rejected);
      case DelegationDecision.cancel:
        if (!current.canCancel) {
          throw const RelayFailure(RelayFailureKind.protocol, '该派发节点当前不能取消。');
        }
        final childId = current.childSessionId;
        if (childId != null) {
          _sessionState(
            childId,
          ).updateSession(status: MobileSessionStatus.stopped, now: _clock());
        }
        next = current.copyWith(status: DelegationStatus.cancelled);
    }
    state
      ..delegation = next
      ..decisions[input.idempotencyKey] = next;
    _appendDelegationEvent(parent, next);
    return next;
  }

  @override
  Future<CapabilityMatrix> getCapabilities() async {
    _requireFixtureNetwork();
    if (providersUnavailable) {
      // 探测失败：全部 Provider 不可用，能力全部 unsupported 并带中文原因。
      return CapabilityMatrix(
        providers: [
          for (final kind in const ['codex', 'claude', 'opencode', 'openclaw'])
            ProviderCapabilityProfile(
              kind: kind,
              version: '',
              available: false,
              capabilities: [
                for (final name in _fixtureCapabilityNames())
                  CapabilityEntry(
                    name: name,
                    availability: CapabilityAvailability.unsupported,
                    reason: 'OpenCode 本地服务探测失败，控制能力已安全禁用。',
                  ),
              ],
            ),
        ],
      );
    }
    return CapabilityMatrix(
      providers: [
        _fixtureProvider(
          'codex',
          native: const {
            'start',
            'kill',
            'resume',
            'abort',
            'usage',
            'plan',
            'goal',
            'skill_catalog',
            'invoke_skill',
            'model_select',
            'effort_select',
            // v0.8.8 P4：attachments 升格后为 emulated（桥 admission 上限）——
            // fixture 矩阵与真实 successMatrix 对齐，不再按 native 消费。
            'permission_mode',
            'fork',
            'delegate_session',
            // v0.8.8 P2：daemonCapabilities 恒声明 file_read/git_read（§9.3-3），
            // fixture 矩阵与真实 hello 对齐，Git/文件只读入口按矩阵放行。
            'file_read',
            'git_read',
          },
          emulated: const {'delegate_cross_provider', 'attachments'},
        ),
        _fixtureProvider(
          'dsh',
          native: const {
            'start',
            'kill',
            'resume',
            'abort',
            'usage',
            'model_select',
            // v0.8.3 P5 升格：deterministic overlay 通过后全链路成立。
            'permission_mode',
            'fork',
            // v0.8.8 P4 升格：应用层只读命令通道成立（恒声明 + 沙箱 + 真实传输）。
            'file_read',
            'git_read',
          },
          emulated: const {
            'permission',
            // v0.8.3 P5 升格（dsh/* extension 承载上限 emulated）。
            'question',
            'plan',
            'goal',
            'skill_catalog',
            'invoke_skill',
            // v0.8.8 P4 升格：opaque attachment ref 全链路成立，桥 admission 上限
            // emulated（Keystore 实机 gate 承接 V085）。
            'attachments',
          },
          // v0.9.2 P1：执行侧事实来源（云端形态下 Relay 自己跑不了 DSH，
          // 可用性由 Daemon 上报），与 /v1/capabilities 的 facts_source 对齐。
          factsSource: 'terminal',
          unavailableReason: executionSideDshUnavailable ? '执行侧未找到 node 运行时' : null,
          // 与 internal/adapter/dsh successMatrix v0.8.8 口径一致：
          // 升格项 reason 引用套件证据；未接通项如实标注残余链路。
          unsupportedReasons: const {
            'delegate_session': '桥未实现会话委托',
            'delegate_cross_provider': '桥未实现跨 Provider 委托',
          },
        ),
        _fixtureProvider(
          'claude',
          native: const {'skill_catalog', 'model_select'},
          emulated: const {'plan', 'goal'},
        ),
        _fixtureProvider('opencode'),
        _fixtureProvider('openclaw', native: const {'skill_catalog'}),
      ],
    );
  }

  @override
  Future<SessionControlState> getSessionControls(String sessionId) async {
    _requireFixtureNetwork();
    return _sessionState(sessionId).controls;
  }

  /// V094 可见场景专用（计划 P0 fixture 冻结）：为指定会话覆盖确定性 controls
  /// 投影（如长模型名、完全访问目录）。只注入无敏感演示值，不触碰命令链路，
  /// 供布局/紧凑徽标 gate 构造稳定画面；真实 Relay 永远不接受客户端覆盖。
  void applyVisualControlsOverride(String sessionId, SessionControlState controls) {
    final state = _sessionState(sessionId);
    state.controls = controls;
  }

  @override
  Future<ConversationFeedbackItem?> getMessageFeedback(
    String sessionId,
    String messageId,
  ) async {
    _requireFixtureNetwork();
    _sessionState(sessionId);
    return _feedback[sessionId]?[messageId];
  }

  @override
  Future<ConversationFeedbackResult> putMessageFeedback(
    String sessionId, {
    required String messageId,
    required ConversationFeedbackRating rating,
    String? note,
    int? version,
  }) async {
    _requireFixtureNetwork();
    _sessionState(sessionId);
    final bucket = _feedback.putIfAbsent(sessionId, () => {});
    final current = bucket[messageId];
    if (current == null) {
      if (version != null) {
        return const ConversationFeedbackResult.failure('version-conflict');
      }
      final created = ConversationFeedbackItem(
        rating: rating,
        note: note?.trim().isEmpty == true ? null : note?.trim(),
        version: 1,
      );
      bucket[messageId] = created;
      return ConversationFeedbackResult.success(created);
    }
    if (version == null || current.version != version) {
      return const ConversationFeedbackResult.failure('version-conflict');
    }
    final updated = ConversationFeedbackItem(
      rating: rating,
      note: note?.trim().isEmpty == true ? null : note?.trim(),
      version: current.version + 1,
    );
    bucket[messageId] = updated;
    return ConversationFeedbackResult.success(updated);
  }

  @override
  Future<ConversationFeedbackResult> deleteMessageFeedback(
    String sessionId, {
    required String messageId,
    required int version,
  }) async {
    _requireFixtureNetwork();
    _sessionState(sessionId);
    final bucket = _feedback[sessionId];
    final current = bucket?[messageId];
    if (current == null || current.version != version) {
      return const ConversationFeedbackResult.failure('version-conflict');
    }
    bucket!.remove(messageId);
    return const ConversationFeedbackResult.success();
  }

  @override
  Future<bool> sessionContentKeyAvailable(String sessionId) async {
    _sessionState(sessionId);
    return contentKeysReady;
  }

  @override
  Future<WrappedContentDEK?> fetchSessionContentDEK(String sessionId) async {
    // fixture 附件草稿是预密封的确定性字节，不经真实 DEK wrap 通道：
    // 可用性（contentKeysReady）放行入口，但 fetch 返回 null——解密语义由
    // fixture picker/密文块模拟，真实 unwrap 只在 http 链（providers）发生。
    _sessionState(sessionId);
    return null;
  }

  @override
  Future<AttachmentReceipt> uploadAttachmentChunk(
    AttachmentChunkUploadInput input,
  ) async {
    input.validate();
    _requireFixtureNetwork();
    _requireFixtureOwner();
    final session = _sessionState(input.sessionId);
    _ensureFixtureLease(session, input.leaseEpoch);
    if (_failNextAttachmentChunk ||
        _failAttachmentChunkAtIndex == input.chunkIndex) {
      _failNextAttachmentChunk = false;
      _failAttachmentChunkAtIndex = null;
      throw const RelayFailure(
        RelayFailureKind.unavailable,
        'fixture 在上传附件块时临时断开，请重试。',
      );
    }

    final existing = _attachments[input.attachmentId];
    final attachment = existing ?? _FixtureAttachmentState.fromInput(input);
    if (existing == null) {
      _attachments[input.attachmentId] = attachment;
    } else if (!attachment.matches(input) || attachment.completed) {
      throw const RelayFailure(RelayFailureKind.protocol, '附件上传元数据与首次请求不一致。');
    }

    final previous = attachment.chunks[input.chunkIndex];
    if (previous != null) {
      if (previous.idempotencyKey == input.idempotencyKey &&
          _sameBytes(previous.ciphertext, input.ciphertext)) {
        return AttachmentReceipt(
          attachmentId: input.attachmentId,
          chunkIndex: input.chunkIndex,
          status: 'pending',
          idempotent: true,
        );
      }
      throw const RelayFailure(RelayFailureKind.protocol, '附件块幂等键或内容冲突。');
    }
    if (attachment.chunks.length != input.chunkIndex) {
      throw const RelayFailure(RelayFailureKind.validation, '附件密文块必须按顺序上传。');
    }
    attachment.chunks[input.chunkIndex] = _FixtureAttachmentChunk(
      idempotencyKey: input.idempotencyKey,
      ciphertext: Uint8List.fromList(input.ciphertext),
    );
    return AttachmentReceipt(
      attachmentId: input.attachmentId,
      chunkIndex: input.chunkIndex,
      status: 'pending',
      idempotent: false,
    );
  }

  @override
  Future<AttachmentReceipt> completeAttachment(
    AttachmentCompleteInput input,
  ) async {
    input.validate();
    _requireFixtureNetwork();
    _requireFixtureOwner();
    final session = _sessionState(input.sessionId);
    _ensureFixtureLease(session, input.leaseEpoch);
    final attachment = _attachments[input.attachmentId];
    if (attachment == null || attachment.sessionId != input.sessionId) {
      throw const RelayFailure(RelayFailureKind.protocol, '找不到要完成的附件。');
    }
    if (attachment.completed) {
      if (attachment.completeIdempotencyKey == input.idempotencyKey) {
        return AttachmentReceipt(
          attachmentId: input.attachmentId,
          chunkIndex: -1,
          status: 'completed',
          idempotent: true,
        );
      }
      throw const RelayFailure(RelayFailureKind.protocol, '附件已经由另一完成请求收口。');
    }
    if (attachment.totalChunks != input.totalChunks ||
        attachment.chunks.length != attachment.totalChunks) {
      throw const RelayFailure(RelayFailureKind.validation, '附件仍有未上传的密文块。');
    }
    attachment
      ..completed = true
      ..completeIdempotencyKey = input.idempotencyKey;
    return AttachmentReceipt(
      attachmentId: input.attachmentId,
      chunkIndex: -1,
      status: 'completed',
      idempotent: false,
    );
  }

  _FixtureSessionState _sessionState(String sessionId) =>
      _sessions[sessionId] ??
      (throw const RelayFailure(RelayFailureKind.protocol, '找不到会话。'));

  /// V094 收口测试辅助：暴露会话内部状态以便测试直接构造 canonical 事件
  /// 序列（仅测试通道使用，真实调用面不暴露内部状态）。
  dynamic debugSessionState(String sessionId) => _sessionState(sessionId);

  void _requireFixtureOwner() {
    if (!_devices.any((device) => device.isOwner)) {
      throw const RelayFailure(
        RelayFailureKind.forbidden,
        '当前 fixture 没有 active Android owner。',
      );
    }
  }

  void _requireFixtureNetwork() {
    if (!_networkAvailable) {
      throw const RelayFailure(
        RelayFailureKind.unavailable,
        '本地 Relay fixture 当前不可用。',
      );
    }
  }

  void _appendSendConversation(
    _FixtureSessionState state,
    Map<String, dynamic>? ciphertext,
  ) {
    final fixturePayload = ciphertext?['fixture_payload'];
    final message = fixturePayload is Map && fixturePayload['message'] is String
        ? (fixturePayload['message'] as String).trim()
        : '';
    if (message.isEmpty) {
      throw const RelayFailure(RelayFailureKind.validation, '请输入要发送的消息。');
    }
    // v0.8.4（V084-10/VISUAL-MOBILE-36，ADR-015 §3/§5）：流式投影可见场景。
    // 以固定、无敏感的本地 fixture 事件展示 phase 状态行 + thought 独立通道 +
    // 打字机增量正文；时间线故意停在 streaming 中段，让可见窗口能同时捕捉
    // 状态行、thought 节点与生长中的回答（终态收敛由组件与 overlay 测试覆盖）。
    // V094（计划 P0 fixture 冻结）：确定性 Markdown 历史场景。发送包含
    // 'v094 markdown' 的消息 → 生成用户消息 + 富 Markdown 助手回复
    // （GFM 表格、围栏代码块、行内代码、列表），供布局/内容渲染 gate
    // 使用；全部为公开 fixture 文本，不含敏感内容。
    if (message.contains('v094 markdown')) {
      final now = _clock();
      final base = state.nextSequence;
      state.append(
        eventType: 'message.user',
        payload: {
          'kind': 'user_message',
          'label': '你',
          'text': message,
          'copy_text': message,
          'created_at': now.toIso8601String(),
          'message_id': 'fixture-message-$base',
        },
        now: now,
      );
      const markdownReply = '这是 V094 fixture 的 Markdown 演示回复。\n\n'
          '### 汇总表格\n\n'
          '| 模块 | 状态 | 说明 |\n'
          '| --- | --- | --- |\n'
          '| 发送事务 | 已受理 | Relay 202 只代表受理 |\n'
          '| 恢复 | 待机 | daemon 重启后自动 resume |\n\n'
          '### 部署命令\n\n'
          '```bash\n'
          'task test:v094:local\n'
          'flutter run -d <device-id>\n'
          '```\n\n'
          '行内代码使用 `flutter analyze` 检查，要点：\n\n'
          '- 气泡不等于送达\n'
          '- 202 不等于 Provider 成功\n';
      state.append(
        eventType: 'message.assistant',
        payload: {
          'kind': 'assistant_message',
          'label': 'Assistant',
          'text': markdownReply,
          'copy_text': markdownReply,
          'streaming': false,
          'message_id': 'fixture-message-${base + 1}',
        },
        now: now,
      );
      state.updateSession(status: MobileSessionStatus.idle, now: now);
      return;
    }
    // V094（计划 P0 fixture 冻结）：发送失败与自动恢复历史场景。发送包含
    // 'v094 recovery' 的消息 → 用户消息 + 结构化错误 notice（local_state_missing）
    // + 已恢复提示 + 恢复后的助手回复，供错误折叠/恢复链可见性 gate 使用。
    if (message.contains('v094 recovery')) {
      final now = _clock();
      final base = state.nextSequence;
      state.append(
        eventType: 'message.user',
        payload: {
          'kind': 'user_message',
          'label': '你',
          'text': message,
          'copy_text': message,
          'created_at': now.toIso8601String(),
          'message_id': 'fixture-message-$base',
        },
        now: now,
      );
      // 结构化错误事实（error_code）与用户语言提示分离：V094-03/18 的验收锚点。
      state.append(
        eventType: 'session.activity',
        payload: {
          'kind': 'system_notice',
          'label': 'Provider 错误',
          'text': '执行端实例已失效，正在自动恢复会话。',
          'error_code': 'LOCAL_STATE_MISSING',
          'created_at': now.toIso8601String(),
        },
        now: now,
      );
      const recoveredReply = '会话已自动恢复（自动重试 1/1），上一条消息已送达并完成处理。';
      state.append(
        eventType: 'message.assistant',
        payload: {
          'kind': 'assistant_message',
          'label': 'Assistant',
          'text': recoveredReply,
          'copy_text': recoveredReply,
          'streaming': false,
          'message_id': 'fixture-message-${base + 1}',
        },
        now: now,
      );
      state.updateSession(status: MobileSessionStatus.idle, now: now);
      return;
    }
    // v0.8.4（V084-10/VISUAL-MOBILE-36，ADR-015 §3/§5）：流式投影可见场景。
    // 以固定、无敏感的本地 fixture 事件展示 phase 状态行 + thought 独立通道 +
    // 打字机增量正文；时间线故意停在 streaming 中段，让可见窗口能同时捕捉
    // 状态行、thought 节点与生长中的回答（终态收敛由组件与 overlay 测试覆盖）。
    if (message.contains('v084 stream')) {
      final now = _clock();
      final base = state.nextSequence;
      state.append(
        eventType: 'message.user',
        payload: {
          'kind': 'user_message',
          'label': '你',
          'text': message,
          'copy_text': message,
          'created_at': now.toIso8601String(),
          'message_id': 'fixture-message-$base',
        },
        now: now,
      );
      void phase(String name, int revision, String reason) {
        state.append(
          eventType: 'turn.phase',
          payload: {
            'kind': 'turn_phase',
            'phase': name,
            'reason': reason,
            'revision': revision,
            'turn_id': 'fixture-turn-1',
          },
          now: now,
        );
      }

      void thought(String text, bool streaming) {
        state.append(
          eventType: 'message.thought.delta',
          payload: {
            'kind': 'assistant_thought',
            'label': '思考中',
            'text': text,
            'streaming': streaming,
            'visibility': 'raw',
            'message_id': 'fixture-t1s1',
          },
          now: now,
        );
      }

      phase('preparing', 1, 'turn_start');
      phase('thinking', 2, 'first_thought_delta');
      // 与 LocalDevEventEncoder 的累积语义一致：每帧回发全量已收文本，
      // 客户端按"整体替换"折叠为单一生长节点。
      thought('先拆解请求要点，确认输出范围。', true);
      thought('先拆解请求要点，确认输出范围。再组织分步回答的措辞。', true);
      phase('streaming', 3, 'first_text_delta');
      state.append(
        eventType: 'message.assistant.delta',
        payload: const {
          'kind': 'assistant_message',
          'label': 'Assistant',
          'text': '这是 v084 流式投影的增量回答：',
          'streaming': true,
          'message_id': 'fixture-t1s2',
        },
        now: now,
      );
      state.updateSession(status: MobileSessionStatus.streaming, now: now);
      return;
    }
    // v0.8.7（V087-04，迭代计划 §3.4）：时间释放流式回合。全部增量帧在发送
    // 时刻入库，但 createdAt 打上「回合开始后偏移」的未来时间戳；快照按当前
    // 时钟只暴露已到期帧（见 getSessionSnapshot 的可见性过滤），completed
    // 全文与 completed_turn 在 completedAfter 到期后释放。「逐步到达」在
    // 注入时钟（controller/widget 测试）与真实时钟（macOS 可见 gate）下同语义。
    if (message.contains('v087 timed')) {
      final schedule = timedStreamSchedule ?? TimedStreamSchedule.gateDefault();
      final start = _clock();
      state.append(
        eventType: 'message.user',
        payload: {
          'kind': 'user_message',
          'label': '你',
          'text': message,
          'copy_text': message,
          'created_at': start.toIso8601String(),
          'message_id': 'fixture-message-${state.nextSequence}',
        },
        now: start,
      );
      for (var i = 0; i < schedule.offsets.length; i++) {
        final arriveAt = start.add(schedule.offsets[i]);
        state.append(
          eventType: 'message.assistant.delta',
          payload: {
            'kind': 'assistant_message',
            'label': 'Assistant',
            // localdev 语义：每帧回发「全量已收文本」，客户端整体替换。
            'text': schedule.fullTexts[i],
            'streaming': true,
            'message_id': 'fixture-v087-timed',
            'created_at': arriveAt.toIso8601String(),
          },
          now: arriveAt,
        );
      }
      final completedAt = start.add(schedule.completedAfter);
      state.append(
        eventType: 'message.assistant.delta',
        payload: {
          'kind': 'assistant_message',
          'label': 'Assistant',
          'text': schedule.finalText,
          'streaming': false,
          'copy_text': schedule.finalText,
          'message_id': 'fixture-v087-timed',
          'created_at': completedAt.toIso8601String(),
        },
        now: completedAt,
      );
      state.append(
        eventType: 'turn.completed',
        payload: {
          'kind': 'assistant_message',
          'completed_turn': true,
          'created_at': completedAt.toIso8601String(),
        },
        now: completedAt,
      );
      state.updateSession(status: MobileSessionStatus.streaming, now: start);
      _timedReleaseSessions.add(state.session.id);
      return;
    }
    final now = _clock();
    final userSequence = state.nextSequence;
    state.append(
      eventType: 'message.user',
      payload: {
        'kind': 'user_message',
        'label': '你',
        'text': message,
        'copy_text': message,
        'created_at': now.toIso8601String(),
        'message_id': 'fixture-message-$userSequence',
      },
      now: now,
    );
    state.append(
      eventType: 'message.assistant.delta',
      payload: const {
        'kind': 'assistant_message',
        'label': 'Assistant',
        'text': '正在整理这条请求的可控步骤',
        'streaming': true,
      },
      now: now,
    );
    state.append(
      eventType: 'tool.started',
      payload: {
        'kind': 'tool_activity',
        'label': '读取工作区状态',
        'text': 'fixture 工具活动，不含真实命令或文件内容。',
        'tool_status': '运行中',
        'file_path': '.',
        'tool_input': '{"kind":"workspace.status","path":"."}',
        'tool_output': 'fixture: workspace status ready',
        'inspect_target': 'fixture-tool-${state.nextSequence}',
        'produced_files': const [
          'reports/fixture-summary.md',
          'logs/fixture.log',
        ],
      },
      now: now,
    );
    state.append(
      eventType: 'permission.requested',
      payload: {
        'kind': 'permission_request',
        'label': '需要确认',
        'permission': {
          'request_id': 'permission-${state.session.id}-${state.nextSequence}',
          'title': '允许继续执行 fixture 工具步骤？',
          'summary': '仅用于验证确认卡和幂等控制，不会执行本地 shell。',
          // v0.5/P4-D：仅为本地 UI 回归提供脱敏 paired command；fixture 不执行 shell。
          'command':
              'printf fixture-approval && echo safe-preview && echo keep-buttons-visible',
        },
      },
      now: now,
    );
    final questionId = 'question-${state.session.id}-${state.nextSequence}';
    final multiQuestion =
        message.contains('multi question') || message.contains('多题');
    final planReview =
        message.contains('plan review') || message.contains('计划评审');
    state.append(
      eventType: 'question.requested',
      payload: {
        'kind': 'question_request',
        'label': '需要回答',
        'question': planReview
            ? {
                'request_id': questionId,
                'prompt': '请评审以下实施计划。',
                // v0.5/P4-F：plan-review 是同一 composer chain 内的专用形态，
                // 用 intent.kind + detail(plan markdown) + binary approve/decline 表达。
                'questions': [
                  {
                    'id': '$questionId-plan',
                    'prompt': '评审结果',
                    'detail':
                        '## 实施计划\n\n'
                        '1. 建立回归基线并冻结契约。\n'
                        '2. 分阶段实现并逐阶段提交。\n'
                        '3. 补全测试、文档与录屏证据。',
                    'intent': {'kind': 'plan-review', 'approve': '批准执行'},
                    'options': [
                      {'label': '批准执行', 'description': '按计划继续实施。'},
                      {'label': '需要修改', 'description': '先调整计划。'},
                    ],
                  },
                ],
              }
            : multiQuestion
            ? {
                'request_id': questionId,
                'prompt': '请完成 fixture 多题配置。',
                'questions': const [
                  {
                    'id': 'routing',
                    'prompt': '选择执行路径。',
                    'options': [
                      {'label': '标准路径 (推荐)', 'description': '保留默认安全检查。'},
                      {'label': '自定义路径'},
                    ],
                    'allows_freeform': true,
                  },
                  {
                    'id': 'checks',
                    'prompt': '选择需要保留的检查。',
                    'detail': '多选 custom 应与勾选项并存。',
                    'options': [
                      {'label': '静态检查'},
                      {'label': 'Widget 回归'},
                    ],
                    'allows_freeform': true,
                    'multi_select': true,
                  },
                ],
              }
            : {
                'request_id': questionId,
                'prompt': '选择 fixture 的后续处理方式。',
                'options': const ['继续', '仅生成摘要'],
                'allows_freeform': true,
              },
      },
      now: now,
    );
    state.updateSession(status: MobileSessionStatus.streaming, now: now);
  }

  void _appendStart(_FixtureSessionState state) {
    final now = _clock();
    // 与真实 daemon 语义对齐：start 走 session/new。v0.9.2 P2 起"发送前自动恢复"
    // 在存在实例映射时改走 resume（见 session_controller._ensureSessionRunnableForSend），
    // start 只保留给确实没有本机实例的新会话语义。
    state.append(
      eventType: 'session.started',
      payload: const {
        'kind': 'system_notice',
        'label': '会话已启动',
        'text': '本地 deterministic fixture 已建立会话执行状态。',
      },
      now: now,
    );
    state.updateSession(status: MobileSessionStatus.idle, now: now);
  }

  void _appendKill(_FixtureSessionState state) {
    final now = _clock();
    state.append(
      eventType: 'session.killed',
      payload: const {
        'kind': 'system_notice',
        'label': '已结束本机进程',
        'text': '本地 fixture 已清理受控会话进程状态。',
      },
      now: now,
    );
    state.updateSession(status: MobileSessionStatus.stopped, now: now);
  }

  void _appendAbort(_FixtureSessionState state) {
    final now = _clock();
    state.append(
      eventType: 'session.aborted',
      payload: const {
        'kind': 'system_notice',
        'label': '已中止',
        'text': 'Android 控制端已中止当前 fixture 回合。',
      },
      now: now,
    );
    state.updateSession(status: MobileSessionStatus.stopped, now: now);
  }

  // v0.9.2 P2：原 _appendSystemNotice 助手已被 resume 分支的显式事件取代
  // （resume 需要同时推进会话投影为 idle，才能端到端验证"发送前自动恢复"），
  // 故删除以免留下无人调用的死代码。

  /// v0.2/P3：模型切换只更新 controls 并追加系统通知；不伪造 Provider 已切换成功的证据。
  void _applyModelSelect(
    _FixtureSessionState state,
    Map<String, dynamic>? ciphertext,
  ) {
    final model = (ciphertext?['fixture_payload'] as Map?)?['model'] as String?;
    if (model == null || !state.controls.models.contains(model)) {
      throw const RelayFailure(RelayFailureKind.validation, '目标模型不在目录中。');
    }
    state.controls = state.controls.copyWith(model: model);
    final now = _clock();
    state.append(
      eventType: 'session.model_selected',
      payload: {'kind': 'system_notice', 'label': '模型', 'text': '已切换模型：$model'},
      now: now,
    );
  }

  /// v0.2/P3：effort 切换同上。
  void _applyEffortSelect(
    _FixtureSessionState state,
    Map<String, dynamic>? ciphertext,
  ) {
    final effort =
        (ciphertext?['fixture_payload'] as Map?)?['effort'] as String?;
    if (effort == null || !state.controls.efforts.contains(effort)) {
      throw const RelayFailure(RelayFailureKind.validation, '目标 effort 不在目录中。');
    }
    state.controls = state.controls.copyWith(effort: effort);
    final now = _clock();
    state.append(
      eventType: 'session.effort_selected',
      payload: {
        'kind': 'system_notice',
        'label': 'Effort',
        'text': '已切换 effort：$effort',
      },
      now: now,
    );
  }

  /// v0.3/P0：permission mode 切换只更新 controls 并追加通知；不伪造 Provider 已切换成功的证据。
  void _applyPermissionModeSelect(
    _FixtureSessionState state,
    Map<String, dynamic>? ciphertext,
  ) {
    final mode =
        (ciphertext?['fixture_payload'] as Map?)?['mode_id'] as String?;  // v0.8.5 §3.5
    if (mode == null ||
        !state.controls.availablePermissionModes.contains(mode)) {
      throw const RelayFailure(
        RelayFailureKind.validation,
        '目标 permission mode 不在目录中。',
      );
    }
    state.controls = state.controls.copyWith(permissionMode: mode);
    final now = _clock();
    state.append(
      eventType: 'session.permission_mode_selected',
      payload: {
        'kind': 'system_notice',
        'label': '权限模式',
        'text': '已切换 permission mode：$mode',
      },
      now: now,
    );
  }

  /// v0.3/P0：goal 文本编辑只更新 controls 并追加通知；正文不进入任何密文外字段。
  void _applyGoalEdit(
    _FixtureSessionState state,
    Map<String, dynamic>? ciphertext,
  ) {
    final objective =
        (ciphertext?['fixture_payload'] as Map?)?['objective'] as String?;
    final goal = state.controls.goal;
    if (goal == null || objective == null || objective.trim().isEmpty) {
      throw const RelayFailure(RelayFailureKind.validation, '目标文本无效。');
    }
    state.controls = state.controls.copyWith(
      goal: SessionGoalSummary(
        title: objective.trim(),
        progressLabel: goal.progressLabel,
        phase: goal.phase,
      ),
    );
    final now = _clock();
    state.append(
      eventType: 'session.goal_edited',
      payload: {'kind': 'system_notice', 'label': '目标', 'text': '已更新目标'},
      now: now,
    );
  }

  // parent 只收到状态和密文摘要；child 的 session timeline 不会被复制到此处。
  void _appendDelegationEvent(
    _FixtureSessionState parent,
    SessionDelegation delegation,
  ) {
    parent.append(
      eventType: 'delegation.changed',
      payload: {
        'kind': 'delegation_changed',
        'label': '子任务状态更新',
        'delegation_id': delegation.id,
        'child_session_id': delegation.childSessionId,
        'target_provider': delegation.targetProvider,
        'status': delegation.status.wireValue,
        'summary_envelope': delegation.summaryEnvelope,
        'summary_envelope_sha256': delegation.summaryEnvelopeSha256,
      },
      now: _clock(),
    );
  }

  void _appendPermissionDecision(
    _FixtureSessionState state,
    SessionCommandInput input,
  ) {
    final requestId = _fixtureRequestId(input.ciphertext, 'permission');
    final approved = input.kind == SessionCommandKind.permissionApprove;
    state.append(
      eventType: 'permission.resolved',
      payload: {
        'kind': 'system_notice',
        'label': approved ? '已允许' : '已拒绝',
        'text': '确认请求 $requestId 已处理。',
      },
      now: _clock(),
    );
  }

  void _appendQuestionAnswer(
    _FixtureSessionState state,
    SessionCommandInput input,
  ) {
    final requestId = _fixtureRequestId(input.ciphertext, 'question');
    final payload = input.ciphertext?['fixture_payload'];
    // v0.5/P4-C：fixture 只读取测试 envelope 中的 skipped 标记，用来证明
    // skip 仍走 question.answer 写链路；真实 Relay 仍只处理加密命令体。
    final skipped = payload is Map && payload['skipped'] == true;
    final batchAnswered = payload is Map && payload['answers'] is List;
    state.append(
      eventType: 'question.resolved',
      payload: {
        'kind': 'system_notice',
        'label': skipped ? '已跳过' : '已回答',
        'text': skipped
            ? '问题 $requestId 已由 Android 控制端跳过。'
            : batchAnswered
            ? '问题 $requestId 已由 Android 控制端批量回答。'
            : '问题 $requestId 已由 Android 控制端回答。',
        if (batchAnswered) 'answers': payload['answers'],
      },
      now: _clock(),
    );
  }

  void _appendPlanApproval(_FixtureSessionState state) {
    final plan = state.controls.plan;
    if (plan == null || plan.phase != PlanPhase.awaitingApproval) {
      throw const RelayFailure(RelayFailureKind.validation, '当前没有待确认的 Plan。');
    }
    state.controls = state.controls.copyWith(
      plan: plan.copyWith(phase: PlanPhase.active),
    );
    state.append(
      eventType: 'plan.approved',
      payload: const {
        'kind': 'system_notice',
        'label': 'Plan 已确认',
        'text': 'fixture Plan 已进入执行状态。',
      },
      now: _clock(),
    );
  }

  void _appendGoalToggle(_FixtureSessionState state) {
    final goal = state.controls.goal;
    if (goal == null || goal.phase == GoalPhase.completed) {
      throw const RelayFailure(RelayFailureKind.validation, '当前 Goal 不能切换状态。');
    }
    final next = goal.phase == GoalPhase.active
        ? GoalPhase.paused
        : GoalPhase.active;
    state.controls = state.controls.copyWith(goal: goal.copyWith(phase: next));
    state.append(
      eventType: 'goal.changed',
      payload: {
        'kind': 'system_notice',
        'label': next == GoalPhase.paused ? 'Goal 已暂停' : 'Goal 已恢复',
        'text': 'fixture Goal 状态已更新。',
      },
      now: _clock(),
    );
  }

  void _appendGoalClear(_FixtureSessionState state) {
    if (state.controls.goal == null) {
      throw const RelayFailure(RelayFailureKind.validation, '当前没有可清除的 Goal。');
    }
    state.controls = state.controls.copyWith(clearGoal: true);
    state.append(
      eventType: 'goal.cleared',
      payload: const {
        'kind': 'system_notice',
        'label': 'Goal 已清除',
        'text': 'fixture Goal 已从模型设置任务控制区移除。',
      },
      now: _clock(),
    );
  }

  /// P5-E3 fixture：`/goal ...` 先生成 command-input 节点，再更新 Goal 投影。
  /// 目标文本只来自本地 fixture payload；真实 Relay 仍应转发加密命令体。
  void _appendGoalCreate(
    _FixtureSessionState state,
    Map<String, dynamic>? ciphertext,
  ) {
    final objective =
        (ciphertext?['fixture_payload'] as Map?)?['objective'] as String?;
    if (state.controls.goal != null) {
      throw const RelayFailure(RelayFailureKind.validation, '当前已有 Goal。');
    }
    if (objective == null || objective.trim().isEmpty) {
      throw const RelayFailure(RelayFailureKind.validation, '目标文本无效。');
    }
    final trimmed = objective.trim();
    final now = _clock();
    state.append(
      eventType: 'goal.command_input',
      payload: {
        'kind': 'system_notice',
        'label': 'Command input',
        'text': '/goal $trimmed',
      },
      now: now,
    );
    state.controls = state.controls.copyWith(
      goal: SessionGoalSummary(
        title: trimmed,
        progressLabel: '0 / 1',
        phase: GoalPhase.active,
      ),
    );
    state.append(
      eventType: 'goal.created',
      payload: const {
        'kind': 'system_notice',
        'label': 'Goal 已创建',
        'text': 'fixture Goal 已加入模型设置任务控制区。',
      },
      now: now,
    );
  }

  void _appendSkillInvocation(
    _FixtureSessionState state,
    SessionCommandInput input,
  ) {
    final payload = input.ciphertext?['fixture_payload'];
    final skillID = payload is Map && payload['skill_id'] is String
        ? payload['skill_id'] as String
        : '';
    final skill = state.controls.skills.where((item) => item.id == skillID);
    if (skill.isEmpty) {
      throw const RelayFailure(
        RelayFailureKind.validation,
        'fixture Skill 标识无效。',
      );
    }
    state.append(
      eventType: 'skill.invoked',
      payload: {
        'kind': 'system_notice',
        'label': 'Skill 已确认',
        'text': '${skill.first.title} 已进入 fixture 控制队列。',
      },
      now: _clock(),
    );
  }

  String _fixtureRequestId(Map<String, dynamic>? ciphertext, String prefix) {
    final fixturePayload = ciphertext?['fixture_payload'];
    final requestId =
        fixturePayload is Map && fixturePayload['request_id'] is String
        ? fixturePayload['request_id'] as String
        : null;
    if (requestId == null || !requestId.startsWith(prefix)) {
      throw const RelayFailure(RelayFailureKind.validation, 'fixture 请求标识无效。');
    }
    return requestId;
  }

  void _ensureFixtureLease(_FixtureSessionState session, int leaseEpoch) {
    if (leaseEpoch != session.leaseEpoch || leaseEpoch <= 0) {
      throw const RelayFailure(RelayFailureKind.forbidden, '会话可操作状态已更新，请重试。');
    }
  }

  AuthTokens _newTokens({String? deviceId}) => AuthTokens(
    accessToken: 'fixture-access-token-${deviceId ?? 'readonly'}',
    refreshToken: 'fixture-refresh-token-${deviceId ?? 'readonly'}',
    expiresAt: _clock().add(const Duration(hours: 1)),
    deviceId: deviceId,
  );

  String? _deviceIdFromRefreshToken(String refreshToken) {
    const prefix = 'fixture-refresh-token-';
    if (!refreshToken.startsWith(prefix)) {
      throw const RelayFailure(RelayFailureKind.unauthorized, '设备连接已失效，请重新连接。');
    }
    final deviceId = refreshToken.substring(prefix.length);
    return deviceId == 'readonly' ? null : deviceId;
  }
}

/// fixture 能力名清单（与 SPI CapabilityNames 对齐）。
List<String> _fixtureCapabilityNames() => const [
  'start',
  'resume',
  'abort',
  'usage',
  'permission',
  'permission_mode',
  'question',
  'plan',
  'goal',
  'skill_catalog',
  'invoke_skill',
  'model_select',
  'effort_select',
  'attachments',
  'file_read',
  'git_read',
  'fork',
  'delegate_session',
  'delegate_cross_provider',
];

ProviderCapabilityProfile _fixtureProvider(
  String kind, {
  Set<String> native = const {},
  Set<String> emulated = const {},
  Map<String, String> unsupportedReasons = const {},
  // v0.9.2（V092 录屏/可见场景）：可用性事实来源（relay/terminal/unavailable）。
  // 缺省为空串，与"旧 Relay 不返回该字段"的兼容形态一致。
  String factsSource = '',
  // v0.9.2：执行侧声明不可用时的原因；非空即整条 Provider fail-closed
  // （available=false + 全部 capability unsupported + 同一中文原因）。
  String? unavailableReason,
}) {
  const names = [
    'start',
    'kill',
    'resume',
    'abort',
    'usage',
    'permission',
    'permission_mode',
    'question',
    'plan',
    'goal',
    'skill_catalog',
    'invoke_skill',
    'model_select',
    'effort_select',
    'attachments',
    'file_read',
    'git_read',
    'fork',
    'delegate_session',
    'delegate_cross_provider',
  ];
  final unavailable = unavailableReason != null;
  return ProviderCapabilityProfile(
    kind: kind,
    version: unavailable ? '' : 'fixture-1.0',
    available: !unavailable,
    factsSource: factsSource,
    capabilities: names
        .map(
          (name) => CapabilityEntry(
            name: name,
            availability: unavailable
                ? CapabilityAvailability.unsupported
                : native.contains(name)
                ? CapabilityAvailability.native
                : emulated.contains(name)
                ? CapabilityAvailability.emulated
                : CapabilityAvailability.unsupported,
            reason: unavailable
                ? unavailableReason
                : native.contains(name) || emulated.contains(name)
                ? null
                : unsupportedReasons[name] ?? 'fixture Provider 未声明此能力。',
          ),
        )
        .toList(growable: false),
  );
}

SessionControlState _fixtureControlsForProvider(String provider) =>
    SessionControlState(
      // 当前模型必须属于下面的 models 目录，否则 composer 下拉会断言失败。
      model: 'fixture-model-a',
      effort: '高',
      plan: const SessionPlanSummary(
        title: '检查并收口会话控制',
        summary: '先验证 capability，再执行可逆的 fixture 操作。',
        phase: PlanPhase.awaitingApproval,
      ),
      goal: const SessionGoalSummary(
        title: '保持移动端控制链路可回归',
        progressLabel: '2 / 3',
        phase: GoalPhase.active,
      ),
      todos: const [
        SessionTodoItem(
          content: '冻结 v0.5 移动端回归矩阵',
          status: TodoItemStatus.completed,
        ),
        SessionTodoItem(
          content: '迁移 Goal / Todo 到 input.dock',
          status: TodoItemStatus.inProgress,
        ),
        SessionTodoItem(
          content: '录屏前制定 headed 回归清单',
          status: TodoItemStatus.pending,
        ),
      ],
      skills: const [
        SessionSkillDescriptor(
          id: 'fixture-review-skill',
          title: '检查会话控制',
          summary: '会读取 fixture 状态并生成本地摘要。',
          risk: SkillRisk.high,
        ),
      ],
      // v0.2/P3：模型/effort 目录与 usage 均来自 deterministic fixture；真实 Relay 无此通道时为空。
      models: const ['fixture-model-a', 'fixture-model-b'],
      efforts: const ['低', '中', '高'],
      // v0.5/P5-E5：图片限制来自 deterministic Host projection，供 intake 预检使用。
      imageLimits: SessionImageLimits(
        maxImageBytes: 10 * 1024 * 1024,
        maxImagesPerMessage: 2,
        maxMessageImageBytes: 12 * 1024 * 1024,
        mediaTypes: ['image/png', 'image/jpeg', 'image/webp', 'image/gif'],
      ),
      // v0.3/P1：usage 深度——cache 计数与 context 窗口（用于上下文警告）。
      usage: const SessionUsageSummary(
        inputTokens: 12480,
        outputTokens: 3840,
        contextTokens: 92000,
        cacheReadTokens: 61000,
        cacheCreationTokens: 800,
        contextWindowTokens: 100000,
        // v0.8.5 §3.7：fixture 对齐真实链路 timing 投影——chips 在 ttft/throughput
        // 有值时显示真实读数（“首字 x.xs / 解码 xx tok/s”），缺省时保持隐藏。
        ttftMs: 734,
        decodeThroughput: 42.5,
      ),
      // v0.3/P0：permission mode 目录（Happy permissionMode 对齐）。
      // v0.5/P5：含 danger-full-access 用于风险确认回归；custom 预设不作为可点菜单项。
      permissionMode: 'default',
      availablePermissionModes: const [
        'default',
        'plan',
        'acceptEdits',
        'danger-full-access',
      ],
      // V094-26：展示目录（id/name/description 白名单投影），fixture 与真实
      // Relay 同构注入；danger-full-access 保留说明，风险确认门不受展示名影响。
      availablePermissionModeDetails: const [
        SessionPermissionModeDetail(
          id: 'default',
          name: '默认模式',
          description: '标准权限：执行常规操作前需要确认。',
        ),
        SessionPermissionModeDetail(
          id: 'plan',
          name: '计划模式',
          description: '只制定计划，不执行修改。',
        ),
        SessionPermissionModeDetail(
          id: 'acceptEdits',
          name: '自动接受编辑',
          description: '自动接受文件编辑，其余操作仍需确认。',
        ),
        SessionPermissionModeDetail(
          id: 'danger-full-access',
          name: '完整访问',
          description: '无限制执行所有操作，风险自负。',
        ),
      ],
    );

bool _sameBytes(Uint8List left, Uint8List right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

// 视觉和 widget fixture 只生成不可读的固定 envelope 形状；业务 UI 只显示 hash，不读取 ciphertext。
Map<String, dynamic> _fixtureDelegationEnvelope(String seed) => {
  'alg': 'v1-aes256gcm-hkdfsha256',
  'key_id': 'fixture-dek',
  'nonce': 'fixture-nonce-$seed',
  'ciphertext': 'fixture-opaque-$seed',
  'aad_hash': 'fixture-aad-$seed',
  'payload_version': 1,
};

String _fixtureDelegationHash(String seed) {
  final prefix = seed.codeUnits
      .map((unit) => unit.toRadixString(16).padLeft(2, '0'))
      .join();
  return (prefix + List<String>.filled(64, '0').join()).substring(0, 64);
}

/// fixture 的派发状态只保存 parent 可见元数据和加密摘要，不保存 child timeline 或任务书。
class _FixtureDelegationState {
  _FixtureDelegationState(this.delegation, {Set<String>? proposalKeys})
    : proposalKeys = proposalKeys ?? {};

  SessionDelegation delegation;
  final Map<String, SessionDelegation> decisions = {};
  // 记录由 Android 派发入口创建的幂等键，重试返回同一节点。
  final Set<String> proposalKeys;
}

/// fixture 内部状态只保存无敏感演示 payload；真实 Relay 仍只保存 event envelope。
class _FixtureSessionState {
  _FixtureSessionState({required this.session, required this.controls});

  MobileSession session;
  SessionControlState controls;
  int leaseEpoch = 0;
  int resumeCount = 0;
  final List<RelaySessionEvent> events = [];
  final Map<String, SessionCommandReceipt> commandReceipts = {};

  int get nextSequence => events.length + 1;

  void append({
    required String eventType,
    required Map<String, dynamic> payload,
    required DateTime now,
  }) {
    final sequence = nextSequence;
    final eventPayload = Map<String, dynamic>.from(payload);
    eventPayload.putIfAbsent('created_at', () => now.toIso8601String());
    events.add(
      RelaySessionEvent(
        sequence: sequence,
        eventType: eventType,
        envelope: {'fixture_payload': eventPayload},
        createdAt: now,
      ),
    );
    session = session.copyWith(
      lastSequence: sequence,
      updatedAt: now,
      lastActivityAt: now,
    );
  }

  void updateSession({
    required MobileSessionStatus status,
    required DateTime now,
  }) {
    session = session.copyWith(
      status: status,
      updatedAt: now,
      lastActivityAt: now,
    );
  }
}

/// v0.8.7 时间释放流式回合脚本（V087-04，迭代计划 §3.4）。
///
/// 「打字机」的可观察性前提：原 fixture 在发送时刻一次性追加全部增量帧，
/// 快照全量返回，演不出「逐步到达」。时间释放脚本把每条增量帧的 createdAt
/// 打上回合开始后的偏移，快照按当前时钟只暴露已到期帧（localdev「全量已收
/// 文本」语义不变）；completed 全文与 completed_turn 终态在 [completedAfter]
/// 到期后释放。注入时钟（controller/widget 测试）与真实时钟（macOS 可见
/// gate 的 flutter-smoke-recording 口径）共用同一脚本形状。
class TimedStreamSchedule {
  TimedStreamSchedule({
    required List<Duration> offsets,
    required List<String> fullTexts,
    required this.finalText,
    this.completedAfter = const Duration(milliseconds: 400),
  }) : assert(offsets.length == fullTexts.length, '每条偏移必须对应一条全量文本'),
       offsets = List.unmodifiable(offsets),
       fullTexts = List.unmodifiable(fullTexts);

  /// 每条增量相对回合开始的到达偏移（须单调不减）。
  final List<Duration> offsets;

  /// 每条增量的「全量已收文本」（localdev 语义：整体替换生长节点）。
  final List<String> fullTexts;

  /// completed 权威全文（终态对账基准，须等于末条全量文本）。
  final String finalText;

  /// completed 全文与 completed_turn 终态的到达偏移（不早于末条增量）。
  final Duration completedAfter;

  /// 可见 gate 默认脚本（P0 裁决 §3.5）：40 帧 × 400ms ≈ 16s，落在
  /// §6.1 的回合预算（12-20s）内，满足帧数下限 ≥30 与严格递增 ≥3 的判定预算。
  factory TimedStreamSchedule.gateDefault() {
    final offsets = <Duration>[];
    final texts = <String>[];
    final buffer = StringBuffer();
    for (var i = 1; i <= 40; i++) {
      offsets.add(Duration(milliseconds: 400 * i));
      buffer
        ..write('第 $i 帧增量到达：气泡文本随上游产出逐步生长，')
        ..write('这就是打字机式的流式传输过程。\n');
      texts.add(buffer.toString());
    }
    return TimedStreamSchedule(
      offsets: offsets,
      fullTexts: texts,
      finalText: texts.last,
      completedAfter: const Duration(milliseconds: 400 * 40 + 400),
    );
  }
}

/// fixture 内部只保存无敏感的密文 bytes，用于验证上传顺序和幂等，而非模拟真实文件内容。
class _FixtureAttachmentState {
  _FixtureAttachmentState({
    required this.sessionId,
    required this.mimeType,
    required this.byteSize,
    required this.compression,
    required this.metadataCiphertext,
    required this.totalChunks,
  });

  factory _FixtureAttachmentState.fromInput(AttachmentChunkUploadInput input) =>
      _FixtureAttachmentState(
        sessionId: input.sessionId,
        mimeType: input.mimeType,
        byteSize: input.byteSize,
        compression: input.compression,
        metadataCiphertext: Uint8List.fromList(input.metadataCiphertext),
        totalChunks: input.totalChunks,
      );

  final String sessionId;
  final String mimeType;
  final int byteSize;
  final String compression;
  final Uint8List metadataCiphertext;
  final int totalChunks;
  final Map<int, _FixtureAttachmentChunk> chunks = {};
  bool completed = false;
  String? completeIdempotencyKey;

  bool matches(AttachmentChunkUploadInput input) =>
      sessionId == input.sessionId &&
      mimeType == input.mimeType &&
      byteSize == input.byteSize &&
      compression == input.compression &&
      totalChunks == input.totalChunks &&
      _sameBytes(metadataCiphertext, input.metadataCiphertext);
}

class _FixtureAttachmentChunk {
  const _FixtureAttachmentChunk({
    required this.idempotencyKey,
    required this.ciphertext,
  });

  final String idempotencyKey;
  final Uint8List ciphertext;
}
