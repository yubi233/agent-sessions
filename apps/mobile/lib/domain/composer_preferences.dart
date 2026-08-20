import 'dart:convert';

/// v0.5/P5：Composer 用户级偏好。
///
/// 对应《迭代计划v0.5.md》第 3 节「Enter 设置」契约：
/// - busy Enter 偏好是用户级设置项，默认 Queue，可切换 Queue / Steer；
/// - composer 与设置页读取同一个用户级事实来源。
/// busy（streaming）时按下 Enter 的分流策略。
///
/// - [queue]：运行中输入 Enter 只进入本地 transient queue（默认，保守）；
/// - [steer]：运行中输入 Enter 直接插话/steer 到队列或会话。
enum ComposerEnterBehavior { queue, steer }

extension ComposerEnterBehaviorLabel on ComposerEnterBehavior {
  String get label => switch (this) {
    ComposerEnterBehavior.queue => '排队 (Queue)',
    ComposerEnterBehavior.steer => '插话 (Steer)',
  };
}

class ComposerPreferences {
  const ComposerPreferences({this.enterBehavior = ComposerEnterBehavior.queue});

  static const defaults = ComposerPreferences();

  final ComposerEnterBehavior enterBehavior;

  ComposerPreferences copyWith({ComposerEnterBehavior? enterBehavior}) =>
      ComposerPreferences(enterBehavior: enterBehavior ?? this.enterBehavior);

  String encode() =>
      jsonEncode(<String, String>{'enterBehavior': enterBehavior.name});

  factory ComposerPreferences.decode(String encoded) {
    final value = jsonDecode(encoded);
    if (value is! Map) {
      throw const FormatException('composer preference must be an object');
    }
    final name = value['enterBehavior'];
    if (name is! String) {
      throw const FormatException('composer preference is incomplete');
    }
    try {
      return ComposerPreferences(
        enterBehavior: ComposerEnterBehavior.values.byName(name),
      );
    } on ArgumentError {
      throw const FormatException('composer preference has an unknown value');
    }
  }

  @override
  bool operator ==(Object other) =>
      other is ComposerPreferences && other.enterBehavior == enterBehavior;

  @override
  int get hashCode => enterBehavior.hashCode;
}
