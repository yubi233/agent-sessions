import 'dart:convert';

import 'package:dio/dio.dart';

import '../domain/control_models.dart';
import '../domain/daemon_observation_models.dart';
import '../domain/delegation_models.dart';
import '../domain/models.dart';
import '../domain/session_models.dart';
import '../domain/session_projection_models.dart';
import '../domain/terminal_models.dart';
import '../domain/usage_models.dart';
import 'relay_repository.dart';

/// 真实 Relay REST 适配器。密码登录不提交角色或设备 id，只能获得 Relay 默认的只读 token。
class HttpRelayRepository implements RelayRepository {
  HttpRelayRepository({
    required Dio dio,
    required Future<AuthTokens?> Function() readTokens,
    Future<void> Function(AuthTokens tokens)? writeTokens,
    DateTime Function()? clock,
  }) : this._(dio, readTokens, clock ?? DateTime.now, writeTokens);

  HttpRelayRepository._(this._dio, this._readTokens, this._clock, this._writeTokens);

  final Dio _dio;
  final Future<AuthTokens?> Function() _readTokens;
  final DateTime Function() _clock;
  final Future<void> Function(AuthTokens tokens)? _writeTokens;

  /// 并发的多个 401 共享同一次在途刷新：refresh token 是旋转的单次凭证，
  /// 重复使用会触发 Relay 的 reuse 撤销，把整个令牌族作废。
  Future<AuthTokens?>? _refreshInFlight;

  @override
  Future<DeviceBootstrapResult> bootstrapDevice(
    BootstrapOwnerInput input,
  ) async {
    final response = await _send(
      'POST',
      '/v1/auth/device-bootstrap',
      data: {
        'display_name': input.displayName,
        'platform': input.platform,
        'identity_public_key': input.keys.identityPublicKey,
        'encryption_public_key': input.keys.encryptionPublicKey,
      },
    );
    final body = _asMap(response.data);
    final devicePayload = body['device'];
    final tokenPayload = body['tokens'];
    if (devicePayload is! Map || tokenPayload is! Map) {
      throw const RelayFailure(RelayFailureKind.protocol, '设备初始化响应格式错误。');
    }
    final device = Device.fromJson(Map<String, dynamic>.from(devicePayload));
    final tokens = AuthTokens.fromRelayJson(
      Map<String, dynamic>.from(tokenPayload),
      _clock(),
    );
    if (tokens.deviceId == null ||
        tokens.deviceId!.isEmpty ||
        tokens.deviceId != device.id) {
      throw const RelayFailure(RelayFailureKind.protocol, '设备初始化令牌绑定不一致。');
    }
    return DeviceBootstrapResult(tokens: tokens, device: device);
  }

  @override
  Future<AuthTokens> register(LoginCredentials credentials) async {
    credentials.validate();
    final response = await _send(
      'POST',
      '/v1/auth/register',
      data: {
        'email': credentials.email.trim(),
        'password': credentials.password,
      },
    );
    return AuthTokens.fromRelayJson(_asMap(response.data), _clock());
  }

  @override
  Future<AuthTokens> login(LoginCredentials credentials) async {
    credentials.validate();
    final response = await _send(
      'POST',
      '/v1/auth/login',
      data: {
        'email': credentials.email.trim(),
        'password': credentials.password,
      },
    );
    return AuthTokens.fromRelayJson(_asMap(response.data), _clock());
  }

  @override
  Future<AuthTokens> refresh(String refreshToken) async {
    final response = await _send(
      'POST',
      '/v1/auth/refresh',
      data: {'refresh_token': refreshToken},
    );
    return AuthTokens.fromRelayJson(_asMap(response.data), _clock());
  }

  @override
  Future<SessionCommandReceipt> getSessionCommand(String commandId) async {
    final response = await _authenticatedSend('GET', '/v1/commands/$commandId');
    return SessionCommandReceipt.fromRelayJson(_asMap(response.data));
  }

  @override
  Future<void> logout(AuthTokens tokens) async {
    await _send(
      'POST',
      '/v1/auth/logout',
      accessToken: tokens.accessToken,
      data: {'refresh_token': tokens.refreshToken},
    );
  }

