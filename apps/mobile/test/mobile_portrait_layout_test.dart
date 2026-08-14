import 'package:agent_sessions_mobile/domain/models.dart';
import 'package:agent_sessions_mobile/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/app_harness.dart';

void main() {
  testWidgets('MOBILE-01：macOS 受限窗口仍以 480x960 手机逻辑画布渲染', (tester) async {
    await tester.binding.setSurfaceSize(const Size(480, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    Size? logicalSize;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: const MediaQueryData(size: Size(480, 800)),
          child: MacBookPhoneCanvas(
            child: Builder(
              builder: (context) {
                logicalSize = MediaQuery.sizeOf(context);
                return const SizedBox.expand(
                  key: Key('macos-phone-logical-content'),
                );
              },
            ),
          ),
        ),
      ),
    );

    expect(logicalSize, macBookPhoneLogicalSize);
    expect(
      tester.getSize(find.byKey(const Key('macos-phone-canvas'))),
      const Size(400, 800),
    );
    expect(
      tester
          .getRect(find.byKey(const Key('macos-phone-logical-content')))
          .height,
      closeTo(800, 0.1),
    );
  });

  testWidgets('MOBILE-01：480x960 竖屏保持 Happy 风格控制端层级与主操作尺寸', (tester) async {
    await tester.binding.setSurfaceSize(const Size(480, 960));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final harness = MobileAppHarness();
    await tester.pumpWidget(harness.build());
    await tester.pumpAndSettle();

    expect(
      tester.getSize(find.byKey(const Key('mobile-page-shell'))),
      const Size(480, 960),
    );
    expect(find.byKey(const Key('mobile-header-title')), findsOneWidget);
    expect(find.byKey(const Key('mobile-header-status')), findsOneWidget);
    expect(find.byKey(const Key('mobile-content-rail')), findsOneWidget);
    expect(find.byKey(const Key('mobile-auth-intro')), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const Key('login-submit'))).height,
      greaterThanOrEqualTo(52),
    );

    await _registerOwner(tester, 'portrait-layout@fixture.test');

    // owner 成功后的状态和操作仍在手机竖屏内容轨道内，不能因视觉重构丢失关键入口。
    expect(find.byKey(const Key('mobile-control-status')), findsOneWidget);
    expect(find.byKey(const Key('owner-ready-state')), findsOneWidget);
    expect(find.byKey(const Key('pairing-page-link')), findsOneWidget);
  });

  testWidgets('PAIR-01：480px 竖屏将 QR 详情和批准操作约束在同一移动端请求块内', (tester) async {
    await tester.binding.setSurfaceSize(const Size(480, 960));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final harness = MobileAppHarness();
    await tester.pumpWidget(harness.build());
    await tester.pumpAndSettle();
    await _registerOwner(tester, 'portrait-pairing@fixture.test');

    final request = await harness.relay.createPairing(
      const PairingRequestInput(
        role: DeviceRole.terminal,
        displayName: 'Portrait Fixture Terminal',
        platform: 'macos',
        keys: DeviceRegistrationMaterial(
          identityPublicKey: 'portrait-terminal-identity',
          encryptionPublicKey: 'portrait-terminal-encryption',
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('pairing-page-link')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('pairing-request-id')),
      PairingPayload.encode(request.id),
    );
    await tester.tap(find.byKey(const Key('pairing-load-button')));
    await tester.pumpAndSettle();

    final requestBlock = find.byKey(Key('pairing-request-${request.id}'));
    expect(requestBlock, findsOneWidget);
    expect(find.byKey(Key('pairing-qr-image-${request.id}')), findsOneWidget);
    expect(find.byKey(Key('pairing-cancel-${request.id}')), findsOneWidget);
    expect(find.byKey(Key('pairing-approve-${request.id}')), findsOneWidget);
    expect(tester.getRect(requestBlock).right, lessThanOrEqualTo(480));
    expect(
      tester.getSize(find.byKey(Key('pairing-approve-${request.id}'))).width,
      lessThan(240),
    );
    expect(tester.takeException(), isNull);
  });
}

Future<void> _registerOwner(WidgetTester tester, String email) async {
  await tester.tap(find.byKey(const Key('register-link')));
  await tester.pumpAndSettle();
  await tester.enterText(find.byKey(const Key('register-email')), email);
  await tester.enterText(
    find.byKey(const Key('register-password')),
    'test-password',
  );
  await tester.tap(find.byKey(const Key('register-submit')));
  await tester.pumpAndSettle();
  expect(find.byKey(const Key('owner-ready-state')), findsOneWidget);
}
