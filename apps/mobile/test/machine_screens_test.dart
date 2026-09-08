import 'package:agent_sessions_mobile/app/providers.dart';
import 'package:agent_sessions_mobile/domain/models.dart';
import 'package:agent_sessions_mobile/domain/terminal_models.dart';
import 'package:agent_sessions_mobile/relay/fixture_relay_repository.dart';
import 'package:agent_sessions_mobile/state/terminal_status_controller.dart';
import 'package:agent_sessions_mobile/ui/terminal_status_screens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 让微任务队列（single-flight whenComplete 补拍链）完全结算。
Future<void> _settle() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

void main() {
  final now = DateTime.utc(2026, 8, 16, 12);

  group('MOBILE-17 终端状态控制器', () {
    test('根据只读白名单状态区分 online、offline、stale 与 unsupported', () async {
      final relay = FixtureRelayRepository(clock: () => now);
      relay.replaceTerminals([
        TerminalSummary(
          id: 'term_online',
          hostname: 'Build Mac',
          platform: 'macos',
          status: TerminalConnectionStatus.online,
          protocolVersion: 1,
          daemonVersion: '0.4.0',
          lastSeen: now.subtract(const Duration(seconds: 20)),
        ),
        TerminalSummary(
          id: 'term_offline',
          hostname: 'Offline Linux',
          platform: 'linux',
          status: TerminalConnectionStatus.offline,
          protocolVersion: 1,
          lastSeen: now.subtract(const Duration(minutes: 5)),
        ),
        TerminalSummary(
          id: 'term_stale',
          hostname: 'Stale Mac',
          platform: 'macos',
          status: TerminalConnectionStatus.online,
          protocolVersion: 1,
          lastSeen: now.subtract(const Duration(minutes: 3)),
        ),
        TerminalSummary(
          id: 'term_unsupported',
          hostname: 'Future Daemon',
          platform: 'linux',
          status: TerminalConnectionStatus.online,
          protocolVersion: 2,
          lastSeen: now.subtract(const Duration(seconds: 10)),
        ),
      ]);
      // v0.9.1：控制器需先建立同步资格（认证+前台+在线+surface）才会发起同步。
      final controller = TerminalStatusController(
        relay: relay,
        clock: () => now,
      );
      controller.reportAuthBoundary(authenticated: true);
      controller.attachSurface();

      await controller.initialize();

      expect(controller.phase, TerminalListPhase.ready);
      expect(controller.terminals, hasLength(4));
      expect(
        controller.availabilityFor(controller.terminals[0]),
        TerminalAvailability.online,
      );
      expect(
        controller.availabilityFor(controller.terminals[1]),
        TerminalAvailability.offline,
      );
      // v0.9.1 事故回归：旧实现按本机墙钟 - lastSeen(90s) 把在线终端判成 stale；
      // 现在客户端不再做墙钟二次裁决，legacy DTO 按 status/protocol 派生为 online。
      expect(
        controller.availabilityFor(controller.terminals[2]),
        TerminalAvailability.online,
      );
      expect(
        controller.availabilityFor(controller.terminals[3]),
        TerminalAvailability.unsupported,
      );
    });

    test('新 Relay availability 投影原样透传（online/unknown/offline/unsupported）', () {
      final projected = TerminalSummary.fromRelayJson({
        'id': 'term_projected',
        'hostname': 'Projected Mac',
        'platform': 'macos',
        'status': 'online',
        'protocol_version': 1,
        'availability': 'unknown',
        'presence_revision': 7,
        'last_heartbeat_unix_ms': 1700000000000,
        'next_check_unix_ms': 1700000060000,
      });
      expect(projected.availability, TerminalAvailability.unknown);
      expect(projected.presenceRevision, 7);
      expect(projected.nextCheck, isNotNull);
    });

    test('Relay 不可达时保留最后一份状态，并在首屏给出可重试错误', () async {
      final relay = FixtureRelayRepository(clock: () => now);
      relay.replaceTerminals([
        TerminalSummary(
          id: 'term_retained',
          hostname: 'Retained Terminal',
          platform: 'macos',
          status: TerminalConnectionStatus.online,
          protocolVersion: 1,
          lastSeen: now,
        ),
      ]);
      final controller = TerminalStatusController(
        relay: relay,
        clock: () => now,
      );
      controller.reportAuthBoundary(authenticated: true);
      controller.attachSurface();

      await controller.initialize();
      relay.setNetworkAvailable(false);
      await controller.refresh();
      // v0.9.1 single-flight 补拍是异步尾随的：断言前让事件循环结算。
      await _settle();

      expect(controller.phase, TerminalListPhase.ready);
      expect(controller.terminals.single.hostname, 'Retained Terminal');
      expect(controller.errorMessage, contains('不可用'));

      final unavailableRelay = FixtureRelayRepository(clock: () => now)
        ..setNetworkAvailable(false);
      final firstLoad = TerminalStatusController(
        relay: unavailableRelay,
        clock: () => now,
      );
      firstLoad.reportAuthBoundary(authenticated: true);
      firstLoad.attachSurface();
      await firstLoad.initialize();
      // v0.9.1 single-flight 补拍是异步尾随的：断言前让事件循环结算。
      await _settle();

      expect(firstLoad.phase, TerminalListPhase.error);
      expect(firstLoad.terminals, isEmpty);
      expect(firstLoad.errorMessage, contains('不可用'));
    });

    test('未知 DTO 状态 fail-closed，错误的协议或状态字段被拒绝', () {
      final unknown = TerminalSummary.fromRelayJson({
        'id': 'term_unknown',
        'hostname': 'Unknown Terminal',
        'platform': 'unknown',
        'status': 'future_state',
      });
      expect(unknown.availability, TerminalAvailability.unknown);
      expect(
        () => TerminalSummary.fromRelayJson({
          'id': 'term_bad_protocol',
          'hostname': 'Bad',
          'platform': 'macos',
          'status': 'online',
          'protocol_version': -1,
        }),
        throwsA(
          isA<RelayFailure>().having(
            (failure) => failure.kind,
            'kind',
            RelayFailureKind.protocol,
          ),
        ),
      );
      expect(
        () => TerminalSummary.fromRelayJson({
          'id': 'term_fractional_protocol',
          'hostname': 'Bad',
          'platform': 'macos',
          'status': 'online',
          'protocol_version': 1.5,
        }),
        throwsA(
          isA<RelayFailure>().having(
            (failure) => failure.kind,
            'kind',
            RelayFailureKind.protocol,
          ),
        ),
      );
      expect(
        () => TerminalSummary.fromRelayJson({
          'id': 'term_bad_status',
          'hostname': 'Bad',
          'platform': 'macos',
          'status': 1,
        }),
        throwsA(
          isA<RelayFailure>().having(
            (failure) => failure.kind,
            'kind',
            RelayFailureKind.protocol,
          ),
        ),
      );
    });
  });

  group('MOBILE-17 终端状态 UI', () {
    testWidgets('显示白名单状态而不显示 opaque ID、路径、日志或重启写入口', (tester) async {
      final relay = FixtureRelayRepository(clock: () => now);
      relay.replaceTerminals([
        TerminalSummary(
          id: 'term_opaque_should_not_render',
          hostname: 'Build Mac',
          platform: 'macos',
          status: TerminalConnectionStatus.online,
          protocolVersion: 1,
          daemonVersion: '0.4.0',
          lastSeen: now.subtract(const Duration(seconds: 10)),
        ),
        TerminalSummary(
          id: 'term_stale_should_not_render',
          hostname: 'Stale Linux',
          platform: 'linux',
          status: TerminalConnectionStatus.online,
          protocolVersion: 1,
          lastSeen: now.subtract(const Duration(minutes: 4)),
        ),
        TerminalSummary(
          id: 'term_offline_should_not_render',
          hostname: 'Offline Linux',
          platform: 'linux',
          status: TerminalConnectionStatus.offline,
          protocolVersion: 1,
          lastSeen: now.subtract(const Duration(minutes: 4)),
        ),
        TerminalSummary(
          id: 'term_unsupported_should_not_render',
          hostname: 'Future Linux',
          platform: 'linux',
          status: TerminalConnectionStatus.online,
          protocolVersion: 2,
          lastSeen: now.subtract(const Duration(seconds: 10)),
        ),
        TerminalSummary(
          id: 'term_unknown_should_not_render',
          hostname: 'Unknown Linux',
          platform: 'linux',
          status: TerminalConnectionStatus.unknown,
          protocolVersion: 1,
        ),
      ]);
      final controller = TerminalStatusController(
        relay: relay,
        clock: () => now,
      );
      controller.reportAuthBoundary(authenticated: true);
      controller.attachSurface();
      await controller.initialize();

      await tester.pumpWidget(
        ProviderScope(
          key: UniqueKey(),
          overrides: [
            relayRepositoryProvider.overrideWithValue(relay),
            terminalStatusControllerProvider.overrideWith((_) => controller),
          ],
          child: const MaterialApp(home: TerminalStatusScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('terminal-status-list')), findsOneWidget);
      expect(find.byKey(const Key('terminal-status-tile-0')), findsOneWidget);
      expect(find.text('Build Mac'), findsOneWidget);
      // v0.9.1：客户端不再产出「状态过期」——Stale Linux（status=online、legacy
      // DTO）与 Build Mac 一样按 Relay 投影渲染为在线。
      expect(find.text('在线'), findsNWidgets(2));
      expect(find.text('离线'), findsOneWidget);
      expect(find.text('协议不支持'), findsOneWidget);
      expect(find.text('状态过期'), findsNothing);
      await tester.scrollUntilVisible(
        find.text('状态未确认'),
        160,
        scrollable: find.byType(Scrollable),
      );
      expect(find.text('状态未确认'), findsOneWidget);
      expect(find.text('term_opaque_should_not_render'), findsNothing);
      expect(find.textContaining('/'), findsNothing);
      expect(find.byTooltip('重启终端'), findsNothing);
      await tester.scrollUntilVisible(
        find.byKey(const Key('terminal-status-unavailable-note')),
        160,
        scrollable: find.byType(Scrollable),
      );
      expect(
        find.byKey(const Key('terminal-status-unavailable-note')),
        findsOneWidget,
      );
    });

    testWidgets('首次读取前显示 loading 状态', (tester) async {
      final relay = FixtureRelayRepository(clock: () => now);
      final controller = TerminalStatusController(
        relay: relay,
        clock: () => now,
      );

      await tester.pumpWidget(
        ProviderScope(
          key: UniqueKey(),
          overrides: [
            relayRepositoryProvider.overrideWithValue(relay),
            terminalStatusControllerProvider.overrideWith((_) => controller),
          ],
          child: const MaterialApp(home: TerminalStatusScreen()),
        ),
      );

      expect(find.byKey(const Key('terminal-status-loading')), findsOneWidget);
    });

    // v0.9.1 V091-12 控制器层回归：App 长时间挂机后进入终端状态页，页面挂载
    // （attachSurface）触发去重首拍重拉 Relay 权威投影；客户端不再做墙钟 stale
    // 判定，挂机期间快照中的在线终端也绝不会被误渲染为「状态过期」。
    // 本用例把 fixture 时钟前推 5 分钟并更新终端 lastSeen（模拟 daemon 持续
    // 心跳），断言进入页面后展示「在线」。
    testWidgets('长时间挂机后进入页面触发去重首拍，旧快照纠正为最新在线态', (tester) async {
      var current = now;
      final relay = FixtureRelayRepository(clock: () => current);
      relay.replaceTerminals([
        TerminalSummary(
          id: 'term_opaque_idle',
          hostname: 'Build Mac',
          platform: 'macos',
          status: TerminalConnectionStatus.online,
          protocolVersion: 1,
          daemonVersion: 'agent-sessions-daemon-p2',
          lastSeen: now.subtract(const Duration(seconds: 10)),
        ),
      ]);
      final controller = TerminalStatusController(
        relay: relay,
        clock: () => current,
      );
      controller.reportAuthBoundary(authenticated: true);
      controller.attachSurface();
      await controller.initialize();

      // App 挂机 5 分钟：fixture 时钟前推，daemon 心跳持续（lastSeen 同步前推），
      // 但 controller 尚未重新拉取——此刻其快照已落在 90s 窗口之外。
      current = now.add(const Duration(minutes: 5));
      relay.replaceTerminals([
        TerminalSummary(
          id: 'term_opaque_idle',
          hostname: 'Build Mac',
          platform: 'macos',
          status: TerminalConnectionStatus.online,
          protocolVersion: 1,
          daemonVersion: 'agent-sessions-daemon-p2',
          lastSeen: current.subtract(const Duration(seconds: 10)),
        ),
      ]);

      await tester.pumpWidget(
        ProviderScope(
          key: UniqueKey(),
          overrides: [
            relayRepositoryProvider.overrideWithValue(relay),
            terminalStatusControllerProvider.overrideWith((_) => controller),
          ],
          child: const MaterialApp(home: TerminalStatusScreen()),
        ),
      );
      // 进入页面触发 entry refresh：pumpAndSettle 等待重拉完成。
      await tester.pumpAndSettle();

      expect(find.text('在线'), findsOneWidget);
      expect(find.text('状态过期'), findsNothing);
    });

    testWidgets('empty 与 Relay 错误都展示明确状态', (tester) async {
      final emptyRelay = FixtureRelayRepository(clock: () => now);
      final emptyController = TerminalStatusController(
        relay: emptyRelay,
        clock: () => now,
      );
      emptyController.reportAuthBoundary(authenticated: true);
      emptyController.attachSurface();
      await emptyController.initialize();
      await tester.pumpWidget(
        ProviderScope(
          key: UniqueKey(),
          overrides: [
            relayRepositoryProvider.overrideWithValue(emptyRelay),
            terminalStatusControllerProvider.overrideWith(
              (_) => emptyController,
            ),
          ],
          child: const MaterialApp(home: TerminalStatusScreen()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('terminal-status-empty')), findsOneWidget);

      final unavailableRelay = FixtureRelayRepository(clock: () => now)
        ..setNetworkAvailable(false);
      final unavailableController = TerminalStatusController(
        relay: unavailableRelay,
        clock: () => now,
      );
      unavailableController.reportAuthBoundary(authenticated: true);
      unavailableController.attachSurface();
      await unavailableController.initialize();
      await tester.pumpWidget(
        ProviderScope(
          key: UniqueKey(),
          overrides: [
            relayRepositoryProvider.overrideWithValue(unavailableRelay),
            terminalStatusControllerProvider.overrideWith(
              (_) => unavailableController,
            ),
          ],
          child: const MaterialApp(home: TerminalStatusScreen()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('terminal-status-error')), findsOneWidget);
      expect(
        find.byKey(const Key('terminal-status-retry-button')),
        findsOneWidget,
      );
    });
  });
}
