import 'dart:math';

import 'package:flutter/foundation.dart';

import '../domain/control_models.dart';
import '../domain/delegation_models.dart';
import '../domain/models.dart';
import '../domain/session_models.dart';
import '../relay/relay_repository.dart';

/// 父子图的加载状态与会话正文状态分离，避免 parent 刷新时短暂显示上一会话的 delegation。
enum DelegationPhase { idle, loading, ready, error }

/// DelegationController 只持有 parent 可见的安全图投影。
/// 它不解密任务书、不读取 child timeline，也不缓存 child session 的控制权。
class DelegationController extends ChangeNotifier {
  DelegationController({
    required this.relay,
    DateTime Function()? clock,
    Random? random,
  }) : _clock = clock ?? DateTime.now,
       _random = random ?? Random.secure();

  final RelayRepository relay;
  final DateTime Function() _clock;
  final Random _random;

  DelegationPhase _phase = DelegationPhase.idle;
  String? _parentSessionId;
  List<SessionDelegation> _delegations = const [];
  final Map<String, List<SessionDelegation>> _catalogs = {};
  final Map<String, DelegationPhase> _catalogPhases = {};
  final Map<String, String> _catalogMessages = {};
  final Set<String> _pendingActionKeys = {};
  final Map<String, String> _idempotencyKeys = {};
  String? _message;
  int _requestSerial = 0;
  int _idempotencyCounter = 0;

  DelegationPhase get phase => _phase;
  String? get parentSessionId => _parentSessionId;
  List<SessionDelegation> get delegations =>
      List<SessionDelegation>.unmodifiable(_delegations);
  String? get message => _message;
  bool get isLoading => _phase == DelegationPhase.loading;
  List<SessionDelegation> catalogFor(String parentSessionId) =>
      List<SessionDelegation>.unmodifiable(
        _catalogs[parentSessionId] ?? const [],
      );
  DelegationPhase catalogPhaseFor(String parentSessionId) =>
      _catalogPhases[parentSessionId] ?? DelegationPhase.idle;
  String? catalogMessageFor(String parentSessionId) =>
      _catalogMessages[parentSessionId];

  bool isDecisionPending(String delegationId) =>
      _pendingActionKeys.any((key) => key.endsWith(':$delegationId'));

  /// parent 切换时先清空旧节点。request serial 防止慢响应覆盖当前详情页的图。
  Future<void> loadForParent(
    String parentSessionId, {
    bool force = false,
  }) async {
    final normalized = parentSessionId.trim();
    if (normalized.isEmpty) {
      _parentSessionId = null;
      _delegations = const [];
      _phase = DelegationPhase.idle;
      _message = null;
      notifyListeners();
      return;
    }
    if (!force &&
        _parentSessionId == normalized &&
        _phase == DelegationPhase.ready) {
      return;
    }
    final serial = ++_requestSerial;
    _parentSessionId = normalized;
    _delegations = const [];
    _message = null;
    _phase = DelegationPhase.loading;
    _catalogPhases[normalized] = DelegationPhase.loading;
    _catalogMessages.remove(normalized);
    notifyListeners();
    try {
      final next = await relay.listSessionDelegations(normalized);
      if (serial != _requestSerial || _parentSessionId != normalized) return;
      _delegations = next;
      _catalogs[normalized] = next;
      _catalogPhases[normalized] = DelegationPhase.ready;
      _catalogMessages.remove(normalized);
      _phase = DelegationPhase.ready;
    } on RelayFailure catch (failure) {
      if (serial != _requestSerial || _parentSessionId != normalized) return;
      _phase = DelegationPhase.error;
      _message = failure.message;
      _catalogPhases[normalized] = DelegationPhase.error;
      _catalogMessages[normalized] = failure.message;
    } catch (_) {
      if (serial != _requestSerial || _parentSessionId != normalized) return;
      _phase = DelegationPhase.error;
      _message = '子会话图暂时不可用，请稍后刷新。';
      _catalogPhases[normalized] = DelegationPhase.error;
      _catalogMessages[normalized] = _message!;
    }
    notifyListeners();
  }

