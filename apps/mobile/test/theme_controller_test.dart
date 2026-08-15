import 'package:agent_sessions_mobile/app/theme_controller.dart';
import 'package:agent_sessions_mobile/storage/theme_preference_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('MOBILE-15：外观偏好按设备持久化且不包含账户数据', () async {
    final store = InMemoryThemePreferenceStore();
    final controller = ThemeController(store);
    await controller.initialize();

    expect(controller.mode, ThemePreferenceMode.system);
    expect(controller.materialThemeMode, ThemeMode.system);

    await controller.setMode(ThemePreferenceMode.dark);
    await controller.setAccent(AppAccent.mint);

    final restored = ThemeController(store);
    await restored.initialize();
    expect(restored.mode, ThemePreferenceMode.dark);
    expect(restored.accent, AppAccent.mint);
    expect(restored.materialThemeMode, ThemeMode.dark);

    controller.dispose();
    restored.dispose();
  });

  test('MOBILE-15：损坏的本机偏好安全回退到系统主题', () {
    expect(
      () => ThemePreferences.decode('{"mode":"unknown","accent":"ocean"}'),
      throwsFormatException,
    );
  });
}
