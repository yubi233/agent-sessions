import '../domain/models.dart';
import '../storage/secure_token_store.dart';

class LocalDevOwnerBootstrap {
  const LocalDevOwnerBootstrap({required this.tokens, required this.device});

  final AuthTokens tokens;
  final Device device;
}

Future<LocalDevOwnerBootstrap?> readLocalDevOwnerBootstrap() async => null;

/// stub 平台（web）无 localdev 私钥注入；与 io 版本保持同名同形状。
String? readLocalDevEncryptionPrivateKeyB64() => null;

/// stub 平台无 bootstrap 缓存文件；与 io 版本保持同名同形状。
String? localDevOwnerBootstrapFilePath() => null;

/// stub 平台为 no-op；与 io 版本保持同名同形状。
void writeLocalDevOwnerBootstrapTokens(String? path, AuthTokens tokens) {}

/// stub 平台直通 no-op；与 io 版本保持同名同形状（缓存路径/设备 id 仅 io 版消费）。
class WriteThroughLocalDevTokenStore implements SecureTokenStore {
  WriteThroughLocalDevTokenStore(
    this._inner,
    String? bootstrapFile,
    String? deviceId,
  ) : _bootstrapFile = bootstrapFile,
      _deviceId = deviceId;

  final SecureTokenStore _inner;
  // stub 平台不回写文件；字段保留以维持与 io 版本一致的构造签名。
  // ignore: unused_field
  final String? _bootstrapFile;
  // ignore: unused_field
  final String? _deviceId;

  @override
  Future<void> clear() => _inner.clear();

  @override
  Future<AuthTokens?> read() => _inner.read();

  @override
  Future<void> write(AuthTokens tokens) => _inner.write(tokens);
}
