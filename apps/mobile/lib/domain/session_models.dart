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
    this.model,
    this.displayName,
    this.projectName,
    this.workspaceName,
    this.updatedAt,
    this.lastActivityAt,
    this.parentSessionId,
    this.forkedFromMessageId,
    this.agentPresetId,
    this.subagentReadOnlyReason,
    this.archivedAt,
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
        model: _nullableString(json['model']),
        displayName: _nullableString(json['display_name']),
        projectName: _nullableString(json['project_name']),
        workspaceName: _nullableString(json['workspace_name']),
        updatedAt: _nullableDateTime(json['updated_at']),
        lastActivityAt: _nullableDateTimeFromMillis(
          json['last_activity_at_unix_ms'],
        ),
        parentSessionId: _nullableString(json['parent_session_id']),
        forkedFromMessageId: _nullableString(json['forked_from_message_id']),
        agentPresetId: _nullableString(json['agent_preset_id']),
        subagentReadOnlyReason: _nullableString(
          json['subagent_read_only_reason'],
        ),
        archivedAt: _nullableDateTimeFromMillis(json['archived_at_unix_ms']),
      );

  final String id;
  final String workspaceId;
  final MobileSessionStatus status;
  final String provider;
  final int lastSequence;
  final String? model;
  final String? displayName;
  final String? projectName;
  final String? workspaceName;
  final DateTime? updatedAt;

  /// Relay 最后一次状态/事件写入的活动时间（`last_activity_at_unix_ms`）。
  /// 「最后消息时间」展示、列表排序与 idle 休眠衰减都只消费它；null 表示
  /// 旧数据未知，排序沉底、展示按休眠处理。
  final DateTime? lastActivityAt;

  /// Optional display projections. Production Relay may omit them; the UI must
  /// then keep the related header/composer seats unavailable.
  final String? parentSessionId;
  final String? forkedFromMessageId;
  final String? agentPresetId;
  final String? subagentReadOnlyReason;

  /// 归档时间；非 null 表示该会话已从默认列表隐藏，但数据和事件仍保留。
  final DateTime? archivedAt;

  bool get isArchived => archivedAt != null;

  String get title => displayName?.trim().isNotEmpty == true
      ? displayName!.trim()
      : '会话 ${id.length > 8 ? id.substring(0, 8) : id}';

  String get workspaceLabel => workspaceName?.trim().isNotEmpty == true
      ? workspaceName!.trim()
      : workspaceId;

  /// 最近活动时间戳：优先 Relay last_activity，退到本地 updatedAt；都缺失按 0。
  int get _activityEpochMS =>
      (lastActivityAt ?? updatedAt)?.millisecondsSinceEpoch ?? 0;

  /// idle 会话在最后活动超过 10 分钟后视为「休眠」：本地开发里历史 idle 会话
  /// 几乎永远存在，不能把「完成且陈旧」继续当作在线。活动时间未知（旧数据/
  /// 旧 Relay）同样视为休眠——「在线」只能由确凿的新近活动支撑。
  static const dormantAfter = Duration(minutes: 10);

  bool isDormant({DateTime? now}) {
    if (status != MobileSessionStatus.idle) return false;
    final last = lastActivityAt ?? updatedAt;
    if (last == null) return true;
    return (now ?? DateTime.now()).difference(last).abs() > dormantAfter;
  }

  /// 稳定排序：最后活动时间降序（未知沉底）；同时间按 lastSequence 降序，再按 id
  /// 字典序，避免刷新跳项。会话列表与最近会话页共用。
  static int compareByLastActivity(MobileSession left, MobileSession right) {
    final leftMS = left._activityEpochMS;
    final rightMS = right._activityEpochMS;
    if (leftMS != rightMS) return rightMS.compareTo(leftMS);
    if (left.lastSequence != right.lastSequence) {
      return right.lastSequence.compareTo(left.lastSequence);
    }
    return left.id.compareTo(right.id);
  }

  MobileSession copyWith({
    MobileSessionStatus? status,
    int? lastSequence,
    String? model,
    String? displayName,
    String? projectName,
    String? workspaceName,
    DateTime? updatedAt,
    DateTime? lastActivityAt,
    String? parentSessionId,
    String? forkedFromMessageId,
    String? agentPresetId,
    String? subagentReadOnlyReason,
    DateTime? archivedAt,
    bool clearArchivedAt = false,
  }) => MobileSession(
    id: id,
    workspaceId: workspaceId,
    status: status ?? this.status,
    provider: provider,
    lastSequence: lastSequence ?? this.lastSequence,
    model: model ?? this.model,
    displayName: displayName ?? this.displayName,
    projectName: projectName ?? this.projectName,
    workspaceName: workspaceName ?? this.workspaceName,
    updatedAt: updatedAt ?? this.updatedAt,
    lastActivityAt: lastActivityAt ?? this.lastActivityAt,
    parentSessionId: parentSessionId ?? this.parentSessionId,
    forkedFromMessageId: forkedFromMessageId ?? this.forkedFromMessageId,
    agentPresetId: agentPresetId ?? this.agentPresetId,
    subagentReadOnlyReason:
        subagentReadOnlyReason ?? this.subagentReadOnlyReason,
    archivedAt: clearArchivedAt ? null : (archivedAt ?? this.archivedAt),
  );
}

