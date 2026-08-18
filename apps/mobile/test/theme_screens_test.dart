import 'package:agent_sessions_mobile/storage/theme_preference_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/app_harness.dart';

void main() {
  testWidgets('MOBILE-15：外观菜单切换主题和强调色并保留稳定 Key', (tester) async {
    final harness = MobileAppHarness();
    await tester.pumpWidget(harness.build());
    await tester.pumpAndSettle();

    expect(_app(tester).themeMode, ThemeMode.system);
    await tester.tap(find.byKey(const Key('appearance-menu-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('appearance-mode-light')));
    await tester.pumpAndSettle();
    expect(_app(tester).themeMode, ThemeMode.light);

    await tester.tap(find.byKey(const Key('appearance-menu-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('appearance-accent-mint')));
    await tester.pumpAndSettle();

    final saved = await harness.appearance.read();
    expect(
      saved,
      const ThemePreferences(
        mode: ThemePreferenceMode.light,
        accent: AppAccent.mint,
      ),
    );
    expect(find.byKey(const Key('mobile-page-shell')), findsOneWidget);
    expect(find.byKey(const Key('device-connect-submit')), findsOneWidget);
  });

  testWidgets('MOBILE-26：系统深色和大字号下连接页不抛出布局异常', (tester) async {
    tester.binding.platformDispatcher.platformBrightnessTestValue =
        Brightness.dark;
    addTearDown(
      tester.binding.platformDispatcher.clearPlatformBrightnessTestValue,
    );
    await tester.binding.setSurfaceSize(const Size(320, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          platformBrightness: Brightness.dark,
          textScaler: TextScaler.linear(2),
          disableAnimations: true,
        ),
        child: MobileAppHarness().build(),
      ),
    );
    await tester.pumpAndSettle();

    final context = tester.element(find.byKey(const Key('mobile-page-shell')));
    expect(Theme.of(context).brightness, Brightness.dark);
    expect(MediaQuery.of(context).disableAnimations, isTrue);
    expect(find.byKey(const Key('device-connect-submit')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

MaterialApp _app(WidgetTester tester) =>
    tester.widget<MaterialApp>(find.byType(MaterialApp));
