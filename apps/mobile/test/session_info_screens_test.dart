import 'package:agent_sessions_mobile/app/providers.dart';
import 'package:agent_sessions_mobile/domain/session_models.dart';
import 'package:agent_sessions_mobile/domain/terminal_models.dart';
import 'package:agent_sessions_mobile/relay/fixture_relay_repository.dart';
import 'package:agent_sessions_mobile/state/app_controller.dart';
import 'package:agent_sessions_mobile/state/session_controller.dart';
import 'package:agent_sessions_mobile/state/session_info_controller.dart';
import 'package:agent_sessions_mobile/state/terminal_status_controller.dart';
import 'package:agent_sessions_mobile/storage/encrypted_cache.dart';
import 'package:agent_sessions_mobile/storage/secure_token_store.dart';
import 'package:agent_sessions_mobile/ui/session_info_screens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fixture_owner.dart';

/// MOBILE-19：会话 info 页只读聚合白名单元数据；不展示正文、token、恢复码或完整路径。
/// 复制只提供会话 ID 与 Provider；分享在独立安全 ADR 通过前恒为 unavailable。
void main() {
  final now = DateTime.utc(2026, 8, 16, 12);

  group('MOBILE-19 会话信息控制器', () {
    test('statusLabel 使用 Relay 白名单状态文案，分享恒为 unavailable', () async {
      final relay = await _fixtureWithSession(
        provider: 'codex',
        clock: () => now,
      );
      final terminals = await _terminalController(relay, now);
      final sessions = await _readySessions(relay, now);
      final sessionId = sessions.selectedSessionId!;

      final controller = SessionInfoController(
        sessionController: sessions,
        terminalStatusController: terminals,
      );

      expect(controller.session?.id, sessionId);
      expect(controller.statusLabel, '空闲');
      expect(controller.shareUnavailable, isTrue);
    });

    test('无 lease 时终止显示阻断原因；未声明 abort/resume 的 Provider fail-closed', () async {
      final relay = await _fixtureWithSession(
        provider: 'opencode',
        clock: () => now,
      );
      final terminals = await _terminalController(relay, now);
      final sessions = await _readySessions(relay, now);
      // opencode 未声明 abort/resume；先拿 lease 排除「无租约」这一更早的阻断分支。
      await sessions.acquireSelectedLease(
        deviceId: 'android-owner-fixture',
        canWrite: true,
      );

      final controller = SessionInfoController(
        sessionController: sessions,
        terminalStatusController: terminals,
      );

      expect(controller.stopBlockedReason, 'fixture Provider 未声明此能力。');
      expect(controller.killBlockedReason, 'fixture Provider 未声明此能力。');
      expect(controller.resumeBlockedReason, 'fixture Provider 未声明此能力。');
    });

    test('codex 声明 abort 且有 lease 时终止可用；恢复仍按只读阻断', () async {
      final relay = await _fixtureWithSession(
        provider: 'codex',
        clock: () => now,
      );
      final terminals = await _terminalController(relay, now);
      final sessions = await _readySessions(relay, now);
      await sessions.acquireSelectedLease(
        deviceId: 'android-owner-fixture',
        canWrite: true,
      );

      final controller = SessionInfoController(
        sessionController: sessions,
        terminalStatusController: terminals,
      );

      expect(controller.stopBlockedReason, isNull);
      expect(controller.killBlockedReason, '当前设备是只读状态');
      expect(controller.resumeBlockedReason, '当前设备是只读状态');
    });
  });

  group('MOBILE-19 会话信息 UI', () {
    testWidgets('有会话时展示状态/Provider/事件序号/工作区白名单字段', (tester) async {
      _usePhoneSurface(tester);
      final relay = await _fixtureWithSession(
        provider: 'codex',
        clock: () => now,
      );
      await _pumpInfoScreen(tester, relay, now);

      expect(find.byKey(const Key('session-info-screen')), findsOneWidget);
      expect(find.byKey(const Key('session-info-list')), findsOneWidget);
      expect(find.text('会话信息'), findsOneWidget);
      expect(find.text('状态'), findsOneWidget);
      expect(find.text('空闲'), findsOneWidget);
      expect(find.text('Provider'), findsOneWidget);
      expect(find.text('codex'), findsOneWidget);
      expect(find.text('事件序号'), findsOneWidget);
      expect(find.text('1'), findsOneWidget);
      expect(find.text('工作区'), findsOneWidget);
      expect(find.text('fixture-workspace'), findsOneWidget);
    });

    testWidgets('机器卡只显示 hostname/平台/Daemon 版本，不显示终端 ID、路径、日志', (tester) async {
      _usePhoneSurface(tester);
      final relay = await _fixtureWithSession(
        provider: 'codex',
        clock: () => now,
      );
      relay.replaceTerminals([
        TerminalSummary(
          id: 'term-opaque-001',
          hostname: 'Build Mac',
          platform: 'macos',
          status: TerminalConnectionStatus.online,
          protocolVersion: 1,
          daemonVersion: '0.4.0',
          lastSeen: now.subtract(const Duration(seconds: 20)),
        ),
        TerminalSummary(
          id: 'term-opaque-002',
          hostname: 'Stale Linux',
          platform: 'linux',
          status: TerminalConnectionStatus.online,
          protocolVersion: 1,
          lastSeen: now.subtract(const Duration(minutes: 5)),
        ),
      ]);
      await _pumpInfoScreen(tester, relay, now);

      expect(find.text('机器'), findsOneWidget);
      expect(find.text('Build Mac · macos · Daemon 0.4.0'), findsOneWidget);
      expect(find.text('Stale Linux · linux · Daemon 版本未知'), findsOneWidget);
      // opaque ID、路径与日志不是机器卡白名单字段。
      expect(find.text('term-opaque-001'), findsNothing);
      expect(find.text('term-opaque-002'), findsNothing);
      expect(find.textContaining('/'), findsNothing);
      expect(find.textContaining('日志'), findsNothing);
    });

    testWidgets('无 lease 时终止/恢复显示阻断原因，不显示假可用入口', (tester) async {
      _usePhoneSurface(tester);
      final relay = await _fixtureWithSession(
        provider: 'codex',
        clock: () => now,
      );
      await _pumpInfoScreen(tester, relay, now);

      expect(find.text('终止会话'), findsOneWidget);
      expect(find.text('当前会话暂不可操作。'), findsOneWidget);
      expect(find.text('结束本机进程'), findsOneWidget);
      expect(find.text('恢复会话'), findsOneWidget);
      expect(find.text('当前设备是只读状态'), findsNWidgets(2));
      expect(find.text('可用'), findsNothing);
    });

    testWidgets('Provider 未声明 abort/resume 时即使有 lease 也 fail-closed', (
      tester,
    ) async {
      _usePhoneSurface(tester);
      final relay = await _fixtureWithSession(
        provider: 'opencode',
        clock: () => now,
      );
      final sessions = await _readySessions(relay, now);
      await sessions.acquireSelectedLease(
        deviceId: 'android-owner-fixture',
        canWrite: true,
      );
      await _pumpInfoScreen(tester, relay, now, sessions: sessions);

      expect(find.text('fixture Provider 未声明此能力。'), findsNWidgets(3));
      expect(find.text('可用'), findsNothing);
    });

    testWidgets('声明 abort 且有 lease 时终止显示可用，恢复仍只读阻断', (tester) async {
      _usePhoneSurface(tester);
      final relay = await _fixtureWithSession(
        provider: 'codex',
        clock: () => now,
      );
      final sessions = await _readySessions(relay, now);
      await sessions.acquireSelectedLease(
        deviceId: 'android-owner-fixture',
        canWrite: true,
      );
      await _pumpInfoScreen(tester, relay, now, sessions: sessions);

      expect(find.text('可用'), findsOneWidget);
      expect(find.text('当前设备是只读状态'), findsNWidgets(2));
    });

    testWidgets('owner 会话信息显示启动/结束入口，并要求 kill 二次确认', (tester) async {
      _usePhoneSurface(tester);
      final tokenStore = InMemorySecureTokenStore();
      final identities = InMemoryDeviceIdentityStore();
      final relay = FixtureRelayRepository(clock: () => now);
      await bootstrapFixtureOwner(
        relay,
        tokens: tokenStore,
        identities: identities,
      );
      await relay.createSession(
        const CreateMobileSessionInput(
          workspaceId: 'fixture-workspace',
          provider: 'codex',
          deviceId: 'android-owner-fixture',
        ),
      );
      final sessions = await _readySessions(relay, now);
      await sessions.acquireSelectedLease(
        deviceId: 'android-owner-fixture',
        canWrite: true,
      );
      final app = AppController(
        relay: relay,
        tokenStore: tokenStore,
        identityStore: identities,
        encryptedCache: InMemoryEncryptedCacheStore(),
      );
      await app.initialize();
      await _pumpInfoScreen(tester, relay, now, sessions: sessions, app: app);

      expect(find.byKey(const Key('session-start-button')), findsOneWidget);
      expect(find.byKey(const Key('session-kill-button')), findsOneWidget);
      expect(find.byKey(const Key('session-kill-confirm')), findsNothing);

      await _tapVisible(tester, find.byKey(const Key('session-kill-button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('session-kill-confirm')), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('session-kill-confirm')), findsNothing);
    });

    testWidgets('分享恒为 unavailable，明确说明未通过安全决策门', (tester) async {
      _usePhoneSurface(tester);
      final relay = await _fixtureWithSession(
        provider: 'codex',
        clock: () => now,
      );
      await _pumpInfoScreen(tester, relay, now);

      expect(find.text('分享'), findsOneWidget);
      expect(find.text('分享能力未通过安全决策门，当前不可用。'), findsOneWidget);
    });

    testWidgets('复制按钮只复制会话 ID 与 Provider（mock 剪贴板）', (tester) async {
      _usePhoneSurface(tester);
      final relay = await _fixtureWithSession(
        provider: 'codex',
        clock: () => now,
      );
      final sessionId = (await relay.listSessions()).single.id;
      await _pumpInfoScreen(tester, relay, now);

      // 剪贴板走 mock 平台通道，避免真实平台挂起（与 MOBILE-14 同一做法）。
      final clipboardValues = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              clipboardValues.add((call.arguments as Map)['text'] as String);
            }
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });

      expect(
        find.byKey(const Key('session-info-copy-id-button')),
        findsOneWidget,
      );
      expect(find.text('复制会话 ID'), findsOneWidget);
      expect(
        find.byKey(const Key('session-info-copy-provider-button')),
        findsOneWidget,
      );
      expect(find.text('复制 Provider'), findsOneWidget);

      await _tapVisible(
        tester,
        find.byKey(const Key('session-info-copy-id-button')),
      );
      await _tapVisible(
        tester,
        find.byKey(const Key('session-info-copy-provider-button')),
      );
      expect(clipboardValues, [sessionId, 'codex']);
    });

    testWidgets('页面不显示消息正文、token、恢复码与完整路径', (tester) async {
      _usePhoneSurface(tester);
      final relay = await _fixtureWithSession(
        provider: 'codex',
        clock: () => now,
      );
      // 先把会话推进到带正文的状态，确认 info 页只读投影不会带上时间线内容。
      final sessions = await _readySessions(relay, now);
      await sessions.acquireSelectedLease(
        deviceId: 'android-owner-fixture',
        canWrite: true,
      );
      await sessions.sendMessage(
        message: '这是不应外泄的会话正文',
        deviceId: 'android-owner-fixture',
        canWrite: true,
      );
      await _pumpInfoScreen(tester, relay, now, sessions: sessions);

      expect(find.text('这是不应外泄的会话正文'), findsNothing);
      expect(find.textContaining('正在整理这条请求的可控步骤'), findsNothing);
      expect(find.textContaining('fixture-access-token'), findsNothing);
      expect(find.text('RECOVERY-FIXTURE-0001'), findsNothing);
      expect(find.textContaining('/'), findsNothing);
      expect(find.textContaining('消息正文、token 与完整路径不会显示'), findsOneWidget);
    });

    testWidgets('无会话时显示 empty 状态且不展示复制按钮', (tester) async {
      _usePhoneSurface(tester);
      final relay = FixtureRelayRepository(clock: () => now);
      // 只有 owner 没有会话：info 页按未选择会话处理。
      await bootstrapFixtureOwner(relay);
      final terminals = await _terminalController(relay, now);
      final sessions = SessionController(relay: relay, clock: () => now);
      await sessions.initialize();

      // 产品 bug 备注：真实 sessionInfoControllerProvider 在未选中会话时会同步触发
      // selectSession -> notifyListeners，违反 Riverpod「初始化期间禁止修改其它 provider」，
      // debug 下直接断言崩溃（见回报）。此处 override 该 family 只验证 empty 展示层。
      await tester.pumpWidget(
        ProviderScope(
          key: UniqueKey(),
          overrides: [
            relayRepositoryProvider.overrideWithValue(relay),
            sessionControllerProvider.overrideWith((_) => sessions),
            terminalStatusControllerProvider.overrideWith((_) => terminals),
            sessionInfoControllerProvider.overrideWith(
              (ref, sessionId) => SessionInfoController(
                sessionController: sessions,
                terminalStatusController: terminals,
              ),
            ),
          ],
          child: const MaterialApp(
            home: SessionInfoScreen(sessionId: 'missing-session'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('session-info-empty')), findsOneWidget);
      expect(find.text('未找到会话信息。'), findsOneWidget);
      expect(
        find.byKey(const Key('session-info-copy-id-button')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('session-info-copy-provider-button')),
        findsNothing,
      );
    });
  });
}

/// 用 fixture relay bootstrap owner 并创建一个指定 Provider 的会话。
Future<FixtureRelayRepository> _fixtureWithSession({
  required String provider,
  required DateTime Function() clock,
}) async {
  final relay = FixtureRelayRepository(clock: clock);
  await bootstrapFixtureOwner(relay);
  await relay.createSession(
    CreateMobileSessionInput(
      workspaceId: 'fixture-workspace',
      provider: provider,
      deviceId: 'android-owner-fixture',
    ),
  );
  return relay;
}

/// 构造并初始化终端状态控制器。
Future<TerminalStatusController> _terminalController(
  FixtureRelayRepository relay,
  DateTime now,
) async {
  final controller = TerminalStatusController(relay: relay, clock: () => now);
  await controller.initialize();
  return controller;
}

/// 构造已初始化并选中唯一会话的 SessionController。
Future<SessionController> _readySessions(
  FixtureRelayRepository relay,
  DateTime now,
) async {
  final controller = SessionController(relay: relay, clock: () => now);
  await controller.initialize();
  final sessionId = (await relay.listSessions()).single.id;
  await controller.selectSession(sessionId);
  return controller;
}

/// 手机竖屏表面：480x960，保证 info 页整页可见、点击无需先滚动。
void _usePhoneSurface(WidgetTester tester) {
  tester.binding.setSurfaceSize(const Size(480, 960));
  addTearDown(() => tester.binding.setSurfaceSize(null));
}

/// 组装 ProviderScope overrides 并 pump SessionInfoScreen（与 machine_screens_test 同模式）。
Future<void> _pumpInfoScreen(
  WidgetTester tester,
  FixtureRelayRepository relay,
  DateTime now, {
  SessionController? sessions,
  AppController? app,
}) async {
  final terminalController = await _terminalController(relay, now);
  final resolvedSessions = sessions ?? await _readySessions(relay, now);
  await tester.pumpWidget(
    _infoScreen(
      sessionId: resolvedSessions.selectedSessionId!,
      relay: relay,
      sessions: resolvedSessions,
      terminals: terminalController,
      app: app,
    ),
  );
  await tester.pumpAndSettle();
}

/// 直接 pump SessionInfoScreen，不依赖 router（router 只做参数转发）。
Widget _infoScreen({
  required String sessionId,
  required FixtureRelayRepository relay,
  required SessionController sessions,
  required TerminalStatusController terminals,
  AppController? app,
}) => ProviderScope(
  key: UniqueKey(),
  overrides: [
    relayRepositoryProvider.overrideWithValue(relay),
    sessionControllerProvider.overrideWith((_) => sessions),
    terminalStatusControllerProvider.overrideWith((_) => terminals),
    if (app != null) appControllerProvider.overrideWith((_) => app),
  ],
  child: MaterialApp(home: SessionInfoScreen(sessionId: sessionId)),
);

Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  for (var frame = 0; frame < 3; frame += 1) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.tap(finder);
}
