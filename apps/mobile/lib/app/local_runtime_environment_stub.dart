/// 非 dart:io 平台没有本地进程环境，保持 compile-time dart-define 作为唯一入口。
bool get localFixtureModeFromRuntime => false;

String get localVisualScenarioFromRuntime => '';
