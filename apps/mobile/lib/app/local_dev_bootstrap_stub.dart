import '../domain/models.dart';

class LocalDevOwnerBootstrap {
  const LocalDevOwnerBootstrap({required this.tokens, required this.device});

  final AuthTokens tokens;
  final Device device;
}

Future<LocalDevOwnerBootstrap?> readLocalDevOwnerBootstrap() async => null;

/// stub 平台（web）无 localdev 私钥注入；与 io 版本保持同名同形状。
String? readLocalDevEncryptionPrivateKeyB64() => null;
