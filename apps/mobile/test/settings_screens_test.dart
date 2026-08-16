import 'package:agent_sessions_mobile/app/providers.dart';
import 'package:agent_sessions_mobile/domain/models.dart';
import 'package:agent_sessions_mobile/domain/terminal_models.dart';
import 'package:agent_sessions_mobile/relay/fixture_relay_repository.dart';
import 'package:agent_sessions_mobile/state/settings_controller.dart';
import 'package:agent_sessions_mobile/storage/secure_token_store.dart';
import 'package:agent_sessions_mobile/storage/theme_preference_store.dart';
import 'package:agent_sessions_mobile/ui/settings_screens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

void main() {
  final now = DateTime.utc(2026, 8, 16, 12);

  group('MOBILE-16 设置中心 UI', () {
    testWidgets('索引页显示五个分区入口，点击进入对应分区', (tester) async {
      final relay = FixtureRelayRepository(clock: () => now);
      final tokens = await _seedOwner(relay);
      relay.replaceTerminals([
        _terminal(id: 'term_a', hostname: 'Build Mac', lastSeen: now),
        _terminal(
          id: 'term_b',
          hostname: 'Work Linux',
          lastSeen: now.subtract(const Duration(seconds: 20)),
        ),
      ]);
      final controller = SettingsController(relay: relay, clock: () => now);
      await controller.initialize();

      await tester.pumpWidget(
        _buildSettingsApp(relay: relay, controller: controller, tokens: tokens),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('settings-screen')), findsOneWidget);
      expect(find.byKey(const Key('settings-section-list')), findsOneWidget);
      for (final tileKey in [
        'settings-account-tile',
        'settings-appearance-tile',
        'settings-agents-tile',
        'settings-usage-tile',
        'settings-connect-tile',
      ]) {
        expect(find.byKey(Key(tileKey)), findsOneWidget);
      }
      // 分区副标题来自只读白名单状态
      expect(find.text('已确认 owner 设备'), findsOneWidget);
      expect(find.text('4/4 个 Provider 可用'), findsOneWidget);
      expect(find.text('暂无可用的用量统计'), findsOneWidget);
      expect(find.text('2 台终端'), findsOneWidget);

      // 账户分区
      await tester.tap(find.byKey(const Key('settings-account-tile')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('settings-account-screen')), findsOneWidget);
      await tester.tap(find.byTooltip('返回设置'));
      await tester.pumpAndSettle();

      // 外观分区
      await tester.tap(find.byKey(const Key('settings-appearance-tile')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('settings-appearance-screen')), findsOneWidget);
      await tester.tap(find.byTooltip('返回设置'));
      await tester.pumpAndSettle();

      // Agent 能力分区
      await tester.tap(find.byKey(const Key('settings-agents-tile')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('settings-agents-screen')), findsOneWidget);
      await tester.tap(find.byTooltip('返回设置'));
      await tester.pumpAndSettle();

      // 用量分区
      await tester.tap(find.byKey(const Key('settings-usage-tile')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('settings-usage-screen')), findsOneWidget);
      await tester.tap(find.byTooltip('返回设置'));
      await tester.pumpAndSettle();

      // 连接分区
      await tester.tap(find.byKey(const Key('settings-connect-tile')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('settings-connect-screen')), findsOneWidget);
    });

    testWidgets('账户分区显示 owner 设备，不暴露 token/恢复码明文与写入口', (tester) async {
      final relay = FixtureRelayRepository(clock: () => now);
      final tokens = await _seedOwner(relay);
      final controller = SettingsController(relay: relay, clock: () => now);
      await controller.initialize();

      await tester.pumpWidget(
        _buildSettingsApp(
          relay: relay,
          controller: controller,
          tokens: tokens,
          initialLocation: '/settings/account',
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('settings-account-screen')), findsOneWidget);
      // owner 设备只读展示
      expect(
        find.byKey(const Key('settings-account-device-android-owner-fixture')),
        findsOneWidget,
      );
      expect(find.text('Android Owner'), findsOneWidget);
      expect(find.text('owner 设备'), findsOneWidget);
      // 不显示 token/恢复码明文，也没有写入口
      expect(find.textContaining('fixture-access-token'), findsNothing);
      expect(find.textContaining('fixture-refresh-token'), findsNothing);
      expect(find.textContaining('RECOVERY-FIXTURE'), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(find.text('撤销'), findsNothing);
      // 页面明确声明边界
      expect(find.byKey(const Key('settings-account-note')), findsOneWidget);
    });

    testWidgets('外观分区切换主题模式与强调色并持久化本机偏好', (tester) async {
      final relay = FixtureRelayRepository(clock: () => now);
      final controller = SettingsController(relay: relay, clock: () => now);
      await controller.initialize();
      final appearance = InMemoryThemePreferenceStore();

      await tester.pumpWidget(
        _buildSettingsApp(
          relay: relay,
          controller: controller,
          appearance: appearance,
          initialLocation: '/settings/appearance',
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('settings-appearance-screen')), findsOneWidget);
      expect(find.byKey(const Key('settings-appearance-mode')), findsOneWidget);
      expect(
        find.byKey(const Key('settings-appearance-accent-ocean')),
        findsOneWidget,
      );

      // 默认跟随系统 + 海蓝
      expect(await appearance.read(), ThemePreferences.defaults);

      // 切换主题模式为浅色
      await tester.tap(find.text('浅色'));
      await tester.pumpAndSettle();
      // 切换强调色为薄荷
      await tester.tap(find.byKey(const Key('settings-appearance-accent-mint')));
      await tester.pumpAndSettle();

      expect(
        await appearance.read(),
        const ThemePreferences(
          mode: ThemePreferenceMode.light,
          accent: AppAccent.mint,
        ),
      );
      // 只读提示仍在
      expect(find.byKey(const Key('settings-appearance-note')), findsOneWidget);
    });

    testWidgets('Agent 能力分区展示 Provider 列表与三态能力 chip', (tester) async {
      final relay = FixtureRelayRepository(clock: () => now);
      final controller = SettingsController(relay: relay, clock: () => now);
      await controller.initialize();

      await tester.pumpWidget(
        _buildSettingsApp(
          relay: relay,
          controller: controller,
          initialLocation: '/settings/agents',
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('settings-agents-screen')), findsOneWidget);
      expect(
        find.byKey(const Key('settings-agents-provider-codex')),
        findsOneWidget,
      );
      // codex：start 原生、delegate_cross_provider 兼容（三态 chip）
      final nativeChip = _chipInside(tester, 'codex', 'start');
      final emulatedChip = _chipInside(tester, 'codex', 'delegate_cross_provider');
      expect(nativeChip.backgroundColor, isNotNull);
      expect(emulatedChip.backgroundColor, isNotNull);
      expect(nativeChip.backgroundColor, isNot(emulatedChip.backgroundColor));

      // 其余 Provider 卡片
      await tester.scrollUntilVisible(
        find.byKey(const Key('settings-agents-provider-opencode')),
        240,
        scrollable: find.byType(Scrollable),
      );
      // opencode 未声明能力：unsupported chip 无背景色
      final unsupportedChip = _chipInside(tester, 'opencode', 'start');
      expect(unsupportedChip.backgroundColor, isNull);
      expect(
        find.descendant(
          of: find.byKey(const Key('settings-agents-provider-opencode')),
          matching: find.text('可用'),
        ),
        findsOneWidget,
      );
      await tester.scrollUntilVisible(
        find.byKey(const Key('settings-agents-provider-openclaw')),
        240,
        scrollable: find.byType(Scrollable),
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('settings-agents-provider-openclaw')),
          matching: find.text('可用'),
        ),
        findsOneWidget,
      );
      await tester.scrollUntilVisible(
        find.byKey(const Key('settings-agents-note')),
        240,
        scrollable: find.byType(Scrollable),
      );
      expect(find.byKey(const Key('settings-agents-note')), findsOneWidget);

      // 探测失败降级：Provider 全部显示不可用
      relay.providersUnavailable = true;
      final degraded = SettingsController(relay: relay, clock: () => now);
      await degraded.initialize();
      await tester.pumpWidget(
        _buildSettingsApp(
          relay: relay,
          controller: degraded,
          initialLocation: '/settings/agents',
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const Key('settings-agents-provider-codex')),
          matching: find.text('不可用'),
        ),
        findsOneWidget,
      );
      expect(find.text('可用'), findsNothing);
    });

    testWidgets('用量分区显示暂不可用降级，不伪造统计数字', (tester) async {
      final relay = FixtureRelayRepository(clock: () => now);
      final controller = SettingsController(relay: relay, clock: () => now);
      await controller.initialize();

      await tester.pumpWidget(
        _buildSettingsApp(
          relay: relay,
          controller: controller,
          initialLocation: '/settings/usage',
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('settings-usage-screen')), findsOneWidget);
      expect(find.byKey(const Key('settings-usage-unavailable')), findsOneWidget);
      expect(find.textContaining('用量统计暂不可用'), findsOneWidget);
      expect(find.textContaining('ADR-010'), findsOneWidget);
      // 不出现估算或伪造统计
      expect(find.textContaining('今日与 7 天用量'), findsNothing);
      expect(find.textContaining('tokens'), findsNothing);
      expect(find.textContaining('↑'), findsNothing);
      expect(find.byType(TextField), findsNothing);
    });

    testWidgets('连接分区显示终端列表与配对入口，无重启/工作区写入口', (tester) async {
      final relay = FixtureRelayRepository(clock: () => now);
      relay.replaceTerminals([
        _terminal(
          id: 'term_a',
          hostname: 'Build Mac',
          lastSeen: now.subtract(const Duration(seconds: 10)),
        ),
        _terminal(
          id: 'term_b',
          hostname: 'Work Linux',
          lastSeen: now.subtract(const Duration(seconds: 30)),
        ),
      ]);
      final controller = SettingsController(relay: relay, clock: () => now);
      await controller.initialize();

      await tester.pumpWidget(
        _buildSettingsApp(
          relay: relay,
          controller: controller,
          initialLocation: '/settings/connect',
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('settings-connect-screen')), findsOneWidget);
      expect(
        find.byKey(const Key('settings-connect-terminal-0')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('settings-connect-terminal-1')),
        findsOneWidget,
      );
      expect(find.text('Build Mac'), findsOneWidget);
      expect(find.text('Work Linux'), findsOneWidget);
      expect(find.text('macos · Daemon 0.4.0'), findsNWidgets(2));
      // 不展示 opaque 终端 id
      expect(find.text('term_a'), findsNothing);
      expect(find.text('term_b'), findsNothing);
      // 配对入口存在，且无重启/工作区写入口
      expect(
        find.byKey(const Key('settings-connect-pairing-button')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('settings-connect-note')), findsOneWidget);
      expect(find.byTooltip('重启终端'), findsNothing);
      expect(find.text('重启'), findsNothing);
      expect(find.text('工作区'), findsNothing);
      expect(find.byType(TextField), findsNothing);

      // 配对入口跳转到配对页
      await tester.tap(find.byKey(const Key('settings-connect-pairing-button')));
      await tester.pumpAndSettle();
      expect(find.text('pairing-placeholder'), findsOneWidget);
    });

    testWidgets('连接分区无终端时显示空提示', (tester) async {
      final relay = FixtureRelayRepository(clock: () => now);
      final controller = SettingsController(relay: relay, clock: () => now);
      await controller.initialize();

      await tester.pumpWidget(
        _buildSettingsApp(
          relay: relay,
          controller: controller,
          initialLocation: '/settings/connect',
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('settings-connect-empty')), findsOneWidget);
      expect(find.text('尚无已确认的终端。'), findsOneWidget);
      expect(
        find.byKey(const Key('settings-connect-pairing-button')),
        findsOneWidget,
      );
    });

    testWidgets('loading/error 状态与重试按钮', (tester) async {
      final relay = FixtureRelayRepository(clock: () => now);
      final controller = SettingsController(relay: relay, clock: () => now);

      // 未读取完成前显示 loading
      await tester.pumpWidget(
        _buildSettingsApp(relay: relay, controller: controller),
      );
      expect(find.byKey(const Key('settings-loading')), findsOneWidget);

      // 首屏失败显示 error 与重试按钮
      final unavailableRelay = FixtureRelayRepository(clock: () => now)
        ..setNetworkAvailable(false);
      final unavailableController = SettingsController(
        relay: unavailableRelay,
        clock: () => now,
      );
      await unavailableController.initialize();
      await tester.pumpWidget(
        _buildSettingsApp(
          relay: unavailableRelay,
          controller: unavailableController,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('settings-error')), findsOneWidget);
      expect(find.textContaining('不可用'), findsOneWidget);
      expect(find.byKey(const Key('settings-retry-button')), findsOneWidget);

      // 恢复网络后重试进入 ready
      unavailableRelay.setNetworkAvailable(true);
      await tester.tap(find.byKey(const Key('settings-retry-button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('settings-section-list')), findsOneWidget);
      expect(find.byKey(const Key('settings-error')), findsNothing);
    });
  });
}