  Future<void> loadCatalog(String parentSessionId, {bool force = false}) async {
    final normalized = parentSessionId.trim();
    if (normalized.isEmpty) return;
    if (!force && _catalogPhases[normalized] == DelegationPhase.ready) {
      return;
    }
    _catalogPhases[normalized] = DelegationPhase.loading;
    _catalogMessages.remove(normalized);
    notifyListeners();
    try {
      final next = await relay.listSessionDelegations(normalized);
      _catalogs[normalized] = next;
      _catalogPhases[normalized] = DelegationPhase.ready;
    } on RelayFailure catch (failure) {
      _catalogPhases[normalized] = DelegationPhase.error;
      _catalogMessages[normalized] = failure.message;
    } catch (_) {
      _catalogPhases[normalized] = DelegationPhase.error;
      _catalogMessages[normalized] = '子会话图暂时不可用，请稍后刷新。';
    }
    notifyListeners();
  }

  /// 决策入口必须同时经过 Provider capability、Android owner 和 parent lease 三重门控。
  /// child 的 lease 不会传入这里，防止 UI 误把 child 控制权当作父会话确认权限。
  String? decisionBlockedReason({
    required SessionDelegation delegation,
    required DelegationDecision decision,
    required CapabilityMatrix capabilities,
    required bool canWrite,
    required String? deviceId,
    required SessionLease? parentLease,
  }) {
    if (delegation.parentSessionId != _parentSessionId) {
      return '派发节点不属于当前会话。';
    }
    if (!canWrite || deviceId == null || deviceId.trim().isEmpty) {
      return '当前设备是只读状态';
    }
    if (parentLease == null ||
        parentLease.sessionId != delegation.parentSessionId ||
        parentLease.epoch <= 0) {
      return '请先在父会话中确认可操作状态后重试';
    }
    final capability = capabilities
        .provider(delegation.targetProvider)
        .capability('delegate_cross_provider');
    if (!capability.isSupported) {
      return capability.reason ?? '目标 Provider 不支持跨工具派发。';
    }
    final allowed = switch (decision) {
      DelegationDecision.approve ||
      DelegationDecision.reject => delegation.canApproveOrReject,
      DelegationDecision.cancel => delegation.canCancel,
    };
    if (!allowed) return '该派发节点当前不能执行此操作。';
    return null;
  }

  /// approve/reject/cancel 共用稳定幂等键。成功后只替换同一安全图节点，绝不合并 child 内容。
  Future<SessionDelegation?> decide({
    required SessionDelegation delegation,
    required DelegationDecision decision,
    required CapabilityMatrix capabilities,
    required bool canWrite,
    required String? deviceId,
    required SessionLease? parentLease,
  }) async {
    final blocked = decisionBlockedReason(
      delegation: delegation,
      decision: decision,
      capabilities: capabilities,
      canWrite: canWrite,
      deviceId: deviceId,
      parentLease: parentLease,
    );
    if (blocked != null) {
      _message = blocked;
      notifyListeners();
      return null;
    }
    final actionKey = '${decision.wireValue}:${delegation.id}';
    if (_pendingActionKeys.contains(actionKey)) return null;
    final lease = parentLease!;
    _pendingActionKeys.add(actionKey);
    _message = null;
    notifyListeners();
    try {
      final result = await relay.decideDelegation(
        delegation.id,
        DelegationDecisionInput(
          decision: decision,
          idempotencyKey: _idempotencyKeyFor('$actionKey:${lease.epoch}'),
          parentLeaseEpoch: lease.epoch,
          deviceId: deviceId!.trim(),
        ),
      );
      if (result.parentSessionId != delegation.parentSessionId) {
        throw const RelayFailure(
          RelayFailureKind.protocol,
          'Relay 返回了另一父会话的派发节点。',
        );
      }
      _delegations = _delegations
          .map((item) => item.id == result.id ? result : item)
          .toList(growable: false);
      _catalogs[delegation.parentSessionId] = _delegations;
      return result;
    } on RelayFailure catch (failure) {
      _message = failure.message;
      return null;
    } catch (_) {
      _message = '派发决策未完成，请稍后重试。';
      return null;
    } finally {
      _pendingActionKeys.remove(actionKey);
      notifyListeners();
    }
  }

