import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:agent_sessions_mobile/domain/models.dart';
import 'package:agent_sessions_mobile/domain/terminal_models.dart';
import 'package:agent_sessions_mobile/relay/fixture_relay_repository.dart';
import 'package:agent_sessions_mobile/state/lifecycle_recovery_controller.dart';
import 'package:agent_sessions_mobile/state/terminal_status_controller.dart';

// v0.9.1 P2（迭代计划 §4 P2）：Flutter 生命周期感知同步的控制器级回归。
// 覆盖 V091-08（生命周期边界）、V091-09（single-flight/代际隔离）、
// V091-10（失败保留可信投影 + unknown 不伪装 offline）。
// widget 层可见验收（V091-11..12）与 headed fixture（V091-14）分别在
// v091_terminal_ui_test.dart 与 e2e-verify/mobile 中。

/// 可控 Relay：listTerminals 支持挂起（Completer）、错误注入与请求计数。
class _ControllableTerminalRelay extends FixtureRelayRepository {
  /// 预排队列：请求开始时取走并转入 inFlight（调用方随后手动放行）。
  final List<Completer<List<TerminalSummary>>> queued = [];
  /// 已开始、等待测试放行的在飞请求（按开始顺序）。
  final List<Completer<List<TerminalSummary>>> inFlight = [];
  int requestCount = 0;
  RelayFailure? nextFailure;
  List<TerminalSummary>? immediateResult;

  void holdNextRequest() => queued.add(Completer<List<TerminalSummary>>());

  void completeOldestInFlight(List<TerminalSummary> terminals) {
    inFlight.removeAt(0).complete(terminals);
  }

  void failNextRequest(RelayFailure failure) => nextFailure = failure;

  void succeedNextWith(List<TerminalSummary> terminals) =>
      immediateResult = terminals;

  @override
  Future<List<TerminalSummary>> listTerminals() {
    requestCount++;
    final failure = nextFailure;
    nextFailure = null;
    if (failure != null) return Future.error(failure);
    final result = immediateResult;
    immediateResult = null;
    if (result != null) return Future.value(result);
    if (queued.isNotEmpty) {
      final completer = queued.removeAt(0);
      inFlight.add(completer);
      return completer.future;
    }
    return Future.value(const <TerminalSummary>[]);
  }
}

TerminalSummary _onlineTerminal({
  String id = 'term-v091',
  int revision = 1,
}) {
  return TerminalSummary.fromRelayJson({
    'id': id,
    'hostname': 'darwin',
    'platform': 'macos',
    'status': 'online',
    'protocol_version': 1,
    'availability': 'online',
    'presence_revision': revision,
    'last_heartbeat_unix_ms': 1700000000000,
  });
}

/// 构造具备完整同步资格（认证+前台+在线+surface）的控制器并完成首拍挂起管理。
/// 注意：attachSurface 会立即触发一次去重首拍（第 1 个请求）。
TerminalStatusController _eligibleController(
  _ControllableTerminalRelay relay, {
  Duration safetyInterval = const Duration(seconds: 45),
}) {
  final controller = TerminalStatusController(
    relay: relay,
    safetyInterval: () => safetyInterval,
  );
  controller.reportAuthBoundary(authenticated: true);
  controller.reportNetworkAvailability(MobileNetworkAvailability.online);
  controller.attachSurface();
  return controller;
}

