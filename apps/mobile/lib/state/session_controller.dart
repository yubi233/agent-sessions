import 'dart:math';

import 'package:flutter/foundation.dart';

import '../domain/control_models.dart';
import '../domain/models.dart';
import '../domain/session_models.dart';
import '../relay/relay_repository.dart';

enum SessionListPhase { loading, ready, error }

/// 会话状态与认证状态分离：认证控制器只负责设备身份，本文控制器只负责用户可见的会话旅程。
class SessionController extends ChangeNotifier {
  /// 保持公开依赖参数为 relay，避免私有字段名成为外部调用契约。
  factory SessionController({
    required RelayRepository relay,
    DateTime Function()? clock,
    Random? random,
  }) => SessionController._(relay, clock: clock, random: random);

  SessionController._(this._relay, {DateTime Function()? clock, Random? random})
    : _clock = clock ?? DateTime.now,
      _random = random ?? Random.secure();

  final RelayRepository _relay;
  final DateTime Function() _clock;
  final Random _random;

  SessionListPhase _phase = SessionListPhase.loading;
  List<MobileSession> _sessions = const [];
  String? _selectedSessionId;
  List<SessionTimelineEvent> _timeline = const [];
  SessionLease? _selectedLease;
  CapabilityMatrix _capabilities = CapabilityMatrix.empty;
  SessionControlState _controls = const SessionControlState.empty();
  SkillConfirmation? _skillConfirmation;
  List<AttachmentTransfer> _attachments = const [];
  List<AttachmentRejection> _attachmentRejections = const [];
  bool _isDetailLoading = false;
  bool _isCapabilitiesLoading = false;
  final Set<String> _pendingActionKeys = {};
  final Set<String> _resolvedRequestKeys = {};
  final Map<String, String> _idempotencyKeys = {};
  String? _errorMessage;
  int _idempotencyCounter = 0;
  bool _initializing = false;

  SessionListPhase get phase => _phase;
  List<MobileSession> get sessions =>
      List<MobileSession>.unmodifiable(_sessions);
  List<SessionTimelineEvent> get timeline =>
      List<SessionTimelineEvent>.unmodifiable(_timeline);
  String? get selectedSessionId => _selectedSessionId;
  MobileSession? get selectedSession => _sessionById(_selectedSessionId);
  SessionLease? get selectedLease => _selectedLease;
  CapabilityMatrix get capabilities => _capabilities;
  ProviderCapabilityProfile get selectedProviderCapabilities =>
      _capabilities.provider(selectedSession?.provider ?? 'unknown');
  SessionControlState get controls => _controls;
  SkillConfirmation? get skillConfirmation => _skillConfirmation;
  List<AttachmentTransfer> get attachments =>
      List<AttachmentTransfer>.unmodifiable(_attachments);
  List<AttachmentRejection> get attachmentRejections =>
      List<AttachmentRejection>.unmodifiable(_attachmentRejections);
  bool get isDetailLoading => _isDetailLoading;
  bool get isCapabilitiesLoading => _isCapabilitiesLoading;
  bool get isBusy => _pendingActionKeys.isNotEmpty;
  String? get errorMessage => _errorMessage;
  bool get hasSelectedLease =>
      _selectedLease != null && _selectedLease!.epoch > 0;
  bool get isStreaming =>
      selectedSession?.status == MobileSessionStatus.streaming;
  bool get isEmpty => _phase == SessionListPhase.ready && _sessions.isEmpty;

  /// 仅在首次消费 provider 时拉取列表，避免页面 rebuild 时重复请求 Relay。
  Future<void> initialize() async {
    if (_initializing || _phase == SessionListPhase.ready) return;
    _initializing = true;
    try {
      await Future.wait([refreshSessions(), refreshCapabilities()]);
    } finally {
      _initializing = false;
    }
  }

