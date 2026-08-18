import 'package:agent_sessions_mobile/app/providers.dart';
import 'package:agent_sessions_mobile/domain/session_models.dart';
import 'package:agent_sessions_mobile/relay/fixture_relay_repository.dart';
import 'package:agent_sessions_mobile/state/command_palette_controller.dart';
import 'package:agent_sessions_mobile/state/session_controller.dart';
import 'package:agent_sessions_mobile/ui/command_palette_screens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'support/fixture_owner.dart';

/// MOBILE-22：命令面板只读索引 UI。
/// 直接 pump CommandPaletteScreen 并 override sessionControllerProvider 与
/// commandPaletteControllerProvider，用带 router 的 harness 验证列表渲染、
/// 关键字过滤、空态与 blocked 门控展示；不依赖认证守卫。
void main() {
  final now = DateTime.utc(2026, 8, 16, 12);
  const ownerDeviceId = 'android-owner-fixture';

  /// 注册 owner 并创建两个会话（codex / claude）。
  Future<FixtureRelayRepository> fixtureWithSessions() async {
    final relay = FixtureRelayRepository(clock: () => now);
    await bootstrapFixtureOwner(relay);
    await relay.createSession(
      CreateMobileSessionInput(
        workspaceId: 'workspace-a',
        provider: 'codex',
        deviceId: ownerDeviceId,
      ),
    );
    await relay.createSession(
      CreateMobileSessionInput(
        workspaceId: 'workspace-b',
        provider: 'claude',
        deviceId: ownerDeviceId,
      ),
    );
    return relay;
  }

  Future<void> usePhoneSurface(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(480, 960));
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }

  /// 面板测试 harness：真实路由 + fixture overrides，不连接真实 Relay。
  Widget buildPaletteApp({
    required FixtureRelayRepository relay,
    required SessionController sessions,
    required CommandPaletteController palette,
  }) {
    final router = GoRouter(
      initialLocation: '/command-palette',
      routes: [
        GoRoute(
          path: '/command-palette',
          builder: (context, state) => const CommandPaletteScreen(),
        ),
        GoRoute(
          path: '/settings',
          builder: (context, state) =>
              const _PlaceholderScreen(label: 'settings'),
        ),
        GoRoute(
          path: '/sessions/recent',
          builder: (context, state) =>
              const _PlaceholderScreen(label: 'sessions-recent'),
        ),
        GoRoute(
          path: '/sessions/:id',
          builder: (context, state) => _PlaceholderScreen(
            label: 'sessions-${state.pathParameters['id']}',
          ),
        ),
      ],
    );
    return ProviderScope(
      key: UniqueKey(),
      overrides: [
        relayRepositoryProvider.overrideWithValue(relay),
        sessionControllerProvider.overrideWith((_) => sessions),
        commandPaletteControllerProvider.overrideWith((_) => palette),
      ],
      child: MaterialApp.router(routerConfig: router),
    );
  }

  group('MOBILE-22 命令面板 UI', () {
    testWidgets('打开显示输入框与结果列表，输入后过滤生效', (tester) async {
      await usePhoneSurface(tester);
      final relay = await fixtureWithSessions();
      final sessions = SessionController(relay: relay, clock: () => now);
      await sessions.initialize();
      final palette = CommandPaletteController(sessionController: sessions);

      await tester.pumpWidget(
        buildPaletteApp(relay: relay, sessions: sessions, palette: palette),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('command-palette-screen')), findsOneWidget);
      expect(
        find.byKey(const Key('command-palette-back-button')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('command-palette-input')), findsOneWidget);
      // 未输入时索引为空，展示引导空态。
      expect(find.byKey(const Key('command-palette-empty')), findsOneWidget);
      expect(find.text('输入关键字开始搜索'), findsOneWidget);

      // 输入'设置'过滤出导航命令。
      await tester.enterText(
        find.byKey(const Key('command-palette-input')),
        '设置',
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('command-palette-results')), findsOneWidget);
      expect(find.byKey(const Key('command-palette-empty')), findsNothing);
      expect(find.byKey(const Key('command-palette-result-0')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('command-palette-results')),
          matching: find.text('设置'),
        ),
        findsOneWidget,
      );
      expect(find.text('/settings'), findsOneWidget);
    });

    testWidgets('输入关键字过滤会话索引', (tester) async {
      await usePhoneSurface(tester);
      final relay = await fixtureWithSessions();
      final sessions = SessionController(relay: relay, clock: () => now);
      await sessions.initialize();
      final palette = CommandPaletteController(sessionController: sessions);

      await tester.pumpWidget(
        buildPaletteApp(relay: relay, sessions: sessions, palette: palette),
      );
      await tester.pumpAndSettle();

      // 'codex' 命中 codex 会话的副标题。
      await tester.enterText(
        find.byKey(const Key('command-palette-input')),
        'codex',
      );
      await tester.pumpAndSettle();

      expect(find.text('codex · 空闲'), findsOneWidget);
      expect(find.text('新的会话 1'), findsOneWidget);
      expect(find.text('新的会话 2'), findsNothing);

      // 清空查询显示全部登记命令（6 导航 + 4 控制 + 2 会话）。
      await tester.enterText(
        find.byKey(const Key('command-palette-input')),
        '',
      );
      await tester.pumpAndSettle();
      expect(find.byType(ListTile), findsNWidgets(12));
    });

    testWidgets('无匹配时显示 command-palette-empty', (tester) async {
      await usePhoneSurface(tester);
      final relay = await fixtureWithSessions();
      final sessions = SessionController(relay: relay, clock: () => now);
      await sessions.initialize();
      final palette = CommandPaletteController(sessionController: sessions);

      await tester.pumpWidget(
        buildPaletteApp(relay: relay, sessions: sessions, palette: palette),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('command-palette-input')),
        '不存在的关键字',
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('command-palette-empty')), findsOneWidget);
      expect(find.text('没有匹配的命令'), findsOneWidget);
      expect(find.byKey(const Key('command-palette-results')), findsNothing);
    });

    testWidgets('blocked 项 disabled 且有原因文本，点击不执行', (tester) async {
      await usePhoneSurface(tester);
      final relay = await fixtureWithSessions();
      final sessions = SessionController(relay: relay, clock: () => now);
      await sessions.initialize();
      final palette = CommandPaletteController(sessionController: sessions);

      await tester.pumpWidget(
        buildPaletteApp(relay: relay, sessions: sessions, palette: palette),
      );
      await tester.pumpAndSettle();

      // 无选中会话时 resume 处于 blocked，并展示原因。
      await tester.enterText(
        find.byKey(const Key('command-palette-input')),
        '恢复',
      );
      await tester.pumpAndSettle();

      final tile = tester.widget<ListTile>(
        find.byKey(const Key('command-palette-result-0')),
      );
      expect(tile.enabled, isFalse);
      expect((tile.subtitle as Text?)?.data, '当前没有选中会话。');

      // 点击 disabled 项不会导航、不会崩溃。
      await tester.tap(
        find.byKey(const Key('command-palette-result-0')),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('command-palette-screen')), findsOneWidget);
      expect(find.text('settings-placeholder'), findsNothing);
    });

    testWidgets('页面本身无写入口泄漏：输入框只是搜索索引', (tester) async {
      await usePhoneSurface(tester);
      final relay = await fixtureWithSessions();
      final sessions = SessionController(relay: relay, clock: () => now);
      await sessions.initialize();
      final palette = CommandPaletteController(sessionController: sessions);

      await tester.pumpWidget(
        buildPaletteApp(relay: relay, sessions: sessions, palette: palette),
      );
      await tester.pumpAndSettle();

      // 唯一输入框是搜索框本身，没有 composer、发送/终止等写入口。
      expect(find.byType(TextField), findsOneWidget);
      expect(find.byKey(const Key('command-palette-input')), findsOneWidget);
      expect(find.byKey(const Key('session-composer')), findsNothing);
      expect(find.byType(FloatingActionButton), findsNothing);
      expect(find.byTooltip('发送'), findsNothing);
      expect(find.text('终止'), findsNothing);
      expect(find.text('恢复'), findsNothing);
      expect(find.text('暂停'), findsNothing);
    });

    testWidgets('点击导航命令跳转到对应路由', (tester) async {
      await usePhoneSurface(tester);
      final relay = await fixtureWithSessions();
      final sessions = SessionController(relay: relay, clock: () => now);
      await sessions.initialize();
      final palette = CommandPaletteController(sessionController: sessions);

      await tester.pumpWidget(
        buildPaletteApp(relay: relay, sessions: sessions, palette: palette),
      );
      await tester.pumpAndSettle();

      // 只过滤出'设置'导航命令并点击。
      await tester.enterText(
        find.byKey(const Key('command-palette-input')),
        '设置',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('command-palette-result-0')));
      await tester.pumpAndSettle();
      expect(find.text('settings-placeholder'), findsOneWidget);
    });
  });
}

/// 路由跳转目标的占位页，只验证导航是否发生，不依赖真实业务页面。
class _PlaceholderScreen extends StatelessWidget {
  const _PlaceholderScreen({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) =>
      Scaffold(body: Center(child: Text('$label-placeholder')));
}
