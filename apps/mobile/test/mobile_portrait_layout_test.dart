import 'package:agent_sessions_mobile/app/router.dart';
import 'package:agent_sessions_mobile/domain/models.dart';
import 'package:agent_sessions_mobile/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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

  testWidgets('MOBILE-01：480x960 竖屏保持连接页主操作尺寸与 DSH 首页轨道', (tester) async {
    await tester.binding.setSurfaceSize(const Size(480, 960));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final harness = MobileAppHarness();
    await tester.pumpWidget(harness.build());
    await tester.pumpAndSettle();

    // 未认证：竖屏连接页保持主操作尺寸与内容轨道。
    expect(
      tester.getSize(find.byKey(const Key('mobile-page-shell'))),
      const Size(480, 960),
    );
    expect(find.byKey(const Key('mobile-header-title')), findsOneWidget);
    expect(find.byKey(const Key('mobile-header-status')), findsOneWidget);
    expect(find.byKey(const Key('mobile-content-rail')), findsOneWidget);
    expect(find.byKey(const Key('mobile-auth-intro')), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const Key('device-connect-submit'))).height,
      greaterThanOrEqualTo(52),
    );

    // v0.8.1+：owner 预置后以全新 harness 启动进入 DSH 工作区首页。
    await harness.launchAsOwner();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await tester.pumpWidget(harness.build());
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('session-home-screen')), findsOneWidget);
    expect(find.byKey(const Key('session-recent-button')), findsOneWidget);
    expect(find.byKey(const Key('mobile-header-title')), findsOneWidget);
  });

  testWidgets('PAIR-01：480px 竖屏将 QR 详情和批准操作约束在同一移动端请求块内', (tester) async {
    await tester.binding.setSurfaceSize(const Size(480, 960));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final harness = MobileAppHarness();
    await harness.launchAsOwner();
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
    await _goToRoute(tester, '/pairing');
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

/// 经 router 直达路由（v0.8.1+ 控制端入口从首页卡片收敛到 router/设置）。
Future<void> _goToRoute(WidgetTester tester, String route) async {
  final container = ProviderScope.containerOf(
    tester.element(find.byKey(const Key('session-home-screen'))),
  );
  container.read(appRouterProvider).go(route);
  for (var i = 0; i < 40; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    if (find.byKey(const Key('pairing-request-id')).evaluate().isNotEmpty ||
        find.byKey(const Key('session-home-screen')).evaluate().isNotEmpty) {
      break;
    }
  }
  await tester.pumpAndSettle();
}

/// v0.8.1+：owner 初始化已由 launchAsOwner 预置；等 DSH 首页出现。
Future<void> _registerOwner(WidgetTester tester, String _) async {
  for (var i = 0; i < 60; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    if (find.byKey(const Key('session-home-screen')).evaluate().isNotEmpty) {
      return;
    }
  }
  expect(find.byKey(const Key('session-home-screen')), findsOneWidget);
}
