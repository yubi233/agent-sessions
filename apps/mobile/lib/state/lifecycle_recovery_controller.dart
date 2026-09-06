import 'dart:async';

import 'package:flutter/foundation.dart';

import 'session_controller.dart';

/// 平台生命周期只归一为前台/后台，避免业务层依赖 Android、macOS 或 Flutter 的具体枚举。
enum MobileAppVisibility { foreground, background }

/// 连通性插件只负责提示链路变化；真正是否可达仍以 Relay 的只读恢复请求为准。
enum MobileNetworkAvailability { unknown, online, offline }

enum SessionRecoveryPhase {
  idle,
  paused,
  waitingForNetwork,
  recovering,
  recovered,
  unavailable,
}

/// 无 UnifiedPush distributor 时的应用内降级通知。
/// 只记录会话标识、数量和时间，绝不把事件正文、密文或凭据放入通知队列。
class InAppRecoveryNotice {
  const InAppRecoveryNotice({
    required this.id,
    required this.sessionId,
    required this.eventCount,
    required this.createdAt,
  });

  final String id;
  final String sessionId;
  final int eventCount;
  final DateTime createdAt;
}

/// 将前后台、网络变化和 cursor 恢复编排在同一处。
/// 它不保存或重放待写命令，恢复期间只调用 [SessionController] 的只读增量 snapshot 路径。
class SessionRecoveryController extends ChangeNotifier {
  factory SessionRecoveryController({
    required SessionController sessions,
    DateTime Function()? clock,
  }) => SessionRecoveryController._(sessions, clock: clock);

