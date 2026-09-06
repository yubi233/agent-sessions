import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';

import 'session_sse.dart';

/// v0.9.0 C6：会话事件传输状态机。
/// SSE 只是失效通知加速路径：收到 wake 帧后拉增量快照，快照成功合并才提交
/// cursor；快照仍是内容与状态的唯一事实源，重连永远使用最近成功合并的 wake。
enum SessionEventTransportState {
  connecting,
  live,
  backoff,
  pollFallback,
  resourceInvalid,
  authInvalid,
  stopped,
}

/// 传输回调契约（由 SessionController 注入实现）：
typedef SessionSnapshotPull = Future<bool> Function({required bool forceFull});

typedef SessionSnapshotProbe = Future<SessionSnapshotProbeResult> Function();

typedef SessionAuthRefresh = Future<bool> Function();

/// 传输生命周期（C6）：
/// - 先成功合并一次目标会话快照，再用其 session cursor 建立 SSE（调用方保证）；
/// - wake 帧只是唤醒：pullSnapshot 成功才 commit frame id；
/// - 临时错误（网络/EOF/watchdog/429/5xx）：1→30 秒带 jitter 指数退避，前台持续
///   重试不永久降级；401 refresh 一次成功即重连；403 按 code typed 分类；
///   404 做 snapshot 探测后分类；405/501 固定 pollFallback；重复协议错误回落；
/// - [stop] 同步取消 stream、watchdog、退避计时（后台/离线/离开页面/dispose）。
class SessionEventTransport {
  SessionEventTransport({
    required this.sessionId,
    required this.source,
    required this.pullSnapshot,
    required this.probeSnapshot,
    required this.refreshAuth,
    this.onState,
    Random? random,
    this.handshakeTimeout = const Duration(seconds: 10),
    this.watchdogTimeout = const Duration(seconds: 40),
    this.baseBackoff = const Duration(seconds: 1),
    this.maxBackoff = const Duration(seconds: 30),
  }) : _random = random ?? Random.secure();

  final String sessionId;
  final SessionEventStreamSource source;
  final SessionSnapshotPull pullSnapshot;
  final SessionSnapshotProbe probeSnapshot;
  final SessionAuthRefresh refreshAuth;
  final void Function(SessionEventTransportState state)? onState;
  final Random _random;
  final Duration handshakeTimeout;
  final Duration watchdogTimeout;
  final Duration baseBackoff;
  final Duration maxBackoff;

  SessionEventTransportState _state = SessionEventTransportState.stopped;

  /// 当前状态（只读）。
  SessionEventTransportState get state => _state;

  /// 最近一次成功合并的 wake watermark（SSE 重连 cursor）。
  int? get committedWake => _committedWake;
  int? _committedWake;

  /// 协议错误计数（重复协议错误固定回落）。
  int _protocolErrors = 0;
  bool _fullSnapshotRetryUsed = false;
  int _backoffAttempts = 0;
  bool _stopping = false;
  Timer? _backoffTimer;
  Future<void>? _runLoop;

  void start() {
    if (_stopping || _runLoop != null) return;
    _setState(SessionEventTransportState.connecting);
    _runLoop = _run();
  }

  /// 同步阻止新调度并取消 stream/watchdog/退避计时；在途 Future 返回后不再
  /// 触发任何回调（C6 生命周期契约）。
  void stop() {
    if (_stopping) return;
    _stopping = true;
    _backoffTimer?.cancel();
    _setState(SessionEventTransportState.stopped);
  }

  void _setState(SessionEventTransportState next) {
    // stop 后只允许写入 stopped 终态（stop 自身的终态写入也要生效）。
    if (_state == next) return;
    if (_stopping && next != SessionEventTransportState.stopped) return;
    _state = next;
    onState?.call(next);
  }

