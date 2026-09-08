import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/models.dart';
import '../domain/terminal_models.dart';
import '../relay/relay_repository.dart';
import 'lifecycle_recovery_controller.dart';

/// P3 机器页的只读状态机；v0.9.1 P2 升级为「生命周期感知的无感同步」控制器
/// （迭代计划 §3.3 / §4 P2，V091-08..10）。
///
/// 设计冻结（裁决 T2/T4/T5）：
///   - availability 唯一来源是 Relay 投影（`TerminalSummary.availability`），
///     本控制器不再用客户端墙钟二次裁决；本地时钟仅用于诊断展示；
///   - 失效通知（presence invalidation）只是加速，前台 45-60s 带 jitter 的
///     safety reconcile 是兜底；两者与手动刷新、生命周期恢复共用同一
///     single-flight / pending coalescing 通道；
///   - quiet refresh：失败保留最后可信列表、不闪 loading、不把网络失败改写成
///     执行端 offline（`isUnreachable` 单独表达「事实不可确认」）。
///
/// 同步资格（eligibility）= 已认证 && 前台 && 网络非离线 && 至少一个活跃 surface。
/// 资格之外零新请求；恢复资格只触发一次去重首拍（[MobileAppVisibility] 等枚举
/// 复用生命周期恢复控制器的归一化定义，避免两套生命周期口径）。
enum TerminalListPhase { loading, ready, error }

/// 同步唤醒来源；只用于诊断计数，不改变同步语义。
enum TerminalSyncWakeSource { manual, presenceInvalidation, safetyReconcile, lifecycleRecovery }

class TerminalStatusController extends ChangeNotifier {
  TerminalStatusController({
    required this.relay,
    DateTime Function()? clock,
    Duration Function()? safetyInterval,
  }) : _clock = clock ?? DateTime.now,
       _safetyInterval = safetyInterval ?? _defaultSafetyInterval;

  /// 前台 safety reconcile 周期冻结为 45s 基础 + 0-15s jitter（裁决 T4）。
  static Duration _defaultSafetyInterval() {
    final jitterMs = DateTime.now().millisecondsSinceEpoch % 15000;
    return Duration(milliseconds: 45000 + jitterMs);
  }

  final RelayRepository relay;
  final DateTime Function() _clock;

  /// 诊断用本地时间（仅调试口径；在线态投影一律来自 Relay，见 availabilityFor）。
  @visibleForTesting
  DateTime get diagnosticsNow => _clock();

  final Duration Function() _safetyInterval;

  TerminalListPhase _phase = TerminalListPhase.loading;
  List<TerminalSummary> _terminals = const [];
  String? _errorMessage;
  bool _isRefreshing = false;
  // 最后一次同步失败且已有可信数据时为 true：页面据此表达 unknown/unreachable，
  // 绝不把网络故障改写成执行端 offline（裁决 T5）。
  bool _unreachable = false;
  // 同步资格输入。
  MobileAppVisibility _visibility = MobileAppVisibility.foreground;
  MobileNetworkAvailability _network = MobileNetworkAvailability.unknown;
  bool _authenticated = false;
  int _attachedSurfaces = 0;
  // 代际：认证边界（注销/换账号/dispose 语义）与页面挂载代际。
  // 迟到 Future 只有在「认证代际 + surface 代际」都匹配时才允许写入状态。
  int _authGeneration = 0;
  int _surfaceGeneration = 0;
  bool _disposed = false;
  // single-flight + pending coalescing：同一时刻至多一个在飞请求；
  // 飞行中的其它唤醒合并为 pending，落地后按最新资格补一拍。
  Future<void>? _inflight;
  bool _pendingWake = false;
  Timer? _safetyTimer;

  TerminalListPhase get phase => _phase;
  List<TerminalSummary> get terminals =>
      List<TerminalSummary>.unmodifiable(_terminals);
  String? get errorMessage => _errorMessage;
  bool get isRefreshing => _isRefreshing;
  bool get isUnreachable => _unreachable;
  MobileAppVisibility get visibility => _visibility;
  MobileNetworkAvailability get network => _network;

