import 'package:agent_sessions_mobile/app/providers.dart';
import 'package:agent_sessions_mobile/domain/session_models.dart';
import 'package:agent_sessions_mobile/domain/terminal_models.dart';
import 'package:agent_sessions_mobile/relay/fixture_relay_repository.dart';
import 'package:agent_sessions_mobile/state/app_controller.dart';
import 'package:agent_sessions_mobile/state/session_controller.dart';
import 'package:agent_sessions_mobile/state/terminal_status_controller.dart';
import 'package:agent_sessions_mobile/storage/encrypted_cache.dart';
import 'package:agent_sessions_mobile/storage/secure_token_store.dart';
import 'package:agent_sessions_mobile/ui/session_screens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'support/fixture_owner.dart';

void main() {
  testWidgets('V081-P1：首页默认显示 DSH 工作区并保留空工作区', (tester) async {
    final relay = FixtureRelayRepository(clock: () => DateTime.now());
    final owner = await _ownerContext(relay);
    relay.replaceWorkspaces([
      const MobileWorkspace(
        id: 'ws-alpha',
        projectId: 'alpha',
        terminalId: 'term-mac',
        origin: MobileWorkspaceOrigin.dsh,
        displayName: '网游风格小说',
        status: 'active',
      ),
      const MobileWorkspace(
        id: 'ws-empty',
        projectId: 'empty',
        terminalId: 'term-mac',
        origin: MobileWorkspaceOrigin.dsh,
        displayName: '斗罗奶龙',
        status: 'active',
      ),
    ]);
    final session = await relay.createSession(
      const CreateMobileSessionInput(
        workspaceId: 'ws-alpha',
        provider: 'dsh',
        deviceId: 'android-owner-fixture',
      ),
    );
    final controller = SessionController(relay: relay);
    await controller.initialize();

    await tester.pumpWidget(_home(relay, controller, owner));
    await tester.pumpAndSettle();

    expect(find.text('DSH 工作区'), findsOneWidget);
    expect(find.byKey(const Key('session-dsh-mode-button')), findsNothing);
    expect(find.byKey(const Key('session-new-button')), findsNothing);
    expect(find.byKey(const Key('dsh-workspace-ws-alpha')), findsOneWidget);
    expect(find.byKey(const Key('dsh-workspace-ws-empty')), findsOneWidget);
    await tester.tap(find.byKey(const Key('dsh-workspace-expand-ws-alpha')));
    await tester.pumpAndSettle();
    expect(find.text(session.title), findsOneWidget);
    expect(find.text('尚无 DSH 会话'), findsNothing);
  });

  testWidgets('V081-P1：展开箭头与工作区选中是独立交互目标，搜索只过滤安全标签', (tester) async {
    final relay = FixtureRelayRepository(clock: () => DateTime.now());
    final owner = await _ownerContext(relay);
    relay.replaceWorkspaces([
      const MobileWorkspace(
        id: 'ws-one',
        projectId: 'one',
        terminalId: 'term-mac',
        origin: MobileWorkspaceOrigin.dsh,
        displayName: 'agent-sessions',
      ),
      const MobileWorkspace(
        id: 'ws-two',
        projectId: 'two',
        terminalId: 'term-mac',
        origin: MobileWorkspaceOrigin.dsh,
        displayName: '另一个项目',
      ),
    ]);
    final controller = SessionController(relay: relay);
    await controller.initialize();
    await tester.pumpWidget(_home(relay, controller, owner));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('dsh-workspace-expand-ws-one')));
    await tester.pumpAndSettle();
    expect(find.text('尚无 DSH 会话'), findsOneWidget);
    await tester.tap(find.byKey(const Key('dsh-workspace-select-ws-one')));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('dsh-workspace-search-input')),
      'agent',
    );
    await tester.pump();
    expect(find.byKey(const Key('dsh-workspace-ws-one')), findsOneWidget);
    expect(find.byKey(const Key('dsh-workspace-ws-two')), findsNothing);
  });

  testWidgets('V081-P1：同步确认只显示在线且声明能力的终端', (tester) async {
    final relay = FixtureRelayRepository(clock: () => DateTime.now());
    final owner = await _ownerContext(relay);
    relay.replaceTerminals([
      TerminalSummary(
        id: 'term-capable',
        hostname: 'MacBook Pro',
        platform: 'macos',
        status: TerminalConnectionStatus.online,
        protocolVersion: 1,
        lastSeen: DateTime.now(),
        capabilities: const ['dsh_workspace_sync'],
      ),
      TerminalSummary(
        id: 'term-unsupported',
        hostname: 'Linux',
        platform: 'linux',
        status: TerminalConnectionStatus.online,
        protocolVersion: 1,
        lastSeen: DateTime.now(),
      ),
    ]);
    await owner.terminals.refresh();
    final controller = SessionController(relay: relay);
    await controller.initialize();
    await tester.pumpWidget(_home(relay, controller, owner));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('dsh-workspace-sync-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dsh-workspace-sync-sheet')), findsOneWidget);
    expect(find.text('MacBook Pro'), findsOneWidget);
    expect(find.text('Linux'), findsNothing);
    expect(find.byKey(const Key('dsh-workspace-sync-confirm')), findsOneWidget);
  });

  testWidgets('V081-P2：窄屏工作区标题进入详情，创建入口锁定 DSH workspace', (tester) async {
    final relay = FixtureRelayRepository(clock: () => DateTime.now());
    final owner = await _ownerContext(relay);
    relay.replaceTerminals([
      TerminalSummary(
        id: 'term-dsh',
        hostname: 'DSH Mac',
        platform: 'macos',
        status: TerminalConnectionStatus.online,
        protocolVersion: 1,
        lastSeen: DateTime.now(),
        capabilities: const ['start', 'dsh_session_import'],
      ),
    ]);
    await owner.terminals.refresh();
    relay.replaceWorkspaces(const [
      MobileWorkspace(
        id: 'ws-dsh',
        projectId: 'dsh-project',
        terminalId: 'term-dsh',
        origin: MobileWorkspaceOrigin.dsh,
        displayName: 'agent-sessions',
        status: 'active',
      ),
    ]);
    final controller = SessionController(relay: relay);
    await controller.initialize();

    final router = GoRouter(
      initialLocation: '/home',
      routes: [
        GoRoute(path: '/home', builder: (_, _) => const SessionHomeScreen()),
        GoRoute(
          path: '/workspaces/:id',
          builder: (_, state) => DSHWorkspaceDetailScreen(
            workspaceId: state.pathParameters['id']!,
          ),
        ),
        GoRoute(
          path: '/sessions/:id',
          builder: (_, state) =>
              Scaffold(body: Text('会话 ${state.pathParameters['id']}')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(_routedHome(relay, controller, owner, router));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('dsh-workspace-select-ws-dsh')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('dsh-workspace-detail-screen')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('dsh-workspace-create-session-button')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const Key('dsh-workspace-create-session-button')),
    );
    await tester.pumpAndSettle();
    final created = controller.sessions.single;
    expect(created.workspaceId, 'ws-dsh');
    expect(created.provider, 'dsh');
  });

  testWidgets('V081-P2：详情页导入确认明确仅导入元数据，且离线时禁用写入口', (tester) async {
    final relay = FixtureRelayRepository(clock: () => DateTime.now());
    final owner = await _ownerContext(relay);
    relay.replaceTerminals([
      TerminalSummary(
        id: 'term-dsh',
        hostname: 'DSH Mac',
        platform: 'macos',
        status: TerminalConnectionStatus.online,
        protocolVersion: 1,
        lastSeen: DateTime.now(),
        capabilities: const ['start', 'dsh_session_import'],
      ),
    ]);
    await owner.terminals.refresh();
    relay.replaceWorkspaces(const [
      MobileWorkspace(
        id: 'ws-dsh',
        projectId: 'dsh-project',
        terminalId: 'term-dsh',
        origin: MobileWorkspaceOrigin.dsh,
        displayName: 'agent-sessions',
        status: 'active',
      ),
    ]);
    final controller = SessionController(relay: relay);
    await controller.initialize();
    await tester.pumpWidget(_detail(relay, controller, owner));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('dsh-workspace-more-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('dsh-workspace-import-button')));
    await tester.pumpAndSettle();
    expect(find.textContaining('仅导入会话元数据'), findsOneWidget);
    await tester.tap(find.byKey(const Key('dsh-workspace-import-confirm')));
    await tester.pumpAndSettle();
    expect(find.text('未发现可导入会话。'), findsOneWidget);

    relay.replaceTerminals([
      TerminalSummary(
        id: 'term-dsh',
        hostname: 'DSH Mac',
        platform: 'macos',
        status: TerminalConnectionStatus.offline,
        protocolVersion: 1,
        lastSeen: DateTime.now(),
        capabilities: const ['start', 'dsh_session_import'],
      ),
    ]);
    await owner.terminals.refresh();
    await tester.pumpAndSettle();
    final create = tester.widget<FilledButton>(
      find.byKey(const Key('dsh-workspace-create-session-button')),
    );
    expect(create.onPressed, isNull);
    expect(find.textContaining('home Terminal 当前离线'), findsOneWidget);
  });

  testWidgets('V081-P2：宽屏保留工作区栏，并在右侧联动详情', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final relay = FixtureRelayRepository(clock: () => DateTime.now());
    final owner = await _ownerContext(relay);
    relay.replaceWorkspaces(const [
      MobileWorkspace(
        id: 'ws-wide',
        projectId: 'wide-project',
        terminalId: 'term-dsh',
        origin: MobileWorkspaceOrigin.dsh,
        displayName: '很长很长的工作区名称用于验证宽屏详情布局不会挤压工作区栏',
        status: 'active',
      ),
    ]);
    final controller = SessionController(relay: relay);
    await controller.initialize();
    await tester.pumpWidget(_home(relay, controller, owner));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('dsh-workspace-master-detail-scroll')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('dsh-workspace-detail-pane')), findsOneWidget);
    expect(find.byKey(const Key('session-new-button')), findsNothing);
  });
}

