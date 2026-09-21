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

/// stub 平台直通 no-op；与 io 版本保持同名同形状。
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
  Future<void> write(AuthTokens tokens) => _inner.write(tokens);
}
