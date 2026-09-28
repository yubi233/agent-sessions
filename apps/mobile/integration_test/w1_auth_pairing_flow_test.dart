import 'package:agent_sessions_mobile/domain/models.dart';
import 'package:agent_sessions_mobile/main.dart' show macBookPhoneLogicalSize;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/support/app_harness.dart';
import '../test/support/pairing_scanner_fixture.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('MOBILE-01 PAIR-01 PAIR-02 PAIR-03：免登录设备初始化、QR 批准与撤销', (
    tester,
  ) async {
    // 使用 integration binding 的官方 surface API 同时约束布局和输入坐标，
    // 不让桌面宿主宽度把手机内容轨道居中到 480px 测试面之外。
    await binding.setSurfaceSize(macBookPhoneLogicalSize);
    addTearDown(() => binding.setSurfaceSize(null));

    final harness = MobileAppHarness(
      scannerBuilder: buildPairingScannerFixture,
    );
    await tester.pumpWidget(harness.build());
    expect(
      tester.getSize(find.byKey(const Key('mobile-page-shell'))),
      macBookPhoneLogicalSize,
    );
    await _waitForVisible(
      tester,
      find.byKey(const Key('device-connect-submit')),
    );
    expect(find.byKey(const Key('login-email')), findsNothing);
    expect(find.byKey(const Key('register-email')), findsNothing);
    debugPrint('[MOBILE-01] device connect ready');

    await _tapVisible(tester, find.byKey(const Key('device-connect-submit')));
    // v0.8.1 起 router 在认证成功后把 /connect 重定向到 /home（DSH 工作区主页），
    // W1 时期的 owner-ready 中间页不再停留（owner 就绪状态由主页"安全与设备"
    // 区块承载）；配对/设备入口同在主页列表，_tapVisible 会滚动到位。
    // （2026-09-28 真机 gate 归因：旧断言在当前路由下必然超时——diag 截图实证
    // tap 后已进入 DSH 主页。）
    await _waitForVisible(tester, find.byKey(const Key('session-home-screen')));
    debugPrint('[MOBILE-01] owner ready');

    final pairing = await harness.relay.createPairing(
      const PairingRequestInput(
        role: DeviceRole.terminal,
        displayName: 'macOS Fixture Terminal',
        platform: 'linux',
        keys: DeviceRegistrationMaterial(
          identityPublicKey: 'macos-terminal-identity',
          encryptionPublicKey: 'macos-terminal-encryption',
        ),
      ),
    );
    // v0.8.1 起配对入口经命令面板（主页 appbar）→ /pairing；HomeScreen 的
    // pairing-page-link 已随首页改造下线（不在任何路由）。
    await _tapVisible(
      tester,
      find.byKey(const Key('session-command-palette-button')),
    );
    await _waitForVisible(
      tester,
      find.byKey(const Key('command-palette-screen')),
    );
    await _tapVisible(tester, find.text('配对'));
    await _waitForVisible(
      tester,
      find.byKey(const Key('pairing-scan-open-button')),
    );
    await _tapVisible(
      tester,
      find.byKey(const Key('pairing-scan-open-button')),
    );
    await _waitForVisible(
      tester,
      find.byKey(const Key('fixture-scanner-payload')),
    );
    await _enterTextVisible(
      tester,
      find.byKey(const Key('fixture-scanner-payload')),
      PairingPayload.encode(pairing.id),
    );
    await _tapVisible(
      tester,
      find.byKey(const Key('fixture-scanner-detect-button')),
    );
    await _waitForVisible(
      tester,
      find.byKey(Key('pairing-request-${pairing.id}')),
    );

    // 本地桌面回归中同时保留手动输入契约，确保相机不可用时流程仍可继续。
    await _enterTextVisible(
      tester,
      find.byKey(const Key('pairing-request-id')),
      PairingPayload.encode(pairing.id),
    );
    await _tapVisible(tester, find.byKey(const Key('pairing-load-button')));
    await _waitForVisible(
      tester,
      find.byKey(Key('pairing-qr-image-${pairing.id}')),
    );
    expect(find.byKey(Key('pairing-qr-image-${pairing.id}')), findsOneWidget);
    expect(find.byKey(Key('pairing-qr-payload-${pairing.id}')), findsOneWidget);
    debugPrint('[MOBILE-01] pairing request loaded');
    await _tapVisible(tester, find.byKey(Key('pairing-approve-${pairing.id}')));
    await _waitForVisible(tester, find.textContaining('approved'));
    debugPrint('[MOBILE-01] pairing approved');
    await _tapVisible(tester, find.byKey(const Key('back-home-button')));
    await _waitForVisible(tester, find.byKey(const Key('session-home-screen')));
    await _tapVisible(
      tester,
      find.byKey(const Key('session-command-palette-button')),
    );
    await _waitForVisible(
      tester,
      find.byKey(const Key('command-palette-screen')),
    );
    await _tapVisible(tester, find.text('设备'));
    await _waitForVisible(tester, find.text('设备管理'));
    final deviceId = 'device-${pairing.id}';
    await _waitForVisible(tester, find.byKey(Key('device-revoke-$deviceId')));
    debugPrint('[MOBILE-01] device revoke control ready');
    await _tapVisible(tester, find.byKey(Key('device-revoke-$deviceId')));
    await _waitForVisible(tester, find.textContaining('revoked'));
    expect(find.textContaining('revoked'), findsOneWidget);
    debugPrint('[MOBILE-01] device revoked');
  });
}

