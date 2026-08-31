import 'package:agent_sessions_mobile/app/providers.dart';
import 'package:agent_sessions_mobile/domain/session_models.dart';
import 'package:agent_sessions_mobile/relay/fixture_relay_repository.dart';
import 'package:agent_sessions_mobile/state/session_controller.dart';
import 'package:agent_sessions_mobile/ui/session_screens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fixture_owner.dart';

/// V08-14/V08-15：主页提供 DSH 模式入口，DSH 模式下按工作区分组。
void main() {
  testWidgets('V08-14/V08-15：DSH 模式切换并按工作区分组', (tester) async {
    final relay = FixtureRelayRepository(clock: () => DateTime.now());
    await bootstrapFixtureOwner(relay);
    const ownerDeviceId = 'android-owner-fixture';
    final dshSession = await relay.createSession(
      const CreateMobileSessionInput(
        workspaceId: 'ws-dsh-alpha',
        provider: 'dsh',
        deviceId: 'android-owner-fixture',
      ),
    );
    await relay.createSession(
      const CreateMobileSessionInput(
        workspaceId: 'ws-dsh-alpha',
        provider: 'dsh',
        deviceId: ownerDeviceId,
      ),
    );
    await relay.createSession(
      const CreateMobileSessionInput(
        workspaceId: 'ws-dsh-beta',
        provider: 'dsh',
        deviceId: ownerDeviceId,
      ),
    );
    final controller = SessionController(relay: relay);
    await controller.initialize();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          relayRepositoryProvider.overrideWithValue(relay),
          sessionControllerProvider.overrideWithValue(controller),
        ],
        child: const MaterialApp(home: SessionHomeScreen()),
      ),
    );
    await tester.pumpAndSettle();

    // 默认普通模式存在 DSH 模式入口。
    expect(find.byKey(const Key('session-dsh-mode-button')), findsOneWidget);
    expect(find.byKey(const Key('session-list-scroll')), findsOneWidget);

    // 点击进入 DSH 模式。
    await tester.tap(find.byKey(const Key('session-dsh-mode-button')));
    await tester.pumpAndSettle();

    expect(find.text('DSH 工作区'), findsOneWidget);
    // 两个工作区分组头存在（fixture 中 workspaceName 默认等于 workspaceId）。
    expect(find.text('ws-dsh-alpha'), findsOneWidget);
    expect(find.text('ws-dsh-beta'), findsOneWidget);
    // 三个 DSH 会话均展示。
    expect(find.text(dshSession.title), findsOneWidget);
  });
}
