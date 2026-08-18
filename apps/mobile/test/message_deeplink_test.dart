import 'package:agent_sessions_mobile/app/providers.dart';
import 'package:agent_sessions_mobile/domain/models.dart';
import 'package:agent_sessions_mobile/domain/session_models.dart';
import 'package:agent_sessions_mobile/relay/fixture_relay_repository.dart';
import 'package:agent_sessions_mobile/state/message_deep_link_controller.dart';
import 'package:agent_sessions_mobile/state/session_controller.dart';
import 'package:agent_sessions_mobile/ui/message_deep_link_screens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'support/fixture_owner.dart';

/// MOBILE-27：P3 单消息深链页。
/// 只定位授权会话中的目标消息：eventFor(sequence) 命中返回事件、不存在/无权统一返回 null；
/// 页面展示卡片 + SelectableText 消息文本 + 事件序号，不泄漏 token、恢复码或会话其他正文。
void main() {
  group('MOBILE-27 消息深链控制器', () {
    test('加载授权会话后 eventFor 返回目标序号的事件', () async {
      final relay = await _fixtureWithMessage(_clock);
      final sessions = await _readySessions(relay, _clock);
      final controller = MessageDeepLinkController(sessionController: sessions);
      final sessionId = (await relay.listSessions()).single.id;

      await controller.load(sessionId: sessionId);

      expect(controller.phase, MessageDeepLinkPhase.ready);
      expect(controller.currentSessionId, sessionId);
      expect(controller.errorMessage, isNull);
      final event = controller.eventFor(2);
      expect(event, isNotNull);
      expect(event!.sequence, 2);
      expect(event.kind, SessionTimelineKind.userMessage);
      expect(event.text, '深链目标消息正文');
    });

    test('不存在的序号 eventFor 返回 null', () async {
      final relay = await _fixtureWithMessage(_clock);
      final sessions = await _readySessions(relay, _clock);
      final controller = MessageDeepLinkController(sessionController: sessions);
      final sessionId = (await relay.listSessions()).single.id;

      await controller.load(sessionId: sessionId);

      expect(controller.phase, MessageDeepLinkPhase.ready);
      expect(controller.eventFor(99), isNull);
      // 边界外的 0 序号同样返回 null，不泄漏消息是否存在。
      expect(controller.eventFor(0), isNull);
    });

    test('未加载（loading 阶段）时 eventFor 返回 null', () {
      final relay = FixtureRelayRepository(clock: _clock);
      final sessions = SessionController(relay: relay, clock: _clock);
      final controller = MessageDeepLinkController(sessionController: sessions);

      expect(controller.phase, MessageDeepLinkPhase.loading);
      expect(controller.eventFor(2), isNull);
    });

    test('selectSession 抛 Relay 错误时进入 error 并记录错误信息', () async {
      final failing = _FailingSessionController();
      final controller = MessageDeepLinkController(sessionController: failing);

      await controller.load(sessionId: 'session-fixture-001');

      expect(controller.phase, MessageDeepLinkPhase.error);
      expect(controller.errorMessage, isNotNull);
      expect(controller.currentSessionId, 'session-fixture-001');
      // error 阶段不允许按序号读取任何事件。
      expect(controller.eventFor(2), isNull);
    });
  });

  group('MOBILE-27 消息深链 UI', () {
    testWidgets('首帧展示 loading，加载完成后展示卡片、可复制消息文本与事件序号', (tester) async {
      _usePhoneSurface(tester);
      final relay = await _fixtureWithMessage(_clock);
      final sessions = await _readySessions(relay, _clock);
      final controller = MessageDeepLinkController(sessionController: sessions);
      final sessionId = (await relay.listSessions()).single.id;

      await tester.pumpWidget(
        _deepLinkApp(
          relay: relay,
          sessions: sessions,
          controller: controller,
          sessionId: sessionId,
          messageSequence: 2,
        ),
      );
      // initState 的微任务尚未完成加载：首帧必须展示 loading。
      expect(find.byKey(const Key('message-deeplink-loading')), findsOneWidget);

      await tester.pumpAndSettle();

      expect(find.byKey(const Key('message-deeplink-screen')), findsOneWidget);
      expect(find.byKey(const Key('message-deeplink-list')), findsOneWidget);
      expect(find.byKey(const Key('message-deeplink-card')), findsOneWidget);
      // 消息文本由 SelectableText 承载，可直接选择复制（不 mock 剪贴板）。
      expect(find.byKey(const Key('message-deeplink-text')), findsOneWidget);
      expect(find.byType(SelectableText), findsOneWidget);
      expect(find.text('深链目标消息正文'), findsOneWidget);
      expect(find.text('事件序号 2'), findsOneWidget);
      expect(find.byKey(const Key('message-deeplink-note')), findsOneWidget);
      expect(find.byKey(const Key('message-deeplink-error')), findsNothing);
    });

    testWidgets('目标序号不存在时显示统一 empty 且不泄漏任何消息文本', (tester) async {
      _usePhoneSurface(tester);
      final relay = await _fixtureWithMessage(_clock);
      final sessions = await _readySessions(relay, _clock);
      final controller = MessageDeepLinkController(sessionController: sessions);
      final sessionId = (await relay.listSessions()).single.id;

      await tester.pumpWidget(
        _deepLinkApp(
          relay: relay,
          sessions: sessions,
          controller: controller,
          sessionId: sessionId,
          messageSequence: 99,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('message-deeplink-empty')), findsOneWidget);
      expect(find.text('未找到消息。链接可能已过期或无权访问。'), findsOneWidget);
      // 会话中真实存在 seq 2 消息，但 empty 页不渲染任何消息文本，不泄漏存在性。
      expect(find.text('深链目标消息正文'), findsNothing);
      expect(find.byKey(const Key('message-deeplink-card')), findsNothing);
      expect(find.byType(SelectableText), findsNothing);
    });

    testWidgets('无权/不存在的会话显示同样的统一 empty，不泄漏存在性', (tester) async {
      _usePhoneSurface(tester);
      final relay = await _fixtureWithMessage(_clock);
      final sessions = await _readySessions(relay, _clock);
      final controller = MessageDeepLinkController(sessionController: sessions);

      await tester.pumpWidget(
        _deepLinkApp(
          relay: relay,
          sessions: sessions,
          controller: controller,
          sessionId: 'session-not-mine',
          messageSequence: 2,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('message-deeplink-empty')), findsOneWidget);
      expect(find.text('未找到消息。链接可能已过期或无权访问。'), findsOneWidget);
      expect(find.byKey(const Key('message-deeplink-card')), findsNothing);
      expect(find.text('深链目标消息正文'), findsNothing);
    });

    testWidgets('页面不显示 token、恢复码或目标消息之外的会话正文', (tester) async {
      _usePhoneSurface(tester);
      final relay = await _fixtureWithMessage(_clock);
      final sessions = await _readySessions(relay, _clock);
      final controller = MessageDeepLinkController(sessionController: sessions);
      final sessionId = (await relay.listSessions()).single.id;

      await tester.pumpWidget(
        _deepLinkApp(
          relay: relay,
          sessions: sessions,
          controller: controller,
          sessionId: sessionId,
          messageSequence: 2,
        ),
      );
      await tester.pumpAndSettle();

      // 只有目标消息可见；fixture 紧随其后的 assistant/tool 事件正文不得出现。
      expect(find.text('深链目标消息正文'), findsOneWidget);
      expect(find.text('正在整理这条请求的可控步骤'), findsNothing);
      expect(find.textContaining('fixture-access-token'), findsNothing);
      expect(find.text('RECOVERY-FIXTURE-0001'), findsNothing);
      // 边界说明明确告知：复制不会附加 token、内部 ID 或隐藏正文。
      expect(find.textContaining('复制不会附加 token'), findsOneWidget);
    });

    testWidgets('Relay 失败展示 error 与重试按钮，恢复后重试成功展示消息', (tester) async {
      _usePhoneSurface(tester);
      final relay = await _fixtureWithMessage(_clock);
      final sessions = await _readySessions(relay, _clock);
      // 首次 selectSession 抛 RelayFailure，之后放行到真实 SessionController。
      final flaky = _FlakySessionController(sessions);
      final controller = MessageDeepLinkController(sessionController: flaky);
      final sessionId = (await relay.listSessions()).single.id;

      await tester.pumpWidget(
        _deepLinkApp(
          relay: relay,
          sessions: flaky,
          controller: controller,
          sessionId: sessionId,
          messageSequence: 2,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('message-deeplink-error')), findsOneWidget);
      expect(find.text('Relay 暂时不可用，请稍后重试。'), findsOneWidget);
      expect(
        find.byKey(const Key('message-deeplink-retry-button')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('message-deeplink-card')), findsNothing);

      // 网络恢复后点击重试按钮进入 ready 并展示目标消息。
      await tester.tap(find.byKey(const Key('message-deeplink-retry-button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('message-deeplink-error')), findsNothing);
      expect(find.byKey(const Key('message-deeplink-card')), findsOneWidget);
      expect(find.text('深链目标消息正文'), findsOneWidget);
    });

    testWidgets(
      '路由 harness：从 /sessions/:id 深链到 /sessions/:id/messages/:seq 并可返回',
      (tester) async {
        _usePhoneSurface(tester);
        final relay = await _fixtureWithMessage(_clock);
        final sessions = await _readySessions(relay, _clock);
        final controller = MessageDeepLinkController(
          sessionController: sessions,
        );
        final sessionId = (await relay.listSessions()).single.id;

        final router = GoRouter(
          initialLocation: '/sessions/$sessionId',
          routes: [
            GoRoute(
              path: '/sessions/:id',
              builder: (context, state) =>
                  _DeepLinkLauncher(sessionId: state.pathParameters['id']!),
            ),
            GoRoute(
              path: '/sessions/:id/messages/:seq',
              builder: (context, state) => MessageDeepLinkScreen(
                sessionId: state.pathParameters['id']!,
                messageSequence:
                    int.tryParse(state.pathParameters['seq'] ?? '') ?? 0,
              ),
            ),
          ],
        );
        await tester.pumpWidget(
          ProviderScope(
            key: UniqueKey(),
            overrides: [
              relayRepositoryProvider.overrideWithValue(relay),
              sessionControllerProvider.overrideWith((_) => sessions),
              messageDeepLinkControllerProvider.overrideWith((_) => controller),
            ],
            child: MaterialApp.router(routerConfig: router),
          ),
        );
        await tester.pumpAndSettle();

        // 先停在 /sessions/:id 占位页，再点按钮跳到消息深链。
        expect(
          find.byKey(const Key('deeplink-launcher-button')),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const Key('deeplink-launcher-button')));
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('message-deeplink-screen')),
          findsOneWidget,
        );
        expect(find.text('深链目标消息正文'), findsOneWidget);
        expect(find.text('事件序号 2'), findsOneWidget);

        // 返回按钮回到 /sessions/:id。
        await tester.tap(find.byKey(const Key('message-deeplink-back-button')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('deeplink-launcher-button')),
          findsOneWidget,
        );
      },
    );
  });
}