  @override
  Future<Device> bootstrapOwner(BootstrapOwnerInput input) async {
    final response = await _authenticatedSend(
      'POST',
      '/v1/pairing/bootstrap',
      data: {
        'display_name': input.displayName,
        'platform': input.platform,
        'identity_public_key': input.keys.identityPublicKey,
        'encryption_public_key': input.keys.encryptionPublicKey,
      },
    );
    return Device.fromJson(_asMap(response.data));
  }

  @override
  Future<List<Device>> listDevices() async {
    final response = await _authenticatedSend('GET', '/v1/devices');
    return _asList(
      response.data,
      wrappedKey: 'devices',
    ).map(Device.fromJson).toList(growable: false);
  }

  @override
  Future<void> revokeDevice(String deviceId) async {
    await _authenticatedSend('DELETE', '/v1/devices/$deviceId');
  }

  @override
  Future<List<TerminalSummary>> listTerminals() async {
    final response = await _authenticatedSend('GET', '/v1/terminals');
    return _asList(
      response.data,
      wrappedKey: 'terminals',
    ).map(TerminalSummary.fromRelayJson).toList(growable: false);
  }

  @override
  Future<UsageSummary> getUsageSummary({int days = 30}) async {
    final response = await _authenticatedSend(
      'GET',
      '/v1/usage/summary?days=$days',
    );
    return UsageSummary.fromRelayJson(_asMap(response.data));
  }

  @override
  Future<PairingRequest> createPairing(PairingRequestInput input) async {
    final response = await _authenticatedSend(
      'POST',
      '/v1/pairing/requests',
      data: {
        'role': input.role.wireValue == 'android_owner'
            ? 'android'
            : input.role.wireValue,
        'display_name': input.displayName,
        'platform': input.platform,
        'identity_public_key': input.keys.identityPublicKey,
        'encryption_public_key': input.keys.encryptionPublicKey,
      },
    );
    return PairingRequest.fromJson(_asMap(response.data));
  }

  @override
  Future<PairingRequest> getPairing(String requestId) async {
    final response = await _authenticatedSend(
      'GET',
      '/v1/pairing/requests/$requestId',
    );
    return PairingRequest.fromJson(_asMap(response.data));
  }

  @override
  Future<Device> approvePairing(String requestId) async {
    final response = await _authenticatedSend(
      'POST',
      '/v1/pairing/requests/$requestId/approve',
    );
    return Device.fromJson(_asMap(response.data));
  }

  @override
  Future<void> cancelPairing(String requestId) async {
    await _authenticatedSend('POST', '/v1/pairing/requests/$requestId/cancel');
  }

  @override
  Future<String> generateRecoveryCode() async {
    final response = await _authenticatedSend('POST', '/v1/recovery-codes');
    final code = _asMap(response.data)['recovery_code'];
    if (code is! String || code.isEmpty) {
      throw const RelayFailure(RelayFailureKind.protocol, 'Relay 未返回有效恢复码。');
    }
    return code;
  }

  @override
  Future<RecoveryResult> restoreWithRecoveryCode(
    RecoveryCodeInput input,
  ) async {
    final response = await _send(
      'POST',
      '/v1/recovery-codes/restore',
      data: {
        if (input.email.trim().isNotEmpty) 'email': input.email.trim(),
        'recovery_code': input.code,
        'display_name': input.displayName,
        'platform': 'android',
        'identity_public_key': input.keys.identityPublicKey,
        'encryption_public_key': input.keys.encryptionPublicKey,
      },
    );
    final body = _asMap(response.data);
    final tokens = AuthTokens.fromRelayJson(
      Map<String, dynamic>.from(body['tokens'] as Map? ?? body),
      _clock(),
    );
    final devicePayload = body['device'];
    if (devicePayload is! Map) {
      throw const RelayFailure(RelayFailureKind.protocol, '恢复响应缺少设备绑定。');
    }
    final device = Device.fromJson(Map<String, dynamic>.from(devicePayload));
    // 恢复响应的 token 与 device 必须来自同一次 Relay 绑定，不能由上层静默改写。
    if (tokens.deviceId == null ||
        tokens.deviceId!.isEmpty ||
        tokens.deviceId != device.id) {
      throw const RelayFailure(RelayFailureKind.protocol, '恢复响应中的设备令牌绑定不一致。');
    }
    return RecoveryResult(tokens: tokens, device: device);
  }

