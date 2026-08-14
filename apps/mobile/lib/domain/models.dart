import 'dart:convert';

/// Relay 的设备角色是服务端授权事实，客户端只负责展示与提交请求。
enum DeviceRole {
  androidOwner('android_owner'),
  android('android'),
  terminal('terminal'),
  web('web'),
  admin('admin');

  const DeviceRole(this.wireValue);

  final String wireValue;

  static DeviceRole fromWire(String value) => switch (value) {
    'android_owner' => DeviceRole.androidOwner,
    'android' => DeviceRole.android,
    'terminal' => DeviceRole.terminal,
    'web' => DeviceRole.web,
    'admin' => DeviceRole.admin,
    _ => throw FormatException('未知设备角色。'),
  };
}

enum DeviceStatus {
  active('active'),
  revoked('revoked');

  const DeviceStatus(this.wireValue);

  final String wireValue;

  static DeviceStatus fromWire(String value) => switch (value) {
    'active' => DeviceStatus.active,
    'revoked' => DeviceStatus.revoked,
    _ => throw FormatException('未知设备状态。'),
  };
}

/// 认证 token 只允许经 [SecureTokenStore] 保存，不能写入普通缓存或日志。
class AuthTokens {
  const AuthTokens({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
    this.deviceId,
  });

  factory AuthTokens.fromRelayJson(Map<String, dynamic> json, DateTime now) {
    final expiresIn = json['expires_in'];
    if (expiresIn is! num) {
      throw const FormatException('认证响应缺少过期时间。');
    }
    return AuthTokens(
      accessToken: _requiredString(json, 'access_token'),
      refreshToken: _requiredString(json, 'refresh_token'),
      expiresAt: now.add(Duration(seconds: expiresIn.toInt())),
      deviceId: json['device_id'] as String?,
    );
  }

  factory AuthTokens.fromSecureJson(Map<String, dynamic> json) => AuthTokens(
    accessToken: _requiredString(json, 'access_token'),
    refreshToken: _requiredString(json, 'refresh_token'),
    expiresAt: DateTime.parse(_requiredString(json, 'expires_at')),
    deviceId: json['device_id'] as String?,
  );

  final String accessToken;
  final String refreshToken;
  final DateTime expiresAt;
  final String? deviceId;

  bool get needsRefresh =>
      expiresAt.isBefore(DateTime.now().add(const Duration(minutes: 1)));

  Map<String, dynamic> toSecureJson() => {
    'access_token': accessToken,
    'refresh_token': refreshToken,
    'expires_at': expiresAt.toUtc().toIso8601String(),
    if (deviceId != null) 'device_id': deviceId,
  };

  String encodeForSecureStorage() => jsonEncode(toSecureJson());

  AuthTokens copyWith({String? deviceId}) => AuthTokens(
    accessToken: accessToken,
    refreshToken: refreshToken,
    expiresAt: expiresAt,
    deviceId: deviceId ?? this.deviceId,
  );
}

class LoginCredentials {
  const LoginCredentials({required this.email, required this.password});

  final String email;
  final String password;

  void validate() {
    if (!email.contains('@') || password.isEmpty) {
      throw const RelayFailure.validation('请输入有效邮箱和密码。');
    }
  }
}

/// 设备身份材料的私钥必须由安全存储实现保存；该 DTO 仅允许离开设备的公钥。
class DeviceRegistrationMaterial {
  const DeviceRegistrationMaterial({
    required this.identityPublicKey,
    required this.encryptionPublicKey,
  });

  final String identityPublicKey;
  final String encryptionPublicKey;
}

class BootstrapOwnerInput {
  const BootstrapOwnerInput({
    required this.displayName,
    required this.platform,
    required this.keys,
  });

  final String displayName;
  final String platform;
  final DeviceRegistrationMaterial keys;
}

class PairingRequestInput {
  const PairingRequestInput({
    required this.role,
    required this.displayName,
    required this.platform,
    required this.keys,
  });

  final DeviceRole role;
  final String displayName;
  final String platform;
  final DeviceRegistrationMaterial keys;
}

class Device {
  const Device({
    required this.id,
    required this.role,
    required this.status,
    required this.displayName,
    required this.platform,
    this.lastSeen,
  });

