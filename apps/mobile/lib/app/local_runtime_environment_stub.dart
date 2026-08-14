import 'dart:typed_data';

/// 非 dart:io 平台没有本地进程环境，保持 compile-time dart-define 作为唯一入口。
bool get localFixtureModeFromRuntime => false;

String get localVisualScenarioFromRuntime => '';

String get localVisualFrameDirectoryFromRuntime => '';

int get localVisualFrameCountFromRuntime => 0;

int get localVisualFrameIntervalMsFromRuntime => 0;

Future<void> writeLocalVisualFrame(String outputPath, Uint8List bytes) async {}
