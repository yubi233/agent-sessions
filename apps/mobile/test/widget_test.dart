import 'package:agent_sessions_mobile/app/router.dart';
import 'package:agent_sessions_mobile/domain/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/app_harness.dart';
import 'support/pairing_scanner_fixture.dart';

void main() {
  testWidgets('MOBILE-01：Android 免登录初始化 owner，主路径不出现账号表单', (tester) async {
    final harness = MobileAppHarness();
    await tester.pumpWidget(harness.build());
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('device-connect-submit')), findsOneWidget);
    expect(find.byKey(const Key('login-email')), findsNothing);
    expect(find.byKey(const Key('login-password')), findsNothing);
    expect(find.byKey(const Key('register-email')), findsNothing);
    expect(find.byKey(const Key('register-password')), findsNothing);

    await tester.tap(find.byKey(const Key('device-connect-submit')));
    await tester.pumpAndSettle();

    // v0.8.1+：控制端 owner 初始化完成后进入 DSH 工作区首页。
    expect(find.byKey(const Key('session-home-screen')), findsOneWidget);
    expect(find.byKey(const Key('mobile-header-title')), findsOneWidget);

    await tester.tap(find.byKey(const Key('signout-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('device-connect-submit')), findsOneWidget);
    expect(find.byKey(const Key('login-submit')), findsNothing);
  });

  testWidgets('MOBILE-01：owner 恢复码只在当前页展示，确认后立即清除', (tester) async {
    final harness = MobileAppHarness();
    await harness.launchAsOwner();
    await tester.pumpWidget(harness.build());
    await _waitForVisible(tester, find.byKey(const Key('session-home-screen')));
    await _registerOwner(tester, 'recovery-code-owner@fixture.test');

    await _goToRoute(
      tester,
      '/recovery-code',
      routeKey: const Key('recovery-code-back-button'),
    );
    expect(
      find.byKey(const Key('recovery-code-generate-button')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('recovery-code-generate-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('recovery-code-value')), findsOneWidget);
    expect(
      find.byKey(const Key('recovery-code-dismiss-button')),
      findsOneWidget,
    );

    // 确认后返回控制端，再进入同一路由必须重新生成，不能复用内存外的旧明文。
    await tester.tap(find.byKey(const Key('recovery-code-dismiss-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('recovery-code-value')), findsNothing);
    expect(find.byKey(const Key('session-home-screen')), findsOneWidget);
    await _goToRoute(
      tester,
      '/recovery-code',
      routeKey: const Key('recovery-code-back-button'),
    );
    expect(
      find.byKey(const Key('recovery-code-generate-button')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('recovery-code-value')), findsNothing);
  });

  testWidgets('PAIR-01..03：owner 读取 QR payload、批准并撤销终端设备', (tester) async {
    final harness = MobileAppHarness();
    await harness.launchAsOwner();
    await tester.pumpWidget(harness.build());
    await _waitForVisible(tester, find.byKey(const Key('session-home-screen')));

    await _registerOwner(tester, 'pairing@fixture.test');

    final request = await harness.relay.createPairing(
      const PairingRequestInput(
        role: DeviceRole.terminal,
        displayName: 'Fixture Terminal',
        platform: 'linux',
        keys: DeviceRegistrationMaterial(
          identityPublicKey: 'terminal-id-public',
          encryptionPublicKey: 'terminal-encryption-public',
        ),
      ),
    );
    await _goToRoute(
      tester,
      '/pairing',
      routeKey: const Key('pairing-request-id'),
    );
    await tester.enterText(
      find.byKey(const Key('pairing-request-id')),
      PairingPayload.encode(request.id),
    );
    await tester.tap(find.byKey(const Key('pairing-load-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(Key('pairing-qr-image-${request.id}')), findsOneWidget);
    expect(find.byKey(Key('pairing-short-code-${request.id}')), findsOneWidget);
    await tester.tap(find.byKey(Key('pairing-approve-${request.id}')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('back-home-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('session-home-screen')), findsOneWidget);
    await _goToRoute(
      tester,
      '/devices',
      // owner 设备恒存在，且该 key 只在设备管理页出现（pairing 页同用 back-home-button）。
      routeKey: const Key('device-android-owner-fixture'),
    );
    // fixture 设备 id 已带 device- 前缀，列表 tile 再加一层前缀（见 _DeviceTile）。
    final deviceId = 'device-${request.id}';
    expect(find.byKey(Key('device-$deviceId')), findsOneWidget);
    await tester.tap(find.byKey(Key('device-revoke-$deviceId')));
    await tester.pumpAndSettle();
    expect(find.textContaining('revoked'), findsOneWidget);
  });

  testWidgets('PAIR-01：有效相机扫描回填 payload 并自动读取配对请求', (tester) async {
    final harness = MobileAppHarness(
      scannerBuilder: buildPairingScannerFixture,
    );
    await harness.launchAsOwner();
    await tester.pumpWidget(harness.build());
    await _waitForVisible(tester, find.byKey(const Key('session-home-screen')));
    await _registerOwner(tester, 'scanner@fixture.test');

    final request = await harness.relay.createPairing(
      const PairingRequestInput(
        role: DeviceRole.terminal,
        displayName: 'Camera Fixture Terminal',
        platform: 'linux',
        keys: DeviceRegistrationMaterial(
          identityPublicKey: 'camera-terminal-identity',
          encryptionPublicKey: 'camera-terminal-encryption',
        ),
      ),
    );
    await _goToRoute(
      tester,
      '/pairing',
      routeKey: const Key('pairing-request-id'),
    );
    await tester.tap(find.byKey(const Key('pairing-scan-open-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('fixture-scanner-payload')), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('fixture-scanner-payload')),
      PairingPayload.encode(request.id),
    );
    await tester.tap(find.byKey(const Key('fixture-scanner-detect-button')));
    await tester.pumpAndSettle();

    final requestInput = tester.widget<TextField>(
      find.byKey(const Key('pairing-request-id')),
    );
    expect(requestInput.controller!.text, PairingPayload.encode(request.id));
    expect(find.byKey(Key('pairing-request-${request.id}')), findsOneWidget);
  });

  testWidgets('PAIR-01：无效扫码内容不会离开扫码页或请求 Relay', (tester) async {
    final harness = MobileAppHarness(
      scannerBuilder: buildPairingScannerFixture,
    );
    await harness.launchAsOwner();
    await tester.pumpWidget(harness.build());
    await _waitForVisible(tester, find.byKey(const Key('session-home-screen')));
    await _registerOwner(tester, 'invalid-scan@fixture.test');
    await _goToRoute(
      tester,
      '/pairing',
      routeKey: const Key('pairing-request-id'),
    );
    await tester.tap(find.byKey(const Key('pairing-scan-open-button')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('fixture-scanner-payload')),
      'https://untrusted.example/not-a-pairing-request',
    );
    await tester.tap(find.byKey(const Key('fixture-scanner-detect-button')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('pairing-scanner-invalid-payload')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('pairing-scanner-screen')), findsOneWidget);
  });

  testWidgets('PAIR-01：相机权限失败后回退到手动输入', (tester) async {
    final harness = MobileAppHarness(
      scannerBuilder: buildPairingScannerFixture,
    );
    await harness.launchAsOwner();
    await tester.pumpWidget(harness.build());
    await _waitForVisible(tester, find.byKey(const Key('session-home-screen')));
    await _registerOwner(tester, 'fallback@fixture.test');

    final request = await harness.relay.createPairing(
      const PairingRequestInput(
        role: DeviceRole.terminal,
        displayName: 'Manual Fallback Terminal',
        platform: 'linux',
        keys: DeviceRegistrationMaterial(
          identityPublicKey: 'fallback-terminal-identity',
          encryptionPublicKey: 'fallback-terminal-encryption',
        ),
      ),
    );
    await _goToRoute(
      tester,
      '/pairing',
      routeKey: const Key('pairing-request-id'),
    );
    await tester.tap(find.byKey(const Key('pairing-scan-open-button')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('fixture-scanner-unavailable-button')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('pairing-scanner-fallback-message')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const Key('pairing-scanner-manual-fallback-button')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('pairing-request-id')),
      PairingPayload.encode(request.id),
    );
    await tester.tap(find.byKey(const Key('pairing-load-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(Key('pairing-request-${request.id}')), findsOneWidget);
  });

  testWidgets('MOBILE-01：恢复码不要求邮箱并恢复已绑定 owner', (tester) async {
    final harness = MobileAppHarness();
    await tester.pumpWidget(harness.build());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('recovery-link')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('recovery-email')), findsNothing);
    await tester.enterText(
      find.byKey(const Key('recovery-code')),
      'RECOVERY-FIXTURE-0001',
    );
    await tester.tap(find.byKey(const Key('recovery-submit')));
    await tester.pumpAndSettle();

    // v0.8.1+：恢复码接管 owner 成功后进入 DSH 工作区首页。
    expect(find.byKey(const Key('session-home-screen')), findsOneWidget);
  });
}

/// 经 router 直达路由（v0.8.1+ 控制端入口从首页卡片收敛到 router/设置）。
/// [routeKey] 为落地页的稳定元素 key，避免在路由过渡帧过早返回。
Future<void> _goToRoute(
  WidgetTester tester,
  String route, {
  required Key routeKey,
}) async {
  final container = ProviderScope.containerOf(
    tester.element(find.byKey(const Key('session-home-screen'))),
  );
  container.read(appRouterProvider).go(route);
  await _waitForVisible(tester, find.byKey(const Key('mobile-page-shell')));
  // 等路由目标页自身的稳定元素出现（shell 在过渡帧可能已匹配）。
  await _waitForVisible(tester, find.byKey(routeKey));
}

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

/// v0.8.1+：owner 初始化已由 launchAsOwner 预置；等 DSH 首页出现。
Future<void> _registerOwner(WidgetTester tester, String _) async {
  await _waitForVisible(tester, find.byKey(const Key('session-home-screen')));
}
