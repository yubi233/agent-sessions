import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 外观偏好只属于当前设备，不包含账户、会话正文或任何密钥。
enum ThemePreferenceMode { system, light, dark }

/// 仅提供少量高对比 accent，避免把状态颜色误作品牌或权限语义。
enum AppAccent { ocean, mint, berry }

extension AppAccentLabel on AppAccent {
  String get label => switch (this) {
    AppAccent.ocean => '海蓝',
    AppAccent.mint => '薄荷',
    AppAccent.berry => '莓红',
  };
}

class ThemePreferences {
  const ThemePreferences({
    this.mode = ThemePreferenceMode.system,
    this.accent = AppAccent.ocean,
  });

  static const defaults = ThemePreferences();

  final ThemePreferenceMode mode;
  final AppAccent accent;

  ThemePreferences copyWith({ThemePreferenceMode? mode, AppAccent? accent}) =>
      ThemePreferences(mode: mode ?? this.mode, accent: accent ?? this.accent);

  String encode() =>
      jsonEncode(<String, String>{'mode': mode.name, 'accent': accent.name});

  factory ThemePreferences.decode(String encoded) {
    final value = jsonDecode(encoded);
    if (value is! Map) {
      throw const FormatException('appearance preference must be an object');
    }
    final modeName = value['mode'];
    final accentName = value['accent'];
    if (modeName is! String || accentName is! String) {
      throw const FormatException('appearance preference is incomplete');
    }
    try {
      return ThemePreferences(
        mode: ThemePreferenceMode.values.byName(modeName),
        accent: AppAccent.values.byName(accentName),
      );
    } on ArgumentError {
      throw const FormatException('appearance preference has an unknown value');
    }
  }

  @override
  bool operator ==(Object other) =>
      other is ThemePreferences && other.mode == mode && other.accent == accent;

  @override
  int get hashCode => Object.hash(mode, accent);
}

abstract interface class ThemePreferenceStore {
  Future<ThemePreferences> read();

  Future<void> write(ThemePreferences preferences);

  Future<void> clear();
}

/// 运行时复用既有安全存储依赖，避免为非敏感偏好再引入第二个持久化栈。
class FlutterThemePreferenceStore implements ThemePreferenceStore {
  FlutterThemePreferenceStore({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(
              storageNamespace: 'agent_sessions.appearance.v1',
            ),
          );

  static const _storageKey = 'theme_preferences';
  final FlutterSecureStorage _storage;

  @override
  Future<ThemePreferences> read() async {
    final encoded = await _storage.read(key: _storageKey);
    if (encoded == null || encoded.isEmpty) return ThemePreferences.defaults;
    try {
      return ThemePreferences.decode(encoded);
    } on FormatException {
      await clear();
      return ThemePreferences.defaults;
    }
  }

  @override
  Future<void> write(ThemePreferences preferences) =>
      _storage.write(key: _storageKey, value: preferences.encode());

  @override
  Future<void> clear() => _storage.delete(key: _storageKey);
}

/// Widget 测试和本地 fixture 使用短生命周期存储，确保不读取宿主设备偏好。
class InMemoryThemePreferenceStore implements ThemePreferenceStore {
  ThemePreferences _preferences = ThemePreferences.defaults;

  @override
  Future<ThemePreferences> read() async => _preferences;

  @override
  Future<void> write(ThemePreferences preferences) async {
    _preferences = preferences;
  }

  @override
  Future<void> clear() async {
    _preferences = ThemePreferences.defaults;
  }
}
