import 'package:agent_sessions_mobile/domain/model_effort_preferences.dart';
import 'package:flutter_test/flutter_test.dart';

/// V086：「模型 → 上次推理等级」本地记忆的编解码与写入口径。
void main() {
  test('withEffort 记录模型等级，相同值不产生新对象', () {
    const preferences = ModelEffortPreferences();
    final updated = preferences.withEffort('model-a', 'high');
    expect(updated.effortFor('model-a'), 'high');
    expect(updated.effortFor('model-b'), isNull);

    final unchanged = updated.withEffort('model-a', 'high');
    expect(unchanged, same(updated));
    expect(updated.withEffort('model-a', 'low'), isNot(equals(updated)));
  });

  test('encode/decode 往返一致，畸形输入抛 FormatException', () {
    const preferences = ModelEffortPreferences(
      effortsByModel: {'model-a': 'low', 'model-b': 'high'},
    );
    final decoded = ModelEffortPreferences.decode(preferences.encode());
    expect(decoded, equals(preferences));

    expect(
      () => ModelEffortPreferences.decode('[]'),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => ModelEffortPreferences.decode('{"model-a": 3}'),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => ModelEffortPreferences.decode('{"": "low"}'),
      throwsA(isA<FormatException>()),
    );
  });
}
