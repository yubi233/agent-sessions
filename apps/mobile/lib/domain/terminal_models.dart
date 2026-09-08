import 'models.dart';

/// Relay `/v1/terminals` 的白名单只读投影。
///
/// `id` 只用于客户端列表稳定性，UI、日志和剪贴板均不展示它；工作区根、命令正文和
/// Daemon 日志不属于此 DTO。
///
/// v0.9.1 C1：availability / presenceRevision / lastHeartbeat / nextCheck 是
/// Relay 以服务端时间即时投影的 additive 字段。availability 是在线态唯一权威：
/// 客户端墙钟只用于展示，绝不二次裁决「能否投递命令」（裁决 T2）。
class TerminalSummary {
  const TerminalSummary({
    required this.id,
    required this.hostname,
    required this.platform,
    required this.status,
    required this.protocolVersion,
    this.daemonVersion,
    this.lastSeen,
    this.capabilities = const [],
    this.wireAvailability,
    this.presenceRevision,
    this.lastHeartbeat,
    this.nextCheck,
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
    final presenceRevision = _optionalNonNegativeInteger(
      json['presence_revision'],
      message: 'Relay 返回了无效的终端 presence 版本。',
    );
    final lastHeartbeatUnixMs = _optionalNonNegativeInteger(
      json['last_heartbeat_unix_ms'],
      message: 'Relay 返回了无效的终端最后心跳时间。',
    );
    final nextCheckUnixMs = _optionalNonNegativeInteger(
      json['next_check_unix_ms'],
      message: 'Relay 返回了无效的终端下一次投影边界。',
    );
    final status = json['status'];
    if (status != null && status is! String) {
      throw const RelayFailure(RelayFailureKind.protocol, 'Relay 返回了无效的终端状态。');
    }
    final availability = json['availability'];
    if (availability != null &&
        (availability is! String || !_wireAvailabilityLookup.containsKey(availability))) {
      throw const RelayFailure(RelayFailureKind.protocol, 'Relay 返回了无效的终端在线态。');
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
      capabilities: _capabilityNames(json['capabilities']),
      wireAvailability: availability as String?,
      presenceRevision: presenceRevision,
      lastHeartbeat: lastHeartbeatUnixMs != null
          ? DateTime.fromMillisecondsSinceEpoch(lastHeartbeatUnixMs)
          : null,
      nextCheck: nextCheckUnixMs != null
          ? DateTime.fromMillisecondsSinceEpoch(nextCheckUnixMs)
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
  final List<String> capabilities;

  /// Relay 权威 availability 的 wire 原值；旧 Relay（v0.9.0 及更早）没有该字段，
  /// 此时为 null，由 [availability] 走 legacy 派生（绝不用本机墙钟）。
  final String? wireAvailability;

  /// availability 投影的单调版本号（invalidation 去重与丢帧补偿用；旧 Relay 为 null）。
  final int? presenceRevision;

  /// 最后一次有效心跳的服务端时间（展示口径；不参与客户端裁决）。
  final DateTime? lastHeartbeat;

  /// Relay 给出的下一个投影边界（展示口径；0/缺省表示无边界）。
  final DateTime? nextCheck;

  bool hasCapability(String capability) => capabilities.contains(capability);

  /// 在线态唯一投影来源（v0.9.1 C1）：
  ///   1. 新 Relay：直接消费 availability 字段（服务端时间口径）；
  ///   2. 旧 Relay 降级：status + protocol 派生，但不再做任何本地墙钟 stale 判断——
  ///      刷新时效由 [TerminalStatusController] 的前台 safety reconcile 保证。
  TerminalAvailability get availability {
    final wire = wireAvailability;
    if (wire != null) {
      return _wireAvailabilityLookup[wire]!;
    }
    // legacy 派生（旧 Relay）：不读取任何本地时钟。
    switch (status) {
      case TerminalConnectionStatus.offline:
        return TerminalAvailability.offline;
      case TerminalConnectionStatus.online:
        if (protocolVersion <= 0 || protocolVersion > supportedTerminalProtocol) {
          return TerminalAvailability.unsupported;
        }
        return TerminalAvailability.online;
      case TerminalConnectionStatus.unknown:
        return TerminalAvailability.unknown;
    }
  }
}

const Map<String, TerminalAvailability> _wireAvailabilityLookup = {
  'online': TerminalAvailability.online,
  'unknown': TerminalAvailability.unknown,
  'offline': TerminalAvailability.offline,
  'unsupported': TerminalAvailability.unsupported,
};

List<String> _capabilityNames(Object? value) {
  if (value is! List) return const [];
  final names = value
      .whereType<String>()
      .map((name) => name.trim())
      .where((name) => name.isNotEmpty)
      .toSet()
      .toList(growable: false);
  return names;
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
/// v0.9.1 起 `stale` 不再由客户端墙钟派生，仅为旧 UI 兼容保留枚举位。
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
