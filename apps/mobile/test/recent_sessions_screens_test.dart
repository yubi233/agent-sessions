import 'package:agent_sessions_mobile/app/providers.dart';
import 'package:agent_sessions_mobile/domain/session_models.dart';
import 'package:agent_sessions_mobile/relay/fixture_relay_repository.dart';
import 'package:agent_sessions_mobile/state/recent_sessions_controller.dart';
import 'package:agent_sessions_mobile/ui/recent_sessions_screens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'support/fixture_owner.dart';

/// MOBILE-25：最近会话页只读 UI。
/// 直接 pump RecentSessionsScreen 并 override relay/controller，
/// 用带 router 的 harness 验证返回与 /sessions/:id 深链，绕过认证守卫。
void main() {
  group('MOBILE-25 最近会话 UI', () {
    testWidgets('有会话时按更新时间降序展示列表项、Provider 与相对时间', (tester) async {
      await _usePhoneSurface(tester);
      // 相对时间标签与真实时钟比较，因此用 DateTime.now() 反向偏移播种 fixture。
      final now = DateTime.now();
      final relay = await _fixtureWithSessions(now);
      final controller = RecentSessionsController(relay: relay);
      await controller.initialize();

      await tester.pumpWidget(
        _buildRecentSessionsApp(relay: relay, controller: controller),
      );
      await tester.pumpAndSettle();

      // 页面骨架与只读说明
      expect(find.byKey(const Key('recent-sessions-screen')), findsOneWidget);
      expect(find.text('最近会话'), findsOneWidget);
      expect(find.byKey(const Key('recent-sessions-list')), findsOneWidget);
      expect(find.byKey(const Key('recent-sessions-header')), findsOneWidget);

      // 三个会话项都在，最新的 session-fixture-003 排在最前
      expect(
        find.byKey(const Key('recent-session-session-fixture-003')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('recent-session-session-fixture-002')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('recent-session-session-fixture-001')),
        findsOneWidget,
      );
      expect(find.byType(ListTile), findsNWidgets(3));
      final newestTop = tester.getTopLeft(
        find.byKey(const Key('recent-session-session-fixture-003')),
      );
      final olderTop = tester.getTopLeft(
        find.byKey(const Key('recent-session-session-fixture-002')),
      );
      expect(newestTop.dy, lessThan(olderTop.dy));

      // 标题来自 fixture 会话名（状态标签只渲染为图标，不落为文本）
      expect(find.text('新的会话 1'), findsOneWidget);
      expect(find.text('新的会话 2'), findsOneWidget);
      expect(find.text('新的会话 3'), findsOneWidget);

      // Provider 与相对时间组成副标题
      expect(find.text('codex · 3 小时前'), findsOneWidget);
      expect(find.text('claude · 5 分钟前'), findsOneWidget);
      expect(find.text('opencode · 刚刚'), findsOneWidget);

      // 只读元数据展示：不渲染 opaque 会话 id 明文
      expect(find.text('session-fixture-001'), findsNothing);
    });

    testWidgets('空列表显示 empty 状态', (tester) async {
      await _usePhoneSurface(tester);
      final relay = FixtureRelayRepository(clock: () => DateTime.now());
      final controller = RecentSessionsController(relay: relay);
      await controller.initialize();

      await tester.pumpWidget(
        _buildRecentSessionsApp(relay: relay, controller: controller),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('recent-sessions-empty')), findsOneWidget);
      expect(find.text('还没有会话'), findsOneWidget);
      expect(find.textContaining('创建会话后'), findsOneWidget);
      expect(find.byType(ListTile), findsNothing);
    });

    testWidgets('首次读取前显示 loading，初始化完成后进入 ready', (tester) async {
      await _usePhoneSurface(tester);
      final relay = FixtureRelayRepository(clock: () => DateTime.now());
      // 不提前 initialize：由屏幕 initState 的 postFrameCallback 发起首次读取。
      final controller = RecentSessionsController(relay: relay);

      await tester.pumpWidget(
        _buildRecentSessionsApp(relay: relay, controller: controller),
      );

      // 首帧 postFrameCallback 尚未触发 initialize，展示 loading
      expect(find.byKey(const Key('recent-sessions-loading')), findsOneWidget);

      await tester.pumpAndSettle();
      expect(find.byKey(const Key('recent-sessions-loading')), findsNothing);
      expect(find.byKey(const Key('recent-sessions-empty')), findsOneWidget);
    });

    testWidgets('Relay 不可用时显示 error 与重试按钮，恢复网络重试成功', (tester) async {
      await _usePhoneSurface(tester);
      final relay = FixtureRelayRepository(clock: () => DateTime.now())
        ..setNetworkAvailable(false);
      final controller = RecentSessionsController(relay: relay);
      await controller.initialize();

      await tester.pumpWidget(
        _buildRecentSessionsApp(relay: relay, controller: controller),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('recent-sessions-error')), findsOneWidget);
      expect(find.textContaining('不可用'), findsOneWidget);
      expect(find.byTooltip('重试读取最近会话'), findsOneWidget);
      expect(find.byKey(const Key('recent-sessions-list')), findsNothing);

      // 恢复网络后点击重试按钮进入 ready（空列表）。
      relay.setNetworkAvailable(true);
      await tester.tap(find.byTooltip('重试读取最近会话'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('recent-sessions-error')), findsNothing);
      expect(find.byKey(const Key('recent-sessions-empty')), findsOneWidget);
    });

    testWidgets('刷新失败保留旧列表并显示内联错误，可再次重试恢复', (tester) async {
      await _usePhoneSurface(tester);
      final now = DateTime.now();
      final relay = await _fixtureWithSessions(now);
      final controller = RecentSessionsController(relay: relay);
      await controller.initialize();

      await tester.pumpWidget(
        _buildRecentSessionsApp(relay: relay, controller: controller),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('recent-session-session-fixture-001')),
        findsOneWidget,
      );

      // 下拉/按钮刷新失败：旧列表仍在，顶部出现内联错误。
      relay.setNetworkAvailable(false);
      await tester.tap(find.byKey(const Key('recent-sessions-refresh-button')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('recent-session-session-fixture-001')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('recent-sessions-inline-error')),
        findsOneWidget,
      );
      expect(find.textContaining('不可用'), findsOneWidget);

      // 恢复网络后通过内联重试按钮恢复。
      relay.setNetworkAvailable(true);
      await tester.tap(find.byTooltip('重试读取最近会话'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('recent-sessions-inline-error')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('recent-session-session-fixture-001')),
        findsOneWidget,
      );
    });

    testWidgets('点击会话项深链到 /sessions/:id', (tester) async {
      await _usePhoneSurface(tester);
      final now = DateTime.now();
      final relay = await _fixtureWithSessions(now);
      final controller = RecentSessionsController(relay: relay);
      await controller.initialize();

      await tester.pumpWidget(
        _buildRecentSessionsApp(relay: relay, controller: controller),
      );
      await tester.pumpAndSettle();

      // 点击中间那个会话，应推入 /sessions/<id>。
      await tester.tap(
        find.byKey(const Key('recent-session-session-fixture-002')),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('sessions-session-fixture-002-placeholder'),
        findsOneWidget,
      );
    });

    testWidgets('返回按钮回 /home', (tester) async {
      await _usePhoneSurface(tester);
      final now = DateTime.now();
      final relay = await _fixtureWithSessions(now);
      final controller = RecentSessionsController(relay: relay);
      await controller.initialize();

      await tester.pumpWidget(
        _buildRecentSessionsApp(relay: relay, controller: controller),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('recent-sessions-back-button')));
      await tester.pumpAndSettle();
      expect(find.text('home-placeholder'), findsOneWidget);
    });

    testWidgets('页面无任何写入口：无 composer 输入框、发送/终止按钮', (tester) async {
      await _usePhoneSurface(tester);
      final now = DateTime.now();
      final relay = await _fixtureWithSessions(now);
      final controller = RecentSessionsController(relay: relay);
      await controller.initialize();

      await tester.pumpWidget(
        _buildRecentSessionsApp(relay: relay, controller: controller),
      );
      await tester.pumpAndSettle();

      // 只读页面：只有返回/刷新/外观入口，没有会话写入口。
      expect(find.byKey(const Key('session-composer')), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(find.byType(FloatingActionButton), findsNothing);
      expect(find.byTooltip('发送'), findsNothing);
      expect(find.text('终止'), findsNothing);
      expect(find.text('恢复'), findsNothing);
      expect(
        find.byKey(const Key('recent-sessions-refresh-button')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('recent-sessions-back-button')),
        findsOneWidget,
      );
    });
  });
}

