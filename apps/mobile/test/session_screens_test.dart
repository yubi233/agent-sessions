import 'package:agent_sessions_mobile/domain/models.dart';
import 'package:agent_sessions_mobile/domain/session_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/app_harness.dart';

void main() {
  testWidgets('MOBILE-02：owner 可完成新会话、lease、流式、确认、回答和停止', (tester) async {
    final harness = MobileAppHarness();
    await tester.pumpWidget(harness.build());
    await _waitForVisible(tester, find.byKey(const Key('register-link')));
    await _registerOwner(tester, 'session-ui-owner@fixture.test');

    expect(find.byKey(const Key('session-empty-state')), findsOneWidget);
    await _tapVisible(tester, find.byKey(const Key('session-new-button')));
    await _waitForVisible(
      tester,
      find.byKey(const Key('new-session-workspace-input')),
    );
    await _enterVisible(
      tester,
      find.byKey(const Key('new-session-workspace-input')),
      'fixture-workspace',
    );
    await _tapVisible(
      tester,
      find.byKey(const Key('new-session-create-button')),
    );
    await _waitForVisible(
      tester,
      find.byKey(const Key('session-detail-screen')),
    );
    expect(
      find.byKey(const Key('session-composer-blocked-reason')),
      findsOneWidget,
    );

    await _tapVisible(
      tester,
      find.byKey(const Key('session-acquire-lease-button')),
    );
    await _waitForVisible(tester, find.text('已获得控制权'));
    await _enterVisible(
      tester,
      find.byKey(const Key('session-composer-input')),
      '请验证 fixture 会话',
    );
    await _tapVisible(
      tester,
      find.byKey(const Key('session-composer-primary-action')),
    );
    await _waitForVisible(
      tester,
      find.byKey(const Key('assistant-streaming-indicator')),
    );

    final timeline = (await harness.relay.getSessionSnapshot(
      (await harness.relay.listSessions()).single.id,
    )).events.map(SessionTimelineEvent.fromRelayEvent).toList();
    final permission = timeline
        .firstWhere((event) => event.permission != null)
        .permission!;
    final question = timeline
        .firstWhere((event) => event.question != null)
        .question!;

    await _tapVisible(
      tester,
      find.byKey(Key('permission-approve-${permission.requestId}')),
    );
    await _waitForVisible(
      tester,
      find.byKey(Key('permission-resolved-${permission.requestId}')),
    );
    await _enterVisible(
      tester,
      find.byKey(Key('question-freeform-${question.requestId}')),
      '继续 fixture',
    );
    await _tapVisible(
      tester,
      find.byKey(Key('question-submit-${question.requestId}')),
    );
    await _waitForVisible(
      tester,
      find.byKey(Key('question-resolved-${question.requestId}')),
    );

    await _tapVisible(
      tester,
      find.byKey(const Key('session-composer-primary-action')),
    );
    await _waitForVisible(tester, find.text('已停止'));
  });

  testWidgets('MOBILE-02 CTRL-01：密码登录能查看 fixture 会话，但没有 owner 时所有写入口禁用', (
    tester,
  ) async {
    final harness = MobileAppHarness();
    await harness.relay.register(
      const LoginCredentials(
        email: 'readonly-session@fixture.test',
        password: 'fixture-password',
      ),
    );
    await harness.relay.createSession(
      const CreateMobileSessionInput(
        workspaceId: 'readonly-workspace',
        provider: 'codex',
        deviceId: 'android-owner-fixture',
      ),
    );
    await tester.pumpWidget(harness.build());
    await _waitForVisible(tester, find.byKey(const Key('login-email')));
    await _enterVisible(
      tester,
      find.byKey(const Key('login-email')),
      'readonly-session@fixture.test',
    );
    await _enterVisible(
      tester,
      find.byKey(const Key('login-password')),
      'fixture-password',
    );
    await _tapVisible(tester, find.byKey(const Key('login-submit')));
    await _waitForVisible(
      tester,
      find.byKey(const Key('session-readonly-banner')),
    );

    final sessionId = (await harness.relay.listSessions()).single.id;
    await _tapVisible(tester, find.byKey(Key('session-row-$sessionId')));
    await _waitForVisible(
      tester,
      find.byKey(const Key('session-detail-screen')),
    );
    expect(
      find.byKey(const Key('session-composer-blocked-reason')),
      findsOneWidget,
    );
    final action = tester.widget<IconButton>(
      find.byKey(const Key('session-composer-primary-action')),
    );
    expect(action.onPressed, isNull);
    final lease = tester.widget<IconButton>(
      find.byKey(const Key('session-acquire-lease-button')),
    );
    expect(lease.onPressed, isNull);
  });
}

Future<void> _registerOwner(WidgetTester tester, String email) async {
  await _tapVisible(tester, find.byKey(const Key('register-link')));
  await _waitForVisible(tester, find.byKey(const Key('register-email')));
  await _enterVisible(tester, find.byKey(const Key('register-email')), email);
  await _enterVisible(
    tester,
    find.byKey(const Key('register-password')),
    'fixture-password',
  );
  await _tapVisible(tester, find.byKey(const Key('register-submit')));
  await _waitForVisible(tester, find.byKey(const Key('owner-ready-state')));
}

/// TextField 光标会让 macOS/live binding 持续产帧；回归只等待下一项用户可见契约。
Future<void> _waitForVisible(
  WidgetTester tester,
  Finder finder, {
  int maxFrames = 80,
}) async {
  for (var frame = 0; frame < maxFrames; frame += 1) {
    await tester.pump(const Duration(milliseconds: 50));
    if (finder.evaluate().isNotEmpty) return;
  }
  expect(finder, findsOneWidget);
}

Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  await _waitForVisible(tester, finder);
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
}

Future<void> _enterVisible(
  WidgetTester tester,
  Finder finder,
  String value,
) async {
  await _waitForVisible(tester, finder);
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.enterText(finder, value);
}