/// macOS integration host 中 TextField 光标会持续产生 frame，不能用 pumpAndSettle 判断业务是否完成。
/// 这里只等待下一步用户可见控件，既保留有限超时，也避免把动画当成产品失败。
Future<void> _waitForVisible(
  WidgetTester tester,
  Finder finder, {
  int maxFrames = 80,
}) async {
  // 真机 Keystore 首次身份生成比模拟器/桌面宿主慢一个量级（2026-09-28 真机
  // gate 实测 80 帧=4s 窗口不够）；等待窗对齐初始化的真实耗时上界。
  for (var frame = 0; frame < maxFrames * 3; frame += 1) {
    await tester.pump(const Duration(milliseconds: 50));
    if (finder.evaluate().isNotEmpty) {
      return;
    }
  }
  expect(finder, findsOneWidget);
}

/// integration test 的 macOS surface 可能比内容轨道矮；每次操作前按真实移动端列表行为滚动到目标。
Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  await _waitForVisible(tester, finder);
  await tester.ensureVisible(finder);
  await _waitForTapTarget(tester, finder);
  await tester.tap(finder);
}

/// 路由动画中 finder 会先出现再移入手机画布；只推进有限 frame，避免 TextField 光标让 pumpAndSettle 永不返回。
Future<void> _waitForTapTarget(WidgetTester tester, Finder finder) async {
  for (var frame = 0; frame < 10; frame += 1) {
    await tester.pump(const Duration(milliseconds: 50));
    await tester.ensureVisible(finder);
    final center = tester.getRect(finder).center;
    if (center.dx >= 0 &&
        center.dx <= macBookPhoneLogicalSize.width &&
        center.dy >= 0 &&
        center.dy <= macBookPhoneLogicalSize.height) {
      return;
    }
  }

  final center = tester.getRect(finder).center;
  expect(center.dx, inInclusiveRange(0, macBookPhoneLogicalSize.width));
  expect(center.dy, inInclusiveRange(0, macBookPhoneLogicalSize.height));
}

/// 输入框同样需要先滚动到可命中的可见区域，避免测试绕过真实触控边界。
Future<void> _enterTextVisible(
  WidgetTester tester,
  Finder finder,
  String value,
) async {
  await _waitForVisible(tester, finder);
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.enterText(finder, value);
}
