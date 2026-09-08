import 'dart:async';

import 'package:agent_sessions_mobile/app/providers.dart';
import 'package:agent_sessions_mobile/domain/session_models.dart';
import 'package:agent_sessions_mobile/domain/terminal_models.dart';
import 'package:agent_sessions_mobile/relay/fixture_relay_repository.dart';
import 'package:agent_sessions_mobile/state/app_controller.dart';
import 'package:agent_sessions_mobile/state/session_controller.dart';
import 'package:agent_sessions_mobile/state/terminal_status_controller.dart';
import 'package:agent_sessions_mobile/storage/encrypted_cache.dart';
import 'package:agent_sessions_mobile/storage/secure_token_store.dart';
import 'package:agent_sessions_mobile/storage/theme_preference_store.dart';
import 'package:agent_sessions_mobile/ui/app_theme.dart';
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
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('dsh-workspace-select-ws-one')),
        matching: find.byIcon(Icons.folder_outlined),
      ),
    );
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
    final controller = SessionController(relay: relay);
    await controller.initialize();
    await tester.pumpWidget(_home(relay, controller, owner));
    await tester.pumpAndSettle();
    // v0.8.6 C（G9）：终端卡片化——有能力的终端卡显示卡内同步按钮（直发，
    // 无抽屉），无能力终端卡灰态并给出原因。
    expect(find.text('MacBook Pro'), findsOneWidget);
    expect(find.text('Linux'), findsOneWidget);
    expect(
      find.byKey(const Key('dsh-workspace-sync-sheet')),
      findsNothing,
    );
    final capableSync = tester.widget<IconButton>(
      find.byKey(const Key('terminal-sync-term-capable')),
    );
    expect(capableSync.onPressed, isNotNull);
    expect(
      find.byKey(const Key('terminal-unsyncable-reason-term-unsupported')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('terminal-sync-term-unsupported')),
      findsNothing,
    );
  });

  testWidgets('V081-P1：同步入口刷新终端并明确提示能力缺失', (tester) async {
    final relay = FixtureRelayRepository(clock: () => DateTime.now());
    final owner = await _ownerContext(relay);
    relay.replaceTerminals([
      TerminalSummary(
        id: 'term-without-dsh-sync',
        hostname: 'Local Daemon',
        platform: 'macos',
        status: TerminalConnectionStatus.online,
        protocolVersion: 1,
        lastSeen: DateTime.now(),
        capabilities: const ['start'],
      ),
    ]);
    final controller = SessionController(relay: relay);
    await controller.initialize();
    await tester.pumpWidget(_home(relay, controller, owner));
    await tester.pumpAndSettle();

    // v0.8.6 C（G9）：能力缺失的终端卡灰态并明确给出原因（无抽屉）。
    expect(
      find.byKey(const Key('terminal-unsyncable-reason-term-without-dsh-sync')),
      findsOneWidget,
    );
    expect(find.textContaining('终端未声明 DSH 工作区同步能力'), findsOneWidget);
    expect(
      find.byKey(const Key('terminal-sync-term-without-dsh-sync')),
      findsNothing,
    );
  });

  testWidgets('V081-P1：终端刷新挂起时同步弹窗立即反馈并在结果返回后可确认', (tester) async {
    final relay = _DeferredTerminalRelay(clock: () => DateTime.now());
    final owner = await _ownerContext(relay);
    relay.replaceTerminals([
      TerminalSummary(
        id: 'term-delayed-dsh',
        hostname: 'Delayed DSH Mac',
        platform: 'macos',
        status: TerminalConnectionStatus.online,
        protocolVersion: 1,
        lastSeen: DateTime.now(),
        capabilities: const ['dsh_workspace_sync'],
      ),
    ]);
    final controller = SessionController(relay: relay);
    await controller.initialize();
    relay.deferTerminalRead();
    await tester.pumpWidget(_home(relay, controller, owner));
    await tester.pumpAndSettle();

    // 刷新挂起：卡片展示"正在更新终端状态…"加载态。
    await tester.pump();
    expect(
      find.byKey(const Key('terminal-sync-loading')),
      findsOneWidget,
    );

    await relay.completeTerminalRead();
    await tester.pumpAndSettle();

    // 终端就绪：加载态消失，卡内同步按钮可用（点击即直发，无抽屉）。
    expect(find.byKey(const Key('terminal-sync-loading')), findsNothing);
    expect(find.text('Delayed DSH Mac'), findsOneWidget);
    final syncButton = tester.widget<IconButton>(
      find.byKey(const Key('terminal-sync-term-delayed-dsh')),
    );
    expect(syncButton.onPressed, isNotNull);
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

  testWidgets('V081-05：通用新建会话页不暴露 DSH Provider', (tester) async {
    final relay = FixtureRelayRepository(clock: () => DateTime.now());
    final owner = await _ownerContext(relay);
    final controller = SessionController(relay: relay);
    await controller.initialize();

    await tester.pumpWidget(_newSession(relay, controller, owner));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('new-session-provider-select')));
    await tester.pumpAndSettle();

    expect(find.text('Codex').last, findsOneWidget);
    expect(find.text('Claude').last, findsOneWidget);
    expect(find.text('OpenCode').last, findsOneWidget);
    expect(find.text('DeepSeek Harness'), findsNothing);
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
    // v0.8.6 C：工具栏只保留搜索（全局同步按钮被终端卡片同步取代）。
    expect(find.byKey(const Key('dsh-workspace-search-input')), findsOneWidget);
    expect(
      find.byKey(const Key('dsh-workspace-search-input')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('dsh-workspace-detail-pane')), findsOneWidget);
    expect(find.byKey(const Key('session-new-button')), findsNothing);
  });

  testWidgets('V081-10：窄屏搜索独占一行且不产生横向溢出', (tester) async {
    tester.view.physicalSize = const Size(375, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
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
        capabilities: const ['start'],
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
      ),
    ]);
    final controller = SessionController(relay: relay);
    await controller.initialize();

    await tester.pumpWidget(_home(relay, controller, owner));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('dsh-workspace-search-input')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('dsh-workspace-search-input')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
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
  // v0.9.1：控制器需先建立同步资格（认证+前台+surface）才会发起同步。
  // 预取完成后立即 detach（surface 由被 pump 的页面负责挂载/卸载），
  // 避免 surface 计数泄漏让 safety timer 在测试结束时仍挂起。
  terminals.reportAuthBoundary(authenticated: true);
  terminals.attachSurface();
  await terminals.initialize();
  terminals.detachSurface();
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
  child: MaterialApp(
    theme: AppTheme.dark(AppAccent.ocean),
    home: const SessionHomeScreen(),
  ),
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

Widget _newSession(
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
  child: const MaterialApp(home: NewSessionScreen()),
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

class _DeferredTerminalRelay extends FixtureRelayRepository {
  _DeferredTerminalRelay({super.clock});

  Completer<List<TerminalSummary>>? _terminalRead;

  void deferTerminalRead() {
    _terminalRead = Completer<List<TerminalSummary>>();
  }

  Future<void> completeTerminalRead() async {
    final pending = _terminalRead;
    if (pending == null) return;
    _terminalRead = null;
    pending.complete(await super.listTerminals());
  }

  @override
  Future<List<TerminalSummary>> listTerminals() {
    final pending = _terminalRead;
    return pending?.future ?? super.listTerminals();
  }
}