  /// capability 失败时采取 fail-closed：已有会话仍可读，但所有 P3 写入口保持禁用。
  Future<void> refreshCapabilities() async {
    _isCapabilitiesLoading = true;
    notifyListeners();
    try {
      _capabilities = await _relay.getCapabilities();
    } on RelayFailure catch (failure) {
      _capabilities = CapabilityMatrix.empty;
      _errorMessage = failure.message;
    } catch (_) {
      _capabilities = CapabilityMatrix.empty;
      _errorMessage = '能力矩阵暂时不可用，控制入口已安全禁用。';
    } finally {
      _isCapabilitiesLoading = false;
      notifyListeners();
    }
  }

  Future<void> refreshSessions() async {
    _errorMessage = null;
    _phase = SessionListPhase.loading;
    notifyListeners();
    try {
      _sessions = await _relay.listSessions();
      _phase = SessionListPhase.ready;
      if (_selectedSessionId != null &&
          _sessionById(_selectedSessionId) == null) {
        _clearSelection();
      }
    } on RelayFailure catch (failure) {
      _phase = SessionListPhase.error;
      _errorMessage = failure.message;
    } catch (_) {
      _phase = SessionListPhase.error;
      _errorMessage = '会话列表暂时不可用，请稍后重试。';
    }
    notifyListeners();
  }

  /// 新会话尚未有可 fencing 的 session id，因此这里只校验 owner 身份；后续控制命令再要求 lease。
  Future<MobileSession?> createSession({
    required String workspaceId,
    required String provider,
    required String? deviceId,
    required bool canWrite,
  }) async {
    if (!_ensureWriteAccess(canWrite: canWrite, deviceId: deviceId)) {
      return null;
    }
    final actionKey = 'create:${workspaceId.trim()}:${provider.trim()}';
    return _runAction<MobileSession?>(actionKey, () async {
      final created = await _relay.createSession(
        CreateMobileSessionInput(
          workspaceId: workspaceId,
          provider: provider,
          deviceId: deviceId!,
        ),
      );
      _sessions = [
        created,
        ..._sessions.where((item) => item.id != created.id),
      ];
      _phase = SessionListPhase.ready;
      await _loadSelectedSession(created.id);
      return created;
    });
  }

  Future<void> selectSession(String sessionId) =>
      _loadSelectedSession(sessionId);

  /// 获取 lease 是显式操作，UI 可以准确呈现“只读”与“等待控制权”而不伪造可发送状态。
  Future<void> acquireSelectedLease({
    required String? deviceId,
    required bool canWrite,
  }) async {
    final sessionId = _selectedSessionId;
    if (sessionId == null ||
        !_ensureWriteAccess(canWrite: canWrite, deviceId: deviceId)) {
      return;
    }
    await _runAction<void>('lease:$sessionId', () async {
      final lease = await _relay.acquireSessionLease(sessionId);
      if (lease.sessionId != sessionId || lease.epoch <= 0) {
        throw const RelayFailure(RelayFailureKind.protocol, 'Relay 返回了无效控制权。');
      }
      _selectedLease = lease;
    });
  }

  Future<void> sendMessage({
    required String message,
    required String? deviceId,
    required bool canWrite,
  }) async {
    final trimmed = message.trim();
    if (trimmed.isEmpty) {
      _setError('请输入消息后再发送。');
      return;
    }
    final sessionId = _selectedSessionId;
    if (sessionId == null ||
        !_ensureWriteAccess(canWrite: canWrite, deviceId: deviceId) ||
        !_ensureSelectedLease(sessionId)) {
      return;
    }
    // 同一条待发送内容重试复用幂等键；成功后的新输入会生成新的 action key。
    final operation =
        'send:$sessionId:${selectedSession?.lastSequence ?? 0}:$trimmed';
    await _submitCommand(
      sessionId: sessionId,
      operation: operation,
      kind: SessionCommandKind.send,
      deviceId: deviceId!,
      ciphertext: {
        'fixture_payload': {'message': trimmed},
      },
    );
  }

  Future<void> stopStreaming({
    required String? deviceId,
    required bool canWrite,
  }) async {
    final sessionId = _selectedSessionId;
    if (sessionId == null ||
        !_ensureWriteAccess(canWrite: canWrite, deviceId: deviceId) ||
        !_ensureSelectedLease(sessionId)) {
      return;
    }
    await _submitCommand(
      sessionId: sessionId,
      operation: 'abort:$sessionId:${selectedSession?.lastSequence ?? 0}',
      kind: SessionCommandKind.abort,
      deviceId: deviceId!,
    );
  }

