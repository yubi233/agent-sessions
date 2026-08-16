import 'models.dart';

/// Relay `/v1/terminals` 的白名单只读投影。
///
/// `id` 只用于客户端列表稳定性，UI、日志和剪贴板均不展示它；工作区根、命令正文和
/// Daemon 日志不属于此 DTO。
class TerminalSummary {
  const TerminalSummary({
    required this.id,
    required this.hostname,
    required this.platform,
    required this.status,
    required this.protocolVersion,
    this.daemonVersion,
    this.lastSeen,
  });

  factory TerminalSummary.fromRelayJson(Map<String, dynamic> json) {
    final protocolVersion = _optionalNonNegativeInteger(
      json['protocol_version'],
      message: 'Relay 返回了无效的终端协议版本。',
    );
    final lastSeenUnixMs = _optionalNonNegativeInteger(
      json['last_seen_unix_ms'],
      message: 'Relay 返回了无效的终端最后在线时间。',
    );
    final status = json['status'];
    if (status != null && status is! String) {
      throw const RelayFailure(RelayFailureKind.protocol, 'Relay 返回了无效的终端状态。');
    }
    return TerminalSummary(
      id: _requiredTerminalString(json, 'id'),
      hostname: _displayString(json['hostname'], fallback: '未命名终端'),
      platform: _displayString(json['platform'], fallback: '未知平台'),
      status: TerminalConnectionStatus.fromWire(status as String?),
      protocolVersion: protocolVersion ?? 0,
      daemonVersion: _optionalDisplayString(json['daemon_version']),
      lastSeen: lastSeenUnixMs != null
          ? DateTime.fromMillisecondsSinceEpoch(lastSeenUnixMs)
          : null,
    );
  }

  /// 终端 opaque ID 只供 key 和状态归并使用，不是可展示字段。
  final String id;
  final String hostname;
  final String platform;
  final TerminalConnectionStatus status;
  final int protocolVersion;
  final String? daemonVersion;
  final DateTime? lastSeen;

  /// 仅以 Relay 白名单元数据推导展示状态；不把本地路径或 Daemon 日志带进 Android。
  TerminalAvailability availabilityAt(
    DateTime now, {
    Duration staleAfter = const Duration(seconds: 90),
  }) {
    if (status == TerminalConnectionStatus.offline) {
      return TerminalAvailability.offline;
    }
    if (status != TerminalConnectionStatus.online) {
      return TerminalAvailability.unknown;
    }
    if (protocolVersion <= 0 || protocolVersion > supportedTerminalProtocol) {
      return TerminalAvailability.unsupported;
    }
    final seen = lastSeen;
    if (seen == null || now.toUtc().difference(seen.toUtc()) > staleAfter) {
      return TerminalAvailability.stale;
    }
    return TerminalAvailability.online;
  }
}

/// 当前 Android 只认识 ADR-009 的 v1 Terminal 协议。未来版本必须明确降级，不能假定兼容。
const supportedTerminalProtocol = 1;

enum TerminalConnectionStatus {
  online('online'),
  offline('offline'),
  unknown('unknown');

  const TerminalConnectionStatus(this.wireValue);

  final String wireValue;

  static TerminalConnectionStatus fromWire(String? value) => switch (value) {
    'online' => TerminalConnectionStatus.online,
    'offline' => TerminalConnectionStatus.offline,
    _ => TerminalConnectionStatus.unknown,
  };
}

/// P3 机器页可见的安全状态；`unsupported` 只说明协议不能安全消费，不表示可尝试控制。
enum TerminalAvailability { online, offline, stale, unsupported, unknown }

String _requiredTerminalString(Map<String, dynamic> json, String field) {
  final value = json[field];
  if (value is! String || value.trim().isEmpty) {
    throw RelayFailure(RelayFailureKind.protocol, 'Relay 响应缺少 $field。');
  }
  return value;
}

String _displayString(Object? value, {required String fallback}) {
  if (value is! String || value.trim().isEmpty) return fallback;
  return value.trim();
}

String? _optionalDisplayString(Object? value) {
  if (value is! String || value.trim().isEmpty) return null;
  return value.trim();
}

int? _optionalNonNegativeInteger(Object? value, {required String message}) {
  if (value == null) return null;
  if (value is int && value >= 0) return value;
  if (value is double &&
      value.isFinite &&
      value >= 0 &&
      value == value.truncateToDouble()) {
    return value.toInt();
  }
  throw RelayFailure(RelayFailureKind.protocol, message);
}
