import 'dart:convert';
import 'dart:typed_data';

import 'package:agent_sessions_mobile/domain/models.dart';
import 'package:agent_sessions_mobile/domain/session_models.dart';
import 'package:agent_sessions_mobile/relay/http_relay_repository.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MOBILE-01 HttpRelayRepository 协议映射', () {
    test('密码登录不发送 device_id 或 Android 角色，并解析未绑定 token', () async {
      final adapter = _FixtureHttpAdapter((options) {
        expect(options.path, '/v1/auth/login');
        expect(options.method, 'POST');
        expect(options.data, {
          'email': 'owner@example.test',
          'password': 'fixture-password',
        });
        return _jsonResponse({
          'account_id': 'acct_1',
          'access_token': 'access-fixture',
          'refresh_token': 'refresh-fixture',
          'expires_in': 300,
        });
      });
      final repository = _repository(adapter);

      final tokens = await repository.login(
        const LoginCredentials(
          email: ' owner@example.test ',
          password: 'fixture-password',
        ),
      );

      expect(tokens.accessToken, 'access-fixture');
      expect(tokens.refreshToken, 'refresh-fixture');
      expect(tokens.deviceId, isNull);
      expect(tokens.expiresAt, DateTime.utc(2026, 8, 14, 0, 5));
    });

    test('恢复响应需要嵌套的设备绑定 token 与 owner 设备 DTO', () async {
      final adapter = _FixtureHttpAdapter((options) {
        expect(options.path, '/v1/recovery-codes/restore');
        expect(options.data, {
          'email': 'recover@example.test',
          'recovery_code': 'RECOVERY-FIXTURE',
          'display_name': 'Recovered Android',
          'platform': 'android',
          'identity_public_key': 'identity-public',
          'encryption_public_key': 'encryption-public',
        });
        return _jsonResponse({
          'device': {
            'id': 'dev_recovered',
            'role': 'android_owner',
            'status': 'active',
            'display_name': 'Recovered Android',
            'platform': 'android',
          },
          'tokens': {
            'account_id': 'acct_1',
            'device_id': 'dev_recovered',
            'access_token': 'access-recovered',
            'refresh_token': 'refresh-recovered',
            'expires_in': 600,
          },
        });
      });
      final repository = _repository(adapter);

      final restored = await repository.restoreWithRecoveryCode(
        const RecoveryCodeInput(
          email: ' recover@example.test ',
          code: 'RECOVERY-FIXTURE',
          displayName: 'Recovered Android',
          keys: DeviceRegistrationMaterial(
            identityPublicKey: 'identity-public',
            encryptionPublicKey: 'encryption-public',
          ),
        ),
      );

      expect(restored.device.id, 'dev_recovered');
      expect(restored.device.role, DeviceRole.androidOwner);
      expect(restored.tokens.deviceId, 'dev_recovered');
      expect(restored.tokens.expiresAt, DateTime.utc(2026, 8, 14, 0, 10));
    });

    test('恢复响应缺少 token device_id 时拒绝切换本机身份', () async {
      final adapter = _FixtureHttpAdapter(
        (_) => _jsonResponse({
          'device': {
            'id': 'dev_recovered',
            'role': 'android_owner',
            'status': 'active',
            'display_name': 'Recovered Android',
            'platform': 'android',
          },
          'tokens': {
            'access_token': 'access-recovered',
            'refresh_token': 'refresh-recovered',
            'expires_in': 600,
          },
        }),
      );

      await expectLater(
        _repository(adapter).restoreWithRecoveryCode(_recoveryInput()),
        throwsA(
          isA<RelayFailure>().having(
            (failure) => failure.kind,
            'kind',
            RelayFailureKind.protocol,
          ),
        ),
      );
    });

    test('恢复响应 token device_id 与 device DTO 不一致时拒绝', () async {
      final adapter = _FixtureHttpAdapter(
        (_) => _jsonResponse({
          'device': {
            'id': 'dev_recovered',
            'role': 'android_owner',
            'status': 'active',
            'display_name': 'Recovered Android',
            'platform': 'android',
          },
          'tokens': {
            'device_id': 'another-device',
            'access_token': 'access-recovered',
            'refresh_token': 'refresh-recovered',
            'expires_in': 600,
          },
        }),
      );

      await expectLater(
        _repository(adapter).restoreWithRecoveryCode(_recoveryInput()),
        throwsA(
          isA<RelayFailure>().having(
            (failure) => failure.kind,
            'kind',
            RelayFailureKind.protocol,
          ),
        ),
      );
    });

    test('限流错误映射为可重试的脱敏 RelayFailure', () async {
      final adapter = _FixtureHttpAdapter(
        (_) => _jsonResponse({'code': 'RECOVERY_LOCKED'}, statusCode: 429),
      );
      final repository = _repository(adapter);

      await expectLater(
        repository.login(
          const LoginCredentials(
            email: 'owner@example.test',
            password: 'fixture-password',
          ),
        ),
        throwsA(
          isA<RelayFailure>().having(
            (failure) => failure.kind,
            'kind',
            RelayFailureKind.unavailable,
          ),
        ),
      );
    });

    test('会话写命令映射正 lease 与幂等键，但不把 device_id 放进 HTTP body', () async {
      final adapter = _FixtureHttpAdapter((options) {
        expect(options.path, '/v1/sessions/session_1/commands');
        expect(options.method, 'POST');
        expect(options.data, {
          'kind': 'session.send',
          'idempotency_key': 'idem-session-1',
          'lease_epoch': 7,
          'ciphertext': {
            'fixture_payload': {'message': 'safe fixture'},
          },
        });
        expect((options.data as Map).containsKey('device_id'), isFalse);
        return _jsonResponse({
          'id': 'command_1',
          'kind': 'session.send',
          'status': 'accepted',
          'idempotency_key': 'idem-session-1',
          'lease_epoch': 7,
        }, statusCode: 202);
      });
      final repository = _authenticatedRepository(adapter);

      final receipt = await repository.submitSessionCommand(
        'session_1',
        const SessionCommandInput(
          kind: SessionCommandKind.send,
          idempotencyKey: 'idem-session-1',
          leaseEpoch: 7,
          deviceId: 'android-owner-local-boundary',
          ciphertext: {
            'fixture_payload': {'message': 'safe fixture'},
          },
        ),
      );

      expect(receipt.status, 'accepted');
      expect(receipt.leaseEpoch, 7);
    });

    test('会话快照保留 opaque envelope 并发送 after_seq 查询参数', () async {
      final adapter = _FixtureHttpAdapter((options) {
        expect(options.path, '/v1/sessions/session_1/snapshot');
        expect(options.queryParameters, {'after_seq': 4});
        return _jsonResponse({
          'session': {
            'id': 'session_1',
            'workspace_id': 'workspace_1',
            'status': 'streaming',
            'provider': 'codex',
            'last_seq': 5,
          },
          'events': [
            {
              'event_seq': 5,
              'event_type': 'message.delta',
              'envelope': {'alg': 'opaque-ciphertext'},
            },
          ],
        });
      });

      final snapshot = await _authenticatedRepository(
        adapter,
      ).getSessionSnapshot('session_1', afterSequence: 4);

      expect(snapshot.session.lastSequence, 5);
      expect(snapshot.events.single.envelope, {'alg': 'opaque-ciphertext'});
    });

    test('零 lease 在客户端边界被拒绝，不发出 Relay 命令', () async {
      await expectLater(
        _authenticatedRepository(
          _FixtureHttpAdapter((_) {
            fail('零 lease 不应发起 HTTP 请求');
          }),
        ).submitSessionCommand(
          'session_1',
          const SessionCommandInput(
            kind: SessionCommandKind.abort,
            idempotencyKey: 'idem-zero',
            leaseEpoch: 0,
            deviceId: 'android-owner-local-boundary',
          ),
        ),
        throwsA(
          isA<RelayFailure>().having(
            (failure) => failure.kind,
            'kind',
            RelayFailureKind.validation,
          ),
        ),
      );
    });
  });
}