  @override
  Future<List<MobileSession>> listSessions() async {
    final response = await _authenticatedSend('GET', '/v1/sessions');
    return _asList(
      response.data,
      wrappedKey: 'sessions',
    ).map(MobileSession.fromRelayJson).toList(growable: false);
  }

  @override
  Future<List<MobileSession>> listArchivedSessions() async {
    final response = await _authenticatedSend(
      'GET',
      '/v1/sessions?archived=true',
    );
    return _asList(
      response.data,
      wrappedKey: 'sessions',
    ).map(MobileSession.fromRelayJson).toList(growable: false);
  }

  @override
  Future<List<MobileWorkspace>> listWorkspaces() async {
    final response = await _authenticatedSend('GET', '/v1/workspaces');
    return _asList(
      response.data,
      wrappedKey: 'workspaces',
    ).map(MobileWorkspace.fromRelayJson).toList(growable: false);
  }

  @override
  Future<MobileWorkspace> createWorkspace(
    CreateMobileWorkspaceInput input,
  ) async {
    input.validate();
    final response = await _authenticatedSend(
      'POST',
      '/v1/workspaces',
      data: {
        'project_id': input.projectId.trim(),
        'canonical_root': input.canonicalRoot.trim(),
        if (input.terminalId.trim().isNotEmpty)
          'terminal_id': input.terminalId.trim(),
        if (input.branch.trim().isNotEmpty) 'branch': input.branch.trim(),
        'status': 'active',
      },
    );
    return MobileWorkspace.fromRelayJson(_asMap(response.data));
  }

  @override
  Future<WorkspaceCreateState> createWorkspaceWithFolder(
    CreateMobileWorkspaceWithFolderInput input,
  ) async {
    input.validate();
    final response = await _authenticatedSend(
      'POST',
      '/v1/workspaces/create-with-folder',
      data: {
        'name': input.name.trim(),
        if (input.terminalId.trim().isNotEmpty)
          'terminal_id': input.terminalId.trim(),
      },
    );
    return WorkspaceCreateState.fromRelayJson(_asMap(response.data));
  }

  @override
  Future<WorkspaceCreateState> getWorkspaceCreateState(String commandId) async {
    if (commandId.trim().isEmpty) {
      throw const RelayFailure.validation('工作区创建命令标识无效。');
    }
    final response = await _authenticatedSend(
      'GET',
      '/v1/workspaces/create-with-folder/${commandId.trim()}',
    );
    return WorkspaceCreateState.fromRelayJson(_asMap(response.data));
  }

  @override
  Future<MobileSession> createSession(CreateMobileSessionInput input) async {
    input.validate();
    final response = await _authenticatedSend(
      'POST',
      '/v1/sessions',
      // Relay 从 bearer token 推导写设备；绝不能把本地的 deviceId 放入 body。
      data: {
        'workspace_id': input.workspaceId.trim(),
        if (input.provider.trim().isNotEmpty) 'provider': input.provider.trim(),
      },
    );
    return MobileSession.fromRelayJson(_asMap(response.data));
  }

  @override
  Future<MobileSession> forkSession(
    String sessionId,
    SessionForkInput input,
  ) async {
    input.validate();
    if (sessionId.trim().isEmpty) {
      throw const RelayFailure(RelayFailureKind.validation, '会话标识无效。');
    }
    final response = await _authenticatedSend(
      'POST',
      '/v1/sessions/$sessionId/forks',
      // device_id 不进入 wire body；Relay 必须从 bearer 绑定的 Android 写设备推导。
      data: {
        'message_id': input.messageId.trim(),
        'idempotency_key': input.idempotencyKey,
        'lease_epoch': input.leaseEpoch,
      },
    );
    final child = MobileSession.fromRelayJson(_asMap(response.data));
    if (child.parentSessionId != sessionId) {
      throw const RelayFailure(RelayFailureKind.protocol, 'Relay 返回了另一父会话的分支。');
    }
    return child;
  }

  @override
  Future<MobileSession> archiveSession(String sessionId) async {
    if (sessionId.trim().isEmpty) {
      throw const RelayFailure(RelayFailureKind.validation, '会话标识无效。');
    }
    final response = await _authenticatedSend(
      'POST',
      '/v1/sessions/$sessionId/archive',
    );
    return MobileSession.fromRelayJson(_asMap(response.data));
  }

