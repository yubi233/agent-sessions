import 'models.dart';
import 'session_models.dart';

/// P2-F 的会话安全状态投影。它不携带 session/workspace 标识，路由已在本机持有目标会话。
class DaemonObservationSession {
  const DaemonObservationSession({
    required this.status,
    required this.provider,
    required this.lastSequence,
  });

  factory DaemonObservationSession.fromRelayJson(Map<String, dynamic> json) {
    final rawStatus = json['status'];
    final rawSequence = json['last_seq'];
    final rawProvider = json['provider'];
    if (rawStatus is! String || rawSequence is! num || rawSequence < 0) {
      throw const RelayFailure(
        RelayFailureKind.protocol,
        'Relay 返回了无效的 Daemon 会话观察状态。',
      );
    }
    if (rawProvider != null && rawProvider is! String) {
      throw const RelayFailure(
        RelayFailureKind.protocol,
        'Relay 返回了无效的 Daemon Provider。',
      );
    }
    return DaemonObservationSession(
      status: MobileSessionStatus.fromWire(rawStatus),
      provider: rawProvider is String && rawProvider.trim().isNotEmpty
          ? rawProvider.trim()
          : 'unknown',
      lastSequence: rawSequence.toInt(),
    );
  }

  final MobileSessionStatus status;
  final String provider;
  final int lastSequence;
}

/// Relay 命令种类只保留本地枚举；未知值不能原样显示到 UI。
enum DaemonObservationCommandKind {
  start('session.start', '启动会话'),
  send('session.send', '发送消息'),
  resume('session.resume', '恢复会话'),
  abort('session.abort', '停止会话'),
  kill('session.kill', '结束本机进程'),
  fileTree('file.tree', '读取文件树'),
  fileRead('file.read', '读取文件'),
  codeRead('code.read', '读取代码'),
  gitStatus('git.status', '读取 Git 状态'),
  gitChanges('git.changes', '读取 Git 变更'),
  gitDiff('git.diff', '读取 Git Diff'),
  unknown('', '受限命令');

  const DaemonObservationCommandKind(this.wireValue, this.label);

  final String wireValue;
  final String label;

  static DaemonObservationCommandKind fromWire(String value) =>
      DaemonObservationCommandKind.values.firstWhere(
        (item) => item.wireValue == value,
        orElse: () => DaemonObservationCommandKind.unknown,
      );
}

enum DaemonObservationCommandStatus {
  accepted('accepted', '已排队'),
  running('running', 'Daemon 正在处理'),
  succeeded('succeeded', '已完成'),
  failed('failed', '执行失败'),
  cancelled('cancelled', '已取消'),
  rejected('rejected', '已拒绝'),
  expired('expired', '已过期'),
  unknown('', '状态未确认');

  const DaemonObservationCommandStatus(this.wireValue, this.label);

  final String wireValue;
  final String label;

  static DaemonObservationCommandStatus fromWire(String value) =>
      DaemonObservationCommandStatus.values.firstWhere(
        (item) => item.wireValue == value,
        orElse: () => DaemonObservationCommandStatus.unknown,
      );
}

enum DaemonDeliveryState {
  queued('queued', '等待投递'),
  received('received', 'Daemon 已接收'),
  started('started', 'Daemon 已开始'),
  rejected('rejected', 'Daemon 已拒绝'),
  resolved('resolved', 'Daemon 已回写结果'),
  unknown('', '投递状态未确认');

  const DaemonDeliveryState(this.wireValue, this.label);

  final String wireValue;
  final String label;

  static DaemonDeliveryState fromWire(String value) =>
      DaemonDeliveryState.values.firstWhere(
        (item) => item.wireValue == value,
        orElse: () => DaemonDeliveryState.unknown,
      );
}