/// 固定 fixture 时钟：全部用例共享同一 UTC 时刻，保证断言可重复。
DateTime _clock() => DateTime.utc(2026, 8, 16, 12);

/// 注册 owner 并创建一个带一条用户消息的会话：
/// seq 1 = 会话已创建，seq 2 = 用户消息「深链目标消息正文」，seq 3+ = fixture 对话后续事件。
Future<FixtureRelayRepository> _fixtureWithMessage(
  DateTime Function() clock,
) async {
  final relay = FixtureRelayRepository(clock: clock);
  await bootstrapFixtureOwner(relay);
  final session = await relay.createSession(
    const CreateMobileSessionInput(
      workspaceId: 'fixture-workspace',
      provider: 'codex',
      deviceId: 'android-owner-fixture',
    ),
  );
  final lease = await relay.acquireSessionLease(session.id);
  await relay.submitSessionCommand(
    session.id,
    SessionCommandInput(
      kind: SessionCommandKind.send,
      idempotencyKey: 'deeplink-send-1',
      leaseEpoch: lease.epoch,
      deviceId: 'android-owner-fixture',
      ciphertext: const {
        'fixture_payload': {'message': '深链目标消息正文'},
      },
    ),
  );
  return relay;
}

/// 构造已初始化的 SessionController（列表含 fixture 会话，但不预选，由 load 自行选中）。
Future<SessionController> _readySessions(
  FixtureRelayRepository relay,
  DateTime Function() clock,
) async {
  final sessions = SessionController(relay: relay, clock: clock);
  await sessions.initialize();
  return sessions;
}