  SessionRecoveryController._(this._sessions, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final SessionController _sessions;
  final DateTime Function() _clock;

  MobileAppVisibility _visibility = MobileAppVisibility.foreground;
  MobileNetworkAvailability _network = MobileNetworkAvailability.unknown;
  SessionRecoveryPhase _phase = SessionRecoveryPhase.idle;
  String? _message;
  int _noticeSequence = 0;
  Future<void>? _activeRecovery;
  List<InAppRecoveryNotice> _notices = const [];
  // 仅在经历后台或离线后才需要补齐 cursor；首次连接 online 不能伪装成一次恢复完成。
  bool _recoveryPending = false;

  MobileAppVisibility get visibility => _visibility;
  MobileNetworkAvailability get network => _network;
  SessionRecoveryPhase get phase => _phase;
  String? get message => _message;
  bool get isRecovering => _phase == SessionRecoveryPhase.recovering;
  List<InAppRecoveryNotice> get notices =>
      List<InAppRecoveryNotice>.unmodifiable(_notices);
  InAppRecoveryNotice? get latestNotice =>
      _notices.isEmpty ? null : _notices.last;

  /// 后台或链路断开都立即废弃本地 lease；再次写入必须由用户显式重新获取 fencing epoch。
  Future<void> reportAppVisibility(MobileAppVisibility value) async {
    final changed = _visibility != value;
    _visibility = value;
    if (value == MobileAppVisibility.background) {
      _recoveryPending = true;
      _sessions.invalidateSelectedLeaseForRuntimePause();
      // 后台期间禁止写命令自动补获取 lease，防止静默发出用户未看到的输入。
      _sessions.setAutoLeaseEnabled(false);
      // v0.9.0 C4：后台停拍——quiet reconcile 停止，零新请求。
      _sessions.setQuietReconcileActive(false);
      _phase = SessionRecoveryPhase.paused;
      _message = '应用已进入后台，返回后将重新确认可操作状态。';
      if (changed) notifyListeners();
      return;
    }
    if (changed && _network != MobileNetworkAvailability.online) {
      _phase = _network == MobileNetworkAvailability.offline
          ? SessionRecoveryPhase.waitingForNetwork
          : SessionRecoveryPhase.idle;
      _message = _network == MobileNetworkAvailability.offline
          ? '等待网络恢复后补齐会话事件。'
          : null;
      notifyListeners();
    }
    await _recoverIfReady();
  }

  /// 网络状态为 offline 时不尝试请求 Relay；online 仅触发恢复，实际连通性由 snapshot 结果裁决。
  Future<void> reportNetworkAvailability(
    MobileNetworkAvailability value,
  ) async {
    final changed = _network != value;
    _network = value;
    if (value == MobileNetworkAvailability.offline) {
      _recoveryPending = true;
      _sessions.invalidateSelectedLeaseForRuntimePause();
      // 离线时同样禁止自动补获取（请求必然失败，也不该在弱网下发起写）。
      _sessions.setAutoLeaseEnabled(false);
      // v0.9.0 C4：离线停拍。
      _sessions.setQuietReconcileActive(false);
      _phase = _visibility == MobileAppVisibility.background
          ? SessionRecoveryPhase.paused
          : SessionRecoveryPhase.waitingForNetwork;
      _message = '网络暂不可用，已保留只读时间线。';
      if (changed) notifyListeners();
      return;
    }
    if (value == MobileNetworkAvailability.unknown) {
      if (changed && _visibility == MobileAppVisibility.foreground) {
        _phase = SessionRecoveryPhase.idle;
        _message = null;
        notifyListeners();
      }
      return;
    }
    await _recoverIfReady();
  }

  /// 供用户可见的重试入口使用；它仍遵守前台、在线和“只读恢复”三项条件。
  Future<void> retryRecovery() => _recoverIfReady(force: true);

  void dismissNotice(String noticeId) {
    final next = _notices
        .where((notice) => notice.id != noticeId)
        .toList(growable: false);
    if (next.length == _notices.length) return;
    _notices = next;
    notifyListeners();
  }

  Future<void> _recoverIfReady({bool force = false}) {
    if (_visibility != MobileAppVisibility.foreground ||
        _network != MobileNetworkAvailability.online) {
      return Future<void>.value();
    }
    if (!force && !_recoveryPending) {
      return Future<void>.value();
    }
    if (!force && _sessions.selectedSessionId == null) {
      _recoveryPending = false;
      _phase = SessionRecoveryPhase.idle;
      _message = null;
      notifyListeners();
      return Future<void>.value();
    }
    final active = _activeRecovery;
    if (active != null) return active;
    // 让调用方 await 到清理完成；否则下一轮生命周期信号可能看到已完成但尚未清空的 Future，
    // 并把本应执行的 cursor 恢复误判为重复请求。
    late final Future<void> trackedRecovery;
    trackedRecovery = _performRecovery().whenComplete(() {
      if (identical(_activeRecovery, trackedRecovery)) {
        _activeRecovery = null;
      }
    });
    _activeRecovery = trackedRecovery;
    return trackedRecovery;
  }

  Future<void> _performRecovery() async {
    _phase = SessionRecoveryPhase.recovering;
    _message = '正在按已确认 cursor 恢复会话事件。';
    notifyListeners();
    try {
      final recovery = await _sessions.recoverSelectedSessionFromCursor();
      if (recovery == null) {
        _recoveryPending = false;
        _phase = SessionRecoveryPhase.idle;
        _message = null;
        notifyListeners();
        return;
      }
      _phase = SessionRecoveryPhase.recovered;
      _recoveryPending = false;
      // 回到前台/在线：重新打开自动获取闸门。
      _sessions.setAutoLeaseEnabled(true);
      // v0.9.0 C4：前台恢复重新开启 quiet reconcile，并立即执行一次首拍
      // （与上面的 cursor recovery 共享单航班请求，不叠加）。周期拍由
      // Timer.periodic 在完整 25 秒间隔后才会触发，首拍不会重复。
      _sessions.setQuietReconcileActive(true);
      unawaited(_sessions.quietReconcileTick());
      // 恢复只读事件后自动重取会话写权（沿用最近一次成功授权参数），
      // 用户从后台/断网回到前台即可直接发送，无需手动点按“暂不可操作”重试。
      await _sessions.reacquireLeaseAfterRuntimePause();
      _message = recovery.addedEventCount == 0
          ? '会话已同步，没有遗漏事件。'
          : '已同步 ${recovery.addedEventCount} 条新事件。';
      if (recovery.addedEventCount > 0) {
        _noticeSequence += 1;
        final notice = InAppRecoveryNotice(
          id: 'recovery-${_clock().toUtc().microsecondsSinceEpoch}-$_noticeSequence',
          sessionId: recovery.sessionId,
          eventCount: recovery.addedEventCount,
          createdAt: _clock(),
        );
        // 同一个会话只保留最新一条，队列上限防止长期离线导致内存无界增长。
        final nextNotices = [
          ..._notices.where((item) => item.sessionId != notice.sessionId),
          notice,
        ];
        // 新通知追加在末尾，达到上限时必须淘汰最旧项，不能反向丢掉刚恢复的状态。
        _notices = nextNotices.length <= 10
            ? List<InAppRecoveryNotice>.unmodifiable(nextNotices)
            : List<InAppRecoveryNotice>.unmodifiable(
                nextNotices.sublist(nextNotices.length - 10),
              );
      }
    } catch (_) {
      // 底层 Relay 已返回脱敏错误；此处不拼接 transport 原文，避免泄露 token 或正文。
      _phase = SessionRecoveryPhase.unavailable;
      _message = '暂时无法恢复会话，网络恢复后可再次尝试。';
    }
    notifyListeners();
  }
}