/// 只接受协议登记的 Daemon 错误码。未知码降级为通用执行失败，不能渲染 Terminal 自由文本。
enum DaemonObservationErrorCode {
  capabilityUnsupported('CAPABILITY_UNSUPPORTED', '当前 Daemon 未声明所需能力。'),
  contentUnavailable('CONTENT_UNAVAILABLE', '受保护内容当前不可用。'),
  daemonExecutionFailed('DAEMON_EXECUTION_FAILED', 'Daemon 未能完成此命令。'),
  daemonRestartRecovery(
    'DAEMON_RESTART_RECOVERY',
    'Daemon 重启期间无法安全恢复此命令，请重新创建命令。',
  ),
  deadlineExceeded('DEADLINE_EXCEEDED', 'Daemon 执行超时。'),
  localStateMissing('LOCAL_STATE_MISSING', 'Daemon 缺少可安全恢复的本机状态。'),
  protocolUnsupported('PROTOCOL_UNSUPPORTED', 'Daemon 协议不受支持。'),
  snapshotStale('SNAPSHOT_STALE', '读取快照已过期，请刷新后重试。'),
  targetInstanceStale('TARGET_INSTANCE_STALE', '会话实例已更新。'),
  terminalOffline('TERMINAL_OFFLINE', '目标终端当前离线。'),
  upgradeRequired('UPGRADE_REQUIRED', 'Daemon 需要升级协议版本。'),
  workspaceMoved('WORKSPACE_MOVED', '已确认的工作区状态发生变化。'),
  workspacePathDenied('WORKSPACE_PATH_DENIED', '请求超出已确认工作区。');

  const DaemonObservationErrorCode(this.wireValue, this.label);

  final String wireValue;
  final String label;

  static DaemonObservationErrorCode fromWire(String value) =>
      DaemonObservationErrorCode.values.firstWhere(
        (item) => item.wireValue == value,
        orElse: () => DaemonObservationErrorCode.daemonExecutionFailed,
      );
}

/// Daemon 命令的安全投影，不保留 ID、target、lease、幂等键或请求密文。
class DaemonCommandObservation {
  const DaemonCommandObservation({
    required this.kind,
    required this.status,
    required this.deliveryState,
    this.errorCode,
  });

  factory DaemonCommandObservation.fromRelayJson(Map<String, dynamic> json) {
    final rawKind = json['kind'];
    final rawStatus = json['status'];
    final rawDeliveryState = json['delivery_state'];
    final rawErrorCode = json['error_code'];
    if (rawKind is! String ||
        rawStatus is! String ||
        rawDeliveryState is! String ||
        (rawErrorCode != null && rawErrorCode is! String)) {
      throw const RelayFailure(
        RelayFailureKind.protocol,
        'Relay 返回了无效的 Daemon 命令观察状态。',
      );
    }
    return DaemonCommandObservation(
      kind: DaemonObservationCommandKind.fromWire(rawKind),
      status: DaemonObservationCommandStatus.fromWire(rawStatus),
      deliveryState: DaemonDeliveryState.fromWire(rawDeliveryState),
      errorCode: rawErrorCode is String && rawErrorCode.trim().isNotEmpty
          ? DaemonObservationErrorCode.fromWire(rawErrorCode.trim())
          : null,
    );
  }

  final DaemonObservationCommandKind kind;
  final DaemonObservationCommandStatus status;
  final DaemonDeliveryState deliveryState;
  final DaemonObservationErrorCode? errorCode;
}

enum DaemonObservationEventType {
  sessionLifecycle('session.lifecycle', '会话生命周期'),
  turnStarted('turn.started', '回合已开始'),
  messageDelta('message.delta', '消息事件'),
  messageCompleted('message.completed', '消息已完成'),
  toolCall('tool.call', '工具调用'),
  toolResult('tool.result', '工具结果'),
  usageUpdated('usage.updated', '用量已更新'),
  fileChanged('file.changed', '文件状态已更新'),
  gitSnapshot('git.snapshot', 'Git 快照已更新'),
  commandUpdated('command.updated', '命令状态已更新'),
  unknown('unknown', '加密事件');

  const DaemonObservationEventType(this.wireValue, this.label);

  final String wireValue;
  final String label;

  static DaemonObservationEventType fromWire(String value) =>
      DaemonObservationEventType.values.firstWhere(
        (item) => item.wireValue == value,
        orElse: () => DaemonObservationEventType.unknown,
      );
}

enum CipherEnvelopeState { verified, opaque }

/// 经过 Relay 裁剪后的密文封装元数据。原始 key ID、nonce、AAD 和 ciphertext 不属于客户端 DTO。
class CipherEnvelopeMetadata {
  const CipherEnvelopeMetadata({required this.state, this.payloadVersion});