/// 直接 pump MessageDeepLinkScreen 的 harness：override relay/session/deeplink provider。
Widget _deepLinkApp({
  required FixtureRelayRepository relay,
  required SessionController sessions,
  required MessageDeepLinkController controller,
  required String sessionId,
  required int messageSequence,
}) => ProviderScope(
  key: UniqueKey(),
  overrides: [
    relayRepositoryProvider.overrideWithValue(relay),
    sessionControllerProvider.overrideWith((_) => sessions),
    messageDeepLinkControllerProvider.overrideWith((_) => controller),
  ],
  child: MaterialApp(
    home: MessageDeepLinkScreen(
      sessionId: sessionId,
      messageSequence: messageSequence,
    ),
  ),
);

/// selectSession 恒抛 RelayFailure 的 SessionController fake，用于验证 error 分支。
class _FailingSessionController implements SessionController {
  @override
  String? get selectedSessionId => null;

  @override
  List<SessionTimelineEvent> get timeline => const [];

  @override
  Future<void> selectSession(String sessionId) async {
    throw const RelayFailure(
      RelayFailureKind.unavailable,
      'Relay 暂时不可用，请稍后重试。',
    );
  }

  // ProviderScope 拆除时会调用 dispose，这里必须为 no-op。
  @override
  void dispose() {}

