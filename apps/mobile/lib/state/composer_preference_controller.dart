import 'package:flutter/foundation.dart';

import '../domain/composer_preferences.dart';
import '../storage/composer_preference_store.dart';

/// v0.5/P5：Composer 用户级偏好控制器（Enter Queue/Steer 等）。
///
/// 与 ThemeController 同构：只读写本机非敏感偏好，不触发 Relay / 会话命令。
/// composer 与设置页共享同一个 [composerPreferenceControllerProvider] 事实来源。
class ComposerPreferenceController extends ChangeNotifier {
  ComposerPreferenceController(this._store);

  final ComposerPreferenceStore _store;
  ComposerPreferences _preferences = ComposerPreferences.defaults;
  Future<void>? _initialization;
  Future<void> _writeTail = Future<void>.value();
  bool _isReady = false;
  String? _persistenceError;

  ComposerPreferences get preferences => _preferences;
  ComposerEnterBehavior get enterBehavior => _preferences.enterBehavior;
  bool get isReady => _isReady;
  String? get persistenceError => _persistenceError;

  Future<void> initialize() => _initialization ??= _load();

  Future<void> _load() async {
    try {
      _preferences = await _store.read();
    } catch (_) {
      // Enter 偏好损坏不影响认证和会话控制，安全回退为默认 Queue。
      _preferences = ComposerPreferences.defaults;
      _persistenceError = '输入偏好暂时无法读取，已使用默认「排队」。';
    }
    _isReady = true;
    notifyListeners();
  }

  Future<void> setEnterBehavior(ComposerEnterBehavior value) =>
      _persist(_preferences.copyWith(enterBehavior: value));

  Future<void> _persist(ComposerPreferences next) async {
    if (next == _preferences) return;
    _preferences = next;
    _persistenceError = null;
    notifyListeners();

    // 顺序写入，避免快速切换时旧异步写覆盖最后一次选择。
    final write = _writeTail.then<void>(
      (_) => _store.write(next),
      onError: (_) => _store.write(next),
    );
    _writeTail = write;
    try {
      await write;
    } catch (_) {
      if (_preferences == next) {
        _persistenceError = '输入偏好暂时无法保存，本次会话仍会保留当前选择。';
        notifyListeners();
      }
    }
  }
}