  @override
  Future<MobileSession> unarchiveSession(String sessionId) async {
    if (sessionId.trim().isEmpty) {
      throw const RelayFailure(RelayFailureKind.validation, '会话标识无效。');
    }
    final response = await _authenticatedSend(
      'POST',
      '/v1/sessions/$sessionId/unarchive',
    );
    return MobileSession.fromRelayJson(_asMap(response.data));
  }

  @override
  Future<SessionSnapshot> getSessionSnapshot(
    String sessionId, {
    int afterSequence = 0,
  }) async {
    if (afterSequence < 0) {
      throw const RelayFailure(RelayFailureKind.validation, '事件游标不能为负数。');
    }
    final response = await _authenticatedSend(
      'GET',
      '/v1/sessions/$sessionId/snapshot',
      queryParameters: {'after_seq': afterSequence},
    );
    return SessionSnapshot.fromRelayJson(_asMap(response.data));
  }

  @override
  Future<DaemonSessionObservation> getSessionDaemonObservation(
    String sessionId, {
    int afterSequence = 0,
  }) async {
    if (sessionId.trim().isEmpty || afterSequence < 0) {
      throw const RelayFailure(
        RelayFailureKind.validation,
        'Daemon 观察会话或事件游标无效。',
      );
    }
    // P2-F 只读取 Relay 已裁剪的安全投影；Flutter 不连接 Terminal 专用 SSE，
    // 不持有 Daemon bearer，也不获取命令 payload 或原始密文 envelope。
    final response = await _authenticatedSend(
      'GET',
      '/v1/sessions/$sessionId/commands',
      queryParameters: {'after_seq': afterSequence},
    );
    return DaemonSessionObservation.fromRelayJson(_asMap(response.data));
  }

  @override
  Future<SessionLease> acquireSessionLease(String sessionId) async {
    final response = await _authenticatedSend(
      'POST',
      '/v1/sessions/$sessionId/lease',
    );
    final lease = SessionLease.fromRelayJson(_asMap(response.data));
    if (lease.sessionId != sessionId) {
      throw const RelayFailure(
        RelayFailureKind.protocol,
        'Relay 返回了另一会话的 lease。',
      );
    }
    return lease;
  }

  /// Daemon 命令 payload 契约（internal/daemon/runner.go commandEnvelope）：
  /// 顶层必须携带 session_id，业务负载整体位于 ciphertext.fixture_payload。
  /// 控制器侧只组装 fixture 负载（如 {"fixture_payload": {"message": ...}}），
  /// 这里统一补齐顶层 session_id 并把负载移入 ciphertext.fixture_payload，
  /// 否则 Daemon 会以「缺少 session_id」fail-closed 拒绝执行。
  Map<String, dynamic> _daemonCommandPayload(
    String sessionId,
    Map<String, dynamic>? ciphertext,
  ) {
    final inner =
        (ciphertext?['fixture_payload'] as Map<String, dynamic>?) ??
        const <String, dynamic>{};
    return <String, dynamic>{
      'session_id': sessionId,
      'ciphertext': {'fixture_payload': inner},
    };
  }

  @override
  Future<SessionCommandReceipt> submitSessionCommand(
    String sessionId,
    SessionCommandInput input,
  ) async {
    input.validate();
    final response = await _authenticatedSend(
      'POST',
      '/v1/sessions/$sessionId/commands',
      // device_id 只用于本地安全边界校验；服务端必须从认证上下文推导设备身份。
      data: {
        'kind': input.kind.wireValue,
        'idempotency_key': input.idempotencyKey,
        'lease_epoch': input.leaseEpoch,
        if (input.targetInstanceId?.isNotEmpty == true)
          'target_instance_id': input.targetInstanceId,
        'ciphertext': _daemonCommandPayload(sessionId, input.ciphertext),
      },
    );
    return SessionCommandReceipt.fromRelayJson(_asMap(response.data));
  }

  @override
  Future<List<SessionDelegation>> listSessionDelegations(
    String parentSessionId,
  ) async {
    if (parentSessionId.trim().isEmpty) {
      throw const RelayFailure(RelayFailureKind.validation, '父会话标识无效。');
    }
    final response = await _authenticatedSend(
      'GET',
      '/v1/sessions/$parentSessionId/delegations',
    );
    return _asList(
      response.data,
      wrappedKey: 'delegations',
    ).map(SessionDelegation.fromRelayJson).toList(growable: false);
  }

