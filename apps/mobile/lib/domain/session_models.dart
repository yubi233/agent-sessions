import 'models.dart';

/// 会话状态来自 Relay 白名单元数据；消息正文、工具参数和附件内容不属于该字段。
enum MobileSessionStatus {
  idle('idle'),
  streaming('streaming'),
  waitingPermission('waiting_permission'),
  waitingQuestion('waiting_question'),
  stopped('stopped'),
  errored('errored'),
  offline('offline'),
  unknown('unknown');

  const MobileSessionStatus(this.wireValue);

  final String wireValue;

  static MobileSessionStatus fromWire(String value) => switch (value) {
    'idle' || 'waiting' || 'active' => MobileSessionStatus.idle,
    'streaming' || 'running' => MobileSessionStatus.streaming,
    'waiting_permission' ||
    'permission_required' => MobileSessionStatus.waitingPermission,
    'waiting_question' ||
    'question_required' => MobileSessionStatus.waitingQuestion,
    'stopped' || 'aborted' || 'terminated' => MobileSessionStatus.stopped,
    'errored' || 'error' => MobileSessionStatus.errored,
    'offline' || 'disconnected' => MobileSessionStatus.offline,
    _ => MobileSessionStatus.unknown,
  };
}

/// Relay Session 的白名单元数据加上本地可选展示字段。
/// 真实 Relay 只要求 id/workspace/status/provider/last_seq；展示名来自已解密缓存或 fixture。
class MobileSession {
  const MobileSession({
    required this.id,
    required this.workspaceId,
    required this.status,
    required this.provider,
    required this.lastSequence,
    this.displayName,
    this.projectName,
    this.workspaceName,
    this.updatedAt,
  });

  factory MobileSession.fromRelayJson(Map<String, dynamic> json) =>
      MobileSession(
        id: _requiredSessionString(json, 'id'),
        workspaceId: _requiredSessionString(json, 'workspace_id'),
        status: MobileSessionStatus.fromWire(
          (json['status'] as String?) ?? MobileSessionStatus.unknown.wireValue,
        ),
        provider: (json['provider'] as String?) ?? 'unknown',
        lastSequence: (json['last_seq'] as num?)?.toInt() ?? 0,
        displayName: _nullableString(json['display_name']),
        projectName: _nullableString(json['project_name']),
        workspaceName: _nullableString(json['workspace_name']),
        updatedAt: _nullableDateTime(json['updated_at']),
      );

  final String id;
  final String workspaceId;
  final MobileSessionStatus status;
  final String provider;
  final int lastSequence;
  final String? displayName;
  final String? projectName;
  final String? workspaceName;
  final DateTime? updatedAt;

  String get title => displayName?.trim().isNotEmpty == true
      ? displayName!.trim()
      : '会话 ${id.length > 8 ? id.substring(0, 8) : id}';

  String get workspaceLabel => workspaceName?.trim().isNotEmpty == true
      ? workspaceName!.trim()
      : workspaceId;

  MobileSession copyWith({
    MobileSessionStatus? status,
    int? lastSequence,
    String? displayName,
    String? projectName,
    String? workspaceName,
    DateTime? updatedAt,
  }) => MobileSession(
    id: id,
    workspaceId: workspaceId,
    status: status ?? this.status,
    provider: provider,
    lastSequence: lastSequence ?? this.lastSequence,
    displayName: displayName ?? this.displayName,
    projectName: projectName ?? this.projectName,
    workspaceName: workspaceName ?? this.workspaceName,
    updatedAt: updatedAt ?? this.updatedAt,
  );
}

/// Relay snapshot 中的原始事件。客户端尚未获得会话解密材料时只能保留 envelope，不能猜测正文。
class RelaySessionEvent {
  const RelaySessionEvent({
    required this.sequence,
    required this.eventType,
    required this.envelope,
  });

  factory RelaySessionEvent.fromRelayJson(Map<String, dynamic> json) {
    final sequence = json['event_seq'];
    final envelope = json['envelope'];
    if (sequence is! num || sequence.toInt() < 1 || envelope is! Map) {
      throw const RelayFailure(RelayFailureKind.protocol, 'Relay 会话事件格式错误。');
    }
    return RelaySessionEvent(
      sequence: sequence.toInt(),
      eventType: _requiredSessionString(json, 'event_type'),
      envelope: Map<String, dynamic>.from(envelope),
    );
  }

  final int sequence;
  final String eventType;
  final Map<String, dynamic> envelope;
}

class SessionSnapshot {
  const SessionSnapshot({required this.session, required this.events});

  factory SessionSnapshot.fromRelayJson(Map<String, dynamic> json) {
    final session = json['session'];
    final events = json['events'];
    if (session is! Map || events is! List) {
      throw const RelayFailure(RelayFailureKind.protocol, 'Relay 会话快照格式错误。');
    }
    return SessionSnapshot(
      session: MobileSession.fromRelayJson(Map<String, dynamic>.from(session)),
      events: events
          .map(
            (event) => RelaySessionEvent.fromRelayJson(
              Map<String, dynamic>.from(event as Map),
            ),
          )
          .toList(growable: false),
    );
  }