  // 其余未使用到的成员由 noSuchMethod 兜底（标准 fake 模式）。
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 首次 selectSession 失败、之后放行的 fake，用于验证 error -> 重试 -> 成功链路。
class _FlakySessionController implements SessionController {
  _FlakySessionController(this._inner);

  final SessionController _inner;
  bool _failNext = true;

  @override
  String? get selectedSessionId => _inner.selectedSessionId;

  @override
  String? get errorMessage => _inner.errorMessage;

  @override
  List<MobileSession> get sessions => _inner.sessions;

  @override
  List<SessionTimelineEvent> get timeline => _inner.timeline;

  @override
  Future<void> selectSession(String sessionId) async {
    if (_failNext) {
      _failNext = false;
      throw const RelayFailure(
        RelayFailureKind.unavailable,
        'Relay 暂时不可用，请稍后重试。',
      );
    }
    return _inner.selectSession(sessionId);
  }

  // ProviderScope 拆除时会调用 dispose，这里必须为 no-op。
  @override
  void dispose() {}

  // 其余未使用到的成员由 noSuchMethod 兜底（标准 fake 模式）。
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 路由 harness 的 /sessions/:id 占位页：提供跳转到消息深链的按钮。
class _DeepLinkLauncher extends StatelessWidget {
  const _DeepLinkLauncher({required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: ElevatedButton(
        key: const Key('deeplink-launcher-button'),
        onPressed: () => context.go('/sessions/$sessionId/messages/2'),
        child: const Text('打开消息深链'),
      ),
    ),
  );
}

/// 手机竖屏表面：480x960，保证深链页整页可见、点击无需先滚动。
void _usePhoneSurface(WidgetTester tester) {
  tester.binding.setSurfaceSize(const Size(480, 960));
  addTearDown(() => tester.binding.setSurfaceSize(null));
}