/// 用 fixture relay 注册 owner 并按不同时间创建三个会话：
/// session-fixture-001（codex，3 小时前）、002（claude，5 分钟前）、003（opencode，刚刚）。
Future<FixtureRelayRepository> _fixtureWithSessions(DateTime now) async {
  var clock = now.subtract(const Duration(hours: 3));
  final relay = FixtureRelayRepository(clock: () => clock);
  await bootstrapFixtureOwner(relay);
  await relay.createSession(
    CreateMobileSessionInput(
      workspaceId: 'workspace-a',
      provider: 'codex',
      deviceId: 'android-owner-fixture',
    ),
  );
  clock = now.subtract(const Duration(minutes: 5));
  await relay.createSession(
    CreateMobileSessionInput(
      workspaceId: 'workspace-b',
      provider: 'claude',
      deviceId: 'android-owner-fixture',
    ),
  );
  clock = now;
  await relay.createSession(
    CreateMobileSessionInput(
      workspaceId: 'workspace-c',
      provider: 'opencode',
      deviceId: 'android-owner-fixture',
    ),
  );
  return relay;
}

/// 最近会话页 widget 测试专用 harness：真实路由 + fixture overrides，
/// 不连接真实 Relay，也无需通过认证守卫（直接以 /recent-sessions 为初始路由）。
Widget _buildRecentSessionsApp({
  required FixtureRelayRepository relay,
  required RecentSessionsController controller,
}) {
  final router = GoRouter(
    initialLocation: '/recent-sessions',
    routes: [
      GoRoute(
        path: '/recent-sessions',
        builder: (context, state) => const RecentSessionsScreen(),
      ),
      GoRoute(
        path: '/home',
        builder: (context, state) => const _PlaceholderScreen(label: 'home'),
      ),
      GoRoute(
        path: '/sessions/:id',
        builder: (context, state) =>
            _PlaceholderScreen(label: 'sessions-${state.pathParameters['id']}'),
      ),
    ],
  );
  return ProviderScope(
    key: UniqueKey(),
    overrides: [
      relayRepositoryProvider.overrideWithValue(relay),
      recentSessionsControllerProvider.overrideWith((_) => controller),
    ],
    child: MaterialApp.router(routerConfig: router),
  );
}

/// 路由跳转目标的占位页，只验证导航是否发生，不依赖真实业务页面。
class _PlaceholderScreen extends StatelessWidget {
  const _PlaceholderScreen({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) =>
      Scaffold(body: Center(child: Text('$label-placeholder')));
}

/// 手机竖屏表面：480x960，保证列表整页可见、点击无需先滚动。
Future<void> _usePhoneSurface(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(480, 960));
  addTearDown(() => tester.binding.setSurfaceSize(null));
}
