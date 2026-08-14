import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// P1 仍由 ChangeNotifier 承载单一应用状态；Riverpod 3 将该 provider 移到显式 legacy 入口。
import 'package:flutter_riverpod/legacy.dart';

import '../relay/fixture_relay_repository.dart';
import '../relay/http_relay_repository.dart';
import '../relay/relay_repository.dart';
import '../state/app_controller.dart';
import '../state/session_controller.dart';
import '../storage/encrypted_cache.dart';
import '../storage/secure_token_store.dart';

/// 未配置 RELAY_BASE_URL 时使用固定 fixture，保证 Android/Web 本地测试无需真实上游。
final secureTokenStoreProvider = Provider<SecureTokenStore>(
  (ref) => InMemorySecureTokenStore(),
);
final deviceIdentityStoreProvider = Provider<DeviceIdentityStore>(
  (ref) => InMemoryDeviceIdentityStore(),
);
final encryptedCacheStoreProvider = Provider<EncryptedCacheStore>(
  (ref) => InMemoryEncryptedCacheStore(),
);

final relayRepositoryProvider = Provider<RelayRepository>((ref) {
  const relayBaseUrl = String.fromEnvironment('RELAY_BASE_URL');
  if (relayBaseUrl.isEmpty) {
    return FixtureRelayRepository();
  }
  return HttpRelayRepository(
    dio: Dio(
      BaseOptions(
        baseUrl: relayBaseUrl,
        connectTimeout: const Duration(seconds: 10),
      ),
    ),
    readTokens: () => ref.read(secureTokenStoreProvider).read(),
  );
});

final appControllerProvider = ChangeNotifierProvider<AppController>((ref) {
  final controller = AppController(
    relay: ref.read(relayRepositoryProvider),
    tokenStore: ref.read(secureTokenStoreProvider),
    identityStore: ref.read(deviceIdentityStoreProvider),
    encryptedCache: ref.read(encryptedCacheStoreProvider),
  );
  unawaited(controller.initialize());
  return controller;
});

/// 会话流、lease 和 composer 与认证状态独立管理，避免登录页面 rebuild 影响已打开的时间线。
final sessionControllerProvider = ChangeNotifierProvider<SessionController>((
  ref,
) {
  final controller = SessionController(
    relay: ref.read(relayRepositoryProvider),
  );
  unawaited(controller.initialize());
  return controller;
});
