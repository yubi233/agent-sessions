import 'package:agent_sessions_mobile/app/providers.dart';
import 'package:agent_sessions_mobile/domain/session_models.dart';
import 'package:agent_sessions_mobile/domain/terminal_models.dart';
import 'package:agent_sessions_mobile/relay/fixture_relay_repository.dart';
import 'package:agent_sessions_mobile/state/app_controller.dart';
import 'package:agent_sessions_mobile/state/session_controller.dart';
import 'package:agent_sessions_mobile/state/terminal_status_controller.dart';
import 'package:agent_sessions_mobile/storage/encrypted_cache.dart';
import 'package:agent_sessions_mobile/storage/secure_token_store.dart';
import 'package:agent_sessions_mobile/ui/session_home_screens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fixture_owner.dart';

// v0.9.1 P3（迭代计划 §4 P3）：UI 收敛与可见回归。
// 覆盖 V091-11（标题/正文/按钮门控/状态页单一状态源，无矛盾文案）与
// V091-12（90 秒以上前台零交互，自动保持/恢复正确在线态）。

TerminalSummary _terminalWithAvailability(
  String id, {
  required String availability,
  List<String> capabilities = const ['dsh_workspace_sync', 'start'],
  int revision = 1,
}) {
  return TerminalSummary.fromRelayJson({
    'id': id,
    'hostname': 'host-$id',
    'platform': 'macos',
    'status': availability == 'offline' ? 'offline' : 'online',
    'protocol_version': availability == 'unsupported' ? 2 : 1,
    'availability': availability,
    'presence_revision': revision,
    'last_heartbeat_unix_ms': 1700000000000,
    if (availability != 'offline') 'next_check_unix_ms': 1700000060000,
    'capabilities': capabilities,
  });
}

MobileWorkspace _workspace(String id, String terminalId) => MobileWorkspace(
      id: id,
      projectId: 'proj-$id',
      terminalId: terminalId,
      origin: MobileWorkspaceOrigin.dsh,
      displayName: '工作区 $id',
      status: 'active',
    );

Future<_HomeFixture> _pumpHome(
  WidgetTester tester, {
  required List<TerminalSummary> terminals,
  List<MobileWorkspace> workspaces = const [],
  double textScale = 1.0,
}) async {
  final relay = FixtureRelayRepository(clock: () => DateTime.now());
  // v0.9.1：终端/工作区快照必须在控制器初始化前 seed，保证首拍拿到事实。
  relay.replaceTerminals(terminals);
  relay.replaceWorkspaces(workspaces);
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
  final terminalController = TerminalStatusController(
    relay: relay,
    clock: relay.fixtureNow,
  );
  // 预取：attach -> initialize -> detach（surface 交给页面管理）。
  terminalController.reportAuthBoundary(authenticated: true);
  terminalController.attachSurface();
  await terminalController.initialize();
  terminalController.detachSurface();

  final sessions = SessionController(relay: relay);
  await sessions.initialize();

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        relayRepositoryProvider.overrideWithValue(relay),
        appControllerProvider.overrideWith((_) => app),
        terminalStatusControllerProvider.overrideWith((_) => terminalController),
        sessionControllerProvider.overrideWith((_) => sessions),
      ],
      child: MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
          child: SessionHomeScreen(),
        ),
      ),
    ),
  );
  // 页面 initState 的 postFrame attach 会触发一次首拍，等它落地。
  await tester.pumpAndSettle();
  return _HomeFixture(
    relay: relay,
    terminals: terminalController,
    sessions: sessions,
  );
}

class _HomeFixture {
  _HomeFixture({
    required this.relay,
    required this.terminals,
    required this.sessions,
  });

  final FixtureRelayRepository relay;
  final TerminalStatusController terminals;
  final SessionController sessions;

