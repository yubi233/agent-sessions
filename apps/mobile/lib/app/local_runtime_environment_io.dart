import 'dart:io';

/// 仅供 macOS debug fixture 启动器读取；不会被 Web 或 Android 生产路径使用。
bool get localFixtureModeFromRuntime =>
    Platform.environment['LOCAL_FIXTURE_MODE'] == 'true';

/// 场景值只来自本地 runner 的固定清单，不能承载真实 Relay 参数或用户输入。
String get localVisualScenarioFromRuntime =>
    Platform.environment['LOCAL_VISUAL_SCENARIO'] ?? '';