/// Relay workspace whitelist projection. Canonical roots never come back from
/// the list endpoint, so the mobile client cannot expose a host path.
class MobileWorkspace {
  const MobileWorkspace({
    required this.id,
    required this.projectId,
    required this.terminalId,
    this.branch,
    this.status,
  });

  factory MobileWorkspace.fromRelayJson(Map<String, dynamic> json) =>
      MobileWorkspace(
        id: _requiredSessionString(json, 'id'),
        projectId: _requiredSessionString(json, 'project_id'),
        terminalId: _nullableString(json['terminal_id']) ?? '',
        branch: _nullableString(json['branch']),
        status: _nullableString(json['status']),
      );

  final String id;
  final String projectId;
  final String terminalId;
  final String? branch;
  final String? status;

  String get label => projectId.trim().isNotEmpty ? projectId.trim() : id;
}

class CreateMobileWorkspaceInput {
  const CreateMobileWorkspaceInput({
    required this.projectId,
    required this.canonicalRoot,
    required this.deviceId,
    this.terminalId = '',
    this.branch = '',
  });

  final String projectId;
  final String canonicalRoot;
  final String deviceId;
  final String terminalId;
  final String branch;

  void validate() {
    if (projectId.trim().isEmpty ||
        canonicalRoot.trim().isEmpty ||
        deviceId.trim().isEmpty) {
      throw const RelayFailure(RelayFailureKind.validation, '工作区目录或控制端身份无效。');
    }
  }
}

/// 真实 Relay 的会话内新建工作区请求。移动端只提交共享名称，Host
/// canonical root 由 Terminal Daemon 在授权根内推导，不能从客户端传入。
class CreateMobileWorkspaceWithFolderInput {
  const CreateMobileWorkspaceWithFolderInput({
    required this.name,
    required this.deviceId,
    this.terminalId = '',
  });

  final String name;
  final String deviceId;
  final String terminalId;

  void validate() {
    final value = name.trim();
    if (value.isEmpty ||
        value != name ||
        value.length > 64 ||
        !RegExp(r'^[a-zA-Z0-9._-]+$').hasMatch(value) ||
        value == '.' ||
        value == '..' ||
        value.startsWith('.')) {
      throw const RelayFailure.validation('工作区名称无效。');
    }
    if (deviceId.trim().isEmpty) {
      throw const RelayFailure.validation('当前设备没有 Android 写控制端。');
    }
  }
}

/// workspace.create 的脱敏状态；不持有 canonical root。
class WorkspaceCreateState {
  const WorkspaceCreateState({
    required this.status,
    required this.workspaceId,
    this.commandId,
    this.errorCode,
    this.workspace,
  });

  factory WorkspaceCreateState.fromRelayJson(Map<String, dynamic> json) {
    final status = json['status'];
    final workspaceId = json['workspace_id'];
    if (status is! String ||
        status.trim().isEmpty ||
        workspaceId is! String ||
        workspaceId.trim().isEmpty) {
      throw const RelayFailure(RelayFailureKind.protocol, '工作区创建状态格式错误。');
    }
    final rawWorkspace = json['workspace'];
    return WorkspaceCreateState(
      status: status,
      workspaceId: workspaceId,
      commandId: _nullableString(json['command_id']),
      errorCode: _nullableString(json['error_code']),
      workspace: rawWorkspace is Map
          ? MobileWorkspace.fromRelayJson(
              Map<String, dynamic>.from(rawWorkspace),
            )
          : null,
    );
  }

  final String status;
  final String workspaceId;
  final String? commandId;
  final String? errorCode;
  final MobileWorkspace? workspace;

  bool get isPending => status == 'pending';
  bool get isSucceeded => status == 'succeeded';
  bool get isTerminal => const {
    'succeeded',
    'failed',
    'cancelled',
    'rejected',
    'expired',
  }.contains(status);
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
    this.agentPresetId,
  });

  final String workspaceId;
  final String provider;

  /// device_id 是客户端意图边界；HTTP 层必须由 bearer token 推导，不能由请求体伪造。
  final String deviceId;
  final String? agentPresetId;

  void validate() {
    if (workspaceId.trim().isEmpty || deviceId.trim().isEmpty) {
      throw const RelayFailure(RelayFailureKind.validation, '工作区或控制端身份无效。');
    }
  }
}