  /// 用新的权威投影替换 Relay 快照并触发 presence invalidation 唤醒
  /// （模拟 Relay 侧状态变化经 SSE 推送的自动同步路径，用户零交互）。
  Future<void> pushAvailability(List<TerminalSummary> next) async {
    relay.replaceTerminals(next);
    for (final terminal in next) {
      terminals.notifyPresenceInvalidation(
        terminalId: terminal.id,
        presenceRevision: terminal.presenceRevision,
      );
    }
  }
}

void main() {
  testWidgets('V091-11：四态卡片标题/正文/按钮门控消费同一 availability，无矛盾文案', (
    tester,
  ) async {
    // ignore: unused_local_variable
    final fixture = await _pumpHome(
      tester,
      terminals: [
        _terminalWithAvailability('term-online', availability: 'online'),
        _terminalWithAvailability('term-offline', availability: 'offline'),
        _terminalWithAvailability('term-unknown', availability: 'unknown'),
        _terminalWithAvailability(
          'term-unsupported',
          availability: 'unsupported',
        ),
      ],
      workspaces: [
        _workspace('ws-online', 'term-online'),
        _workspace('ws-offline', 'term-offline'),
        _workspace('ws-unknown', 'term-unknown'),
        _workspace('ws-unsupported', 'term-unsupported'),
      ],
    );

    // 标题：platform · 在线态标签，全部来自同一投影。
    expect(find.text('macos · 在线'), findsOneWidget);
    expect(find.text('macos · 离线'), findsOneWidget);
    expect(find.text('macos · 状态未知'), findsOneWidget);
    expect(find.text('macos · 协议不兼容'), findsOneWidget);
    // 不再有"标题在线、正文离线"的矛盾组合。
    expect(find.text('macos · 在线'), findsExactly(1));

    // 正文（禁用原因）：offline 与 unknown/unreachable 分开表述（裁决 T5）。
    expect(
      find.text('终端离线，无法请求同步。'),
      findsOneWidget,
      reason: 'offline 才能报告为执行端离线',
    );
    expect(
      find.text('终端状态未确认，稍后自动重试。'),
      findsOneWidget,
      reason: 'unknown 不得写成执行端离线',
    );
    expect(find.text('终端协议不兼容，无法请求同步。'), findsOneWidget);

    // 按钮门控：只有 online 卡出现同步按钮；不可同步卡带稳定 Key 的原因行。
    expect(find.byKey(const Key('terminal-sync-term-online')), findsOneWidget);
    expect(find.byKey(const Key('terminal-sync-term-offline')), findsNothing);
    expect(find.byKey(const Key('terminal-sync-term-unknown')), findsNothing);
    expect(
      find.byKey(const Key('terminal-sync-term-unsupported')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('terminal-unsyncable-reason-term-offline')),
      findsOneWidget,
    );

    // 稳定 Key：卡片 key 与终端 id 绑定，四张卡齐全。
    for (final id in [
      'term-online',
      'term-offline',
      'term-unknown',
      'term-unsupported',
    ]) {
      expect(find.byKey(Key('terminal-card-$id')), findsWidgets);
    }
  });

  testWidgets('V091-11：offline→online 与 unknown→online 状态切换无布局跳动/溢出', (
    tester,
  ) async {
    // fixture 提供 relay/terminals/sessions 的可控句柄；本用例主要断言渲染结果。
    // ignore: unused_local_variable
    final fixture = await _pumpHome(
      tester,
      terminals: [
        _terminalWithAvailability('term-offline', availability: 'offline'),
        _terminalWithAvailability('term-unknown', availability: 'unknown'),
      ],
      workspaces: [
        _workspace('ws-offline', 'term-offline'),
        _workspace('ws-unknown', 'term-unknown'),
      ],
    );
    final offlineCardOrigin = tester.getTopLeft(
      find.byKey(const Key('terminal-card-term-offline')).first,
    );

    // 恢复：两台终端一并翻正（presence revision 前进 + invalidation 唤醒）。
    await fixture.pushAvailability([
      _terminalWithAvailability(
        'term-offline',
        availability: 'online',
        revision: 2,
      ),
      _terminalWithAvailability(
        'term-unknown',
        availability: 'online',
        revision: 2,
      ),
    ]);
    await tester.pumpAndSettle();

    expect(find.text('macos · 离线'), findsNothing);
    expect(find.text('终端离线，无法请求同步。'), findsNothing);
    expect(find.text('终端状态未确认，稍后自动重试。'), findsNothing);
    expect(find.byKey(const Key('terminal-sync-term-offline')), findsOneWidget);
    // 卡片位置不因状态切换跳动（同一 Key、同一几何位置）。
    expect(
      tester.getTopLeft(find.byKey(const Key('terminal-card-term-offline')).first),
      offlineCardOrigin,
    );
  });

  testWidgets('V091-11：200% 文本缩放与窄屏不产生溢出或语义丢失', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    // ignore: unused_local_variable
    final fixture = await _pumpHome(
      tester,
      terminals: [
        _terminalWithAvailability('term-online', availability: 'online'),
        _terminalWithAvailability('term-offline', availability: 'offline'),
      ],
      workspaces: [_workspace('ws-online', 'term-online')],
      textScale: 2.0,
    );
    // fixture 句柄在本用例不再直接使用：seed 与首拍已由 _pumpHome 完成。
    // 忽略未直接使用 fixture 句柄：_pumpHome 已负责 seed 与首拍。

    // 溢出会被框架捕获为测试失败；这里同时断言关键语义仍然可见。
    expect(find.text('macos · 在线'), findsOneWidget);
    expect(find.text('macos · 离线'), findsOneWidget);
    expect(find.byKey(const Key('terminal-card-term-online')), findsWidgets);
    expect(
      find.byKey(const Key('terminal-unsyncable-reason-term-offline')),
      findsOneWidget,
    );
  });

  testWidgets('V091-12：前台停留 90 秒以上零交互，自动保持/恢复正确在线态', (
    tester,
  ) async {
    final fixture = await _pumpHome(
      tester,
      terminals: [
        _terminalWithAvailability('term-online', availability: 'online'),
      ],
      workspaces: [_workspace('ws-online', 'term-online')],
    );

    expect(find.text('macos · 在线'), findsOneWidget);
    // 客户端缓存超过旧 90 秒阈值：Relay 投影事实未变，卡片绝不误报离线，
    // 也绝不出现已被移除的「状态过期」文案（事故根因回归）。
    await tester.pump(const Duration(seconds: 91));
    expect(find.text('macos · 在线'), findsOneWidget);
    expect(find.text('状态过期'), findsNothing);
    expect(find.byKey(const Key('terminal-card-term-online')), findsWidgets);

    // Daemon 停止心跳：Relay 权威投影 offline，经 invalidation 唤醒自动翻正。
    await fixture.pushAvailability([
      _terminalWithAvailability(
        'term-online',
        availability: 'offline',
        revision: 2,
      ),
    ]);
    await tester.pumpAndSettle();
    expect(find.text('macos · 离线'), findsOneWidget);
    expect(find.text('终端离线，无法请求同步。'), findsOneWidget);
    expect(find.byKey(const Key('terminal-sync-term-online')), findsNothing);

    // 心跳恢复：invalidation 唤醒自动回 online，全程无手工刷新。
    await fixture.pushAvailability([
      _terminalWithAvailability(
        'term-online',
        availability: 'online',
        revision: 3,
      ),
    ]);
    await tester.pumpAndSettle();
    expect(find.text('macos · 在线'), findsOneWidget);
    expect(find.byKey(const Key('terminal-sync-term-online')), findsOneWidget);
    // 整个过程卡片 key 稳定、不闪 loading 清空列表。
    expect(find.byKey(const Key('terminal-card-term-online')), findsWidgets);
    expect(
      find.byKey(const Key('terminal-sync-loading')),
      findsNothing,
      reason: '已有可信数据时 quiet refresh 不闪加载态',
    );
  });
}
