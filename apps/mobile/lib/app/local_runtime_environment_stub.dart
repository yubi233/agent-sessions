import 'dart:typed_data';

/// 非 dart:io 平台没有本地进程环境，保持 compile-time dart-define 作为唯一入口。
bool get localFixtureModeFromRuntime => false;

String get localVisualScenarioFromRuntime => '';

String get localDevTargetSessionIdFromRuntime => '';

String get localVisualFrameDirectoryFromRuntime => '';

int get localVisualFrameCountFromRuntime => 0;

/// v0.8.7 流式门禁证据导出路径：非 io 平台恒为空串（场景仅存在于 macOS debug）。
String get localVisualTelemetryExportPath => '';

/// v0.8.7 V087-12 真实栈自动发送文本：非 io 平台无进程环境，恒为空串。
String get localDevSendMessageFromRuntime => '';

int get localVisualFrameIntervalMsFromRuntime => 0;

Future<void> writeLocalVisualFrame(String outputPath, Uint8List bytes) async {}

Future<void> writeLocalVisualFrameTiming(
  String outputPath,
  Map<String, dynamic> timing,
) async {}