RecoveryCodeInput _recoveryInput() => const RecoveryCodeInput(
  email: 'recover@example.test',
  code: 'RECOVERY-FIXTURE',
  displayName: 'Recovered Android',
  keys: DeviceRegistrationMaterial(
    identityPublicKey: 'identity-public',
    encryptionPublicKey: 'encryption-public',
  ),
);

HttpRelayRepository _repository(_FixtureHttpAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: 'http://relay.fixture'));
  dio.httpClientAdapter = adapter;
  return HttpRelayRepository(
    dio: dio,
    readTokens: () async => null,
    clock: () => DateTime.utc(2026, 8, 14),
  );
}

HttpRelayRepository _authenticatedRepository(_FixtureHttpAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: 'http://relay.fixture'));
  dio.httpClientAdapter = adapter;
  return HttpRelayRepository(
    dio: dio,
    readTokens: () async => AuthTokens(
      accessToken: 'fixture-owner-access-token',
      refreshToken: 'fixture-owner-refresh-token',
      expiresAt: DateTime.utc(2026, 8, 14, 1),
      deviceId: 'android-owner-fixture',
    ),
    clock: () => DateTime.utc(2026, 8, 14),
  );
}

ResponseBody _jsonResponse(Object body, {int statusCode = 200}) =>
    ResponseBody.fromString(
      jsonEncode(body),
      statusCode,
      headers: const {
        'content-type': ['application/json'],
      },
    );

/// 纯内存 Dio transport：断言客户端实际发出的 method/path/body，不启动网络服务。
class _FixtureHttpAdapter implements HttpClientAdapter {
  _FixtureHttpAdapter(this._handler);

  final ResponseBody Function(RequestOptions options) _handler;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => _handler(options);
}
