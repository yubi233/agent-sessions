import 'package:agent_sessions_mobile/domain/composer_preferences.dart';
import 'package:agent_sessions_mobile/state/composer_preference_controller.dart';
import 'package:agent_sessions_mobile/storage/composer_preference_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// MOBILE-V05-21 单元层：busy Enter 偏好（Queue/Steer）持久化与控制器。
///
/// 对应《迭代计划v0.5.md》：
/// - busy Enter 偏好是用户级设置项，默认 Queue，可切换 Queue / Steer；
/// - composer 与设置页读取同一个用户级事实来源。
void main() {
  test('默认 enterBehavior 为 Queue', () {
    expect(
      ComposerPreferences.defaults.enterBehavior,
      ComposerEnterBehavior.queue,
    );
  });

  test('encode/decode 往返保持选择', () {
    const prefs = ComposerPreferences(
      enterBehavior: ComposerEnterBehavior.steer,
    );
    final decoded = ComposerPreferences.decode(prefs.encode());
    expect(decoded, prefs);
  });

  test('损坏的持久化数据 decode 抛 FormatException', () {
    expect(() => ComposerPreferences.decode('[1,2]'), throwsFormatException);
    expect(
      () => ComposerPreferences.decode('{"enterBehavior":"unknown"}'),
      throwsFormatException,
    );
  });

  test('InMemory 存储 read/write 往返', () async {
    final store = InMemoryComposerPreferenceStore();
    expect((await store.read()).enterBehavior, ComposerEnterBehavior.queue);
    await store.write(
      const ComposerPreferences(enterBehavior: ComposerEnterBehavior.steer),
    );
    expect((await store.read()).enterBehavior, ComposerEnterBehavior.steer);
    await store.clear();
    expect((await store.read()).enterBehavior, ComposerEnterBehavior.queue);
  });

  test('controller 初始化读取写入值并支持切换 + 持久化', () async {
    final store = InMemoryComposerPreferenceStore();
    final controller = ComposerPreferenceController(store);
    await controller.initialize();
    expect(controller.enterBehavior, ComposerEnterBehavior.queue);
    expect(controller.persistenceError, isNull);

    await controller.setEnterBehavior(ComposerEnterBehavior.steer);
    expect(controller.enterBehavior, ComposerEnterBehavior.steer);
    // 切换已写入持久化存储；新建 controller（同一 store）重读仍为 steer。
    expect((await store.read()).enterBehavior, ComposerEnterBehavior.steer);
    final reloaded = ComposerPreferenceController(store);
    await reloaded.initialize();
    expect(reloaded.enterBehavior, ComposerEnterBehavior.steer);
  });
}
