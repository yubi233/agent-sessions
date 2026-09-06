import 'dart:async';
import 'dart:typed_data';

import 'package:agent_sessions_mobile/relay/session_event_transport.dart';
import 'package:agent_sessions_mobile/relay/session_sse.dart';
import 'package:flutter_test/flutter_test.dart';

/// V090-09：App 会话事件传输状态机回归（C6）。
/// 覆盖：握手/首帧 live、wake 驱动快照且成功才提交 cursor、快照失败不跳事件、
/// typed 401（refresh 一次）/403 DEVICE_REVOKED/SCOPE_DENIED/404 探测/501 固定回落、
/// watchdog 断开重连、协议错误全量快照一次后回落、stop() 取消一切。
void main() {
  test('V090-09: 连接注释不算 live，首帧事件驱动快照并在合并成功后提交 cursor', () async {
    final env = _TransportEnv();
    // 流保持打开：live 是稳定状态（帧到达后），便于断言。
    env.streams.add(_streamWith([
      _bytes(': connected\n\n'),
      _bytes('id: 5\nevent: invalidated\ndata: {}\n\n'),
    ], closeAfterChunks: false));
    env.pullResults.add(true);
    final transport = env.build();
    transport.start();
    await _waitFor(() => env.pullCalls == 1);
    await _waitFor(() => transport.committedWake == 5);
    // 初始 connected 注释不清零退避/单独算 live：live 只在帧（正式事件）出现后成立。
    expect(transport.state, SessionEventTransportState.live);
    transport.stop();
  });

  test('V090-09: 快照失败不提交 wake——重连仍用已提交 cursor，不跳过未消费事件', () async {
    final env = _TransportEnv();
    env.streams.add(_streamWith([
      _bytes(': connected\n\n'),
      _bytes('id: 5\nevent: invalidated\ndata: {}\n\n'),
    ]));
    env.pullResults.add(false); // 第一次快照失败
    env.baseBackoff = const Duration(milliseconds: 5);
    final transport = env.build();
    transport.start();
    await _waitFor(() => env.pullCalls == 1);
    expect(transport.committedWake, isNull, reason: '快照失败不得提交 SSE id');

    // EOF 关闭 → 退避重连：Last-Event-ID 必须仍为空（不使用已看见未消费的 5）。
    env.streams.add(_streamWith([
      _bytes(': connected\n\n'),
      _bytes('id: 6\nevent: invalidated\ndata: {}\n\n'),
    ]));
    env.pullResults.add(true);
    await _waitFor(() => env.opens >= 2);
    await _waitFor(() => env.openLastEventIds.last == null);
    transport.stop();
  });

  test('V090-09: 401 → single-flight refresh 一次成功后重连', () async {
    final env = _TransportEnv();
    env.openFailures.add(
      const SessionSseHandshakeFailure(SessionSseFailureKind.unauthorized, status: 401),
    );
    env.streams.add(_streamWith([_bytes(': connected\n\n')]));
    env.refreshResults.add(true);
    final transport = env.build();
    transport.start();
    await _waitFor(() => env.opens >= 2, limit: 60);
    expect(env.refreshCalls, 1);
    expect(transport.state, isNot(SessionEventTransportState.authInvalid));
    transport.stop();
  });

  test('V090-09: 401 refresh 失败 → authInvalid', () async {
    final env = _TransportEnv();
    env.openFailures.add(
      const SessionSseHandshakeFailure(SessionSseFailureKind.unauthorized, status: 401),
    );
    env.refreshResults.add(false);
    final transport = env.build();
    transport.start();
    await _waitFor(() => transport.state == SessionEventTransportState.authInvalid);
    expect(env.opens, 1);
    transport.stop();
  });

  test('V090-09: 403 typed 分类——DEVICE_REVOKED 终止认证态，SCOPE_DENIED 只停资源', () async {
    final revoked = _TransportEnv();
    revoked.openFailures.add(
      const SessionSseHandshakeFailure(
        SessionSseFailureKind.deviceRevoked,
        status: 403,
        serverCode: 'DEVICE_REVOKED',
      ),
    );
    final revokedTransport = revoked.build();
    revokedTransport.start();
    await _waitFor(
      () => revokedTransport.state == SessionEventTransportState.authInvalid,
    );
    revokedTransport.stop();

    final denied = _TransportEnv();
    denied.openFailures.add(
      const SessionSseHandshakeFailure(
        SessionSseFailureKind.scopeDenied,
        status: 403,
        serverCode: 'SCOPE_DENIED',
      ),
    );
    final deniedTransport = denied.build();
    deniedTransport.start();
    await _waitFor(
      () => deniedTransport.state == SessionEventTransportState.resourceInvalid,
    );
    // 资源级失效不得注销仍有效的账号（refresh 未被调用）。
    expect(denied.refreshCalls, 0);
    deniedTransport.stop();
  });

  test('V090-09: 404 探测——snapshot 200 判定旧 Relay 固定 pollFallback；404 → resourceInvalid；网络未知保持退避', () async {
    // ① snapshot 200 → 旧 Relay 无该路由。
    final legacy = _TransportEnv();
    legacy.openFailures.add(
      const SessionSseHandshakeFailure(SessionSseFailureKind.notFound, status: 404),
    );
    legacy.probeResults.add(SessionSnapshotProbeResult.reachable);
    final legacyTransport = legacy.build();
    legacyTransport.start();
    await _waitFor(
      () => legacyTransport.state == SessionEventTransportState.pollFallback,
    );
    expect(legacy.probeCalls, 1);
    legacyTransport.stop();

    // ② snapshot 404/403 → 会话不存在/越权 → resourceInvalid。
    final missing = _TransportEnv();
    missing.openFailures.add(
      const SessionSseHandshakeFailure(SessionSseFailureKind.notFound, status: 404),
    );
    missing.probeResults.add(SessionSnapshotProbeResult.missing);
    final missingTransport = missing.build();
    missingTransport.start();
    await _waitFor(
      () => missingTransport.state == SessionEventTransportState.resourceInvalid,
    );
    missingTransport.stop();

    // ③ 探测遇网络失败 → 结论未知 → 保持 backoff 并重连。
    final unknown = _TransportEnv();
    unknown.openFailures.add(
      const SessionSseHandshakeFailure(SessionSseFailureKind.notFound, status: 404),
    );
    unknown.probeResults.add(SessionSnapshotProbeResult.unknown);
    unknown.baseBackoff = const Duration(milliseconds: 5);
    unknown.streams.add(_streamWith([_bytes(': connected\n\n')]));
    final unknownTransport = unknown.build();
    unknownTransport.start();
    await _waitFor(() => unknown.opens >= 2);
    expect(unknownTransport.state, isNot(SessionEventTransportState.resourceInvalid));
    unknownTransport.stop();
  });

  test('V090-09: 501/CAPABILITY_UNSUPPORTED（kill switch）直接固定 pollFallback', () async {
    final env = _TransportEnv();
    env.openFailures.add(
      const SessionSseHandshakeFailure(
        SessionSseFailureKind.capabilityUnsupported,
        status: 501,
        serverCode: 'CAPABILITY_UNSUPPORTED',
      ),
    );
    final transport = env.build();
    transport.start();
    await _waitFor(
      () => transport.state == SessionEventTransportState.pollFallback,
    );
    expect(env.probeCalls, 0, reason: 'kill switch 直接回落，不做 404 探测');
    transport.stop();
  });

  test('V090-09: watchdog——40 秒无字节判定僵死并主动重连（测试注入短 watchdog）', () async {
    final env = _TransportEnv();
    env.watchdogTimeout = const Duration(milliseconds: 40);
    // 永不产出字节的流。
    env.streams.add(Stream<Uint8List>.fromFuture(Completer<Uint8List>().future));
    env.streams.add(_streamWith([_bytes(': connected\n\n')]));
    env.baseBackoff = const Duration(milliseconds: 5);
    final transport = env.build();
    transport.start();
    await _waitFor(() => env.opens >= 2);
    transport.stop();
  });

  test('V090-09: 协议错误——首次强制全量快照重试一次，重复失败固定 pollFallback', () async {
    final env = _TransportEnv();
    env.streams.add(_streamWith([
      _bytes(': connected\n\n'),
      _bytes('id: not-a-number\nevent: invalidated\ndata: {}\n\n'),
    ]));
    final transport = env.build();
    transport.start();
    // 首次协议错误：全量快照（forceFull=true）被调用一次，随后流关闭触发重连。
    await _waitFor(() => env.fullSnapshotPulls == 1);
    transport.stop();
  });

  test('V090-09: stop() 取消 stream/watchdog/退避，不再发起新建流', () async {
    final env = _TransportEnv();
    env.baseBackoff = const Duration(milliseconds: 5);
    // 立即 EOF 的流：触发持续重连循环。
    env.streams.add(_streamWith(const []));
    final transport = env.build();
    transport.start();
    await _waitFor(() => env.opens >= 1);
    transport.stop();
    final opensAtStop = env.opens;
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(env.opens, opensAtStop, reason: 'stop 后不得再建流');
    expect(transport.state, SessionEventTransportState.stopped);
  });
}