  Future<void> resolvePermission({
    required String requestId,
    required bool approved,
    required String? deviceId,
    required bool canWrite,
  }) async {
    final sessionId = _selectedSessionId;
    final requestKey = 'permission:$requestId';
    if (_resolvedRequestKeys.contains(requestKey) ||
        sessionId == null ||
        !_ensureWriteAccess(canWrite: canWrite, deviceId: deviceId) ||
        !_ensureSelectedLease(sessionId)) {
      return;
    }
    await _submitCommand(
      sessionId: sessionId,
      operation: '$requestKey:${approved ? 'approve' : 'reject'}',
      kind: approved
          ? SessionCommandKind.permissionApprove
          : SessionCommandKind.permissionReject,
      deviceId: deviceId!,
      ciphertext: {
        'fixture_payload': {'request_id': requestId},
      },
      onAccepted: () => _resolvedRequestKeys.add(requestKey),
    );
  }

  Future<void> answerQuestion({
    required String requestId,
    required String answer,
    required String? deviceId,
    required bool canWrite,
  }) async {
    final sessionId = _selectedSessionId;
    final requestKey = 'question:$requestId';
    if (answer.trim().isEmpty) {
      _setError('请选择或输入一个回答。');
      return;
    }
    if (_resolvedRequestKeys.contains(requestKey) ||
        sessionId == null ||
        !_ensureWriteAccess(canWrite: canWrite, deviceId: deviceId) ||
        !_ensureSelectedLease(sessionId)) {
      return;
    }
    await _submitCommand(
      sessionId: sessionId,
      operation: '$requestKey:answer',
      kind: SessionCommandKind.questionAnswer,
      deviceId: deviceId!,
      ciphertext: {
        'fixture_payload': {'request_id': requestId, 'answer': answer.trim()},
      },
      onAccepted: () => _resolvedRequestKeys.add(requestKey),
    );
  }

  bool isRequestPending(String requestId) =>
      _pendingActionKeys.any((key) => key.contains(':$requestId'));

  bool isRequestResolved(String type, String requestId) =>
      _resolvedRequestKeys.contains('$type:$requestId');

  /// 按 Provider capability、认证角色和当前 lease 依次收口写入口；调用方直接把返回原因呈现给用户。
  String? controlBlockedReason(
    String capability, {
    required bool canWrite,
    bool requiresLease = true,
  }) {
    final declared = selectedProviderCapabilities.capability(capability);
    if (!declared.isSupported) {
      return declared.reason ?? '$capability 当前不可用。';
    }
    if (!canWrite) return '当前登录是只读状态';
    if (_selectedSessionId == null) return '请选择一个会话';
    if (requiresLease && !hasSelectedLease) return '等待获取会话控制权';
    return null;
  }

  /// 高风险 Skill 先进入本地确认态；这里没有任何 Relay 写入，拒绝也不会产生 Provider 命令。
  void requestSkillConfirmation(
    SessionSkillDescriptor skill, {
    required bool canWrite,
  }) {
    final blocked = controlBlockedReason('invoke_skill', canWrite: canWrite);
    if (blocked != null) {
      _setError(blocked);
      return;
    }
    _skillConfirmation = SkillConfirmation(skill: skill);
    notifyListeners();
  }

  void rejectSkillConfirmation() {
    if (_skillConfirmation == null) return;
    _skillConfirmation = null;
    notifyListeners();
  }

  Future<void> confirmSkill({
    required String? deviceId,
    required bool canWrite,
  }) async {
    final confirmation = _skillConfirmation;
    final sessionId = _selectedSessionId;
    final blocked = controlBlockedReason('invoke_skill', canWrite: canWrite);
    if (confirmation == null || sessionId == null || blocked != null) {
      if (blocked != null) _setError(blocked);
      return;
    }
    await _submitCommand(
      sessionId: sessionId,
      operation: 'skill:$sessionId:${confirmation.skill.id}',
      kind: SessionCommandKind.skillInvoke,
      deviceId: deviceId!,
      ciphertext: {
        'fixture_payload': {'skill_id': confirmation.skill.id},
      },
      onAccepted: () => _skillConfirmation = null,
    );
  }