  /// 在线态唯一投影入口（v0.9.1 C1）：透传 Relay 投影/legacy 派生，不读本地墙钟。
  TerminalAvailability availabilityFor(TerminalSummary terminal) =>
      terminal.availability;

  Future<void> initialize() => ensureSync(TerminalSyncWakeSource.lifecycleRecovery);

  // ---- 生命周期边界（App 层 binding 转发） ----

  /// 前后台切换。后台停止新请求并取消 safety timer；回前台触发一次去重首拍。
  void reportAppVisibility(MobileAppVisibility value) {
    if (_disposed || _visibility == value) return;
    _visibility = value;
    if (_isEligible) {
      _armSafetyTimer();
      unawaited(ensureSync(TerminalSyncWakeSource.lifecycleRecovery));
    } else {
      _cancelSafetyTimer();
    }
    notifyListeners();
  }

  /// 网络可用性变化。offline 停止新请求；恢复只触发一个去重首拍。
  void reportNetworkAvailability(MobileNetworkAvailability value) {
    if (_disposed || _network == value) return;
    final wasOffline = _network == MobileNetworkAvailability.offline;
    _network = value;
    if (_isEligible) {
      _armSafetyTimer();
      // offline -> 恢复：去重首拍；其它网络抖动交由 safety reconcile 兜底。
      if (wasOffline) {
        unawaited(ensureSync(TerminalSyncWakeSource.lifecycleRecovery));
      }
    } else {
      _cancelSafetyTimer();
    }
    notifyListeners();
  }

  /// 认证边界（注销/设备失效/换账号/重新认证）。递增认证代际：在飞响应按代际
  /// 丢弃，旧账号数据不得污染新账号（V091-09）。
  void reportAuthBoundary({required bool authenticated}) {
    if (_disposed) return;
    _authGeneration++;
    _authenticated = authenticated;
    if (!authenticated) {
      // 注销即清空可信投影：新账号绝不能看到旧账号的 Terminal 列表。
      _terminals = const [];
      _errorMessage = null;
      _unreachable = false;
      _phase = TerminalListPhase.loading;
      _cancelSafetyTimer();
    } else if (_isEligible) {
      _armSafetyTimer();
      unawaited(ensureSync(TerminalSyncWakeSource.lifecycleRecovery));
    }
    notifyListeners();
  }

  /// 页面挂载/卸载（surface 代际）。挂载递增代际并按资格触发去重首拍；
  /// 全部 surface 卸载后停止 safety reconcile（页面切换不产生后台请求）。
  void attachSurface() {
    if (_disposed) return;
    _attachedSurfaces++;
    _surfaceGeneration++;
    if (_isEligible) {
      _armSafetyTimer();
      unawaited(ensureSync(TerminalSyncWakeSource.lifecycleRecovery));
    }
  }

  void detachSurface() {
    if (_disposed) return;
    _attachedSurfaces =
        _attachedSurfaces > 0 ? _attachedSurfaces - 1 : 0;
    if (!_isEligible) {
      _cancelSafetyTimer();
    }
  }

  /// presence invalidation 唤醒（账号 SSE terminal.presence.changed 的消费入口）。
  /// 只做失效通知语义：revision 校验交由快照对比（Relay DTO 是唯一事实），
  /// 与其它唤醒共用 single-flight 通道。
  void notifyPresenceInvalidation({
    String? terminalId,
    int? presenceRevision,
  }) {
    if (_disposed || !_isEligible) return;
    unawaited(ensureSync(TerminalSyncWakeSource.presenceInvalidation));
  }

  /// 手动刷新始终允许（用户显式动作），但同样走 single-flight 通道。
  Future<void> refresh() => ensureSync(TerminalSyncWakeSource.manual);

  // ---- 同步内核 ----

  /// 同步资格：认证有效 + 前台 + 网络非离线 + 至少一个活跃 surface。
  /// manual 唤醒不受此限制（见 [refresh]），资格检查发生在 ensureSync 内部。
  bool get _isEligible =>
      _authenticated &&
      !_disposed &&
      _visibility == MobileAppVisibility.foreground &&
      _network != MobileNetworkAvailability.offline &&
      _attachedSurfaces > 0;