  @override
  Future<SessionDelegation> proposeDelegation(
    String parentSessionId,
    DelegationProposalInput input,
  ) async {
    input.validate();
    if (parentSessionId.trim().isEmpty) {
      throw const RelayFailure(RelayFailureKind.validation, '父会话标识无效。');
    }
    final response = await _authenticatedSend(
      'POST',
      '/v1/sessions/$parentSessionId/delegations',
      // device_id 不进 wire body；Relay 必须从 bearer 绑定的 Android 写设备推导。
      data: {
        'target_workspace_id': input.targetWorkspaceId,
        'target_provider': input.targetProvider,
        'task_envelope': input.taskEnvelope,
        'summary_envelope': input.summaryEnvelope,
        'idempotency_key': input.idempotencyKey,
        'lease_epoch': input.parentLeaseEpoch,
      },
    );
    final delegation = SessionDelegation.fromRelayJson(_asMap(response.data));
    if (delegation.parentSessionId != parentSessionId) {
      throw const RelayFailure(
        RelayFailureKind.protocol,
        'Relay 返回了另一父会话的派发节点。',
      );
    }
    return delegation;
  }

  @override
  Future<SessionDelegation> decideDelegation(
    String delegationId,
    DelegationDecisionInput input,
  ) async {
    input.validate();
    if (delegationId.trim().isEmpty) {
      throw const RelayFailure(RelayFailureKind.validation, '派发标识无效。');
    }
    final response = await _authenticatedSend(
      'POST',
      '/v1/delegations/$delegationId/decision',
      // device_id 不进入 wire body；Relay 必须从 bearer 绑定的 Android 写设备推导。
      data: {
        'decision': input.decision.wireValue,
        'idempotency_key': input.idempotencyKey,
        'lease_epoch': input.parentLeaseEpoch,
      },
    );
    final delegation = SessionDelegation.fromRelayJson(_asMap(response.data));
    if (delegation.id != delegationId) {
      throw const RelayFailure(RelayFailureKind.protocol, 'Relay 返回了另一派发节点。');
    }
    return delegation;
  }

  @override
  Future<CapabilityMatrix> getCapabilities() async {
    final response = await _authenticatedSend('GET', '/v1/capabilities');
    return CapabilityMatrix.fromRelayJson(_asMap(response.data));
  }

  @override
  Future<bool> sessionContentKeyAvailable(String sessionId) async {
    if (sessionId.trim().isEmpty) {
      throw const RelayFailure(RelayFailureKind.validation, '会话标识无效。');
    }
    // 真实 Relay 尚未部署端到端内容密钥交付通道；必须 fail-closed，禁止附件选文件入口。
    return false;
  }

  @override
  Future<SessionControlState> getSessionControls(String sessionId) async {
    if (sessionId.trim().isEmpty) {
      throw const RelayFailure.validation('会话标识无效。');
    }
    final response = await _authenticatedSend(
      'GET',
      '/v1/sessions/$sessionId/controls',
    );
    // Plan/Goal/Skill 的正文仍在端到端加密事件中；这里只消费 Relay 白名单
    // model/usage/timing 字段，缺失时保持空态，不补假数字。
    return SessionControlState.fromRelayJson(_asMap(response.data));
  }

  @override
  Future<ConversationFeedbackItem?> getMessageFeedback(
    String sessionId,
    String messageId,
  ) async {
    if (sessionId.trim().isEmpty || messageId.trim().isEmpty) {
      throw const RelayFailure.validation('反馈会话或消息标识无效。');
    }
    final response = await _authenticatedSend(
      'GET',
      '/v1/sessions/$sessionId/feedback/$messageId',
    );
    final item = _asMap(response.data)['item'];
    if (item == null) return null;
    if (item is! Map) {
      throw const RelayFailure(
        RelayFailureKind.protocol,
        'Relay feedback 响应格式错误。',
      );
    }
    return _feedbackItemFromRelay(Map<String, dynamic>.from(item));
  }

