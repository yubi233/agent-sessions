import 'dart:math';

import 'package:flutter/foundation.dart';

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
  bool _isDetailLoading = false;
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
  bool get isDetailLoading => _isDetailLoading;
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
    await refreshSessions();
    _initializing = false;
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
    _isDetailLoading = true;
    notifyListeners();
    try {
      final snapshot = await _relay.getSessionSnapshot(sessionId);
      _mergeSnapshot(snapshot);
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
  }

  void _setError(String message) {
    _errorMessage = message;
    notifyListeners();
  }
}
