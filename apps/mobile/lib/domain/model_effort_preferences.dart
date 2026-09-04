import 'dart:convert';

/// 用户本地记忆的「模型 → 上次选中推理等级」映射（v0.8.6）。
///
/// 目的：切换模型时自动带回该模型上次使用的推理等级，避免每次重复选择；
/// 模型选择列表也在模型名后展示该值，用户能预知切换后会用哪个等级。
/// 只保存非敏感的目录内标签（模型 id / effort id），不含会话正文或密钥。
class ModelEffortPreferences {
  const ModelEffortPreferences({this.effortsByModel = const {}});

  static const defaults = ModelEffortPreferences();

  /// key = 模型目录 value（controls.models 里的模型 id）。
  final Map<String, String> effortsByModel;

  String? effortFor(String model) => effortsByModel[model];

  ModelEffortPreferences withEffort(String model, String effort) {
    if (effortsByModel[model] == effort) return this;
    return ModelEffortPreferences(
      effortsByModel: {...effortsByModel, model: effort},
    );
  }

  String encode() => jsonEncode(effortsByModel);

  factory ModelEffortPreferences.decode(String encoded) {
    final value = jsonDecode(encoded);
    if (value is! Map) {
      throw const FormatException('model effort preferences must be an object');
    }
    final entries = <String, String>{};
    for (final entry in value.entries) {
      final model = entry.key;
      final effort = entry.value;
      if (model is! String || model.isEmpty || effort is! String) {
        throw const FormatException('model effort preference is invalid');
      }
      entries[model] = effort;
    }
    return ModelEffortPreferences(effortsByModel: entries);
  }

  @override
  bool operator ==(Object other) {
    if (other is! ModelEffortPreferences) return false;
    if (effortsByModel.length != other.effortsByModel.length) return false;
    for (final entry in effortsByModel.entries) {
      if (other.effortsByModel[entry.key] != entry.value) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(
    effortsByModel.entries.map((entry) => Object.hash(entry.key, entry.value)),
  );
}
