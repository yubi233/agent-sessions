import 'dart:typed_data';

import '../domain/control_models.dart';
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
  final Map<String, _FixtureAttachmentState> _attachments = {};
  var _pairingSequence = 0;
  var _sessionSequence = 0;
  var _commandSequence = 0;
  var _failNextAttachmentChunk = false;
  int? _failAttachmentChunkAtIndex;

  /// 供 ATTACH-01 注入一次可恢复失败；下一次相同幂等键重试必须能够继续。
  void failNextAttachmentChunk() => _failNextAttachmentChunk = true;

  /// 可见 fixture 在首块确认后让指定块失败，用于同时展示上传进度与重试入口。
  void failAttachmentChunkAtIndex(int chunkIndex) {
    _failAttachmentChunkAtIndex = chunkIndex;
  }

  int get submittedCommandCount => _commandSequence;

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
      case SessionCommandKind.planApprove:
        _appendPlanApproval(state);
      case SessionCommandKind.goalToggle:
        _appendGoalToggle(state);
      case SessionCommandKind.skillInvoke:
        _appendSkillInvocation(state, input);
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

  @override
  Future<CapabilityMatrix> getCapabilities() async => CapabilityMatrix(
    providers: [
      _fixtureProvider(
        'codex',
        native: const {
          'plan',
          'goal',
          'skill_catalog',
          'invoke_skill',
          'model_select',
          'effort_select',
          'attachments',
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

  @override
  Future<SessionControlState> getSessionControls(String sessionId) async =>
      _sessionState(sessionId).controls;

  @override
  Future<AttachmentReceipt> uploadAttachmentChunk(
    AttachmentChunkUploadInput input,
  ) async {
    input.validate();
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
      throw const RelayFailure(RelayFailureKind.forbidden, '会话控制权已更新，请重新获取。');
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
      throw const RelayFailure(RelayFailureKind.unauthorized, '登录状态已失效，请重新登录。');
    }
    final deviceId = refreshToken.substring(prefix.length);
    return deviceId == 'readonly' ? null : deviceId;
  }
}

ProviderCapabilityProfile _fixtureProvider(
  String kind, {
  Set<String> native = const {},
  Set<String> emulated = const {},
}) {
  const names = [
    'plan',
    'goal',
    'skill_catalog',
    'invoke_skill',
    'model_select',
    'effort_select',
    'attachments',
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
                : 'fixture Provider 未声明此能力。',
          ),
        )
        .toList(growable: false),
  );
}

SessionControlState _fixtureControlsForProvider(String provider) =>
    SessionControlState(
      model: provider == 'claude' ? 'Claude fixture' : 'Codex fixture',
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
      skills: const [
        SessionSkillDescriptor(
          id: 'fixture-review-skill',
          title: '检查会话控制',
          summary: '会读取 fixture 状态并生成本地摘要。',
          risk: SkillRisk.high,
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

/// fixture 内部状态只保存无敏感演示 payload；真实 Relay 仍只保存 event envelope。
class _FixtureSessionState {
  _FixtureSessionState({required this.session, required this.controls});

  MobileSession session;
  SessionControlState controls;
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
