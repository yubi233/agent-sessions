import 'package:agent_sessions_mobile/app/providers.dart';
import 'package:agent_sessions_mobile/domain/usage_models.dart';
import 'package:agent_sessions_mobile/relay/fixture_relay_repository.dart';
import 'package:agent_sessions_mobile/state/usage_controller.dart';
import 'package:agent_sessions_mobile/ui/usage_screens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// MOBILE-20：用量统计页只读 UI。
/// 直接 pump UsageScreen 并 override relay/usageControllerProvider，
/// 断言稳定 Key、窗口切换、无数据降级、error 重试，以及页面无写入口、
/// 无 prompt/费用/精确时间文本。
void main() {
  final now = DateTime.utc(2026, 8, 16, 12);

  Future<void> usePhoneSurface(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(480, 960));
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }

  UsageSummary dataSummary() => UsageSummary(
    days: 30,
    utcToday: '2026-08-16',
    providers: const [
      UsageDayAggregate(
        provider: 'codex',
        utcDay: '2026-08-16',
        inputTokens: 1200,
        outputTokens: 800,
        cacheReadTokens: 0,
        cacheWriteTokens: 0,
      ),
      UsageDayAggregate(
        provider: 'claude',
        utcDay: '2026-08-15',
        inputTokens: 4000,
        outputTokens: 2000,
        cacheReadTokens: 0,
        cacheWriteTokens: 0,
      ),
    ],
  );

  /// 预初始化 controller 并构建 ProviderScope harness。
  Widget buildUsageApp({
    required FixtureRelayRepository relay,
    required UsageController controller,
  }) => ProviderScope(
    key: UniqueKey(),
    overrides: [
      relayRepositoryProvider.overrideWithValue(relay),
      usageControllerProvider.overrideWith((_) => controller),
    ],
    child: const MaterialApp(home: UsageScreen()),
  );

  group('MOBILE-20 用量 UI', () {
    testWidgets('预置数据后显示 total card、provider chart 与窗口选择器', (tester) async {
      await usePhoneSurface(tester);
      final relay = FixtureRelayRepository(clock: () => now);
      relay.replaceUsageSummary(dataSummary());
      final controller = UsageController(relay: relay);
      await controller.initialize();

      await tester.pumpWidget(
        buildUsageApp(relay: relay, controller: controller),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('usage-screen')), findsOneWidget);
      expect(find.byKey(const Key('usage-back-button')), findsOneWidget);
      expect(find.byKey(const Key('usage-refresh-button')), findsOneWidget);
      expect(find.byKey(const Key('usage-window-selector')), findsOneWidget);
      expect(find.byKey(const Key('usage-total-card')), findsOneWidget);
      expect(find.byKey(const Key('usage-provider-chart')), findsOneWidget);
      expect(find.byKey(const Key('usage-bar-codex')), findsOneWidget);
      expect(find.byKey(const Key('usage-bar-claude')), findsOneWidget);
      expect(find.byKey(const Key('usage-utc-note')), findsOneWidget);

      // 白名单整数计数以 k/M 缩写展示，不渲染 prompt/费用/精确时间。
      expect(find.text('5.2k'), findsOneWidget);
      expect(find.text('2.8k'), findsOneWidget);
      expect(find.text('2.0k'), findsOneWidget);
      expect(find.text('6.0k'), findsOneWidget);
      expect(find.byKey(const Key('usage-no-data')), findsNothing);
    });

    testWidgets('切换 7 天/30 天按钮刷新窗口', (tester) async {
      await usePhoneSurface(tester);
      final relay = FixtureRelayRepository(clock: () => now);
      relay.replaceUsageSummary(dataSummary());
      final controller = UsageController(relay: relay);
      await controller.initialize();

      await tester.pumpWidget(
        buildUsageApp(relay: relay, controller: controller),
      );
      await tester.pumpAndSettle();

      // 初始为 30 天窗口（'窗口输入' 标签）。
      expect(controller.days, 30);
      expect(find.text('窗口输入'), findsOneWidget);

      await tester.tap(find.text('7 天'));
      await tester.pumpAndSettle();
      expect(controller.days, 7);

      await tester.tap(find.text('30 天'));
      await tester.pumpAndSettle();
      expect(controller.days, 30);

      // 今日窗口切换到'今日输入'标签。
      await tester.tap(find.text('今日'));
      await tester.pumpAndSettle();
      expect(controller.days, 1);
      expect(find.text('今日输入'), findsOneWidget);
    });

    testWidgets('无数据时显示 usage-no-data 且无图表', (tester) async {
      await usePhoneSurface(tester);
      final relay = FixtureRelayRepository(clock: () => now);
      final controller = UsageController(relay: relay);
      await controller.initialize();
      expect(controller.phase, UsagePhase.unavailable);

      await tester.pumpWidget(
        buildUsageApp(relay: relay, controller: controller),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('usage-no-data')), findsOneWidget);
      expect(find.textContaining('无可用统计'), findsOneWidget);
      expect(find.byKey(const Key('usage-total-card')), findsNothing);
      expect(find.byKey(const Key('usage-provider-chart')), findsNothing);
      expect(find.byKey(const Key('usage-bar-codex')), findsNothing);
      expect(find.byKey(const Key('usage-utc-note')), findsNothing);
      // 窗口选择器仍然可用，便于无数据时切换窗口重试。
      expect(find.byKey(const Key('usage-window-selector')), findsOneWidget);
    });

    testWidgets('Relay 不可用时显示 error 与重试按钮，恢复网络重试成功', (tester) async {
      await usePhoneSurface(tester);
      final relay = FixtureRelayRepository(clock: () => now)
        ..setNetworkAvailable(false);
      final controller = UsageController(relay: relay);
      await controller.initialize();
      expect(controller.phase, UsagePhase.error);

      await tester.pumpWidget(
        buildUsageApp(relay: relay, controller: controller),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('usage-error')), findsOneWidget);
      expect(find.textContaining('不可用'), findsOneWidget);
      expect(find.byKey(const Key('usage-retry-button')), findsOneWidget);
      expect(find.byKey(const Key('usage-list')), findsNothing);

      // 恢复网络并预置数据后重试进入 ready。
      relay.setNetworkAvailable(true);
      relay.replaceUsageSummary(dataSummary());
      await tester.tap(find.byKey(const Key('usage-retry-button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('usage-error')), findsNothing);
      expect(find.byKey(const Key('usage-total-card')), findsOneWidget);
      expect(find.byKey(const Key('usage-provider-chart')), findsOneWidget);
    });

    testWidgets('页面无写入口、无 prompt/费用/精确时间文本', (tester) async {
      await usePhoneSurface(tester);
      final relay = FixtureRelayRepository(clock: () => now);
      relay.replaceUsageSummary(dataSummary());
      final controller = UsageController(relay: relay);
      await controller.initialize();

      await tester.pumpWidget(
        buildUsageApp(relay: relay, controller: controller),
      );
      await tester.pumpAndSettle();

      // 只读页面：无输入框、无发送/终止按钮、无 FAB。
      expect(find.byType(TextField), findsNothing);
      expect(find.byKey(const Key('session-composer')), findsNothing);
      expect(find.byType(FloatingActionButton), findsNothing);
      expect(find.byTooltip('发送'), findsNothing);
      expect(find.text('终止'), findsNothing);
      expect(find.text('恢复'), findsNothing);

      // ADR-010：不显示 prompt/费用/精确时间文本。
      expect(find.textContaining('prompt'), findsNothing);
      expect(find.textContaining('Prompt'), findsNothing);
      expect(find.textContaining('费用'), findsNothing);
      expect(find.textContaining('成本'), findsNothing);
      expect(find.textContaining('时间'), findsNothing);
      // 无 opaque 会话/设备 id 或 Provider 之外正文。
      expect(find.textContaining('session-fixture'), findsNothing);
    });

    testWidgets('首次读取前显示 usage-loading', (tester) async {
      await usePhoneSurface(tester);
      final relay = FixtureRelayRepository(clock: () => now);
      // 不提前 initialize：由屏幕 initState 的 postFrameCallback 发起首次读取。
      final controller = UsageController(relay: relay);

      await tester.pumpWidget(
        buildUsageApp(relay: relay, controller: controller),
      );

      expect(find.byKey(const Key('usage-loading')), findsOneWidget);

      await tester.pumpAndSettle();
      expect(find.byKey(const Key('usage-loading')), findsNothing);
      expect(find.byKey(const Key('usage-no-data')), findsOneWidget);
    });
  });
}