  /// 派发入口门控：父 Provider 必须声明 delegate_session；跨 Provider 还要求 delegate_cross_provider。
  String? proposeBlockedReason({
    required String targetProvider,
    required CapabilityMatrix capabilities,
    required bool canWrite,
    required String? deviceId,
    required SessionLease? parentLease,
    required String? parentProvider,
  }) {
    if (!canWrite || deviceId == null || deviceId.trim().isEmpty) {
      return '当前设备是只读状态';
    }
    if (parentLease == null ||
        parentLease.sessionId != _parentSessionId ||
        parentLease.epoch <= 0) {
      return '请先在父会话中确认可操作状态后重试';
    }
    final parentCapability = capabilities
        .provider(parentProvider ?? 'unknown')
        .capability('delegate_session');
    if (!parentCapability.isSupported) {
      return parentCapability.reason ?? '当前 Provider 不支持子会话派发。';
    }
    if (targetProvider != (parentProvider ?? 'unknown')) {
      final cross = capabilities
          .provider(targetProvider)
          .capability('delegate_cross_provider');
      if (!cross.isSupported) {
        return cross.reason ?? '目标 Provider 不支持跨工具派发。';
      }
    }
    return null;
  }

  /// v0.2/P2：Android 发起子会话派发。任务书/摘要由调用方提供密文 envelope，
  /// 控制器只提交目标 Provider 与父会话 fencing，成功后把 proposed 节点加入当前图。
  Future<SessionDelegation?> propose({
    required String parentSessionId,
    required String targetWorkspaceId,
    required String targetProvider,
    required String? parentProvider,
    required Map<String, dynamic> taskEnvelope,
    required Map<String, dynamic> summaryEnvelope,
    required CapabilityMatrix capabilities,
    required bool canWrite,
    required String? deviceId,
    required SessionLease? parentLease,
  }) async {
    final blocked = proposeBlockedReason(
      targetProvider: targetProvider,
      capabilities: capabilities,
      canWrite: canWrite,
      deviceId: deviceId,
      parentLease: parentLease,
      parentProvider: parentProvider,
    );
    if (blocked != null) {
      _message = blocked;
      notifyListeners();
      return null;
    }
    final actionKey = 'propose:$parentSessionId:$targetProvider';
    if (_pendingActionKeys.contains(actionKey)) return null;
    final lease = parentLease!;
    _pendingActionKeys.add(actionKey);
    _message = null;
    notifyListeners();
    try {
      final result = await relay.proposeDelegation(
        parentSessionId,
        DelegationProposalInput(
          targetWorkspaceId: targetWorkspaceId,
          targetProvider: targetProvider,
          taskEnvelope: taskEnvelope,
          summaryEnvelope: summaryEnvelope,
          idempotencyKey: _idempotencyKeyFor('$actionKey:${lease.epoch}'),
          parentLeaseEpoch: lease.epoch,
          deviceId: deviceId!.trim(),
        ),
      );
      if (result.parentSessionId != parentSessionId) {
        throw const RelayFailure(
          RelayFailureKind.protocol,
          'Relay 返回了另一父会话的派发节点。',
        );
      }
      _delegations = [
        result,
        ..._delegations.where((item) => item.id != result.id),
      ];
      return result;
    } on RelayFailure catch (failure) {
      _message = failure.message;
      return null;
    } catch (_) {
      _message = '子会话派发未完成，请稍后重试。';
      return null;
    } finally {
      _pendingActionKeys.remove(actionKey);
      notifyListeners();
    }
  }

  void clearMessage() {
    if (_message == null) return;
    _message = null;
    notifyListeners();
  }

  String _idempotencyKeyFor(
    String operation,
  ) => _idempotencyKeys.putIfAbsent(operation, () {
    _idempotencyCounter += 1;
    final randomPart = _random.nextInt(1 << 32).toRadixString(16);
    return 'delegation-${_clock().toUtc().microsecondsSinceEpoch}-${_idempotencyCounter.toString().padLeft(4, '0')}-$randomPart';
  });
}
