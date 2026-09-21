import 'dart:convert';
import 'dart:io';

import '../domain/models.dart';
import '../storage/secure_token_store.dart';

const _localDevOwnerBootstrapB64 = String.fromEnvironment(
  'LOCAL_DEV_OWNER_BOOTSTRAP_B64',
);

/// restart.sh 的 owner bootstrap 缓存文件路径（mac 模式经 dart-define 注入）。
const _localDevOwnerBootstrapFile = String.fromEnvironment(
  'LOCAL_DEV_OWNER_BOOTSTRAP_FILE',
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

/// 桌面调试壳的刷新令牌缓存路径：`~/.agent-sessions/localdev-owner-cache.json`。
/// 放在用户域而非 restart.sh 的 state 目录——macOS 的 provenance 数据隔离会把
/// restart.sh 创建的文件绑定到创建者进程，Flutter 打开会得到 EPERM（2026-09-21
/// 实测 PathAccessException）；restart.sh 刷新失败时回退读取本文件。
String? localDevOwnerBootstrapFilePath() {
  final compileTime = _localDevOwnerBootstrapFile;
  if (compileTime.isNotEmpty) {
    return compileTime;
  }
  final fromEnv = Platform.environment['LOCAL_DEV_OWNER_BOOTSTRAP_FILE'] ?? '';
  if (fromEnv.isNotEmpty) {
    return fromEnv;
  }
  final home = Platform.environment['HOME'] ?? '';
  return home.isEmpty ? null : '$home/.agent-sessions/localdev-owner-cache.json';
}

/// 桌面调试壳刷新令牌后把最新 tokens 回写用户域缓存。refresh token 为一次性
/// 轮换：Flutter 消费后若不落盘，`restart.sh start` 的缓存刷新必然失败——
/// v0.9.4 起该失败会回退读取本缓存（不再直接重置 Relay DB），手机令牌因此
/// 跨重启保持有效。回写任何异常都静默：它是调试便利，不得影响认证主流程。
void writeLocalDevOwnerBootstrapTokens(String? path, AuthTokens tokens) {
  if (path == null || path.isEmpty) return;
  try {
    final file = File(path);
    file.parent.createSync(recursive: true);
    final body = <String, dynamic>{
      // 保留旧缓存的 device 等字段（若有）；tokens 始终以最新轮换为准。
      if (file.existsSync())
        ...Map<String, dynamic>.from(jsonDecode(file.readAsStringSync()) as Map),
      'tokens': tokens.toSecureJson(),
    };
    // 原子替换 + 0600：文件承载可复用凭据，绝不放宽权限。
    final tmp = File('$path.tmp');
    tmp.writeAsStringSync(jsonEncode(body), flush: true);
    tmp.rename(path);
    Process.runSync('chmod', ['600', path]);
    assert(() {
      // ignore: avoid_print
      print('localdev owner bootstrap 回写成功: $path');
      return true;
    }());
  } on Object catch (error) {
    // 回写失败不影响主流程，但保持可诊断：调试环境打印，release 无输出。
    assert(() {
      // ignore: avoid_print
      print('localdev owner bootstrap 回写失败: $error');
      return true;
    }());
  }
}

/// 刷新落盘直通：localdev 调试壳把新 tokens 写入内存 store 的同时回写
/// restart.sh 缓存文件，形成「Flutter 消费 refresh → 回写」闭环。
/// 只回写与注入设备同 deviceId 的 tokens，避免把其他设备的凭据覆盖进缓存。
class WriteThroughLocalDevTokenStore implements SecureTokenStore {
  WriteThroughLocalDevTokenStore(this._inner, this._bootstrapFile, this._deviceId);

  final SecureTokenStore _inner;
  final String? _bootstrapFile;
  final String _deviceId;

  @override
  Future<void> clear() => _inner.clear();

  @override
  Future<AuthTokens?> read() => _inner.read();

  @override
  Future<void> write(AuthTokens tokens) {
    if (tokens.deviceId == null || tokens.deviceId == _deviceId) {
      writeLocalDevOwnerBootstrapTokens(_bootstrapFile, tokens);
    }
    return _inner.write(tokens);
  }
}
