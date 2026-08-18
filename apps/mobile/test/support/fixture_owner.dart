import 'package:agent_sessions_mobile/domain/models.dart';
import 'package:agent_sessions_mobile/relay/fixture_relay_repository.dart';
import 'package:agent_sessions_mobile/storage/secure_token_store.dart';

/// 本地 mobile feature tests 的 Happy-style owner 初始化结果。
/// 认证兼容性测试仍可直接使用 register/login；业务 fixture 不应依赖账号登录。
class FixtureOwner {
  const FixtureOwner({
    required this.tokens,
    required this.device,
    required this.identity,
  });

  final AuthTokens tokens;
  final Device device;
  final DeviceRegistrationMaterial identity;

  String get deviceId => device.id;
}

Future<FixtureOwner> bootstrapFixtureOwner(
  FixtureRelayRepository relay, {
  InMemorySecureTokenStore? tokens,
  InMemoryDeviceIdentityStore? identities,
  String displayName = '本地 Android 控制端',
}) async {
  final identityStore = identities ?? InMemoryDeviceIdentityStore();
  final identity = await identityStore.createOrRead();
  final result = await relay.bootstrapDevice(
    BootstrapOwnerInput(
      displayName: displayName,
      platform: 'android',
      keys: identity,
    ),
  );
  if (result.tokens.deviceId != result.device.id) {
    throw StateError('本地 bootstrap 返回了不一致的设备绑定。');
  }
  final tokenStore = tokens;
  if (tokenStore != null) {
    await tokenStore.write(result.tokens);
  }
  await identityStore.bindDeviceId(result.device.id);
  await identityStore.markOwnerBootstrapComplete(true);
  return FixtureOwner(
    tokens: result.tokens,
    device: result.device,
    identity: identity,
  );
}
