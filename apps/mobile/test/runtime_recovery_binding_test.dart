import 'package:agent_sessions_mobile/app/providers.dart';
import 'package:agent_sessions_mobile/app/runtime_recovery_binding.dart';
import 'package:agent_sessions_mobile/relay/fixture_relay_repository.dart';
import 'package:agent_sessions_mobile/state/lifecycle_recovery_controller.dart';
import 'package:agent_sessions_mobile/state/session_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fixture_owner.dart';

const _ownerDeviceId = 'android-owner-fixture';
final _now = DateTime.utc(2026, 8, 14, 23, 0);

// V085-25 回归：桌面（macOS/Windows/Linux）窗口失焦产生 inactive/hidden，
// 进程仍完整前台运行——不得作废本地 lease，否则回前台自动重取 lease 触发
// Relay epoch 翻转，长回合会被自己的续期打死。移动端保留旧语义：
// 非 resumed 一律按后台处理。
void main() {
  Future<(FixtureRelayRepository, SessionController, SessionRecoveryController)>
      build() async {
    final relay = FixtureRelayRepository(clock: () => _now);
    await bootstrapFixtureOwner(relay);
    final sessions = SessionController(relay: relay, clock: () => _now);
    await sessions.initialize();
    await sessions.createSession(
      workspaceId: 'lifecycle-desktop-workspace',
      provider: 'codex',
      deviceId: _ownerDeviceId,
      canWrite: true,
    );
    await sessions.acquireSelectedLease(
      deviceId: _ownerDeviceId,
      canWrite: true,
    );
    final recovery = SessionRecoveryController(
      sessions: sessions,
      clock: () => _now,
    );
    return (relay, sessions, recovery);
  }

  Widget wrap(SessionRecoveryController recovery, {bool? desktopPlatform}) =>
      ProviderScope(
        overrides: [
          sessionRecoveryControllerProvider.overrideWith((ref) => recovery),
        ],
        child: RuntimeRecoveryBinding(
          desktopPlatformOverride: desktopPlatform,
          child: const SizedBox(),
        ),
      );

  testWidgets('macOS 窗口失焦（inactive/hidden）不作废本地 lease', (tester) async {
    final (relay, sessions, recovery) = await build();

    await tester.pumpWidget(wrap(recovery, desktopPlatform: true));
    await tester.pump();

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();

    expect(sessions.selectedLease, isNotNull);
  });

  testWidgets('Android inactive 仍按后台处理：lease 立即作废', (tester) async {
    final (relay, sessions, recovery) = await build();

    await tester.pumpWidget(wrap(recovery, desktopPlatform: false));
    await tester.pump();

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();

    expect(sessions.selectedLease, isNull);
  });
}