  final MobileSession session;
  final List<RelaySessionEvent> events;
}

/// 一次只读 cursor 恢复的脱敏结果。
/// 它只携带序号和新增数量，供应用内通知与诊断使用，不能承载事件正文或密文。
class SessionCursorRecovery {
  const SessionCursorRecovery({
    required this.sessionId,
    required this.requestedAfterSequence,
    required this.recoveredCursor,
    required this.addedEventCount,
  });

  final String sessionId;
  final int requestedAfterSequence;
  final int recoveredCursor;
  final int addedEventCount;
}

/// 只允许 Relay 返回正 fencing epoch；0 不能降级成“当前 lease”。
class SessionLease {
  const SessionLease({required this.sessionId, required this.epoch});

  factory SessionLease.fromRelayJson(Map<String, dynamic> json) {
    final epoch = json['lease_epoch'];
    if (epoch is! num || epoch.toInt() <= 0) {
      throw const RelayFailure(
        RelayFailureKind.protocol,
        'Relay 返回了无效的会话 lease。',
      );
    }
    return SessionLease(
      sessionId: _requiredSessionString(json, 'session_id'),
      epoch: epoch.toInt(),
    );
  }

  final String sessionId;
  final int epoch;
}

class CreateMobileSessionInput {
  const CreateMobileSessionInput({
    required this.workspaceId,
    required this.provider,
    required this.deviceId,
  });

  final String workspaceId;
  final String provider;

  /// device_id 是客户端意图边界；HTTP 层必须由 bearer token 推导，不能由请求体伪造。
  final String deviceId;

  void validate() {
    if (workspaceId.trim().isEmpty || deviceId.trim().isEmpty) {
      throw const RelayFailure(RelayFailureKind.validation, '工作区或控制端身份无效。');
    }
  }
}

enum SessionCommandKind {
  send('session.send'),
  abort('session.abort'),
  // v0.2/P2：断线/离线后显式恢复 Provider 会话；结果映射为 resumed / restarted_with_context / unsupported。
  resume('session.resume'),
  permissionApprove('permission.approve'),
  permissionReject('permission.reject'),
  questionAnswer('question.answer'),
  // P3 控制面命令仍经同一 lease/idempotency 链路，避免绕过 Android 写端授权。
  planApprove('plan.approve'),
  goalToggle('goal.toggle'),
  skillInvoke('skill.invoke'),
  // v0.2/P3：composer 内的模型/effort 切换。
  modelSelect('session.model_select'),
  effortSelect('session.effort_select');

  const SessionCommandKind(this.wireValue);

  final String wireValue;
}

/// 所有已存在会话的写操作都必须经过这个边界。
/// [deviceId] 只供本地授权链路核验，Relay 从认证 token 推导设备，不接收可伪造的 device_id body 字段。
class SessionCommandInput {
  const SessionCommandInput({
    required this.kind,
    required this.idempotencyKey,
    required this.leaseEpoch,
    required this.deviceId,
    this.targetInstanceId,
    this.ciphertext,
  });

  final SessionCommandKind kind;
  final String idempotencyKey;
  final int leaseEpoch;
  final String deviceId;
  final String? targetInstanceId;

  /// 真实 Relay 只转发密文；fixture 使用固定的测试 envelope，不会记录到报告或日志。
  final Map<String, dynamic>? ciphertext;

  void validate() {
    if (leaseEpoch <= 0) {
      throw const RelayFailure(RelayFailureKind.validation, '会话控制权已失效，请重新获取。');
    }
    if (idempotencyKey.trim().isEmpty || deviceId.trim().isEmpty) {
      throw const RelayFailure(RelayFailureKind.validation, '写命令缺少设备或幂等标识。');
    }
  }
}

class SessionCommandReceipt {
  const SessionCommandReceipt({
    required this.id,
    required this.kind,
    required this.status,
    required this.idempotencyKey,
    this.leaseEpoch,
  });

  factory SessionCommandReceipt.fromRelayJson(Map<String, dynamic> json) =>
      SessionCommandReceipt(
        id: _requiredSessionString(json, 'id'),
        kind: _requiredSessionString(json, 'kind'),
        status: _requiredSessionString(json, 'status'),
        idempotencyKey: _requiredSessionString(json, 'idempotency_key'),
        leaseEpoch: (json['lease_epoch'] as num?)?.toInt(),
      );

  final String id;
  final String kind;
  final String status;
  final String idempotencyKey;
  final int? leaseEpoch;
}

enum SessionTimelineKind {
  userMessage,
  assistantMessage,
  toolActivity,
  permissionRequest,
  questionRequest,
  systemNotice,
  encryptedPlaceholder,
}

