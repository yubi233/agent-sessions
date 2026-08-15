import 'package:flutter/material.dart';

import '../storage/theme_preference_store.dart';

/// 外观状态独立于账户控制器，切换主题绝不会刷新会话、租约或认证状态。
class ThemeController extends ChangeNotifier {
  ThemeController(this._store);

  final ThemePreferenceStore _store;
  ThemePreferences _preferences = ThemePreferences.defaults;
  Future<void>? _initialization;
  Future<void> _writeTail = Future<void>.value();
  bool _isReady = false;
  String? _persistenceError;

  ThemePreferences get preferences => _preferences;
  ThemePreferenceMode get mode => _preferences.mode;
  AppAccent get accent => _preferences.accent;
  bool get isReady => _isReady;
  String? get persistenceError => _persistenceError;

  ThemeMode get materialThemeMode => switch (mode) {
    ThemePreferenceMode.system => ThemeMode.system,
    ThemePreferenceMode.light => ThemeMode.light,
    ThemePreferenceMode.dark => ThemeMode.dark,
  };

  Future<void> initialize() => _initialization ??= _load();

  Future<void> _load() async {
    try {
      _preferences = await _store.read();
    } catch (_) {
      // 外观存储损坏不影响认证和会话控制，安全回退为系统主题。
      _preferences = ThemePreferences.defaults;
      _persistenceError = '外观偏好暂时无法读取，已改为跟随系统。';
    }
    _isReady = true;
    notifyListeners();
  }

  Future<void> setMode(ThemePreferenceMode value) =>
      _persist(_preferences.copyWith(mode: value));

  Future<void> setAccent(AppAccent value) =>
      _persist(_preferences.copyWith(accent: value));

  Future<void> _persist(ThemePreferences next) async {
    if (next == _preferences) return;
    _preferences = next;
    _persistenceError = null;
    notifyListeners();

    // 顺序写入，避免用户快速切换时旧的异步写覆盖最后一次选择。
    final write = _writeTail.then<void>(
      (_) => _store.write(next),
      onError: (_) => _store.write(next),
    );
    _writeTail = write;
    try {
      await write;
    } catch (_) {
      if (_preferences == next) {
        _persistenceError = '外观偏好暂时无法保存，本次会话仍会保留当前显示。';
        notifyListeners();
      }
    }
  }
}
