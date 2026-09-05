import 'dart:convert';
import 'dart:io';

import '../domain/models.dart';

const _localDevOwnerBootstrapB64 = String.fromEnvironment(
  'LOCAL_DEV_OWNER_BOOTSTRAP_B64',
);

/// v0.8.8 P1（迭代计划 §9.2）：localdev owner X25519 私钥种子——restart.sh 经
/// `daemon encryption-keygen` 幂等生成后注入；与 owner.bootstrap 的真实公钥配对，
/// 使 daemon 会话 DEK wrap 可被本机 unwrap（附件链路前置）。仅 localdev 调试壳。
const _localDevEncryptionPrivateKeyB64 = String.fromEnvironment(
  'LOCAL_DEV_ENCRYPTION_PRIVATE_KEY_B64',
);

/// 读取 localdev owner X25519 私钥种子；未注入时返回 null（附件入口维持
/// fail-closed 的「等待会话附件密钥」）。生产/Release 不读取该值。
String? readLocalDevEncryptionPrivateKeyB64() {
  final compileTime = _localDevEncryptionPrivateKeyB64;
  if (compileTime.isNotEmpty) {
    return compileTime;
  }
  final fromEnv = Platform
      .environment['LOCAL_DEV_ENCRYPTION_PRIVATE_KEY_B64'] ?? '';
  return fromEnv.isEmpty ? null : fromEnv;
}

/// 仅供 macOS debug 本地入口使用：restart.sh 已通过真实 Relay HTTP bootstrap
/// 创建 owner，并把完整 token/device 响应通过 dart-define 注入。Android/Release 不走此入口。
class LocalDevOwnerBootstrap {
  const LocalDevOwnerBootstrap({required this.tokens, required this.device});

  final AuthTokens tokens;
  final Device device;
}

Future<LocalDevOwnerBootstrap?> readLocalDevOwnerBootstrap() async {
  final bootstrapB64 = _localDevOwnerBootstrapB64.isNotEmpty
      ? _localDevOwnerBootstrapB64
      : Platform.environment['LOCAL_DEV_OWNER_BOOTSTRAP_B64'] ?? '';
  if (bootstrapB64.isEmpty) {
    return null;
  }
  late final String raw;
  try {
    raw = utf8.decode(base64Decode(bootstrapB64));
  } on FormatException {
    throw const RelayFailure(RelayFailureKind.protocol, '本地 owner 配对注入格式错误。');
  }
  final body = Map<String, dynamic>.from(jsonDecode(raw) as Map);
  final tokenPayload = body['tokens'];
  final devicePayload = body['device'];
  if (tokenPayload is! Map || devicePayload is! Map) {
    throw const RelayFailure(RelayFailureKind.protocol, '本地 owner 配对注入格式错误。');
  }
  final tokens = AuthTokens.fromRelayJson(
    Map<String, dynamic>.from(tokenPayload),
    DateTime.now(),
  );
  final device = Device.fromJson(Map<String, dynamic>.from(devicePayload));
  if (tokens.deviceId == null ||
      tokens.deviceId!.isEmpty ||
      tokens.deviceId != device.id ||
      !device.isOwner) {
    throw const RelayFailure(
      RelayFailureKind.protocol,
      '本地 owner 配对注入的设备绑定不一致。',
    );
  }
  return LocalDevOwnerBootstrap(tokens: tokens, device: device);
}