  Future<void> _run() async {
    var refreshedOnce = false;
    while (!_stopping) {
      try {
        final stream = await source.open(
          sessionId: sessionId,
          lastEventId: _committedWake,
        ).timeout(handshakeTimeout);
        _backoffAttempts = 0;
        refreshedOnce = false;
        await _consume(stream);
        if (_stopping) return;
        // 服务端正常关闭（EOF）→ 临时错误，退避重连。
        await _backoffBeforeReconnect();
      } on SessionSseHandshakeFailure catch (failure) {
        switch (failure.kind) {
          case SessionSseFailureKind.unauthorized:
            // 一条失败链最多一次 single-flight refresh；成功立即重连。
            if (!refreshedOnce && await refreshAuth()) {
              refreshedOnce = true;
              continue;
            }
            _setState(SessionEventTransportState.authInvalid);
            return;
          case SessionSseFailureKind.deviceRevoked:
            _setState(SessionEventTransportState.authInvalid);
            return;
          case SessionSseFailureKind.scopeDenied:
            _setState(SessionEventTransportState.resourceInvalid);
            return;
          case SessionSseFailureKind.notFound:
            // 404 不直接等同旧 Relay 不支持：只做一次同 session snapshot 探测。
            final probe = await probeSnapshot();
            switch (probe) {
              case SessionSnapshotProbeResult.reachable:
                _setState(SessionEventTransportState.pollFallback);
                return;
              case SessionSnapshotProbeResult.missing:
              case SessionSnapshotProbeResult.forbidden:
                _setState(SessionEventTransportState.resourceInvalid);
                return;
              case SessionSnapshotProbeResult.unknown:
                await _backoffBeforeReconnect();
            }
          case SessionSseFailureKind.capabilityUnsupported:
            _setState(SessionEventTransportState.pollFallback);
            return;
          case SessionSseFailureKind.network:
            await _backoffBeforeReconnect();
          case SessionSseFailureKind.protocol:
            _setState(SessionEventTransportState.pollFallback);
            return;
        }
      } on SessionSseProtocolError catch (error) {
        // C6：首次协议错误先强制 after_seq=0 全量快照并重试一次；重复失败固定回落。
        _protocolErrors += 1;
        if (_protocolErrors == 1 && !_fullSnapshotRetryUsed) {
          _fullSnapshotRetryUsed = true;
          _committedWake = null;
          final merged = await pullSnapshot(forceFull: true);
          if (merged) continue;
        }
        debugPrint('SessionEventTransport[$sessionId] protocol fallback: '
            '${error.sanitizedMessage}');
        _setState(SessionEventTransportState.pollFallback);
        return;
      } catch (_) {
        // 未知异常按临时网络错误处理，保持轮询托底与有界退避。
        await _backoffBeforeReconnect();
      }
    }
  }

  /// 消费已建立的 SSE 流。返回即代表服务端关闭（EOF）。
  /// watchdog：40 秒无任何字节（含注释）判定僵死，主动断开走退避重连。
  Future<void> _consume(Stream<Uint8List> stream) async {
    final parser = SessionSseParser();
    final done = Completer<void>();
    Timer? watchdog;
    StreamSubscription<Uint8List>? subscription;
    var sawFirstByte = false;
    var watchdogFired = false;
    SessionSseProtocolError? protocolError;
    // 唤醒帧串行处理：快照拉取完成前不处理下一帧（合并顺序与 wake 顺序一致）。
    var processing = Future<void>.value();

    void armWatchdog() {
      watchdog?.cancel();
      watchdog = Timer(watchdogTimeout, () {
        watchdogFired = true;
        subscription?.cancel();
        if (!done.isCompleted) done.complete();
      });
    }

    subscription = stream.listen((chunk) {
      sawFirstByte = true;
      armWatchdog();
      List<SessionSseFrame> frames;
      try {
        frames = parser.addBytes(chunk);
      } on SessionSseProtocolError catch (error) {
        // listen 回调内不能向消费循环抛异常：记录后在 await done 之后重抛，
        // 由 _run 的协议错误分支处理（全量快照一次 → 重复失败回落）。
        protocolError = error;
        subscription?.cancel();
        if (!done.isCompleted) done.complete();
        return;
      }
      // C6：连接 flush 注释不清零退避；首个正式 heartbeat/事件才算 live。
      if (parser.sawSignOfLife) {
        _setState(SessionEventTransportState.live);
        _backoffAttempts = 0;
      }
      for (final frame in frames) {
        if (_stopping) {
          subscription?.cancel();
          if (!done.isCompleted) done.complete();
          return;
        }
        if (frame.id <= (_committedWake ?? 0)) continue;
        // 唤醒帧只是 wake watermark：快照成功合并才提交 cursor；失败不提交，
        // 重连仍以已提交 watermark 为准，绝不跳过未消费事件。
        final current = frame;
        processing = processing.then((_) async {
          if (_stopping) return;
          final merged = await pullSnapshot(forceFull: false);
          if (merged) _committedWake = current.id;
          if (!_stopping) armWatchdog();
        });
      }
    }, onError: (Object _) {
      if (!done.isCompleted) done.complete();
    }, onDone: () {
      if (!done.isCompleted) done.complete();
    });
    armWatchdog();
    await done.future;
    watchdog?.cancel();
    await processing;
    if (_stopping) return;
    final error = protocolError;
    if (error != null) throw error;
    if (watchdogFired || !sawFirstByte) {
      throw const SessionSseHandshakeFailure(SessionSseFailureKind.network);
    }
  }

  /// 1 秒到 30 秒指数退避 + jitter；前台期间持续重试，不永久降级。
  Future<void> _backoffBeforeReconnect() async {
    _backoffAttempts += 1;
    final exponential = baseBackoff * (1 << min(_backoffAttempts, 6));
    final jitterMs = _random.nextInt(1000);
    var delay = exponential + Duration(milliseconds: jitterMs);
    if (delay > maxBackoff) delay = maxBackoff;
    _setState(SessionEventTransportState.backoff);
    final completer = Completer<void>();
    _backoffTimer = Timer(delay, () {
      if (!completer.isCompleted) completer.complete();
    });
    await completer.future;
    _backoffTimer = null;
  }
}