  Future<void> approvePlan({
    required String? deviceId,
    required bool canWrite,
  }) async {
    final plan = _controls.plan;
    final sessionId = _selectedSessionId;
    final blocked = controlBlockedReason('plan', canWrite: canWrite);
    if (plan == null ||
        plan.phase != PlanPhase.awaitingApproval ||
        sessionId == null ||
        blocked != null) {
      if (blocked != null) _setError(blocked);
      return;
    }
    await _submitCommand(
      sessionId: sessionId,
      operation: 'plan:$sessionId:approve',
      kind: SessionCommandKind.planApprove,
      deviceId: deviceId!,
      ciphertext: const {
        'fixture_payload': {'action': 'approve'},
      },
      onAccepted: () => _controls = _controls.copyWith(
        plan: plan.copyWith(phase: PlanPhase.active),
      ),
    );
  }

  Future<void> toggleGoal({
    required String? deviceId,
    required bool canWrite,
  }) async {
    final goal = _controls.goal;
    final sessionId = _selectedSessionId;
    final blocked = controlBlockedReason('goal', canWrite: canWrite);
    if (goal == null ||
        goal.phase == GoalPhase.completed ||
        sessionId == null ||
        blocked != null) {
      if (blocked != null) _setError(blocked);
      return;
    }
    final next = goal.phase == GoalPhase.active
        ? GoalPhase.paused
        : GoalPhase.active;
    await _submitCommand(
      sessionId: sessionId,
      operation: 'goal:$sessionId:${next.wireValue}',
      kind: SessionCommandKind.goalToggle,
      deviceId: deviceId!,
      ciphertext: {
        'fixture_payload': {'phase': next.wireValue},
      },
      onAccepted: () =>
          _controls = _controls.copyWith(goal: goal.copyWith(phase: next)),
    );
  }

  /// 添加前的 MIME/大小/密文块预检在本机完成。拒绝项仅显示在内存 composer，不会发出 HTTP 请求。
  bool addAttachmentDraft(AttachmentDraft draft) {
    try {
      draft.validate();
    } on RelayFailure catch (failure) {
      _attachmentRejections = [
        ..._attachmentRejections,
        AttachmentRejection(
          localName: draft.localName,
          reason: failure.message,
        ),
      ];
      notifyListeners();
      return false;
    }
    _attachments = [
      ..._attachments.where((item) => item.draft.id != draft.id),
      AttachmentTransfer(draft: draft, phase: AttachmentTransferPhase.queued),
    ];
    notifyListeners();
    return true;
  }

  void removeAttachment(String attachmentId) {
    _attachments = _attachments
        .where((item) => item.draft.id != attachmentId)
        .toList(growable: false);
    notifyListeners();
  }

  void dismissAttachmentRejection(String localName) {
    _attachmentRejections = _attachmentRejections
        .where((item) => item.localName != localName)
        .toList(growable: false);
    notifyListeners();
  }