class SessionForkInput {
  const SessionForkInput({
    required this.messageId,
    required this.idempotencyKey,
    required this.leaseEpoch,
    required this.deviceId,
  });

  final String messageId;
  final String idempotencyKey;
  final int leaseEpoch;
  final String deviceId;

  void validate() {
    if (messageId.trim().isEmpty || idempotencyKey.trim().isEmpty) {
      throw const RelayFailure(RelayFailureKind.validation, '分支消息或幂等标识无效。');
    }
    if (leaseEpoch <= 0 || deviceId.trim().isEmpty) {
      throw const RelayFailure(RelayFailureKind.validation, '会话控制权已失效，请重新获取。');
    }
  }
}

enum SessionCommandKind {
  start('session.start'),
  send('session.send'),
  abort('session.abort'),
  kill('session.kill'),
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
  effortSelect('session.effort_select'),
  // v0.3/P0：permission mode 选择与 goal 文本编辑（Happy sessionSetAgentModes / goal 编辑对齐）。
  permissionModeSelect('session.permission_mode'),
  goalEdit('goal.edit'),
  // v0.5/P5-E2：GoalDock clear 仍走统一会话命令链路，不在 UI 直接清本地状态。
  goalClear('goal.clear'),
  // v0.5/P5-E3：`/goal ...` command-input 创建目标，同样不能走普通消息发送。
  goalCreate('goal.create');

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
    this.command,
    this.resolved,
  });

  final String requestId;
  final String title;
  final String summary;
  final String? command;
  final bool? resolved;
}

class TimelineQuestionRequest {
  const TimelineQuestionRequest({
    required this.requestId,
    required this.prompt,
    required this.options,
    this.steps = const [],
    this.allowsFreeform = false,
    this.resolved,
  });

  final String requestId;
  final String prompt;
  final List<String> options;
  final List<TimelineQuestionStep> steps;
  final bool allowsFreeform;
  final bool? resolved;
}

class TimelineQuestionStep {
  const TimelineQuestionStep({
    required this.id,
    required this.prompt,
    this.detail,
    this.options = const [],
    this.allowsFreeform = false,
    this.multiSelect = false,
    this.intentKind,
    this.intentApproveLabel,
  });

  final String id;
  final String prompt;
  final String? detail;
  final List<TimelineQuestionOption> options;
  final bool allowsFreeform;
  final bool multiSelect;

  /// 提问意图（display-safe）：如 `plan-review`。只由 fixture/本地投影提供，
  /// 不猜真实 Provider 的意图；null 表示普通 question。
  final String? intentKind;

  /// 意图指定的 approve 选项 label（plan-review 专用），用于从选项里找 approve/decline。
  final String? intentApproveLabel;

  /// 是否为 plan-review 形态：单一决策 + markdown plan + binary approve 选项。
  /// 与 DeepSeek Harness `planReviewOf()` 一致：单题、带 detail、非多选、最多两个选项、存在意图指定 approve。
  bool get isPlanReview =>
      intentKind == 'plan-review' &&
      detail != null &&
      !multiSelect &&
      options.length <= 2 &&
      options.any((option) => option.label == intentApproveLabel);
}

class TimelineQuestionOption {
  const TimelineQuestionOption({required this.label, this.description});

  final String label;
  final String? description;
}

/// Host-projected recursive tool child. It is intentionally limited to
/// display-safe labels/status/input/output and never carries raw envelopes.
class SessionToolSubcall {
  const SessionToolSubcall({
    required this.callId,
    required this.label,
    this.status,
    this.input,
    this.output,
    this.subcalls = const [],
  });

  factory SessionToolSubcall.fromFixture(Object? value) {
    if (value is! Map) {
      return const SessionToolSubcall(callId: '', label: '未知子调用');
    }
    final data = Map<String, dynamic>.from(value);
    return SessionToolSubcall(
      callId:
          _nullableString(data['call_id']) ??
          _nullableString(data['id']) ??
          'subcall-unknown',
      label:
          _nullableString(data['label']) ??
          _nullableString(data['name']) ??
          '工具子调用',
      status: _nullableString(data['status']),
      input: _nullableString(data['input']),
      output: _nullableString(data['output']),
      subcalls: _toolSubcallsFromFixture(data['subcalls']),
    );
  }

