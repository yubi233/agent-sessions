import '../domain/models.dart';
import '../domain/session_models.dart';
import 'relay_repository.dart';

/// 可重复的本地 Relay fixture。它只模拟白名单元数据，绝不生成会话正文。
class FixtureRelayRepository implements RelayRepository {
  FixtureRelayRepository({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  final List<Device> _devices = [];
  final Map<String, PairingRequest> _pairings = {};
  final Map<String, _FixtureSessionState> _sessions = {};
  var _pairingSequence = 0;
  var _sessionSequence = 0;
  var _commandSequence = 0;

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
      throw const RelayFailure(RelayFailureKind.unauthorized, '登录状态已失效，请重新登录。');
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
    if (!input.email.contains('@') || input.code != 'RECOVERY-FIXTURE-0001') {
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
    final sessions = _sessions.values.map((state) => state.session).toList();
    sessions.sort((left, right) {
      final leftTime = left.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final rightTime =
          right.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      return rightTime.compareTo(leftTime);
    });
    return List<MobileSession>.unmodifiable(sessions);
  }

  @override
  Future<MobileSession> createSession(CreateMobileSessionInput input) async {
    input.validate();
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
    );
    final state = _FixtureSessionState(session: session);
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
  Future<SessionSnapshot> getSessionSnapshot(
    String sessionId, {
    int afterSequence = 0,
  }) async {
    if (afterSequence < 0) {
      throw const RelayFailure(RelayFailureKind.validation, '事件游标不能为负数。');
    }
    final state = _sessionState(sessionId);
    return SessionSnapshot(
      session: state.session,
      events: state.events
          .where((event) => event.sequence > afterSequence)
          .toList(growable: false),
    );
  }

  @override
  Future<SessionLease> acquireSessionLease(String sessionId) async {
    _requireFixtureOwner();
    final state = _sessionState(sessionId);
    // 每次显式获取都推进 fencing epoch，确保旧 UI 操作无法被 fixture 静默接受。
    state.leaseEpoch += 1;
    return SessionLease(sessionId: sessionId, epoch: state.leaseEpoch);
  }

  @override
  Future<SessionCommandReceipt> submitSessionCommand(
    String sessionId,
    SessionCommandInput input,
  ) async {
    input.validate();
    _requireFixtureOwner();
    final state = _sessionState(sessionId);
    if (input.leaseEpoch != state.leaseEpoch) {
      throw const RelayFailure(RelayFailureKind.forbidden, '会话控制权已更新，请重新获取。');
    }
    final existing = state.commandReceipts[input.idempotencyKey];
    if (existing != null) {
      return existing;
    }

    switch (input.kind) {
      case SessionCommandKind.send:
        _appendSendConversation(state, input.ciphertext);
      case SessionCommandKind.abort:
        _appendAbort(state);
      case SessionCommandKind.permissionApprove:
      case SessionCommandKind.permissionReject:
        _appendPermissionDecision(state, input);
      case SessionCommandKind.questionAnswer:
        _appendQuestionAnswer(state, input);
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
    state.append(
      eventType: 'message.user',
      payload: {'kind': 'user_message', 'label': '你', 'text': message},
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
      payload: const {
        'kind': 'tool_activity',
        'label': '读取工作区状态',
        'text': 'fixture 工具活动，不含真实命令或文件内容。',
        'tool_status': '运行中',
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
        },
      },
      now: now,
    );
    state.append(
      eventType: 'question.requested',
      payload: {
        'kind': 'question_request',
        'label': '需要回答',
        'question': {
          'request_id': 'question-${state.session.id}-${state.nextSequence}',
          'prompt': '选择 fixture 的后续处理方式。',
          'options': const ['继续', '仅生成摘要'],
          'allows_freeform': true,
        },
      },
      now: now,
    );
    state.updateSession(status: MobileSessionStatus.streaming, now: now);
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
    state.append(
      eventType: 'question.resolved',
      payload: {
        'kind': 'system_notice',
        'label': '已回答',
        'text': '问题 $requestId 已由 Android 控制端回答。',
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

  AuthTokens _newTokens({String? deviceId}) => AuthTokens(
    accessToken: 'fixture-access-token-${deviceId ?? 'readonly'}',
    refreshToken: 'fixture-refresh-token-${deviceId ?? 'readonly'}',
    expiresAt: _clock().add(const Duration(hours: 1)),
    deviceId: deviceId,
  );

  String? _deviceIdFromRefreshToken(String refreshToken) {
    const prefix = 'fixture-refresh-token-';
    if (!refreshToken.startsWith(prefix)) {
      throw const RelayFailure(RelayFailureKind.unauthorized, '登录状态已失效，请重新登录。');
    }
    final deviceId = refreshToken.substring(prefix.length);
    return deviceId == 'readonly' ? null : deviceId;
  }
}

/// fixture 内部状态只保存无敏感演示 payload；真实 Relay 仍只保存 event envelope。
class _FixtureSessionState {
  _FixtureSessionState({required this.session});

  MobileSession session;
  int leaseEpoch = 0;
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
    session = session.copyWith(lastSequence: sequence, updatedAt: now);
  }

  void updateSession({
    required MobileSessionStatus status,
    required DateTime now,
  }) {
    session = session.copyWith(status: status, updatedAt: now);
  }
}
