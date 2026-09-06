import 'package:agent_sessions_mobile/app/providers.dart';
import 'package:agent_sessions_mobile/domain/models.dart';
import 'package:agent_sessions_mobile/domain/terminal_models.dart';
import 'package:agent_sessions_mobile/relay/fixture_relay_repository.dart';
import 'package:agent_sessions_mobile/state/terminal_status_controller.dart';
import 'package:agent_sessions_mobile/ui/terminal_status_screens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

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
      final controller = TerminalStatusController(
        relay: relay,
        clock: () => now,
      );

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
      expect(
        controller.availabilityFor(controller.terminals[2]),
        TerminalAvailability.stale,
      );
      expect(
        controller.availabilityFor(controller.terminals[3]),
        TerminalAvailability.unsupported,
      );
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

      await controller.initialize();
      relay.setNetworkAvailable(false);
      await controller.refresh();

      expect(controller.phase, TerminalListPhase.ready);
      expect(controller.terminals.single.hostname, 'Retained Terminal');
      expect(controller.errorMessage, contains('不可用'));

      final unavailableRelay = FixtureRelayRepository(clock: () => now)
        ..setNetworkAvailable(false);
      final firstLoad = TerminalStatusController(
        relay: unavailableRelay,
        clock: () => now,
      );
      await firstLoad.initialize();

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
      expect(unknown.availabilityAt(now), TerminalAvailability.unknown);
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
      expect(find.text('在线'), findsOneWidget);
      expect(find.text('离线'), findsOneWidget);
      expect(find.text('状态过期'), findsOneWidget);
      expect(find.text('协议不支持'), findsOneWidget);
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

    // 遗留 2026-09-02 #3 收口回归（2026-09-06 用户实测）：App 长时间挂机后进入
    // 终端状态页，此前只渲染启动时拉取的旧快照——lastSeen 落到 90s 新鲜度窗口外，
    // 实际在线的终端被误渲染为「状态过期」（daemon 每 15s 心跳一直正常）。
    // 修复=页面进入后下一帧 refresh() 重拉。本用例把 fixture 时钟前推 5 分钟并
    // 更新终端 lastSeen（模拟 daemon 持续心跳），断言进入页面后展示「在线」。
    testWidgets('长时间挂机后进入页面触发刷新，旧快照的「状态过期」纠正为「在线」', (tester) async {
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