  final String callId;
  final String label;
  final String? status;
  final String? input;
  final String? output;
  final List<SessionToolSubcall> subcalls;
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
    this.messageId,
    this.createdAt,
    this.copyText,
    this.completedTurn = false,
    this.forkAvailable = false,
    this.pendingSteering = false,
    this.referenceLabels = const [],
    this.filePath,
    this.toolInput,
    this.toolOutput,
    this.inspectTarget,
    this.producedFilePaths = const [],
    this.toolSubcalls = const [],
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
      messageId: _nullableString(payload['message_id']),
      createdAt: _nullableDateTime(payload['created_at']),
      copyText: _nullableString(payload['copy_text']),
      completedTurn: payload['completed_turn'] == true,
      forkAvailable: payload['fork_available'] == true,
      pendingSteering: payload['pending_steering'] == true,
      referenceLabels: _stringList(payload['references']),
      filePath: _nullableString(payload['file_path']),
      toolInput: _nullableString(payload['tool_input']),
      toolOutput: _nullableString(payload['tool_output']),
      inspectTarget: _nullableString(payload['inspect_target']),
      producedFilePaths: _stringList(payload['produced_files']),
      toolSubcalls: _toolSubcallsFromFixture(payload['subcalls']),
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

  /// 以下字段只来自本地 fixture 或已解密 display payload；真实 Relay envelope
  /// 未声明时保持缺省，避免 UI 用猜测数据展示 action 或路径。
  final String? messageId;
  final DateTime? createdAt;
  final String? copyText;
  final bool completedTurn;
  final bool forkAvailable;
  final bool pendingSteering;
  final List<String> referenceLabels;
  final String? filePath;
  final String? toolInput;
  final String? toolOutput;
  final String? inspectTarget;
  final List<String> producedFilePaths;
  final List<SessionToolSubcall> toolSubcalls;
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
    command: _nullableString(data['command']),
    resolved: data['resolved'] as bool?,
  );
}

TimelineQuestionRequest? _questionFromFixture(Object? value) {
  if (value is! Map) return null;
  final data = Map<String, dynamic>.from(value);
  final requestId = _nullableString(data['request_id']);
  if (requestId == null) return null;
  final rawOptions = data['options'];
  final rawQuestions = data['questions'];
  final steps = rawQuestions is List
      ? rawQuestions
            .map(_questionStepFromFixture)
            .nonNulls
            .toList(growable: false)
      : const <TimelineQuestionStep>[];
  return TimelineQuestionRequest(
    requestId: requestId,
    prompt: _nullableString(data['prompt']) ?? '请选择下一步。',
    options: rawOptions is List
        ? rawOptions.whereType<String>().toList(growable: false)
        : const [],
    steps: steps,
    allowsFreeform: data['allows_freeform'] == true,
    resolved: data['resolved'] as bool?,
  );
}

TimelineQuestionStep? _questionStepFromFixture(Object? value) {
  if (value is! Map) return null;
  final data = Map<String, dynamic>.from(value);
  final id = _nullableString(data['id']);
  final prompt =
      _nullableString(data['prompt']) ?? _nullableString(data['question']);
  if (id == null || prompt == null) return null;
  final rawOptions = data['options'];
  return TimelineQuestionStep(
    id: id,
    prompt: prompt,
    detail: _nullableString(data['detail']),
    options: rawOptions is List
        ? rawOptions
              .map(_questionOptionFromFixture)
              .nonNulls
              .toList(growable: false)
        : const [],
    allowsFreeform: data['allows_freeform'] == true,
    multiSelect: data['multi_select'] == true,
    intentKind: _nullableString(data['intent']?['kind']),
    intentApproveLabel: _nullableString(data['intent']?['approve']),
  );
}

TimelineQuestionOption? _questionOptionFromFixture(Object? value) {
  if (value is String) return TimelineQuestionOption(label: value);
  if (value is! Map) return null;
  final data = Map<String, dynamic>.from(value);
  final label = _nullableString(data['label']);
  if (label == null) return null;
  return TimelineQuestionOption(
    label: label,
    description: _nullableString(data['description']),
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

DateTime? _nullableDateTimeFromMillis(Object? value) =>
    value is num && value.toInt() > 0
    ? DateTime.fromMillisecondsSinceEpoch(value.toInt(), isUtc: true)
    : null;

List<String> _stringList(Object? value) => value is List
    ? value
          .whereType<String>()
          .where((item) => item.trim().isNotEmpty)
          .toList(growable: false)
    : const [];

List<SessionToolSubcall> _toolSubcallsFromFixture(Object? value) =>
    value is List
    ? value
          .map(SessionToolSubcall.fromFixture)
          .where((item) => item.callId.trim().isNotEmpty)
          .toList(growable: false)
    : const [];
