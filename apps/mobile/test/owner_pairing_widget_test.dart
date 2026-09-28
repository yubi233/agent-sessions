// OWN-01..04（ADR-017 owner 配对加入）widget 契约：
//   - 连接页提供「配对到已有 Relay」入口（未认证可达）；
//   - 配对页生成请求后展示比对码，fixture 批准后领取令牌进入主页；
//   - 配对页 owner 请求渲染比对码，批准需二次确认。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:agent_sessions_mobile/domain/models.dart';

import 'support/app_harness.dart';
import 'support/pairing_scanner_fixture.dart';

Future<MobileAppHarness> _pumpConnect(WidgetTester tester) async {
  final harness = MobileAppHarness();
  await tester.pumpWidget(harness.build());
  // 等待 booting 阶段收敛到连接页（app 初始化含真实 provider 图构建）。
  await _waitForVisible(tester, find.byKey(const Key('device-connect-submit')));
  return harness;
}

Future<void> _waitForVisible(
  WidgetTester tester,
  Finder finder, {
  int maxFrames = 120,
}) async {
  for (var frame = 0; frame < maxFrames; frame += 1) {
    await tester.pump(const Duration(milliseconds: 50));
    if (finder.evaluate().isNotEmpty) {
      return;
    }
  }
  expect(finder, findsOneWidget);
}

void main() {
  testWidgets('连接页提供「配对到已有 Relay」入口并跳转配对页', (tester) async {
    tester.view.physicalSize = const Size(900, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await _pumpConnect(tester);
    expect(find.byKey(const Key('owner-pairing-link')), findsOneWidget);
    await tester.tap(find.byKey(const Key('owner-pairing-link')));
    await _waitForVisible(
      tester,
      find.byKey(const Key('owner-pairing-create')),
    );
  });

  testWidgets('配对页：生成请求展示比对码，批准后领取令牌进入主页', (tester) async {
    tester.view.physicalSize = const Size(900, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await _pumpConnect(tester);
    await tester.tap(find.byKey(const Key('owner-pairing-link')));
    await _waitForVisible(
      tester,
      find.byKey(const Key('owner-pairing-display-name')),
    );
    await tester.enterText(
      find.byKey(const Key('owner-pairing-display-name')),
      '第二台测试机',
    );
    await tester.tap(find.byKey(const Key('owner-pairing-create')));
    // 比对码展示（fixture 固定 123456）。
    await _waitForVisible(
      tester,
      find.byKey(const Key('owner-pairing-compare-code')),
    );
    expect(find.text('123456'), findsOneWidget);

    // fixture 第二次轮询视为已批准 → 领取令牌 → 认证态（自动进主页）。
    await _waitForVisible(
      tester,
      find.byKey(const Key('session-home-screen')),
      maxFrames: 240,
    );
  });

  testWidgets('配对页 owner 请求渲染比对码，批准需二次确认', (tester) async {
    // 与 w1_auth 同法约束手机画布：宽 surface 下 trailing 按钮可能被挤压出命中区。
    tester.view.physicalSize = const Size(900, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final harness = MobileAppHarness(
      scannerBuilder: buildPairingScannerFixture,
    );
    await tester.pumpWidget(harness.build());
    // 未认证态无法进入配对页：先初始化 owner（harness 免登录首 owner）。
    await _waitForVisible(
      tester,
      find.byKey(const Key('device-connect-submit')),
    );
    await tester.tap(find.byKey(const Key('device-connect-submit')));
    await _waitForVisible(
      tester,
      find.byKey(const Key('session-home-screen')),
    );

    // 生成一个 owner 角色的配对请求（模拟另一台新设备发起）。
    final pairing = await harness.relay.createPairing(
      PairingRequestInput(
        role: DeviceRole.androidOwner,
        displayName: '新加入的测试手机',
        platform: 'android',
        keys: const DeviceRegistrationMaterial(
          identityPublicKey: 'join-identity',
          encryptionPublicKey: 'join-encryption',
        ),
      ),
    );
    // 直达配对页（命令面板条目在小屏 surface 可能需滚动，URL 直达更稳）。
    final homeContext = tester.element(
      find.byKey(const Key('session-home-screen')),
    );
    GoRouter.of(homeContext).go('/pairing');
    await _waitForVisible(
      tester,
      find.byKey(const Key('pairing-request-id')),
    );
    await tester.enterText(
      find.byKey(const Key('pairing-request-id')),
      pairing.id,
    );
    await tester.tap(find.byKey(const Key('pairing-load-button')));
    await _waitForVisible(
      tester,
      find.textContaining('比对码'),
    );

    // 批准需要二次确认。按钮可能需滚动到位后再点（列表页在手机 surface 上
    // 超出一屏，直接 tap 会 miss）。
    final approveFinder = find.byKey(Key('pairing-approve-${pairing.id}'));
    await tester.ensureVisible(approveFinder);
    await tester.pump();
    await tester.tap(approveFinder, warnIfMissed: false);
    await _waitForVisible(
      tester,
      find.byKey(const Key('pairing-owner-confirm-dialog')),
    );
  });
}