  /// 一个 attachment 在同一 session 内顺序上传。每块和 complete 都复用稳定幂等键，失败后从已确认块继续。
  Future<void> uploadAttachment({
    required String attachmentId,
    required String? deviceId,
    required bool canWrite,
  }) async {
    final sessionId = _selectedSessionId;
    final blocked = controlBlockedReason('attachments', canWrite: canWrite);
    final transfer = _attachmentByID(attachmentId);
    if (sessionId == null || transfer == null || blocked != null) {
      if (blocked != null) _setError(blocked);
      return;
    }
    final actionKey = 'attachment:$sessionId:$attachmentId';
    if (_pendingActionKeys.contains(actionKey) ||
        transfer.phase == AttachmentTransferPhase.completed) {
      return;
    }
    final lease = _selectedLease;
    if (lease == null || lease.sessionId != sessionId || lease.epoch <= 0) {
      _setError('请先获取此会话的控制权。');
      return;
    }

    _errorMessage = null;
    _pendingActionKeys.add(actionKey);
    _replaceAttachment(
      attachmentId,
      transfer.copyWith(
        phase: AttachmentTransferPhase.uploading,
        clearError: true,
      ),
    );
    notifyListeners();
    try {
      var completedChunks = transfer.completedChunks;
      for (
        var index = completedChunks;
        index < transfer.draft.totalChunks;
        index += 1
      ) {
        await _relay.uploadAttachmentChunk(
          AttachmentChunkUploadInput(
            attachmentId: transfer.draft.id,
            sessionId: sessionId,
            mimeType: transfer.draft.mimeType,
            byteSize: transfer.draft.byteSize,
            compression: transfer.draft.compression,
            metadataCiphertext: transfer.draft.metadataCiphertext,
            chunkIndex: index,
            totalChunks: transfer.draft.totalChunks,
            ciphertext: transfer.draft.ciphertextChunks[index],
            idempotencyKey: _idempotencyKeyFor(
              'attachment:$sessionId:$attachmentId:chunk:$index',
            ),
            leaseEpoch: lease.epoch,
            deviceId: deviceId!,
          ),
        );
        completedChunks = index + 1;
        _replaceAttachment(
          attachmentId,
          transfer.copyWith(
            phase: AttachmentTransferPhase.uploading,
            completedChunks: completedChunks,
            clearError: true,
          ),
        );
        notifyListeners();
      }
      await _relay.completeAttachment(
        AttachmentCompleteInput(
          attachmentId: transfer.draft.id,
          sessionId: sessionId,
          totalChunks: transfer.draft.totalChunks,
          idempotencyKey: _idempotencyKeyFor(
            'attachment:$sessionId:$attachmentId:complete',
          ),
          leaseEpoch: lease.epoch,
          deviceId: deviceId!,
        ),
      );
      _replaceAttachment(
        attachmentId,
        transfer.copyWith(
          phase: AttachmentTransferPhase.completed,
          completedChunks: transfer.draft.totalChunks,
          clearError: true,
        ),
      );
    } on RelayFailure catch (failure) {
      final current = _attachmentByID(attachmentId) ?? transfer;
      _replaceAttachment(
        attachmentId,
        current.copyWith(
          phase: AttachmentTransferPhase.failed,
          errorMessage: failure.message,
        ),
      );
      _errorMessage = failure.message;
    } catch (_) {
      const message = '附件上传未完成，请稍后重试。';
      final current = _attachmentByID(attachmentId) ?? transfer;
      _replaceAttachment(
        attachmentId,
        current.copyWith(
          phase: AttachmentTransferPhase.failed,
          errorMessage: message,
        ),
      );
      _errorMessage = message;
    } finally {
      _pendingActionKeys.remove(actionKey);
      notifyListeners();
    }
  }

  bool isAttachmentPending(String attachmentId) =>
      _pendingActionKeys.any((key) => key.endsWith(':$attachmentId'));

  String? composerBlockedReason({required bool canWrite}) {
    if (!canWrite) return '当前登录是只读状态';
    if (_selectedSessionId == null) return '请选择一个会话';
    if (!hasSelectedLease) return '等待获取会话控制权';
    return null;
  }

  void clearError() {
    if (_errorMessage == null) return;
    _errorMessage = null;
    notifyListeners();
  }

  Future<void> _loadSelectedSession(String sessionId) async {
    if (_sessionById(sessionId) == null) {
      _setError('找不到所选会话。');
      return;
    }
    _errorMessage = null;
    _selectedSessionId = sessionId;
    _selectedLease = null;
    _resolvedRequestKeys.clear();
    _skillConfirmation = null;
    _attachments = const [];
    _attachmentRejections = const [];
    _controls = const SessionControlState.empty();
    _isDetailLoading = true;
    notifyListeners();
    try {
      final snapshot = await _relay.getSessionSnapshot(sessionId);
      _mergeSnapshot(snapshot);
      _controls = await _relay.getSessionControls(sessionId);
    } on RelayFailure catch (failure) {
      _errorMessage = failure.message;
    } catch (_) {
      _errorMessage = '会话内容暂时不可用，请稍后重试。';
    } finally {
      _isDetailLoading = false;
      notifyListeners();
    }
  }