/// 设置中心 widget 测试专用 harness：真实路由 + fixture overrides，不连接真实 Relay。
Widget _buildSettingsApp({
  required FixtureRelayRepository relay,
  required SettingsController controller,
  InMemorySecureTokenStore? tokens,
  InMemoryThemePreferenceStore? appearance,
  String initialLocation = '/settings',
}) {
  final router = GoRouter(
    initialLocation: initialLocation,
    routes: [
      GoRoute(path: '/settings', builder: (context, state) => const SettingsScreen()),
      GoRoute(
        path: '/settings/account',
        builder: (context, state) => const SettingsAccountScreen(),
      ),
      GoRoute(
        path: '/settings/appearance',
        builder: (context, state) => const SettingsAppearanceScreen(),
      ),
      GoRoute(
        path: '/settings/agents',
        builder: (context, state) => const SettingsAgentsScreen(),
      ),
      GoRoute(
        path: '/settings/usage',
        builder: (context, state) => const SettingsUsageScreen(),
      ),
      GoRoute(
        path: '/settings/connect',
        builder: (context, state) => const SettingsConnectScreen(),
      ),
      GoRoute(
        path: '/home',
        builder: (context, state) => const _PlaceholderScreen(label: 'home'),
      ),
      GoRoute(
        path: '/pairing',
        builder: (context, state) => const _PlaceholderScreen(label: 'pairing'),
      ),
    ],
  );
  return ProviderScope(
    key: UniqueKey(),
    overrides: [
      relayRepositoryProvider.overrideWithValue(relay),
      settingsControllerProvider.overrideWith((_) => controller),
      if (tokens != null) secureTokenStoreProvider.overrideWithValue(tokens),
      if (appearance != null)
        themePreferenceStoreProvider.overrideWithValue(appearance),
    ],
    child: MaterialApp.router(routerConfig: router),
  );
}