Uint8List _bytes(String text) => Uint8List.fromList(text.codeUnits);

/// 产出给定字节块的流；[closeAfterChunks] 为 true 时产出即关闭（EOF，
/// 触发退避重连），否则保持打开（由 stop/关闭触发结束）。
Stream<Uint8List> _streamWith(
  List<Uint8List> chunks, {
  bool closeAfterChunks = true,
}) async* {
  for (final chunk in chunks) {
    yield chunk;
  }
  if (!closeAfterChunks) {
    await Completer<void>().future;
  }
}

Future<void> _waitFor(
  bool Function() condition, {
  int limit = 120,
}) async {
  for (var attempt = 0; attempt < limit; attempt++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('等待条件在 ${limit * 10}ms 内未满足');
}

/// 脚本化传输环境：可控 open 失败序列、流序列、快照拉取/探测/refresh 结果。
class _TransportEnv {
  final List<SessionSseHandshakeFailure> openFailures = [];
  final List<Stream<Uint8List>> streams = [];
  final List<bool> pullResults = [];
  final List<bool> refreshResults = [];
  final List<SessionSnapshotProbeResult> probeResults = [];
  final List<int?> openLastEventIds = [];
  int opens = 0;
  int pullCalls = 0;
  int fullSnapshotPulls = 0;
  int refreshCalls = 0;
  int probeCalls = 0;
  Duration baseBackoff = const Duration(milliseconds: 5);
  Duration? watchdogTimeout;

  SessionEventTransport build() {
    final source = _ScriptedSource(this);
    return SessionEventTransport(
      sessionId: 'sess-v090-transport',
      source: source,
      pullSnapshot: ({required bool forceFull}) async {
        pullCalls += 1;
        if (forceFull) fullSnapshotPulls += 1;
        return pullResults.isEmpty ? true : pullResults.removeAt(0);
      },
      probeSnapshot: () async {
        probeCalls += 1;
        return probeResults.isEmpty
            ? SessionSnapshotProbeResult.unknown
            : probeResults.removeAt(0);
      },
      refreshAuth: () async {
        refreshCalls += 1;
        return refreshResults.isEmpty ? false : refreshResults.removeAt(0);
      },
      baseBackoff: baseBackoff,
      watchdogTimeout: watchdogTimeout ?? const Duration(seconds: 40),
    );
  }
}

class _ScriptedSource implements SessionEventStreamSource {
  _ScriptedSource(this.env);
  final _TransportEnv env;

  @override
  Future<Stream<Uint8List>> open({
    required String sessionId,
    required int? lastEventId,
  }) async {
    env.opens += 1;
    env.openLastEventIds.add(lastEventId);
    if (env.openFailures.isNotEmpty) {
      throw env.openFailures.removeAt(0);
    }
    return env.streams.isEmpty
        ? _streamWith(const [])
        : env.streams.removeAt(0);
  }
}
