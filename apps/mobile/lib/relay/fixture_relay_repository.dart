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
  bool _repeatCursorEventOnNextSnapshot = false;
  final Map<String, List<int>> _snapshotAfterSequences = {};

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
    final session = MobileSession(
      id: id,
      workspaceId: input.workspaceId.trim(),
      status: MobileSessionStatus.idle,
      provider: input.provider.trim().isEmpty ? 'codex' : input.provider.trim(),
      lastSequence: 1,
      displayName: '新的会话 $_sessionSequence',
      projectName: 'Fixture Project',
      workspaceName: input.workspaceId.trim(),
      updatedAt: _clock(),
      lastActivityAt: _clock(),
      agentPresetId: input.agentPresetId?.trim(),
    );
    _workspaces.putIfAbsent(
      session.workspaceId,
      () => MobileWorkspace(
        id: session.workspaceId,
        projectId: session.workspaceId,
        terminalId: '',
        status: 'active',
      ),
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
  }) async {
    if (afterSequence < 0) {
      throw const RelayFailure(RelayFailureKind.validation, '事件游标不能为负数。');
    }
    _requireFixtureNetwork();
    final state = _sessionState(sessionId);
    _snapshotAfterSequences
        .putIfAbsent(sessionId, () => <int>[])
        .add(afterSequence);
    final events = state.events
        .where((event) => event.sequence > afterSequence)
        .toList(growable: true);
    if (_repeatCursorEventOnNextSnapshot && afterSequence > 0) {
      _repeatCursorEventOnNextSnapshot = false;
      final boundary = state.events.where(
        (event) => event.sequence == afterSequence,
      );
      if (boundary.isNotEmpty) events.insert(0, boundary.single);
    }
    return SessionSnapshot(
      session: state.session,
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
        // v0.2/P2：resume 只更新会话状态并追加一条系统通知；不伪造 Provider 唤醒结果，
        // 真实结果只能来自 Daemon 的 Adapter 三态映射。
        state.resumeCount += 1;
        _appendSystemNotice(state, '已提交恢复请求（第 ${state.resumeCount} 次）');
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
            'attachments',
            'permission_mode',
            'fork',
            'delegate_session',
          },
          emulated: const {'delegate_cross_provider'},
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
          },
          emulated: const {'permission'},
          // v0.8.3：unsupported reason 与 internal/adapter/dsh successMatrix 同口径
          //（桥已实现面如实标注「链路待接入」，防止客户端残留失效文案）。
          unsupportedReasons: const {
            'permission': '决策通道已接通但当前策略为取消而非静默批准',
            'permission_mode': '桥已实现 session/set_mode；Go adapter/Relay/移动端链路接入后升格',
            'question': '桥未实现提问通道（无 question 相关 wire 方法）',
            'plan': '桥不广播 plan 变体，未接入计划能力',
            'goal': '桥不广播 goal 事件',
            'skill_catalog': '桥未实现技能目录通道',
            'invoke_skill': '桥未实现技能调用方法',
            'attachments': '桥已实现图像 admission 且按 deployment 条件开启；Go opaque ref 链路接入后升格',
            'fork': '桥已实现 session/fork；Go adapter/Relay 链路接入后升格',
            'file_read': '桥 fs/* 请求按 -32601 拒绝，未接入文件读取',
            'git_read': '桥未实现 git 读取能力',
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
    if (state.session.status == MobileSessionStatus.stopped) {
      throw const RelayFailure(
        RelayFailureKind.forbidden,
        '已结束的 fixture 会话不能重新启动。',
      );
    }
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
        'label': '已停止',
        'text': 'Android 控制端已停止当前 fixture 流。',
      },
      now: now,
    );
    state.updateSession(status: MobileSessionStatus.stopped, now: now);
  }

  /// v0.2/P2：resume 在 fixture 中只追加系统通知，不伪造 Provider 唤醒结果。
  void _appendSystemNotice(_FixtureSessionState state, String text) {
    final now = _clock();
    state.append(
      eventType: 'session.resumed',
      payload: {'kind': 'system_notice', 'label': '恢复', 'text': text},
      now: now,
    );
  }

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
        (ciphertext?['fixture_payload'] as Map?)?['permission_mode'] as String?;
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
  return ProviderCapabilityProfile(
    kind: kind,
    version: 'fixture-1.0',
    available: true,
    capabilities: names
        .map(
          (name) => CapabilityEntry(
            name: name,
            availability: native.contains(name)
                ? CapabilityAvailability.native
                : emulated.contains(name)
                ? CapabilityAvailability.emulated
                : CapabilityAvailability.unsupported,
            reason: native.contains(name) || emulated.contains(name)
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
    events.add(
      RelaySessionEvent(
        sequence: sequence,
        eventType: eventType,
        envelope: {'fixture_payload': payload},
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
