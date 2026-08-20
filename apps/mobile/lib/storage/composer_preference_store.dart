import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../domain/composer_preferences.dart';

/// Composer 用户偏好的持久化契约。
///
/// 仅保存非敏感的输入偏好（Enter 行为），不包含会话正文或任何密钥。
abstract interface class ComposerPreferenceStore {
  Future<ComposerPreferences> read();

  Future<void> write(ComposerPreferences preferences);

  Future<void> clear();
}

/// 运行时实现：复用既有安全存储依赖，避免为非敏感偏好引入第二套持久化栈。
class FlutterComposerPreferenceStore implements ComposerPreferenceStore {
  FlutterComposerPreferenceStore({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(
              storageNamespace: 'agent_sessions.composer.v1',
            ),
          );

  static const _storageKey = 'composer_preferences';
  final FlutterSecureStorage _storage;

  @override
  Future<ComposerPreferences> read() async {
    final encoded = await _storage.read(key: _storageKey);
    if (encoded == null || encoded.isEmpty) {
      return ComposerPreferences.defaults;
    }
    try {
      return ComposerPreferences.decode(encoded);
    } on FormatException {
      await clear();
      return ComposerPreferences.defaults;
    }
  }

  @override
  Future<void> write(ComposerPreferences preferences) =>
      _storage.write(key: _storageKey, value: preferences.encode());

  @override
  Future<void> clear() => _storage.delete(key: _storageKey);
}

/// Widget 测试与本地 fixture 使用短生命周期存储，确保不读取宿主设备偏好。
class InMemoryComposerPreferenceStore implements ComposerPreferenceStore {
  ComposerPreferences _preferences = ComposerPreferences.defaults;

  @override
  Future<ComposerPreferences> read() async => _preferences;

  @override
  Future<void> write(ComposerPreferences preferences) async {
    _preferences = preferences;
  }

  @override
  Future<void> clear() async {
    _preferences = ComposerPreferences.defaults;
  }
}
