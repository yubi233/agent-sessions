import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:agent_sessions_mobile/domain/models.dart';
import 'package:agent_sessions_mobile/relay/fixture_relay_repository.dart';
import 'package:agent_sessions_mobile/relay/http_relay_repository.dart';
import 'package:agent_sessions_mobile/state/app_controller.dart';
import 'package:agent_sessions_mobile/storage/encrypted_cache.dart';
import 'package:agent_sessions_mobile/storage/secure_token_store.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// 2026-09-16 真机事故回归（token.reuse_detected → 整族撤销 → 用户被登出）：
/// 冷启动时 AppController 的启动刷新绕过 HttpRelayRepository 的 single-flight，
/// 与 SessionController 首批请求 401 触发的刷新并发携带同一把轮转式 refresh
/// token，后到者触发 Relay reuse 检测。修复后启动刷新必须与 401/SSE 刷新
/// 共享同一条在途 /v1/auth/refresh。
void main() {
  group('MOBILE-REUSE 冷启动刷新 single-flight', () {
    test('启动恢复与 401 触发刷新并发时 /v1/auth/refresh 只发一条', () async {
      final refreshCalls = <String>[];
      final tokens = InMemorySecureTokenStore();
      await tokens.write(
        AuthTokens(
          accessToken: 'access-stale',
          refreshToken: 'refresh-live',
          // needsRefresh 的判定是 expiresAt < now+1min，取明确的过去时刻。
          expiresAt: DateTime.now().subtract(const Duration(hours: 1)),
          deviceId: 'dev_owner',
        ),
      );
      final adapter = _ScriptedAdapter((options) async {
        if (options.path == '/v1/auth/refresh') {
          refreshCalls.add(options.data['refresh_token'] as String);
          // 人为拉长在途窗口，复现两条刷新并发的时间窗。
          await Future<void>.delayed(const Duration(milliseconds: 50));
          return _jsonResponse({
            'account_id': 'acct_1',
            'device_id': 'dev_owner',
            'access_token': 'access-fresh',
            'refresh_token': 'refresh-rotated',
            'expires_in': 900,
          }, statusCode: 200);
        }
        final authorization = options.headers['Authorization'];
        if (authorization == 'Bearer access-stale') {
          return _jsonResponse({'error': 'unauthenticated'}, statusCode: 401);
        }
        if (options.path == '/v1/devices') {
          return _jsonResponse({'devices': []}, statusCode: 200);
        }
        fail('意外路径：${options.path}');
      });
      final dio = Dio(BaseOptions(baseUrl: 'http://relay.fixture'));
      dio.httpClientAdapter = adapter;
      final repository = HttpRelayRepository(
        dio: dio,
        readTokens: () => tokens.read(),
        writeTokens: tokens.write,
      );
      final controller = AppController(
        relay: repository,
        tokenStore: tokens,
        identityStore: InMemoryDeviceIdentityStore(),
        encryptedCache: InMemoryEncryptedCacheStore(),
        refreshFromStore: repository.refreshStoredTokens,
      );

      // 事故形状：启动恢复与首批认证请求（此处以 listDevices 代表 401 触发源）
      // 同一时刻并发执行。
      await Future.wait([controller.initialize(), repository.listDevices()]);

      // 同一把旧 refresh token 只允许一条在途刷新；第二条会触发 reuse 撤销。
      expect(refreshCalls, ['refresh-live']);
      expect(controller.isAuthenticated, isTrue);
      expect(controller.phase, AppAuthPhase.authenticated);
      // 轮转后的 refresh token 已落盘：下一次刷新携带的是新 token。
      expect((await tokens.read())?.refreshToken, 'refresh-rotated');
    });

    test('启动刷新被服务端拒绝（unauthorized）时清理本机认证并给出重连提示', () async {
      final tokens = InMemorySecureTokenStore();
      await tokens.write(
        AuthTokens(
          accessToken: 'access-stale',
          refreshToken: 'refresh-dead',
          expiresAt: DateTime.now().subtract(const Duration(hours: 1)),
          deviceId: 'dev_owner',
        ),
      );
      final identities = InMemoryDeviceIdentityStore();
      await identities.bindDeviceId('dev_owner');
      final controller = AppController(
        relay: FixtureRelayRepository(),
        tokenStore: tokens,
        identityStore: identities,
        encryptedCache: InMemoryEncryptedCacheStore(),
        // 模拟 single-flight 刷新被服务端明确拒绝（reuse 撤销/家族失效）：
        // 凭据终态以 unauthorized 抛出。
        refreshFromStore: () async =>
            throw const RelayFailure(RelayFailureKind.unauthorized, '拒绝刷新'),
      );

      await controller.initialize();

      expect(controller.phase, AppAuthPhase.signedOut);
      expect(controller.isAuthenticated, isFalse);
      expect(controller.errorMessage, '设备连接已失效，请重新连接或使用恢复码。');
      // 凭据终态必须清理本机 token（与既有语义一致）。
      expect(await tokens.read(), isNull);
    });

    test('启动刷新暂时不可达（null）时保留凭据并提示可重试', () async {
      final tokens = InMemorySecureTokenStore();
      final stored = AuthTokens(
        accessToken: 'access-stale',
        refreshToken: 'refresh-live',
        expiresAt: DateTime.now().subtract(const Duration(hours: 1)),
        deviceId: 'dev_owner',
      );
      await tokens.write(stored);
      final controller = AppController(
        relay: FixtureRelayRepository(),
        tokenStore: tokens,
        identityStore: InMemoryDeviceIdentityStore(),
        encryptedCache: InMemoryEncryptedCacheStore(),
        // null = 网络/5xx 暂时不可达：凭据可能仍有效，不得清理本机认证。
        refreshFromStore: () async => null,
      );

      await controller.initialize();

      expect(controller.phase, AppAuthPhase.signedOut);
      expect(controller.errorMessage, 'Relay 暂时不可用，请稍后重试。');
      // 关键差异：暂时失败不销毁凭据——网络恢复后重启应用即可无损恢复会话。
      expect((await tokens.read())?.refreshToken, 'refresh-live');
    });

    test('handleAuthInvalid 只在已认证态收敛一次（幂等）', () async {
      final tokens = InMemorySecureTokenStore();
      final identities = InMemoryDeviceIdentityStore();
      final controller = AppController(
        relay: FixtureRelayRepository(),
        tokenStore: tokens,
        identityStore: identities,
        encryptedCache: InMemoryEncryptedCacheStore(),
      );
      await controller.connectThisDevice();
      expect(controller.isAuthenticated, isTrue);
      expect(await tokens.read(), isNotNull);

      // 运行期并发 401（reuse 撤销后）会多次触发；只有第一次生效。
      await controller.handleAuthInvalid();
      await controller.handleAuthInvalid();

      expect(controller.phase, AppAuthPhase.signedOut);
      expect(controller.errorMessage, '设备连接已失效，请重新连接或使用恢复码。');
      expect(await tokens.read(), isNull);
      expect(controller.devices, isEmpty);
    });

    test('无 refreshFromStore（fixture 模式）时保留直接刷新兜底', () async {
      final tokens = InMemorySecureTokenStore();
      await tokens.write(
        AuthTokens(
          accessToken: 'fixture-access-token-stale',
          refreshToken: 'fixture-refresh-token-dev_owner',
          expiresAt: DateTime.now().subtract(const Duration(hours: 1)),
          deviceId: 'dev_owner',
        ),
      );
      final identities = InMemoryDeviceIdentityStore();
      final controller = AppController(
        relay: FixtureRelayRepository(),
        tokenStore: tokens,
        identityStore: identities,
        encryptedCache: InMemoryEncryptedCacheStore(),
      );

      await controller.initialize();

      expect(controller.isAuthenticated, isTrue);
      final stored = await tokens.read();
      expect(stored?.refreshToken, 'fixture-refresh-token-dev_owner');
      expect(controller.boundDeviceId, 'dev_owner');
    });
  });
}

class _ScriptedAdapter implements HttpClientAdapter {
  _ScriptedAdapter(this._handler);

  final Future<ResponseBody> Function(RequestOptions options) _handler;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) => _handler(options);
}

ResponseBody _jsonResponse(Map<String, dynamic> body, {int statusCode = 200}) =>
    ResponseBody.fromString(
      jsonEncode(body),
      statusCode,
      headers: const {
        'content-type': ['application/json'],
      },
    );
