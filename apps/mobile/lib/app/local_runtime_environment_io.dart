import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const _compileTimeLocalVisualFrameDirectory = String.fromEnvironment(
  'LOCAL_VISUAL_FRAME_DIRECTORY',
);
const _compileTimeLocalVisualFrameCount = int.fromEnvironment(
  'LOCAL_VISUAL_FRAME_COUNT',
);
const _compileTimeLocalVisualFrameIntervalMs = int.fromEnvironment(
  'LOCAL_VISUAL_FRAME_INTERVAL_MS',
);

/// 仅供 macOS debug fixture 启动器读取；不会被 Web 或 Android 生产路径使用。
bool get localFixtureModeFromRuntime =>
    Platform.environment['LOCAL_FIXTURE_MODE'] == 'true';

/// 场景值只来自本地 runner 的固定清单，不能承载真实 Relay 参数或用户输入。
String get localVisualScenarioFromRuntime =>
    Platform.environment['LOCAL_VISUAL_SCENARIO'] ?? '';

/// 仅供本地真实 Relay/DSH 验证使用：启动后打开一个已存在 session。
/// 只接受 Relay 生成的 sess_* 形状，避免把任意路由或用户输入注入 GoRouter。
String get localDevTargetSessionIdFromRuntime {
  final value = Platform.environment['LOCAL_DEV_TARGET_SESSION_ID'] ?? '';
  if (!RegExp(r'^sess_[A-Za-z0-9_]+$').hasMatch(value)) return '';
  return value;
}

/// 仅供 macOS debug 可见 gate 写入 Flutter 渲染帧。环境变量只允许 sandbox 临时目录下的子目录名，
/// 不能把 runner 或 Relay 提供的任意绝对路径交给已沙箱化的 App。
String get localVisualFrameDirectoryFromRuntime {
  final name = _compileTimeLocalVisualFrameDirectory.isNotEmpty
      ? _compileTimeLocalVisualFrameDirectory
      : Platform.environment['LOCAL_VISUAL_FRAME_DIRECTORY'] ?? '';
  if (!RegExp(r'^[A-Za-z0-9_-]{1,120}$').hasMatch(name)) return '';
  return '${Directory.systemTemp.path}/$name';
}

const _compileTimeLocalVisualTelemetryDirectory = String.fromEnvironment(
  'LOCAL_VISUAL_TELEMETRY_DIRECTORY',
);

/// v0.8.7 流式门禁证据目录名（V087-08/09）：只接受固定清单形状的目录名，
/// 不把 runner 提供的任意绝对路径交给已沙箱化的 App；证据文件写入沙箱容器
/// tmp 下同名目录（runner 侧按同一目录名解析回收）。
String get localVisualTelemetryDirectoryFromRuntime {
  final name = _compileTimeLocalVisualTelemetryDirectory.isNotEmpty
      ? _compileTimeLocalVisualTelemetryDirectory
      : Platform.environment['LOCAL_VISUAL_TELEMETRY_DIRECTORY'] ?? '';
  if (!RegExp(r'^[A-Za-z0-9_-]{1,120}$').hasMatch(name)) return '';
  return name;
}

/// 双门禁证据导出文件路径；空串表示本轮未启用流式门禁场景。
String get localVisualTelemetryExportPath {
  final name = localVisualTelemetryDirectoryFromRuntime;
  if (name.isEmpty) return '';
  return '${Directory.systemTemp.path}/$name/streaming-gate.json';
}

/// v0.8.7 V087-12（真实栈口径）：localdev 模式注入的自动发送文本。非空时
/// App 打开目标会话页后自己发送该消息——在途轮询与打字机渲染只有 App 自己
/// 的 sendMessage 才会驱动，API 侧发送不产生可见流式。文本由 harness 固定
/// 演示问句注入，不承载用户输入。
String get localDevSendMessageFromRuntime =>
    Platform.environment['LOCAL_DEV_SEND_MESSAGE'] ?? '';

int get localVisualFrameCountFromRuntime =>
    _compileTimeLocalVisualFrameCount > 0
    ? _compileTimeLocalVisualFrameCount
    : int.tryParse(Platform.environment['LOCAL_VISUAL_FRAME_COUNT'] ?? '') ?? 0;

int get localVisualFrameIntervalMsFromRuntime =>
    _compileTimeLocalVisualFrameIntervalMs > 0
    ? _compileTimeLocalVisualFrameIntervalMs
    : int.tryParse(
            Platform.environment['LOCAL_VISUAL_FRAME_INTERVAL_MS'] ?? '',
          ) ??
          0;

/// 帧由当前可见 Flutter render tree 生成，原始全屏截图不会落盘，避免 Screen Recording 异常时采集桌面内容。
Future<void> writeLocalVisualFrame(String outputPath, Uint8List bytes) async {
  final file = File(outputPath);
  await file.parent.create(recursive: true);
  // 先写同目录临时文件再替换，避免 runner 在跨进程轮询时读取到半张 PNG。
  final temporary = File('$outputPath.part');
  // Runner only reads frames after the final timing file appears; forcing an
  // fsync for every 5fps frame makes the macOS sandbox spend seconds per PNG.
  await temporary.writeAsBytes(bytes, flush: false);
  await temporary.rename(outputPath);
}

/// 与连续帧一起写入无业务数据的单调时间表，供 runner 核验严格 5fps 调度。
Future<void> writeLocalVisualFrameTiming(
  String outputPath,
  Map<String, dynamic> timing,
) async {
  final file = File(outputPath);
  await file.parent.create(recursive: true);
  final temporary = File('$outputPath.part');
  await temporary.writeAsString(jsonEncode(timing), flush: true);
  await temporary.rename(outputPath);
}
