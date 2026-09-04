import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../domain/model_effort_preferences.dart';

/// 「模型 → 上次选中推理等级」本地记忆的持久化契约（v0.8.6）。
///
/// 仅保存非敏感的目录内标签（模型 id / effort id），不包含会话正文或任何密钥。
abstract interface class ModelEffortPreferenceStore {
  Future<ModelEffortPreferences> read();

  Future<void> write(ModelEffortPreferences preferences);

  Future<void> clear();
}

/// 运行时实现：复用既有安全存储依赖，避免为非敏感偏好引入第二套持久化栈。
/// namespace 与 composer 偏好分离，互不影响清理。
class FlutterModelEffortPreferenceStore implements ModelEffortPreferenceStore {
  FlutterModelEffortPreferenceStore({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(
              storageNamespace: 'agent_sessions.model_effort.v1',
            ),
          );

  static const _storageKey = 'model_effort_preferences';
  final FlutterSecureStorage _storage;

  @override
  Future<ModelEffortPreferences> read() async {
    final encoded = await _storage.read(key: _storageKey);
    if (encoded == null || encoded.isEmpty) {
      return ModelEffortPreferences.defaults;
    }
    try {
      return ModelEffortPreferences.decode(encoded);
    } on FormatException {
      await clear();
      return ModelEffortPreferences.defaults;
    }
  }

  @override
  Future<void> write(ModelEffortPreferences preferences) =>
      _storage.write(key: _storageKey, value: preferences.encode());

  @override
  Future<void> clear() => _storage.delete(key: _storageKey);
}

/// Widget 测试与本地 fixture 使用短生命周期存储，确保不读取宿主设备偏好。
class InMemoryModelEffortPreferenceStore implements ModelEffortPreferenceStore {
  ModelEffortPreferences _preferences = ModelEffortPreferences.defaults;

  @override
  Future<ModelEffortPreferences> read() async => _preferences;

  @override
  Future<void> write(ModelEffortPreferences preferences) async {
    _preferences = preferences;
  }

  @override
  Future<void> clear() async {
    _preferences = ModelEffortPreferences.defaults;
  }
}
