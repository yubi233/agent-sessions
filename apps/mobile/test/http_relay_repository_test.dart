import 'dart:convert';
import 'dart:typed_data';

import 'package:agent_sessions_mobile/domain/control_models.dart';
import 'package:agent_sessions_mobile/domain/daemon_observation_models.dart';
import 'package:agent_sessions_mobile/domain/delegation_models.dart';
import 'package:agent_sessions_mobile/domain/models.dart';
import 'package:agent_sessions_mobile/domain/session_models.dart';
import 'package:agent_sessions_mobile/domain/terminal_models.dart';
import 'package:agent_sessions_mobile/domain/usage_models.dart';
import 'package:agent_sessions_mobile/relay/http_relay_repository.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MOBILE-01 HttpRelayRepository 协议映射', () {
    test('设备 bootstrap 不发送账号密码并解析绑定 owner token', () async {
      final adapter = _FixtureHttpAdapter((options) {
        expect(options.path, '/v1/auth/device-bootstrap');
        expect(options.method, 'POST');
        expect(options.data, {
          'display_name': '此 Android 控制端',
          'platform': 'android',
          'identity_public_key': 'identity-public',
          'encryption_public_key': 'encryption-public',
        });
        return _jsonResponse({
          'device': {
            'id': 'dev_owner',
            'role': 'android_owner',
            'status': 'active',
            'display_name': '此 Android 控制端',
            'platform': 'android',
          },
          'tokens': {
            'account_id': 'acct_1',
            'device_id': 'dev_owner',
            'access_token': 'access-owner',
            'refresh_token': 'refresh-owner',
            'expires_in': 600,
          },
        }, statusCode: 201);
      });
      final repository = _repository(adapter);

      final result = await repository.bootstrapDevice(
        const BootstrapOwnerInput(
          displayName: '此 Android 控制端',
          platform: 'android',
          keys: DeviceRegistrationMaterial(
            identityPublicKey: 'identity-public',
            encryptionPublicKey: 'encryption-public',
          ),
        ),
      );

      expect(result.device.id, 'dev_owner');
      expect(result.device.role, DeviceRole.androidOwner);
      expect(result.tokens.deviceId, 'dev_owner');
      expect(result.tokens.expiresAt, DateTime.utc(2026, 8, 14, 0, 10));
    });

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

    test('恢复请求不发送邮箱，并解析嵌套的设备绑定 token 与 owner 设备 DTO', () async {
      final adapter = _FixtureHttpAdapter((options) {
        expect(options.path, '/v1/recovery-codes/restore');
        expect(options.data, {
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
          email: '',
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

    test('start/kill 使用同一 commands API，且不携带账号、密码或可伪造 device_id', () async {
      var call = 0;
      final adapter = _FixtureHttpAdapter((options) {
        expect(options.path, '/v1/sessions/session_1/commands');
        expect(options.method, 'POST');
        final body = Map<String, dynamic>.from(options.data as Map);
        final expectedKind = call++ == 0 ? 'session.start' : 'session.kill';
        expect(body['kind'], expectedKind);
        expect(body['lease_epoch'], 7);
        expect(body.containsKey('device_id'), isFalse);
        expect(body.containsKey('email'), isFalse);
        expect(body.containsKey('password'), isFalse);
        return _jsonResponse({
          'id': 'command-$call',
          'kind': expectedKind,
          'status': 'accepted',
          'idempotency_key': 'idem-$call',
          'lease_epoch': 7,
        }, statusCode: 202);
      });
      final repository = _authenticatedRepository(adapter);

      await repository.submitSessionCommand(
        'session_1',
        const SessionCommandInput(
          kind: SessionCommandKind.start,
          idempotencyKey: 'idem-1',
          leaseEpoch: 7,
          deviceId: 'android-owner-local-boundary',
        ),
      );
      await repository.submitSessionCommand(
        'session_1',
        const SessionCommandInput(
          kind: SessionCommandKind.kill,
          idempotencyKey: 'idem-2',
          leaseEpoch: 7,
          deviceId: 'android-owner-local-boundary',
        ),
      );
      expect(call, 2);
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

    test('P2-F 只读取 Daemon 安全观察投影，不请求 Terminal SSE 或原始密文', () async {
      final adapter = _FixtureHttpAdapter((options) {
        expect(options.path, '/v1/sessions/session_1/commands');
        expect(options.method, 'GET');
        expect(options.queryParameters, {'after_seq': 8});
        expect(options.data, isNull);
        return _jsonResponse({
          'session': {
            'status': 'running',
            'provider': 'opencode',
            'last_seq': 9,
          },
          'commands': [
            {
              'kind': 'session.start',
              'status': 'failed',
              'delivery_state': 'resolved',
              'error_code': 'DAEMON_RESTART_RECOVERY',
            },
          ],
          'events': [
            {
              'event_seq': 9,
              'event_type': 'message.delta',
              'envelope': {
                'state': 'verified',
                'algorithm': 'v1-aes256gcm-hkdfsha256',
                'payload_version': 1,
              },
            },
          ],
        });
      });

      final observation = await _authenticatedRepository(
        adapter,
      ).getSessionDaemonObservation('session_1', afterSequence: 8);

      expect(observation.session.lastSequence, 9);
      expect(
        observation.commands.single.kind,
        DaemonObservationCommandKind.start,
      );
      expect(
        observation.commands.single.errorCode,
        DaemonObservationErrorCode.daemonRestartRecovery,
      );
      expect(
        observation.events.single.eventType,
        DaemonObservationEventType.messageDelta,
      );
      expect(
        observation.events.single.envelope.state,
        CipherEnvelopeState.verified,
      );
      // DTO 不保留 key_id、nonce、AAD 或 ciphertext；编译期字段缺失就是该边界的契约。
      expect(observation.events.single.envelope.payloadVersion, 1);
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

    test('能力矩阵严格解析三态，未知状态降级为 unsupported', () async {
      final adapter = _FixtureHttpAdapter((options) {
        expect(options.path, '/v1/capabilities');
        expect(options.method, 'GET');
        expect(options.data, isNull);
        return _jsonResponse({
          'providers': [
            {
              'kind': 'codex',
              'version': 'fixture-1',
              'available': true,
              'capabilities': [
                {'name': 'plan', 'status': 'native'},
                {'name': 'goal', 'status': 'emulated'},
                {'name': 'attachments', 'status': 'future-state'},
              ],
            },
          ],
        });
      });

      final matrix = await _authenticatedRepository(adapter).getCapabilities();

      expect(
        matrix.provider('codex').capability('plan').availability,
        CapabilityAvailability.native,
      );
      expect(
        matrix.provider('codex').capability('goal').availability,
        CapabilityAvailability.emulated,
      );
      expect(
        matrix.provider('codex').capability('attachments').availability,
        CapabilityAvailability.unsupported,
      );
    });

    test('终端状态只读取账号白名单元数据，不请求或保留工作区路径', () async {
      final adapter = _FixtureHttpAdapter((options) {
        expect(options.path, '/v1/terminals');
        expect(options.method, 'GET');
        expect(options.data, isNull);
        expect(
          options.headers['Authorization'],
          'Bearer fixture-owner-access-token',
        );
        return _jsonResponse({
          'terminals': [
            {
              'id': 'term_opaque_fixture',
              'hostname': 'Fixture Mac',
              'platform': 'macos',
              'status': 'online',
              'last_seen_unix_ms': 1786665600000,
              'protocol_version': 1,
              'daemon_version': '0.4.0-fixture',
              // 服务端即便意外加入未白名单字段，客户端 DTO 也不会持有或显示它。
              'canonical_root': 'untrusted-path-omitted',
              'daemon_log': 'not for Android',
            },
          ],
        });
      });

      final terminals = await _authenticatedRepository(adapter).listTerminals();

      expect(terminals, hasLength(1));
      expect(terminals.single.hostname, 'Fixture Mac');
      expect(terminals.single.platform, 'macos');
      expect(terminals.single.protocolVersion, 1);
      expect(terminals.single.daemonVersion, '0.4.0-fixture');
      expect(
        terminals.single.availabilityAt(DateTime.utc(2026, 8, 14)),
        TerminalAvailability.online,
      );
    });

    test('Delegation 图只读取安全摘要，任务书字段必须被客户端拒绝', () async {
      final adapter = _FixtureHttpAdapter((options) {
        expect(options.path, '/v1/sessions/session_1/delegations');
        expect(options.method, 'GET');
        return _jsonResponse({
          'delegations': [
            {
              'id': 'delegation_1',
              'parent_session_id': 'session_1',
              'target_provider': 'codex',
              'status': 'proposed',
              'summary_envelope': {
                'alg': 'v1-aes256gcm-hkdfsha256',
                'key_id': 'fixture-dek',
                'nonce': 'fixture-nonce',
                'ciphertext': 'fixture-opaque',
                'aad_hash': 'fixture-aad',
                'payload_version': 1,
              },
              'summary_envelope_sha256': _fixtureHash('a'),
            },
          ],
        });
      });

      final delegations = await _authenticatedRepository(
        adapter,
      ).listSessionDelegations('session_1');

      expect(delegations.single.summaryFingerprint, 'aaaaaaaaaaaa');
      expect(delegations.single.childSessionId, isNull);
      expect(delegations.single.status, DelegationStatus.proposed);
      expect(
        () => SessionDelegation.fromRelayJson({
          'id': 'delegation_bad',
          'parent_session_id': 'session_1',
          'target_provider': 'codex',
          'status': 'proposed',
          'task_envelope': const {'plaintext': 'must-not-render'},
          'summary_envelope': {
            'alg': 'v1-aes256gcm-hkdfsha256',
            'key_id': 'fixture-dek',
            'nonce': 'fixture-nonce',
            'ciphertext': 'fixture-opaque',
            'aad_hash': 'fixture-aad',
            'payload_version': 1,
          },
          'summary_envelope_sha256': _fixtureHash('a'),
        }),
        throwsA(isA<RelayFailure>()),
      );
    });

    test('Delegation 决策只提交 parent lease 和幂等键，不发送 device_id', () async {
      final adapter = _FixtureHttpAdapter((options) {
        expect(options.path, '/v1/delegations/delegation_1/decision');
        expect(options.method, 'POST');
        expect(options.data, {
          'decision': 'approve',
          'idempotency_key': 'delegation-decision-1',
          'lease_epoch': 9,
        });
        expect((options.data as Map).containsKey('device_id'), isFalse);
        return _jsonResponse({
          'id': 'delegation_1',
          'parent_session_id': 'session_1',
          'child_session_id': 'child_1',
          'target_provider': 'codex',
          'status': 'running',
          'summary_envelope': {
            'alg': 'v1-aes256gcm-hkdfsha256',
            'key_id': 'fixture-dek',
            'nonce': 'fixture-nonce',
            'ciphertext': 'fixture-opaque',
            'aad_hash': 'fixture-aad',
            'payload_version': 1,
          },
          'summary_envelope_sha256': _fixtureHash('b'),
        });
      });

      final result = await _authenticatedRepository(adapter).decideDelegation(
        'delegation_1',
        const DelegationDecisionInput(
          decision: DelegationDecision.approve,
          idempotencyKey: 'delegation-decision-1',
          parentLeaseEpoch: 9,
          deviceId: 'android-owner-local-boundary',
        ),
      );

      expect(result.childSessionId, 'child_1');
      expect(result.status, DelegationStatus.running);
    });

    test('附件 DTO 以 base64 发送密文，不携带 device_id、filename 或本地显示名', () async {
      final adapter = _FixtureHttpAdapter((options) {
        expect(options.path, '/v1/attachments/chunks');
        expect(options.method, 'POST');
        expect(options.data, {
          'attachment_id': 'attachment_1',
          'session_id': 'session_1',
          'mime_type': 'text/markdown',
          'byte_size': 32,
          'compression': 'none',
          'metadata_ciphertext': 'AQID',
          'chunk_index': 0,
          'total_chunks': 1,
          'ciphertext': 'BAUG',
          'idempotency_key': 'attachment-chunk-1',
          'lease_epoch': 7,
        });
        final wire = options.data as Map;
        expect(wire.containsKey('device_id'), isFalse);
        expect(wire.containsKey('filename'), isFalse);
        expect(wire.containsKey('local_name'), isFalse);
        return _jsonResponse({
          'attachment_id': 'attachment_1',
          'chunk_index': 0,
          'status': 'pending',
          'idempotent': false,
        }, statusCode: 201);
      });
      final repository = _authenticatedRepository(adapter);
      final receipt = await repository.uploadAttachmentChunk(
        AttachmentChunkUploadInput(
          attachmentId: 'attachment_1',
          sessionId: 'session_1',
          mimeType: 'text/markdown',
          byteSize: 32,
          compression: 'none',
          metadataCiphertext: Uint8List.fromList([1, 2, 3]),
          chunkIndex: 0,
          totalChunks: 1,
          ciphertext: Uint8List.fromList([4, 5, 6]),
          idempotencyKey: 'attachment-chunk-1',
          leaseEpoch: 7,
          deviceId: 'android-owner-local-boundary',
        ),
      );

      expect(receipt.status, 'pending');
      expect(receipt.idempotent, isFalse);
    });

    test('附件 complete 使用 path id 和独立幂等键，不回传本地字段', () async {
      final adapter = _FixtureHttpAdapter((options) {
        expect(options.path, '/v1/attachments/attachment_1/complete');
        expect(options.method, 'POST');
        expect(options.data, {
          'session_id': 'session_1',
          'total_chunks': 1,
          'idempotency_key': 'attachment-complete-1',
          'lease_epoch': 7,
        });
        expect((options.data as Map).containsKey('device_id'), isFalse);
        expect((options.data as Map).containsKey('filename'), isFalse);
        return _jsonResponse({
          'attachment_id': 'attachment_1',
          'chunk_index': -1,
          'status': 'completed',
          'idempotent': true,
        });
      });

      final receipt = await _authenticatedRepository(adapter)
          .completeAttachment(
            const AttachmentCompleteInput(
              attachmentId: 'attachment_1',
              sessionId: 'session_1',
              totalChunks: 1,
              idempotencyKey: 'attachment-complete-1',
              leaseEpoch: 7,
              deviceId: 'android-owner-local-boundary',
            ),
          );

      expect(receipt.status, 'completed');
      expect(receipt.chunkIndex, -1);
      expect(receipt.idempotent, isTrue);
    });
  });

  group('MOBILE-20 HttpRelayRepository 用量映射', () {
    test(
      'getUsageSummary(days: 7) 请求 /v1/usage/summary?days=7 并聚合 Provider 计数',
      () async {
        final adapter = _FixtureHttpAdapter((options) {
          expect(options.path, '/v1/usage/summary?days=7');
          expect(options.method, 'GET');
          expect(options.data, isNull);
          expect(
            options.headers['Authorization'],
            'Bearer fixture-owner-access-token',
          );
          return _jsonResponse({
            'days': 7,
            'utc_today': '2026-08-16',
            'providers': [
              {
                'provider': 'codex',
                'utc_day': '2026-08-16',
                'input_tokens': 100,
                'output_tokens': 50,
                'cache_read_tokens': 20,
                'cache_write_tokens': 5,
              },
              {
                'provider': 'claude',
                'utc_day': '2026-08-16',
                'input_tokens': 30,
                'output_tokens': 25,
                'cache_read_tokens': 0,
                'cache_write_tokens': 10,
              },
            ],
          });
        });

        final UsageSummary summary = await _authenticatedRepository(
          adapter,
        ).getUsageSummary(days: 7);

        expect(summary.days, 7);
        expect(summary.utcToday, '2026-08-16');
        expect(summary.providers, hasLength(2));
        expect(summary.providers.first.provider, 'codex');
        expect(summary.providers.first.utcDay, '2026-08-16');
        expect(summary.providers.first.inputTokens, 100);
        expect(summary.providers.first.outputTokens, 50);
        expect(summary.providers.first.cacheReadTokens, 20);
        expect(summary.providers.first.cacheWriteTokens, 5);
        expect(summary.providers.first.totalTokens, 150);
        final (input, output) = summary.totals;
        expect(input, 130);
        expect(output, 75);
      },
    );

    test('缺 providers 字段的响应按 protocol 错误拒绝', () async {
      final adapter = _FixtureHttpAdapter(
        (_) => _jsonResponse({'days': 7, 'utc_today': '2026-08-16'}),
      );

      await expectLater(
        _authenticatedRepository(adapter).getUsageSummary(),
        throwsA(
          isA<RelayFailure>().having(
            (failure) => failure.kind,
            'kind',
            RelayFailureKind.protocol,
          ),
        ),
      );
    });

    test('days 非正数或非数值时按 protocol 错误拒绝', () async {
      for (final invalid in [0, -3, '7']) {
        final adapter = _FixtureHttpAdapter(
          (_) => _jsonResponse({
            'days': invalid,
            'utc_today': '2026-08-16',
            'providers': <Object>[],
          }),
        );

        await expectLater(
          _authenticatedRepository(adapter).getUsageSummary(),
          throwsA(
            isA<RelayFailure>().having(
              (failure) => failure.kind,
              'kind',
              RelayFailureKind.protocol,
            ),
          ),
        );
      }
    });

    test('响应体不是 JSON 对象时按 protocol 错误拒绝', () async {
      final adapter = _FixtureHttpAdapter(
        (_) => _jsonResponse(['not', 'an', 'object']),
      );

      await expectLater(
        _authenticatedRepository(adapter).getUsageSummary(),
        throwsA(
          isA<RelayFailure>().having(
            (failure) => failure.kind,
            'kind',
            RelayFailureKind.protocol,
          ),
        ),
      );
    });

    test('负数 token 计数被拒绝', () async {
      final adapter = _FixtureHttpAdapter(
        (_) => _jsonResponse({
          'days': 7,
          'utc_today': '2026-08-16',
          'providers': [
            {
              'provider': 'codex',
              'utc_day': '2026-08-16',
              'input_tokens': -1,
              'output_tokens': 50,
              'cache_read_tokens': 0,
              'cache_write_tokens': 0,
            },
          ],
        }),
      );

      await expectLater(
        _authenticatedRepository(adapter).getUsageSummary(),
        throwsA(
          isA<RelayFailure>().having(
            (failure) => failure.kind,
            'kind',
            RelayFailureKind.protocol,
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

String _fixtureHash(String character) =>
    List<String>.filled(64, character).join();

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