  /// single-flight 入口：在飞则合并为 pending；资格不满足时静默忽略
  /// （手动刷新除外）。返回当前在飞（或即将执行的）Future。
  Future<void> ensureSync(TerminalSyncWakeSource source, {bool force = false}) {
    if (_disposed) return Future.value();
    if (_inflight != null) {
      // pending coalescing：无论多少唤醒合并，落地后至多补一拍。
      _pendingWake = true;
      if (source == TerminalSyncWakeSource.manual) _pendingWakeFromManual = true;
      return _inflight!;
    }
    if (!force && source != TerminalSyncWakeSource.manual && !_isEligible) {
      return Future.value();
    }
    final future = _runSync(source);
    _inflight = future;
    unawaited(
      future.whenComplete(() {
        _inflight = null;
        if (_disposed) return;
        // pending 补拍：飞行期间有过新唤醒时按最新资格重拉一次；
        // 只有补拍也不再在飞，才会让下一次唤醒立即执行。
        if (_pendingWake) {
          final retryManual = _pendingWakeFromManual;
          _pendingWake = false;
          _pendingWakeFromManual = false;
          if (retryManual || _isEligible) {
            unawaited(
              ensureSync(
                retryManual
                    ? TerminalSyncWakeSource.manual
                    : TerminalSyncWakeSource.lifecycleRecovery,
              ),
            );
          }
        }
      }),
    );
    return future;
  }

  Future<void> _runSync(TerminalSyncWakeSource source) async {
    final authGeneration = _authGeneration;
    final surfaceGeneration = _surfaceGeneration;
    final hadTerminals = _terminals.isNotEmpty;
    _isRefreshing = true;
    _errorMessage = null;
    // quiet refresh：已有可信数据时不闪 loading（phase 保持 ready）。
    if (!hadTerminals) _phase = TerminalListPhase.loading;
    notifyListeners();
    try {
      final terminals = await relay.listTerminals();
      // 迟到响应防护：认证代际或 surface 代际变化（注销/换账号/页面重挂）后，
      // 旧响应既不写入状态也不 notify、更不显示错误（V091-09）。
      if (_disposed ||
          authGeneration != _authGeneration ||
          surfaceGeneration != _surfaceGeneration) {
        return;
      }
      _terminals = terminals;
      _phase = TerminalListPhase.ready;
      _unreachable = false;
    } on RelayFailure catch (failure) {
      if (_disposed ||
          authGeneration != _authGeneration ||
          surfaceGeneration != _surfaceGeneration) {
        return;
      }
      // 失败保留最后可信投影；只在零数据时才进入 error 阶段（首拍失败）。
      _errorMessage = failure.message;
      _unreachable = hadTerminals;
      if (!hadTerminals) _phase = TerminalListPhase.error;
    } catch (_) {
      if (_disposed ||
          authGeneration != _authGeneration ||
          surfaceGeneration != _surfaceGeneration) {
        return;
      }
      _errorMessage = '终端状态暂时不可用，请稍后重试。';
      _unreachable = hadTerminals;
      if (!hadTerminals) _phase = TerminalListPhase.error;
    } finally {
      _isRefreshing = false;
      _notifyChanged();
    }
  }

  // pending 唤醒里是否包含手动刷新（手动刷新允许在资格外补拍）。
  bool _pendingWakeFromManual = false;

  void _notifyChanged() {
    if (!_disposed) notifyListeners();
  }

  // ---- safety reconcile（45-60s jitter） ----

  void _armSafetyTimer() {
    if (_disposed || !_isEligible || _safetyTimer != null) return;
    _safetyTimer = Timer(_safetyInterval(), () {
      _safetyTimer = null;
      if (_isEligible) {
        unawaited(ensureSync(TerminalSyncWakeSource.safetyReconcile));
        _armSafetyTimer();
      }
    });
  }

  void _cancelSafetyTimer() {
    _safetyTimer?.cancel();
    _safetyTimer = null;
  }

  @override
  void dispose() {
    // dispose 递增代际：在飞响应全部作废；timer 释放；此后零新请求。
    _authGeneration++;
    _disposed = true;
    _cancelSafetyTimer();
    super.dispose();
  }
}