class TimelinePermissionRequest {
  const TimelinePermissionRequest({
    required this.requestId,
    required this.title,
    required this.summary,
    this.resolved,
  });

  final String requestId;
  final String title;
  final String summary;
  final bool? resolved;
}

class TimelineQuestionRequest {
  const TimelineQuestionRequest({
    required this.requestId,
    required this.prompt,
    required this.options,
    this.allowsFreeform = false,
    this.resolved,
  });

  final String requestId;
  final String prompt;
  final List<String> options;
  final bool allowsFreeform;
  final bool? resolved;
}

/// 可显示的时间线由本地已解密事件或 deterministic fixture 构建。
/// 未识别的真实 envelope 仅显示脱敏占位，避免把密文或猜测的正文写入 UI、日志或测试报告。
class SessionTimelineEvent {
  const SessionTimelineEvent({
    required this.sequence,
    required this.kind,
    required this.label,
    this.text,
    this.isStreaming = false,
    this.toolStatus,
    this.permission,
    this.question,
  });

  factory SessionTimelineEvent.fromRelayEvent(RelaySessionEvent event) {
    final fixture = event.envelope['fixture_payload'];
    if (fixture is! Map) {
      return SessionTimelineEvent(
        sequence: event.sequence,
        kind: SessionTimelineKind.encryptedPlaceholder,
        label: '已收到加密会话事件',
      );
    }
    final payload = Map<String, dynamic>.from(fixture);
    final kind = _timelineKindFromFixture(payload['kind'] as String?);
    final permission = _permissionFromFixture(payload['permission']);
    final question = _questionFromFixture(payload['question']);
    return SessionTimelineEvent(
      sequence: event.sequence,
      kind: kind,
      label: _nullableString(payload['label']) ?? _fallbackTimelineLabel(kind),
      text: _nullableString(payload['text']),
      isStreaming: payload['streaming'] == true,
      toolStatus: _nullableString(payload['tool_status']),
      permission: permission,
      question: question,
    );
  }

  final int sequence;
  final SessionTimelineKind kind;
  final String label;
  final String? text;
  final bool isStreaming;
  final String? toolStatus;
  final TimelinePermissionRequest? permission;
  final TimelineQuestionRequest? question;
}

SessionTimelineKind _timelineKindFromFixture(String? kind) => switch (kind) {
  'user_message' => SessionTimelineKind.userMessage,
  'assistant_message' => SessionTimelineKind.assistantMessage,
  'tool_activity' => SessionTimelineKind.toolActivity,
  'permission_request' => SessionTimelineKind.permissionRequest,
  'question_request' => SessionTimelineKind.questionRequest,
  'system_notice' => SessionTimelineKind.systemNotice,
  _ => SessionTimelineKind.encryptedPlaceholder,
};

TimelinePermissionRequest? _permissionFromFixture(Object? value) {
  if (value is! Map) return null;
  final data = Map<String, dynamic>.from(value);
  final requestId = _nullableString(data['request_id']);
  if (requestId == null) return null;
  return TimelinePermissionRequest(
    requestId: requestId,
    title: _nullableString(data['title']) ?? '需要确认',
    summary: _nullableString(data['summary']) ?? '此操作需要 Android 控制端确认。',
    resolved: data['resolved'] as bool?,
  );
}

TimelineQuestionRequest? _questionFromFixture(Object? value) {
  if (value is! Map) return null;
  final data = Map<String, dynamic>.from(value);
  final requestId = _nullableString(data['request_id']);
  if (requestId == null) return null;
  final rawOptions = data['options'];
  return TimelineQuestionRequest(
    requestId: requestId,
    prompt: _nullableString(data['prompt']) ?? '请选择下一步。',
    options: rawOptions is List
        ? rawOptions.whereType<String>().toList(growable: false)
        : const [],
    allowsFreeform: data['allows_freeform'] == true,
    resolved: data['resolved'] as bool?,
  );
}

String _fallbackTimelineLabel(SessionTimelineKind kind) => switch (kind) {
  SessionTimelineKind.userMessage => '你',
  SessionTimelineKind.assistantMessage => 'Assistant',
  SessionTimelineKind.toolActivity => '工具活动',
  SessionTimelineKind.permissionRequest => '需要确认',
  SessionTimelineKind.questionRequest => '需要回答',
  SessionTimelineKind.systemNotice => '会话状态',
  SessionTimelineKind.encryptedPlaceholder => '已收到加密会话事件',
};

String _requiredSessionString(Map<String, dynamic> json, String field) {
  final value = json[field];
  if (value is! String || value.trim().isEmpty) {
    throw RelayFailure(RelayFailureKind.protocol, 'Relay 响应缺少 $field。');
  }
  return value;
}

String? _nullableString(Object? value) =>
    value is String && value.trim().isNotEmpty ? value : null;

DateTime? _nullableDateTime(Object? value) =>
    value is String ? DateTime.tryParse(value) : null;
