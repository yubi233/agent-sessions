import '../domain/models.dart';

class LocalDevOwnerBootstrap {
  const LocalDevOwnerBootstrap({required this.tokens, required this.device});

  final AuthTokens tokens;
  final Device device;
}

Future<LocalDevOwnerBootstrap?> readLocalDevOwnerBootstrap() async => null;