  factory CipherEnvelopeMetadata.fromRelayJson(Map<String, dynamic> json) {
    if (json['state'] != 'verified') {
      return const CipherEnvelopeMetadata(state: CipherEnvelopeState.opaque);
    }
    final algorithm = json['algorithm'];
    final payloadVersion = json['payload_version'];
    if (algorithm != 'v1-aes256gcm-hkdfsha256' ||
        payloadVersion is! num ||
        payloadVersion.toInt() < 1) {
      // 未知加密版本不能当作已验证格式展示；保留 opaque 占位并等待后续明确支持。
      return const CipherEnvelopeMetadata(state: CipherEnvelopeState.opaque);
    }
    return CipherEnvelopeMetadata(
      state: CipherEnvelopeState.verified,
      payloadVersion: payloadVersion.toInt(),
    );
  }

  final CipherEnvelopeState state;
  final int? payloadVersion;
}

/// 一条可显示的加密事件元数据。它从不持有、解密或缓存原始 envelope。
class DaemonCipherEventObservation {
  const DaemonCipherEventObservation({
    required this.sequence,
    required this.eventType,
    required this.envelope,
  });

  factory DaemonCipherEventObservation.fromRelayJson(
    Map<String, dynamic> json,
  ) {
    final rawSequence = json['event_seq'];
    final rawType = json['event_type'];
    final rawEnvelope = json['envelope'];
    if (rawSequence is! num ||
        rawSequence.toInt() < 1 ||
        rawType is! String ||
        rawEnvelope is! Map) {
      throw const RelayFailure(
        RelayFailureKind.protocol,
        'Relay 返回了无效的 Daemon 加密事件观察数据。',
      );
    }
    return DaemonCipherEventObservation(
      sequence: rawSequence.toInt(),
      eventType: DaemonObservationEventType.fromWire(rawType),
      envelope: CipherEnvelopeMetadata.fromRelayJson(
        Map<String, dynamic>.from(rawEnvelope),
      ),
    );
  }

  final int sequence;
  final DaemonObservationEventType eventType;
  final CipherEnvelopeMetadata envelope;
}

/// 一次 Relay observation 响应。命令为当前投影，事件可按 after_seq 增量追加。
class DaemonSessionObservation {
  const DaemonSessionObservation({
    required this.session,
    required this.commands,
    required this.events,
  });

  factory DaemonSessionObservation.fromRelayJson(Map<String, dynamic> json) {
    final rawSession = json['session'];
    final rawCommands = json['commands'];
    final rawEvents = json['events'];
    if (rawSession is! Map || rawCommands is! List || rawEvents is! List) {
      throw const RelayFailure(
        RelayFailureKind.protocol,
        'Relay Daemon 观察响应格式错误。',
      );
    }
    return DaemonSessionObservation(
      session: DaemonObservationSession.fromRelayJson(
        Map<String, dynamic>.from(rawSession),
      ),
      commands: rawCommands
          .map(
            (item) => DaemonCommandObservation.fromRelayJson(
              Map<String, dynamic>.from(item as Map),
            ),
          )
          .toList(growable: false),
      events: rawEvents
          .map(
            (item) => DaemonCipherEventObservation.fromRelayJson(
              Map<String, dynamic>.from(item as Map),
            ),
          )
          .toList(growable: false),
    );
  }

  final DaemonObservationSession session;
  final List<DaemonCommandObservation> commands;
  final List<DaemonCipherEventObservation> events;

  /// 增量刷新按事件序号去重，并限制只读页面内存保留窗口，不能累积原始 envelope。
  DaemonSessionObservation mergeIncrement(DaemonSessionObservation incoming) {
    final bySequence = <int, DaemonCipherEventObservation>{
      for (final event in events) event.sequence: event,
      for (final event in incoming.events) event.sequence: event,
    };
    final mergedEvents = bySequence.values.toList()
      ..sort((left, right) => left.sequence.compareTo(right.sequence));
    const maxRetainedEvents = 100;
    final retained = mergedEvents.length <= maxRetainedEvents
        ? mergedEvents
        : mergedEvents.sublist(mergedEvents.length - maxRetainedEvents);
    return DaemonSessionObservation(
      session: incoming.session,
      commands: List<DaemonCommandObservation>.unmodifiable(incoming.commands),
      events: List<DaemonCipherEventObservation>.unmodifiable(retained),
    );
  }
}