/// 消化控制器内所有微任务（含 single-flight whenComplete 补拍链）。
void _drain(FakeAsync async) {
  async.flushMicrotasks();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('V091-08 生命周期自动刷新', () {
    test('资格满足时首拍同步；safety reconcile 按 45-60s 周期自动推进', () {
      fakeAsync((async) {
        final relay = _ControllableTerminalRelay()
          ..succeedNextWith([_onlineTerminal()]);
        final controller = _eligibleController(relay);
        _drain(async);
        expect(relay.requestCount, 1, reason: '资格满足必须立即首拍');
        expect(controller.phase, TerminalListPhase.ready);

        // 前台停留 91 秒（跨两个 45s 周期）：自动同步继续，无需用户交互。
        async.elapse(const Duration(seconds: 91));
        expect(
          relay.requestCount,
          greaterThanOrEqualTo(3),
          reason: 'safety reconcile 必须在前台周期性自动刷新',
        );
        // dispose 必须发生在 fakeAsync zone 内，保证 timer 被真实取消。
        controller.dispose();
      });
    });

    test('后台/离线/注销后零新请求；恢复只产生一个去重首拍', () {
      fakeAsync((async) {
        final relay = _ControllableTerminalRelay()
          ..succeedNextWith([_onlineTerminal()]);
        final controller = _eligibleController(relay);
        _drain(async);
        final afterFirstShot = relay.requestCount;
        expect(afterFirstShot, 1);

        // 切后台：5 分钟内零新请求。
        controller.reportAppVisibility(MobileAppVisibility.background);
        async.elapse(const Duration(minutes: 5));
        expect(relay.requestCount, afterFirstShot, reason: '后台必须零新请求');

        // 回前台：恰好一个去重首拍。
        controller.reportAppVisibility(MobileAppVisibility.foreground);
        _drain(async);
        expect(relay.requestCount, afterFirstShot + 1);
        async.elapse(const Duration(seconds: 5));
        expect(
          relay.requestCount,
          afterFirstShot + 1,
          reason: '恢复只触发一个首拍，不产生请求风暴',
        );

        // 网络离线：零新请求；恢复后一个去重首拍。
        controller.reportNetworkAvailability(MobileNetworkAvailability.offline);
        final beforeOffline = relay.requestCount;
        async.elapse(const Duration(minutes: 5));
        expect(relay.requestCount, beforeOffline);
        controller.reportNetworkAvailability(MobileNetworkAvailability.online);
        _drain(async);
        expect(relay.requestCount, beforeOffline + 1);

        // 注销：清空可信投影且零新请求。
        controller.reportAuthBoundary(authenticated: false);
        async.elapse(const Duration(minutes: 5));
        expect(relay.requestCount, beforeOffline + 1);
        expect(controller.terminals, isEmpty, reason: '注销必须清空旧账号终端投影');

        // dispose 后：任何边界推进都不再发请求（dispose 在 zone 内完成）。
        controller.dispose();
        final afterDispose = relay.requestCount;
        controller.reportAppVisibility(MobileAppVisibility.foreground);
        controller.reportAuthBoundary(authenticated: true);
        controller.attachSurface();
        controller.notifyPresenceInvalidation(terminalId: 'term-v091');
        async.elapse(const Duration(minutes: 5));
        expect(relay.requestCount, afterDispose, reason: 'dispose 后零新请求');
      });
    });
  });

  group('V091-09 single-flight 与代际隔离', () {
    test('多唤醒合并：在飞期间只有一次请求，落地后至多补一拍', () {
      fakeAsync((async) {
        final relay = _ControllableTerminalRelay()..holdNextRequest();
        final controller = _eligibleController(relay);
        _drain(async);
        expect(relay.requestCount, 1, reason: 'attach 首拍是第 1 个在飞请求');

        // 手动刷新、presence invalidation、前后台抖动同时唤醒：全部合并为 pending。
        controller.refresh();
        controller.notifyPresenceInvalidation(terminalId: 'term-v091');
        controller.reportAppVisibility(MobileAppVisibility.background);
        controller.reportAppVisibility(MobileAppVisibility.foreground);
        controller.attachSurface();
        _drain(async);
        expect(relay.requestCount, 1, reason: 'single-flight：同一时刻至多一个请求');

        relay.succeedNextWith([_onlineTerminal()]);
        relay.completeOldestInFlight([_onlineTerminal()]);
        _drain(async);
        _drain(async);
        expect(
          relay.requestCount,
          lessThanOrEqualTo(2),
          reason: '飞行中的多路唤醒合并为一次 pending 补拍',
        );
        expect(controller.phase, TerminalListPhase.ready);
        expect(controller.terminals, isNotEmpty);
        controller.dispose();
      });
    });

    test('注销/换账号后，在飞旧响应不写入状态、不 notify、不显示错误', () {
      fakeAsync((async) {
        final relay = _ControllableTerminalRelay()..holdNextRequest();
        final controller = _eligibleController(relay);
        _drain(async);
        final inflight = relay.inFlight.single;

        // 响应返回前注销（认证代际 +1）。
        controller.reportAuthBoundary(authenticated: false);
        _drain(async);
        inflight.complete([_onlineTerminal(id: 'term-old-account')]);
        _drain(async);
        expect(
          controller.terminals.where((t) => t.id == 'term-old-account'),
          isEmpty,
          reason: '旧代际响应不得写入新账号状态',
        );
        expect(controller.errorMessage, isNull, reason: '迟到旧响应不得显示错误');
        expect(controller.isUnreachable, isFalse);

        // 重新认证 + 首拍：新代际可以重新同步并写入。
        relay.succeedNextWith([_onlineTerminal(id: 'term-new-account')]);
        controller.reportAuthBoundary(authenticated: true);
        _drain(async);
        expect(controller.terminals.single.id, 'term-new-account');
        controller.dispose();
      });
    });

    test('页面重挂（surface 代际）后，旧页面在飞响应被丢弃', () {
      fakeAsync((async) {
        final relay = _ControllableTerminalRelay()..holdNextRequest();
        final controller = _eligibleController(relay);
        _drain(async);
        final stalePageRequest = relay.inFlight.single;

        // 旧页面卸载、新页面挂载：surface 代际 +1。
        controller.detachSurface();
        controller.attachSurface();
        _drain(async);
        stalePageRequest.complete([_onlineTerminal(id: 'term-stale-page')]);
        _drain(async);
        expect(
          controller.terminals.where((t) => t.id == 'term-stale-page'),
          isEmpty,
          reason: 'surface 代际不匹配的迟到响应不得污染新页面',
        );
        expect(controller.errorMessage, isNull);
        controller.dispose();
      });
    });
  });

  group('V091-10 失败保留可信投影', () {
    test('quiet refresh 失败不清空列表、不进入 error、不把失败写成 offline', () {
      fakeAsync((async) {
        final relay = _ControllableTerminalRelay()
          ..succeedNextWith([_onlineTerminal()]);
        final controller = _eligibleController(relay);
        _drain(async);
        expect(
          controller.terminals.single.availability,
          TerminalAvailability.online,
        );
        final trusted = controller.terminals;

        // 网络/Relay 不可达（unavailable 类）。
        relay.failNextRequest(const RelayFailure(
          RelayFailureKind.unavailable,
          '终端状态暂时不可用，请稍后重试。',
        ));
        controller.refresh();
        _drain(async);
        expect(controller.terminals, trusted, reason: '失败必须保留最后可信列表');
        expect(
          controller.phase,
          TerminalListPhase.ready,
          reason: 'quiet 失败不进入 error',
        );
        expect(controller.isUnreachable, isTrue, reason: 'unreachable 必须单独表达');
        expect(
          controller.availabilityFor(controller.terminals.single),
          isNot(TerminalAvailability.offline),
          reason: '网络失败不得改写成执行端 offline',
        );

        // 认证失效同样是 quiet 失败。
        relay.failNextRequest(
          const RelayFailure(RelayFailureKind.unauthorized, '认证已过期'),
        );
        controller.refresh();
        _drain(async);
        expect(controller.terminals, trusted);
        expect(controller.isUnreachable, isTrue);

        // 恢复：新快照自动翻正并清除 unreachable。
        relay.succeedNextWith([_onlineTerminal(revision: 2)]);
        controller.notifyPresenceInvalidation(terminalId: 'term-v091');
        _drain(async);
        _drain(async);
        expect(controller.terminals.single.presenceRevision, 2);
        expect(controller.isUnreachable, isFalse);
        expect(controller.phase, TerminalListPhase.ready);
        controller.dispose();
      });
    });

    test('首拍失败进入 error；unsupported/unknown 投影按 Relay 原样透传', () {
      fakeAsync((async) {
        final relay = _ControllableTerminalRelay()
          ..failNextRequest(
            const RelayFailure(RelayFailureKind.unavailable, 'Relay 不可达'),
          );
        final controller = _eligibleController(relay);
        _drain(async);
        expect(relay.requestCount, 1, reason: 'attach 的首拍消费注入的失败');
        expect(controller.phase, TerminalListPhase.error);
        expect(controller.errorMessage, contains('不可达'));
        expect(
          controller.isUnreachable,
          isFalse,
          reason: '没有任何可信数据时谈不上 unreachable',
        );

        // Relay 投影 unsupported / unknown 原样透传给 UI 层。
        final unsupported = TerminalSummary.fromRelayJson({
          'id': 'term-legacy',
          'hostname': 'old',
          'platform': 'macos',
          'status': 'online',
          'protocol_version': 2,
          'availability': 'unsupported',
        });
        final unknown = TerminalSummary.fromRelayJson({
          'id': 'term-dark',
          'hostname': 'dark',
          'platform': 'macos',
          'status': 'unknown',
          'availability': 'unknown',
        });
        expect(
          controller.availabilityFor(unsupported),
          TerminalAvailability.unsupported,
        );
        expect(
          controller.availabilityFor(unknown),
          TerminalAvailability.unknown,
        );
        controller.dispose();
      });
    });
  });

  test('availability 不受客户端墙钟影响：停留 90 秒以上仍是 Relay 投影', () {
    final terminal = _onlineTerminal();
    // v0.9.1 事故回归：旧实现用本机墙钟 - lastSeen(90s) 二次裁决导致误报离线；
    // 新实现 availability 只读 Relay 投影，本地时钟无论前进多少都不改变结果。
    final shiftedClock =
        DateTime.fromMillisecondsSinceEpoch(1700000000000 + 91 * 1000);
    expect(
      terminal.availability,
      TerminalAvailability.online,
      reason: '本地墙钟前进 91s 不得改变 Relay online 投影',
    );
    expect(shiftedClock.isAfter(terminal.lastHeartbeat!), isTrue);
    expect(
      terminal.availability,
      TerminalAvailability.online,
      reason: 'availability 是纯投影，与读取时刻无关',
    );
  });
}