  @override
  Future<ConversationFeedbackResult> putMessageFeedback(
    String sessionId, {
    required String messageId,
    required ConversationFeedbackRating rating,
    String? note,
    int? version,
  }) async {
    if (sessionId.trim().isEmpty || messageId.trim().isEmpty) {
      throw const RelayFailure.validation('反馈会话或消息标识无效。');
    }
    final body = <String, dynamic>{'rating': _feedbackRatingWire(rating)};
    if (note != null) {
      body['note'] = note;
    }
    if (version != null) {
      body['version'] = version;
    }
    final response = await _authenticatedSend(
      'PUT',
      '/v1/sessions/$sessionId/feedback/$messageId',
      data: body,
    );
    return _feedbackResultFromRelay(_asMap(response.data));
  }

  @override
  Future<ConversationFeedbackResult> deleteMessageFeedback(
    String sessionId, {
    required String messageId,
    required int version,
  }) async {
    if (sessionId.trim().isEmpty || messageId.trim().isEmpty || version <= 0) {
      throw const RelayFailure.validation('反馈会话、消息或版本无效。');
    }
    final response = await _authenticatedSend(
      'DELETE',
      '/v1/sessions/$sessionId/feedback/$messageId',
      data: {'version': version},
    );
    return _feedbackResultFromRelay(_asMap(response.data));
  }

  @override
  Future<AttachmentReceipt> uploadAttachmentChunk(
    AttachmentChunkUploadInput input,
  ) async {
    input.validate();
    final response = await _authenticatedSend(
      'POST',
      '/v1/attachments/chunks',
      // localName 不属于公开 wire contract；只有密文、白名单元数据和 fencing 会离开设备。
      data: {
        'attachment_id': input.attachmentId,
        'session_id': input.sessionId,
        'mime_type': input.mimeType,
        'byte_size': input.byteSize,
        'compression': input.compression,
        'metadata_ciphertext': base64Encode(input.metadataCiphertext),
        'chunk_index': input.chunkIndex,
        'total_chunks': input.totalChunks,
        'ciphertext': base64Encode(input.ciphertext),
        'idempotency_key': input.idempotencyKey,
        'lease_epoch': input.leaseEpoch,
      },
    );
    final receipt = AttachmentReceipt.fromRelayJson(_asMap(response.data));
    if (receipt.attachmentId != input.attachmentId ||
        receipt.chunkIndex != input.chunkIndex) {
      throw const RelayFailure(RelayFailureKind.protocol, 'Relay 返回了另一附件块的回执。');
    }
    return receipt;
  }

  @override
  Future<AttachmentReceipt> completeAttachment(
    AttachmentCompleteInput input,
  ) async {
    input.validate();
    final response = await _authenticatedSend(
      'POST',
      '/v1/attachments/${input.attachmentId}/complete',
      data: {
        'session_id': input.sessionId,
        'total_chunks': input.totalChunks,
        'idempotency_key': input.idempotencyKey,
        'lease_epoch': input.leaseEpoch,
      },
    );
    final receipt = AttachmentReceipt.fromRelayJson(_asMap(response.data));
    if (receipt.attachmentId != input.attachmentId ||
        receipt.status != 'completed') {
      throw const RelayFailure(RelayFailureKind.protocol, 'Relay 未确认附件完成状态。');
    }
    return receipt;
  }

