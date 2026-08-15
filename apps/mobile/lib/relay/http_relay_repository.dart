import 'dart:convert';

import 'package:dio/dio.dart';

import '../domain/control_models.dart';
import '../domain/delegation_models.dart';
import '../domain/models.dart';
import '../domain/session_models.dart';
import 'relay_repository.dart';

/// 真实 Relay REST 适配器。密码登录不提交角色或设备 id，只能获得 Relay 默认的只读 token。
class HttpRelayRepository implements RelayRepository {
  HttpRelayRepository({
    required Dio dio,
    required Future<AuthTokens?> Function() readTokens,
    DateTime Function()? clock,
  }) : this._(dio, readTokens, clock ?? DateTime.now);

  HttpRelayRepository._(this._dio, this._readTokens, this._clock);

  final Dio _dio;
  final Future<AuthTokens?> Function() _readTokens;
  final DateTime Function() _clock;

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
        'email': input.email.trim(),
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
        if (input.ciphertext != null) 'ciphertext': input.ciphertext,
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
      throw const RelayFailure(RelayFailureKind.protocol, 'Relay 返回了另一父会话的派发节点。');
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
  Future<SessionControlState> getSessionControls(String sessionId) async {
    if (sessionId.trim().isEmpty) {
      throw const RelayFailure.validation('会话标识无效。');
    }
    // Plan/Goal/Skill 的正文在端到端加密事件中。当前 HTTP snapshot 保持 opaque envelope，
    // 没有可安全解密的本地事件时只能返回空态，绝不能从 Relay 元数据伪造内容。
    return const SessionControlState.empty();
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
      throw const RelayFailure(RelayFailureKind.unauthorized, '登录状态已失效，请重新登录。');
    }
    return _send(
      method,
      path,
      data: data,
      queryParameters: queryParameters,
      accessToken: tokens.accessToken,
    );
  }

  Future<Response<dynamic>> _send(
    String method,
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    String? accessToken,
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
      throw switch (status) {
        401 => const RelayFailure(
          RelayFailureKind.unauthorized,
          '登录状态已失效，请重新登录。',
        ),
        403 => const RelayFailure(
          RelayFailureKind.forbidden,
          '当前设备没有执行此操作的权限。',
        ),
        409 => const RelayFailure(
          RelayFailureKind.forbidden,
          '会话控制权已更新，请重新获取。',
        ),
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