  Future<void> _submitCommand({
    required String sessionId,
    required String operation,
    required SessionCommandKind kind,
    required String deviceId,
    Map<String, dynamic>? ciphertext,
    VoidCallback? onAccepted,
  }) async {
    if (!_ensureSelectedLease(sessionId)) return;
    await _runAction<void>(operation, () async {
      final lease = _selectedLease;
      if (lease == null || lease.sessionId != sessionId || lease.epoch <= 0) {
        throw const RelayFailure(
          RelayFailureKind.validation,
          '会话控制权已失效，请重新获取。',
        );
      }
      final command = SessionCommandInput(
        kind: kind,
        idempotencyKey: _idempotencyKeyFor(operation),
        leaseEpoch: lease.epoch,
        deviceId: deviceId,
        ciphertext: ciphertext,
      );
      await _relay.submitSessionCommand(sessionId, command);
      onAccepted?.call();
      final snapshot = await _relay.getSessionSnapshot(sessionId);
      _mergeSnapshot(snapshot);
    });
  }

  void _mergeSnapshot(SessionSnapshot snapshot) {
    _sessions = [
      snapshot.session,
      ..._sessions.where((item) => item.id != snapshot.session.id),
    ];
    _timeline = snapshot.events
        .map(SessionTimelineEvent.fromRelayEvent)
        .toList(growable: false);
  }

  AttachmentTransfer? _attachmentByID(String attachmentId) {
    for (final transfer in _attachments) {
      if (transfer.draft.id == attachmentId) return transfer;
    }
    return null;
  }

  void _replaceAttachment(String attachmentId, AttachmentTransfer next) {
    _attachments = _attachments
        .map((item) => item.draft.id == attachmentId ? next : item)
        .toList(growable: false);
  }

  MobileSession? _sessionById(String? sessionId) {
    if (sessionId == null) return null;
    for (final session in _sessions) {
      if (session.id == sessionId) return session;
    }
    return null;
  }

  bool _ensureWriteAccess({required bool canWrite, required String? deviceId}) {
    if (!canWrite || deviceId == null || deviceId.isEmpty) {
      _setError('当前登录为只读状态，没有 Android 写控制端，请使用 owner 设备继续。');
      return false;
    }
    return true;
  }

  bool _ensureSelectedLease(String sessionId) {
    final lease = _selectedLease;
    if (lease == null || lease.sessionId != sessionId || lease.epoch <= 0) {
      _setError('请先获取此会话的控制权。');
      return false;
    }
    return true;
  }

  String _idempotencyKeyFor(
    String operation,
  ) => _idempotencyKeys.putIfAbsent(operation, () {
    _idempotencyCounter += 1;
    final randomPart = _random.nextInt(1 << 32).toRadixString(16);
    return 'mobile-${_clock().toUtc().microsecondsSinceEpoch}-${_idempotencyCounter.toString().padLeft(4, '0')}-$randomPart';
  });

  Future<T?> _runAction<T>(
    String actionKey,
    Future<T> Function() action,
  ) async {
    if (_pendingActionKeys.contains(actionKey)) return null;
    _errorMessage = null;
    _pendingActionKeys.add(actionKey);
    notifyListeners();
    try {
      return await action();
    } on RelayFailure catch (failure) {
      _errorMessage = failure.message;
      return null;
    } catch (_) {
      _errorMessage = '操作未完成，请稍后重试。';
      return null;
    } finally {
      _pendingActionKeys.remove(actionKey);
      notifyListeners();
    }
  }

  void _clearSelection() {
    _selectedSessionId = null;
    _selectedLease = null;
    _timeline = const [];
    _resolvedRequestKeys.clear();
    _controls = const SessionControlState.empty();
    _skillConfirmation = null;
    _attachments = const [];
    _attachmentRejections = const [];
  }

  void _setError(String message) {
    _errorMessage = message;
    notifyListeners();
  }
}