  factory Device.fromJson(Map<String, dynamic> json) => Device(
    id: _requiredString(json, 'id'),
    role: DeviceRole.fromWire(_requiredString(json, 'role')),
    status: DeviceStatus.fromWire(_requiredString(json, 'status')),
    displayName: (json['display_name'] as String?) ?? '未命名设备',
    platform: (json['platform'] as String?) ?? 'unknown',
    lastSeen: json['last_seen_unix_ms'] is num
        ? DateTime.fromMillisecondsSinceEpoch(
            (json['last_seen_unix_ms'] as num).toInt(),
          )
        : null,
  );

  final String id;
  final DeviceRole role;
  final DeviceStatus status;
  final String displayName;
  final String platform;
  final DateTime? lastSeen;

  bool get isOwner =>
      role == DeviceRole.androidOwner && status == DeviceStatus.active;
}

enum PairingStatus {
  pending('pending'),
  approved('approved'),
  cancelled('cancelled'),
  expired('expired');

  const PairingStatus(this.wireValue);

  final String wireValue;

  static PairingStatus fromWire(String value) => switch (value) {
    'pending' => PairingStatus.pending,
    'approved' => PairingStatus.approved,
    'cancelled' => PairingStatus.cancelled,
    'expired' => PairingStatus.expired,
    _ => throw FormatException('未知配对状态。'),
  };
}

class PairingRequest {
  const PairingRequest({
    required this.id,
    required this.status,
    required this.role,
    required this.displayName,
    this.expiresAt,
  });

  factory PairingRequest.fromJson(Map<String, dynamic> json) => PairingRequest(
    id: _requiredString(json, 'id'),
    status: PairingStatus.fromWire(_requiredString(json, 'status')),
    role: DeviceRole.fromWire(_requiredString(json, 'role')),
    displayName: (json['display_name'] as String?) ?? '未命名设备',
    expiresAt: json['expires_at'] is String
        ? DateTime.tryParse(json['expires_at'] as String)
        : null,
  );

  final String id;
  final PairingStatus status;
  final DeviceRole role;
  final String displayName;
  final DateTime? expiresAt;
}

/// 相机扫描与手动输入共用同一 payload；解析失败时不会把任意字符串发给 Relay。
abstract final class PairingPayload {
  static const _scheme = 'agent-sessions';
  static const _host = 'pairing';

  static String encode(String requestId) => '$_scheme://$_host/$requestId';

  static String shortCode(String requestId) {
    final compact = requestId
        .replaceAll(RegExp('[^A-Za-z0-9]'), '')
        .toUpperCase();
    return compact.length <= 8
        ? compact
        : compact.substring(compact.length - 8);
  }

  static String? requestIdFromScan(String scannedValue) {
    final value = scannedValue.trim();
    final uri = Uri.tryParse(value);
    if (uri != null &&
        uri.scheme == _scheme &&
        uri.host == _host &&
        uri.pathSegments.length == 1) {
      return uri.pathSegments.single;
    }
    // 测试或手动输入允许 opaque request id，但拒绝含空格、URL 查询串等歧义值。
    return RegExp(r'^[A-Za-z0-9_-]{3,128}$').hasMatch(value) ? value : null;
  }
}

class RecoveryCodeInput {
  const RecoveryCodeInput({
    required this.email,
    required this.code,
    required this.displayName,
    required this.keys,
  });

  final String email;
  final String code;
  final String displayName;
  final DeviceRegistrationMaterial keys;
}

class RecoveryResult {
  const RecoveryResult({required this.tokens, required this.device});

  final AuthTokens tokens;
  final Device device;
}

enum RelayFailureKind {
  validation,
  unauthorized,
  forbidden,
  unavailable,
  protocol,
  unknown,
}

/// 面向 UI 的脱敏错误；不要向此异常放入 token、正文或 HTTP 原始响应。
class RelayFailure implements Exception {
  const RelayFailure(this.kind, this.message);

  const RelayFailure.validation(String message)
    : this(RelayFailureKind.validation, message);

  final RelayFailureKind kind;
  final String message;
}

String _requiredString(Map<String, dynamic> json, String field) {
  final value = json[field];
  if (value is! String || value.isEmpty) {
    throw FormatException('响应缺少 $field。');
  }
  return value;
}
