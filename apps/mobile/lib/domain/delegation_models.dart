import 'models.dart';

/// Delegation 是产品层父子 Session 图节点。任务书永不进入此客户端投影，
/// 父会话只能看到状态、目标 Provider、child id 和仍保持加密的摘要 envelope。
enum DelegationStatus {
  proposed('proposed', '等待确认'),
  approved('approved', '已确认'),
  running('running', '运行中'),
  completed('completed', '已完成'),
  failed('failed', '失败'),
  cancelled('cancelled', '已取消'),
  rejected('rejected', '已拒绝'),
  unknown('unknown', '状态未知');

  const DelegationStatus(this.wireValue, this.label);

  final String wireValue;
  final String label;

  static DelegationStatus fromWire(Object? value) => switch (value) {
    'proposed' => DelegationStatus.proposed,
    'approved' => DelegationStatus.approved,
    'running' => DelegationStatus.running,
    'completed' => DelegationStatus.completed,
    'failed' => DelegationStatus.failed,
    'cancelled' => DelegationStatus.cancelled,
    'rejected' => DelegationStatus.rejected,
    _ => DelegationStatus.unknown,
  };
}

/// Relay 返回的 parent 图安全节点。`summaryEnvelope` 是 opaque 密文，不由 UI 解密或展示 ciphertext。
class SessionDelegation {
  const SessionDelegation({
    required this.id,
    required this.parentSessionId,
    required this.targetProvider,
    required this.status,
    required this.summaryEnvelope,
    required this.summaryEnvelopeSha256,
    this.childSessionId,
  });

  factory SessionDelegation.fromRelayJson(Map<String, dynamic> json) {
    if (json.containsKey('task_envelope')) {
      throw const RelayFailure(
        RelayFailureKind.protocol,
        'Relay delegation 投影不应包含任务书。',
      );
    }
    final rawEnvelope = json['summary_envelope'];
    if (rawEnvelope is! Map) {
      throw const RelayFailure(
        RelayFailureKind.protocol,
        'Relay delegation 缺少加密摘要。',
      );
    }
    final summaryEnvelope = Map<String, dynamic>.from(rawEnvelope);
    _validateOpaqueSummaryEnvelope(summaryEnvelope);
    return SessionDelegation(
      id: _requiredDelegationString(json, 'id'),
      parentSessionId: _requiredDelegationString(json, 'parent_session_id'),
      childSessionId: _optionalDelegationString(json['child_session_id']),
      targetProvider: _requiredDelegationString(json, 'target_provider'),
      status: DelegationStatus.fromWire(json['status']),
      summaryEnvelope: summaryEnvelope,
      summaryEnvelopeSha256: _requiredDelegationString(
        json,
        'summary_envelope_sha256',
      ),
    );
  }

  final String id;
  final String parentSessionId;
  final String? childSessionId;
  final String targetProvider;
  final DelegationStatus status;
  final Map<String, dynamic> summaryEnvelope;
  final String summaryEnvelopeSha256;

  bool get hasChildSession => childSessionId?.isNotEmpty == true;
  bool get canApproveOrReject => status == DelegationStatus.proposed;
  bool get canCancel =>
      status == DelegationStatus.approved || status == DelegationStatus.running;

  /// UI 只展示 hash 前缀作为“已加密摘要”的可核对标识，禁止读取或显示 ciphertext。
  String get summaryFingerprint => summaryEnvelopeSha256.length <= 12
      ? summaryEnvelopeSha256
      : summaryEnvelopeSha256.substring(0, 12);

  SessionDelegation copyWith({
    String? childSessionId,
    DelegationStatus? status,
  }) => SessionDelegation(
    id: id,
    parentSessionId: parentSessionId,
    childSessionId: childSessionId ?? this.childSessionId,
    targetProvider: targetProvider,
    status: status ?? this.status,
    summaryEnvelope: summaryEnvelope,
    summaryEnvelopeSha256: summaryEnvelopeSha256,
  );
}

enum DelegationDecision {
  approve('approve'),
  reject('reject'),
  cancel('cancel');

  const DelegationDecision(this.wireValue);

  final String wireValue;
}

/// Android 发起子会话派发的最小输入：任务书与摘要都是客户端密文 envelope，
/// 名称与正文永不进入本层 wire 契约；Relay 只保存密文、目标 Provider 与父会话 fencing。
class DelegationProposalInput {
  const DelegationProposalInput({
    required this.targetWorkspaceId,
    required this.targetProvider,
    required this.taskEnvelope,
    required this.summaryEnvelope,
    required this.idempotencyKey,
    required this.parentLeaseEpoch,
    required this.deviceId,
  });

  final String targetWorkspaceId;
  final String targetProvider;
  final Map<String, dynamic> taskEnvelope;
  final Map<String, dynamic> summaryEnvelope;
  final String idempotencyKey;
  final int parentLeaseEpoch;
  final String deviceId;

  void validate() {
    if (targetWorkspaceId.trim().isEmpty ||
        targetProvider.trim().isEmpty ||
        idempotencyKey.trim().isEmpty ||
        deviceId.trim().isEmpty) {
      throw const RelayFailure(RelayFailureKind.validation, '派发请求缺少目标或身份信息。');
    }
    if (parentLeaseEpoch <= 0) {
      throw const RelayFailure(RelayFailureKind.validation, '父会话可操作状态已失效，请重试。');
    }
    _validateOpaqueSummaryEnvelope(taskEnvelope);
    _validateOpaqueSummaryEnvelope(summaryEnvelope);
  }
}

/// 所有确认、拒绝和取消都沿用 parent 当前 lease；child 进入后必须通过它自己的 Session lease 写入。
class DelegationDecisionInput {
  const DelegationDecisionInput({
    required this.decision,
    required this.idempotencyKey,
    required this.parentLeaseEpoch,
    required this.deviceId,
  });

  final DelegationDecision decision;
  final String idempotencyKey;
  final int parentLeaseEpoch;
  final String deviceId;

  void validate() {
    if (idempotencyKey.trim().isEmpty || deviceId.trim().isEmpty) {
      throw const RelayFailure(RelayFailureKind.validation, '派发决策缺少设备或幂等标识。');
    }
    if (parentLeaseEpoch <= 0) {
      throw const RelayFailure(RelayFailureKind.validation, '父会话可操作状态已失效，请重试。');
    }
  }
}

String _requiredDelegationString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty) {
    throw RelayFailure(RelayFailureKind.protocol, 'Relay delegation 缺少 $key。');
  }
  return value.trim();
}

String? _optionalDelegationString(Object? value) =>
    value is String && value.trim().isNotEmpty ? value.trim() : null;

void _validateOpaqueSummaryEnvelope(Map<String, dynamic> envelope) {
  for (final forbidden in const [
    'plaintext',
    'text',
    'message',
    'prompt',
    'content',
    'task',
  ]) {
    if (envelope.containsKey(forbidden)) {
      throw const RelayFailure(
        RelayFailureKind.protocol,
        'Relay delegation 摘要包含禁止的明文字段。',
      );
    }
  }
  for (final key in const [
    'alg',
    'key_id',
    'nonce',
    'ciphertext',
    'aad_hash',
    'payload_version',
  ]) {
    final value = envelope[key];
    if (value == null || (value is String && value.trim().isEmpty)) {
      throw const RelayFailure(
        RelayFailureKind.protocol,
        'Relay delegation 摘要密文不完整。',
      );
    }
  }
}