/// 路由跳转目标的占位页，只验证导航是否发生，不依赖真实业务页面。
class _PlaceholderScreen extends StatelessWidget {
  const _PlaceholderScreen({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(child: Text('$label-placeholder')),
  );
}

/// 在指定 Provider 卡片内按能力名找到对应 chip。
Chip _chipInside(WidgetTester tester, String providerKey, String capability) {
  final finder = find.ancestor(
    of: find.descendant(
      of: find.byKey(Key('settings-agents-provider-$providerKey')),
      matching: find.text(capability),
    ),
    matching: find.byType(Chip),
  );
  return tester.widget<Chip>(finder);
}

/// 通过 fixture 注册 owner 并把 token 写入内存存储，供 AppController 恢复认证设备列表。
Future<InMemorySecureTokenStore> _seedOwner(FixtureRelayRepository relay) async {
  final tokens = await relay.register(
    const LoginCredentials(
      email: 'settings-owner@fixture.test',
      password: 'fixture-password',
    ),
  );
  final store = InMemorySecureTokenStore();
  await store.write(tokens);
  return store;
}

TerminalSummary _terminal({
  required String id,
  required String hostname,
  DateTime? lastSeen,
}) => TerminalSummary(
  id: id,
  hostname: hostname,
  platform: 'macos',
  status: TerminalConnectionStatus.online,
  protocolVersion: 1,
  daemonVersion: '0.4.0',
  lastSeen: lastSeen,
);