  Future<Response<dynamic>> _authenticatedSend(
    String method,
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
  }) async {
    final tokens = await _readTokens();
    if (tokens == null) {
      throw const RelayFailure(RelayFailureKind.unauthorized, '设备连接已失效，请重新连接。');
    }
    return _send(
      method,
      path,
      data: data,
      queryParameters: queryParameters,
      accessToken: tokens.accessToken,
    );
  }

  /// owner access token 只有 15 分钟 TTL；App 长时间闲置后的首个请求会撞 401。
  /// 用 refresh token 换新并重放一次；刷新失败才按未授权收敛，交给会话恢复流程。
  Future<AuthTokens?> _refreshTokensOnce() {
    final existing = _refreshInFlight;
    if (existing != null) {
      return existing;
    }
    final task = _refreshStoredTokens();
    _refreshInFlight = task;
    return task.whenComplete(() => _refreshInFlight = null);
  }

  Future<AuthTokens?> _refreshStoredTokens() async {
    final stored = await _readTokens();
    if (stored == null) {
      return null;
    }
    try {
      final refreshed = await refresh(stored.refreshToken);
      // 新 token（含旋转后的 refresh token）必须立刻持久化，否则下一次刷新
      // 会携带已被轮换的旧 refresh token，触发 reuse 撤销。
      await _writeTokens?.call(refreshed);
      return refreshed;
    } catch (_) {
      return null;
    }
  }

  Future<Response<dynamic>> _send(
    String method,
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    String? accessToken,
    bool allowAuthRefresh = true,
  }) async {
    try {
      return await _dio.request<dynamic>(
        path,
        data: data,
        queryParameters: queryParameters,
        options: Options(
          method: method,
          headers: {
            if (accessToken != null) 'Authorization': 'Bearer $accessToken',
          },
        ),
      );
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      if (status == 401 && accessToken != null && allowAuthRefresh) {
        final refreshed = await _refreshTokensOnce();
        if (refreshed != null) {
          return _send(
            method,
            path,
            data: data,
            queryParameters: queryParameters,
            accessToken: refreshed.accessToken,
            allowAuthRefresh: false,
          );
        }
      }
      throw switch (status) {
        401 => const RelayFailure(
          RelayFailureKind.unauthorized,
          '设备连接已失效，请重新连接。',
        ),
        403 => const RelayFailure(
          RelayFailureKind.forbidden,
          '当前设备没有执行此操作的权限。',
        ),
        409 => const RelayFailure(
          RelayFailureKind.forbidden,
          '会话控制权已更新，请重新获取。',
        ),
        404 => const RelayFailure(RelayFailureKind.validation, '资源不存在或无权访问。'),
        408 || 429 || 500 || 502 || 503 || 504 => const RelayFailure(
          RelayFailureKind.unavailable,
          'Relay 暂时不可用，请稍后重试。',
        ),
        _ => const RelayFailure(RelayFailureKind.protocol, 'Relay 响应不符合预期。'),
      };
    }
  }
}

Map<String, dynamic> _asMap(Object? value) {
  if (value is Map) {
    return Map<String, dynamic>.from(value);
  }
  throw const RelayFailure(RelayFailureKind.protocol, 'Relay 响应格式错误。');
}

List<Map<String, dynamic>> _asList(
  Object? value, {
  required String wrappedKey,
}) {
  final rawList = switch (value) {
    List<dynamic> value => value,
    Map<dynamic, dynamic> value => value[wrappedKey],
    _ => null,
  };
  if (rawList is! List) {
    throw const RelayFailure(RelayFailureKind.protocol, 'Relay 列表响应格式错误。');
  }
  return rawList
      .map((item) => Map<String, dynamic>.from(item as Map))
      .toList(growable: false);
}

ConversationFeedbackItem _feedbackItemFromRelay(Map<String, dynamic> json) {
  final rating = switch (json['rating']) {
    'positive' => ConversationFeedbackRating.positive,
    'negative' => ConversationFeedbackRating.negative,
    _ => throw const RelayFailure(
      RelayFailureKind.protocol,
      'Relay feedback rating 无效。',
    ),
  };
  final version = json['version'];
  return ConversationFeedbackItem(
    rating: rating,
    note: json['note'] is String && (json['note'] as String).trim().isNotEmpty
        ? (json['note'] as String).trim()
        : null,
    version: version is num ? version.toInt() : 0,
  );
}

ConversationFeedbackResult _feedbackResultFromRelay(Map<String, dynamic> json) {
  if (json['ok'] != true) {
    final code = json['error_code'];
    return ConversationFeedbackResult.failure(
      code is String && code.trim().isNotEmpty
          ? code.trim()
          : 'mutation-failed',
    );
  }
  final item = json['item'];
  if (item == null) return const ConversationFeedbackResult.success();
  if (item is! Map) {
    throw const RelayFailure(
      RelayFailureKind.protocol,
      'Relay feedback 响应格式错误。',
    );
  }
  return ConversationFeedbackResult.success(
    _feedbackItemFromRelay(Map<String, dynamic>.from(item)),
  );
}

String _feedbackRatingWire(ConversationFeedbackRating rating) =>
    switch (rating) {
      ConversationFeedbackRating.positive => 'positive',
      ConversationFeedbackRating.negative => 'negative',
    };