class _OwnerContext {
  const _OwnerContext({required this.app, required this.terminals});

  final AppController app;
  final TerminalStatusController terminals;
}

Future<_OwnerContext> _ownerContext(FixtureRelayRepository relay) async {
  final tokens = InMemorySecureTokenStore();
  final identities = InMemoryDeviceIdentityStore();
  await bootstrapFixtureOwner(relay, tokens: tokens, identities: identities);
  final app = AppController(
    relay: relay,
    tokenStore: tokens,
    identityStore: identities,
    encryptedCache: InMemoryEncryptedCacheStore(),
  );
  await app.initialize();
  final terminals = TerminalStatusController(
    relay: relay,
    clock: relay.fixtureNow,
  );
  await terminals.initialize();
  return _OwnerContext(app: app, terminals: terminals);
}

Widget _home(
  FixtureRelayRepository relay,
  SessionController sessions,
  _OwnerContext owner,
) => ProviderScope(
  overrides: [
    relayRepositoryProvider.overrideWithValue(relay),
    appControllerProvider.overrideWith((_) => owner.app),
    terminalStatusControllerProvider.overrideWith((_) => owner.terminals),
    sessionControllerProvider.overrideWith((_) => sessions),
  ],
  child: const MaterialApp(home: SessionHomeScreen()),
);

Widget _detail(
  FixtureRelayRepository relay,
  SessionController sessions,
  _OwnerContext owner,
) => ProviderScope(
  overrides: [
    relayRepositoryProvider.overrideWithValue(relay),
    appControllerProvider.overrideWith((_) => owner.app),
    terminalStatusControllerProvider.overrideWith((_) => owner.terminals),
    sessionControllerProvider.overrideWith((_) => sessions),
  ],
  child: const MaterialApp(
    home: DSHWorkspaceDetailScreen(workspaceId: 'ws-dsh'),
  ),
);

Widget _routedHome(
  FixtureRelayRepository relay,
  SessionController sessions,
  _OwnerContext owner,
  GoRouter router,
) => ProviderScope(
  overrides: [
    relayRepositoryProvider.overrideWithValue(relay),
    appControllerProvider.overrideWith((_) => owner.app),
    terminalStatusControllerProvider.overrideWith((_) => owner.terminals),
    sessionControllerProvider.overrideWith((_) => sessions),
  ],
  child: MaterialApp.router(routerConfig: router),
);
