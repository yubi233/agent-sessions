import 'dart:convert';
import 'dart:typed_data';

import 'package:agent_sessions_mobile/domain/control_models.dart';
import 'package:agent_sessions_mobile/domain/daemon_observation_models.dart';
import 'package:agent_sessions_mobile/domain/delegation_models.dart';
import 'package:agent_sessions_mobile/domain/models.dart';
import 'package:agent_sessions_mobile/domain/session_models.dart';
import 'package:agent_sessions_mobile/domain/session_projection_models.dart';
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

    test('workspace 列表与目录登记映射白名单字段，不发送 device_id', () async {
      var call = 0;
      final adapter = _FixtureHttpAdapter((options) {
        call += 1;
        if (call == 1) {
          expect(options.path, '/v1/workspaces');
          expect(options.method, 'GET');
          return _jsonResponse({
            'workspaces': [
              {
                'id': 'workspace_1',
                'project_id': 'project_1',
                'terminal_id': 'terminal_1',
                'origin': 'managed',
                'branch': 'main',
                'status': 'active',
              },
            ],
          });
        }
        expect(options.path, '/v1/workspaces');
        expect(options.method, 'POST');
        expect(options.data, {
          'project_id': 'project_2',
          'canonical_root': '/host/project-2',
          'terminal_id': 'terminal_2',
          'branch': 'feature/v05',
          'status': 'active',
        });
        expect((options.data as Map).containsKey('device_id'), isFalse);
        return _jsonResponse({
          'id': 'workspace_2',
          'project_id': 'project_2',
          'terminal_id': 'terminal_2',
          'origin': 'managed',
          'branch': 'feature/v05',
          'status': 'active',
        }, statusCode: 201);
      });
      final repository = _authenticatedRepository(adapter);

      final listed = await repository.listWorkspaces();
      final created = await repository.createWorkspace(
        const CreateMobileWorkspaceInput(
          projectId: 'project_2',
          canonicalRoot: '/host/project-2',
          deviceId: 'android-owner-local-boundary',
          terminalId: 'terminal_2',
          branch: 'feature/v05',
        ),
      );

      expect(listed.single.id, 'workspace_1');
      expect(listed.single.projectId, 'project_1');
      expect(created.id, 'workspace_2');
      expect(call, 2);
    });

    test('V07 workspace.create 只发送名称和可选 Terminal，不泄漏路径或 device_id', () async {
      final adapter = _FixtureHttpAdapter((options) {
        expect(options.path, '/v1/workspaces/create-with-folder');
        expect(options.method, 'POST');
        expect(options.data, {
          'name': 'v07-http-project',
          'terminal_id': 'term_1',
        });
        final body = options.data as Map;
        expect(body.containsKey('canonical_root'), isFalse);
        expect(body.containsKey('device_id'), isFalse);
        return _jsonResponse({
          'status': 'succeeded',
          'workspace_id': 'ws_v07_http',
          'workspace': {
            'id': 'ws_v07_http',
            'project_id': 'proj_v07_http',
            'terminal_id': 'term_1',
            'status': 'active',
          },
        });
      });

      final state = await _authenticatedRepository(adapter)
          .createWorkspaceWithFolder(
            const CreateMobileWorkspaceWithFolderInput(
              name: 'v07-http-project',
              deviceId: 'android-owner-local-boundary',
              terminalId: 'term_1',
            ),
          );
      expect(state.isSucceeded, isTrue);
      expect(state.workspaceId, 'ws_v07_http');
      expect(state.workspace?.projectId, 'proj_v07_http');
    });

    test('V07 workspace.create pending 状态轮询只读取 command id 且拒绝路径字段', () async {
      var call = 0;
      final adapter = _FixtureHttpAdapter((options) {
        call += 1;
        expect(options.method, 'GET');
        expect(options.path, '/v1/workspaces/create-with-folder/cmd_v07');
        expect(options.data, isNull);
        return _jsonResponse({
          'status': 'pending',
          'command_id': 'cmd_v07',
          'workspace_id': 'ws_v07_pending',
          // 恶意/错误服务端字段不能被 DTO 传播到客户端模型。
          'canonical_root': '/Users/secret/project',
        });
      });
      final state = await _authenticatedRepository(
        adapter,
      ).getWorkspaceCreateState('cmd_v07');
      expect(call, 1);
      expect(state.isPending, isTrue);
      expect(state.commandId, 'cmd_v07');
      expect(state.workspace, isNull);
    });

    test('V081 DSH 同步与导入只传 opaque ID，并解析脱敏轮询状态', () async {
      var call = 0;
      final adapter = _FixtureHttpAdapter((options) {
        call += 1;
        switch (call) {
          case 1:
            expect(options.method, 'POST');
            expect(options.path, '/v1/workspaces/sync-dsh');
            expect(options.data, {'terminal_id': 'term_dsh'});
            return _jsonResponse({
              'status': 'pending',
              'command_id': 'cmd_sync_dsh',
              // 非白名单私有字段不能进入客户端 DTO。
              'canonical_root': '/Users/private/agent-sessions',
            });
          case 2:
            expect(options.method, 'GET');
            expect(options.path, '/v1/workspaces/sync-dsh/cmd_sync_dsh');
            expect(options.data, isNull);
            return _jsonResponse({
              'status': 'succeeded',
              'command_id': 'cmd_sync_dsh',
              'workspace_ids': ['ws_dsh'],
            });
          case 3:
            expect(options.method, 'POST');
            expect(options.path, '/v1/workspaces/import-dsh');
            expect(options.data, {
              'workspace_id': 'ws_dsh',
              'terminal_id': 'term_dsh',
            });
            return _jsonResponse({
              'status': 'pending',
              'command_id': 'cmd_import_dsh',
              'jsonl_path': '/Users/private/.dsh/history.jsonl',
            });
          case 4:
            expect(options.method, 'GET');
            expect(options.path, '/v1/workspaces/import-dsh/cmd_import_dsh');
            expect(options.data, isNull);
            return _jsonResponse({
              'status': 'succeeded',
              'command_id': 'cmd_import_dsh',
              'session_ids': ['session_dsh_1'],
            });
        }
        fail('unexpected request $call');
      });
      final repository = _authenticatedRepository(adapter);

      final syncPending = await repository.syncDSHWorkspaces(
        terminalId: 'term_dsh',
      );
      final syncCompleted = await repository.getDSHWorkspaceSyncState(
        'cmd_sync_dsh',
      );
      final importPending = await repository.importDSHSessions(
        workspaceId: 'ws_dsh',
        terminalId: 'term_dsh',
      );
      final importCompleted = await repository.getDSHImportState(
        'cmd_import_dsh',
      );

      expect(syncPending.isPending, isTrue);
      expect(syncCompleted.workspaceIds, ['ws_dsh']);
      expect(importPending.isPending, isTrue);
      expect(importCompleted.sessionIds, ['session_dsh_1']);
      expect(call, 4);
    });

    test('V07 workspace.create 非法名称在客户端校验，不发 HTTP 请求', () async {
      var calls = 0;
      final adapter = _FixtureHttpAdapter((_) {
        calls += 1;
        return _jsonResponse({});
      });
      await expectLater(
        _authenticatedRepository(adapter).createWorkspaceWithFolder(
          const CreateMobileWorkspaceWithFolderInput(
            name: '../escape',
            deviceId: 'android-owner-local-boundary',
          ),
        ),
        throwsA(isA<RelayFailure>()),
      );
      expect(calls, 0);
    });

    test('真实 Relay 未定义 agent preset 时会话创建保持协议白名单', () async {
      final adapter = _FixtureHttpAdapter((options) {
        expect(options.path, '/v1/sessions');
        expect(options.method, 'POST');
        expect(options.data, {
          'workspace_id': 'workspace_1',
          'provider': 'codex',
        });
        return _jsonResponse({
          'id': 'session_1',
          'workspace_id': 'workspace_1',
          'status': 'idle',
          'provider': 'codex',
          'last_seq': 0,
        }, statusCode: 201);
      });

      final session = await _authenticatedRepository(adapter).createSession(
        const CreateMobileSessionInput(
          workspaceId: 'workspace_1',
          provider: 'codex',
          deviceId: 'android-owner-local-boundary',
          agentPresetId: 'fixture-must-not-cross-production-wire',
        ),
      );

      expect(session.id, 'session_1');
      expect(session.agentPresetId, isNull);
    });

    test('会话写命令映射正 lease 与幂等键，但不把 device_id 放进 HTTP body', () async {
      final adapter = _FixtureHttpAdapter((options) {
        expect(options.path, '/v1/sessions/session_1/commands');
        expect(options.method, 'POST');
        expect(options.data, {
          'kind': 'session.send',
          'idempotency_key': 'idem-session-1',
          'lease_epoch': 7,
          // Daemon 契约：顶层 session_id + ciphertext.fixture_payload 业务负载。
          'ciphertext': {
            'session_id': 'session_1',
            'ciphertext': {
              'fixture_payload': {'message': 'safe fixture'},
            },
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

    test('命令 payload 统一补齐 Daemon 顶层 session_id，无负载命令也不例外', () async {
      Map<String, dynamic>? capturedBody;
      final adapter = _FixtureHttpAdapter((options) {
        capturedBody = Map<String, dynamic>.from(options.data as Map);
        return _jsonResponse({
          'id': 'command-abort',
          'kind': 'session.abort',
          'status': 'accepted',
          'idempotency_key': 'idem-abort',
          'lease_epoch': 7,
        }, statusCode: 202);
      });
      final repository = _authenticatedRepository(adapter);

      await repository.submitSessionCommand(
        'session_1',
        const SessionCommandInput(
          kind: SessionCommandKind.abort,
          idempotencyKey: 'idem-abort',
          leaseEpoch: 7,
          deviceId: 'android-owner-local-boundary',
        ),
      );

      // internal/daemon/runner.go parseEnvelope 只读顶层 session_id；
      // 缺失时 session.abort 会以「缺少 session_id」fail-closed。
      expect(capturedBody?['ciphertext'], {
        'session_id': 'session_1',
        'ciphertext': {'fixture_payload': <String, dynamic>{}},
      });
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

    test('fork 会话只提交 message、幂等键和 lease，解析 parent lineage', () async {
      final adapter = _FixtureHttpAdapter((options) {
        expect(options.path, '/v1/sessions/session_parent/forks');
        expect(options.method, 'POST');
        expect(options.data, {
          'message_id': 'msg-assistant-1',
          'idempotency_key': 'fork-msg-assistant-1',
          'lease_epoch': 11,
        });
        final body = options.data as Map;
        expect(body.containsKey('device_id'), isFalse);
        expect(body.containsKey('ciphertext'), isFalse);
        return _jsonResponse({
          'id': 'session_child',
          'workspace_id': 'workspace_1',
          'status': 'idle',
          'provider': 'codex',
          'model': 'fixture-model-a',
          'last_seq': 1,
          'parent_session_id': 'session_parent',
          'forked_from_message_id': 'msg-assistant-1',
        }, statusCode: 201);
      });

      final child = await _authenticatedRepository(adapter).forkSession(
        'session_parent',
        const SessionForkInput(
          messageId: 'msg-assistant-1',
          idempotencyKey: 'fork-msg-assistant-1',
          leaseEpoch: 11,
          deviceId: 'android-owner-local-boundary',
        ),
      );

      expect(child.id, 'session_child');
      expect(child.parentSessionId, 'session_parent');
      expect(child.forkedFromMessageId, 'msg-assistant-1');
      expect(child.model, 'fixture-model-a');
    });

    test('controls 只解析白名单 model、usage 与 TTFT/throughput 投影', () async {
      final adapter = _FixtureHttpAdapter((options) {
        expect(options.path, '/v1/sessions/session_1/controls');
        expect(options.method, 'GET');
        expect(options.data, isNull);
        return _jsonResponse({
          'model': 'fixture-model-a',
          'usage': {
            'input_tokens': 120,
            'output_tokens': 80,
            'cache_read_tokens': 30,
            'cache_write_tokens': 10,
            'context_tokens': 240,
            'ttft_ms': 640,
            'decode_throughput': 42.5,
          },
        });
      });

      final controls = await _authenticatedRepository(
        adapter,
      ).getSessionControls('session_1');

      expect(controls.model, 'fixture-model-a');
      expect(controls.usage?.inputTokens, 120);
      expect(controls.usage?.outputTokens, 80);
      expect(controls.usage?.cacheReadTokens, 30);
      expect(controls.usage?.cacheCreationTokens, 10);
      expect(controls.usage?.contextTokens, 240);
      expect(controls.usage?.ttftMs, 640);
      expect(controls.usage?.decodeThroughput, 42.5);
      expect(controls.plan, isNull);
      expect(controls.goal, isNull);
    });

    test('controls 透传 model_groups 分组目录与模型元数据', () async {
      final adapter = _FixtureHttpAdapter((options) {
        expect(options.path, '/v1/sessions/session_1/controls');
        return _jsonResponse({
          'model': 'dsh:model:channel-b:shared',
          'models': [
            'dsh:model:channel-a:shared',
            'dsh:model:channel-b:shared',
          ],
          'model_groups': [
            {
              'id': 'channel-a',
              'name': 'Channel A',
              'models': [
                {
                  'provider': 'channel-a',
                  'value': 'dsh:model:channel-a:shared',
                  'id': 'shared',
                  'name': 'Shared Alpha',
                },
              ],
            },
            {
              'id': 'channel-b',
              'name': 'Channel B',
              'models': [
                {
                  'provider': 'channel-b',
                  'value': 'dsh:model:channel-b:shared',
                  'id': 'shared',
                  'name': 'Shared Beta',
                  'context_window_tokens': 320000,
                  'reasoning': true,
                  'efforts': ['low', 'high'],
                },
              ],
            },
          ],
        });
      });

      final controls = await _authenticatedRepository(
        adapter,
      ).getSessionControls('session_1');

      expect(controls.model, 'dsh:model:channel-b:shared');
      expect(controls.models, [
        'dsh:model:channel-a:shared',
        'dsh:model:channel-b:shared',
      ]);
      expect(controls.modelGroups, hasLength(2));
      expect(controls.modelGroups[0].name, 'Channel A');
      expect(controls.modelGroups[0].models.single.id, 'shared');
      final beta = controls.modelGroups[1].models.single;
      expect(beta.name, 'Shared Beta');
      expect(beta.value, 'dsh:model:channel-b:shared');
      expect(beta.contextWindowTokens, 320000);
      expect(beta.reasoning, isTrue);
      expect(beta.efforts, ['low', 'high']);
    });

    test('message feedback 支持 lazy read、CAS put、conflict 和 delete', () async {
      var call = 0;
      final adapter = _FixtureHttpAdapter((options) {
        switch (call++) {
          case 0:
            expect(options.path, '/v1/sessions/session_1/feedback/msg-1');
            expect(options.method, 'GET');
            return _jsonResponse({
              'item': {'rating': 'positive', 'note': 'helpful', 'version': 2},
            });
          case 1:
            expect(options.path, '/v1/sessions/session_1/feedback/msg-1');
            expect(options.method, 'PUT');
            expect(options.data, {
              'rating': 'negative',
              'note': 'needs source',
              'version': 2,
            });
            return _jsonResponse({
              'ok': true,
              'item': {
                'rating': 'negative',
                'note': 'needs source',
                'version': 3,
              },
            });
          case 2:
            expect(options.path, '/v1/sessions/session_1/feedback/msg-1');
            expect(options.method, 'PUT');
            expect(options.data, {'rating': 'positive', 'version': 2});
            return _jsonResponse({
              'ok': false,
              'error_code': 'version-conflict',
              'current': {
                'rating': 'negative',
                'note': 'needs source',
                'version': 3,
              },
            });
          case 3:
            expect(options.path, '/v1/sessions/session_1/feedback/msg-1');
            expect(options.method, 'DELETE');
            expect(options.data, {'version': 3});
            return _jsonResponse({'ok': true});
          default:
            fail('unexpected HTTP call $call');
        }
      });
      final repository = _authenticatedRepository(adapter);

      final initial = await repository.getMessageFeedback('session_1', 'msg-1');
      expect(initial?.rating, ConversationFeedbackRating.positive);
      expect(initial?.note, 'helpful');
      expect(initial?.version, 2);

      final updated = await repository.putMessageFeedback(
        'session_1',
        messageId: 'msg-1',
        rating: ConversationFeedbackRating.negative,
        note: 'needs source',
        version: 2,
      );
      expect(updated.ok, isTrue);
      expect(updated.item?.rating, ConversationFeedbackRating.negative);
      expect(updated.item?.version, 3);

      final conflict = await repository.putMessageFeedback(
        'session_1',
        messageId: 'msg-1',
        rating: ConversationFeedbackRating.positive,
        version: 2,
      );
      expect(conflict.ok, isFalse);
      expect(conflict.errorCode, 'version-conflict');

      final deleted = await repository.deleteMessageFeedback(
        'session_1',
        messageId: 'msg-1',
        version: 3,
      );
      expect(deleted.ok, isTrue);
      expect(deleted.item, isNull);
      expect(call, 4);
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

    // v0.8.9 收口回归（2026-09-06 实测）：能力矩阵端点接收超时单独放宽到 60s。
    // Relay 对 /v1/capabilities 做实时 Provider 探测（OpenCode + DSH 桥 Detect 冷启动），
    // Relay DB 重建后实测 12.01s——恰好越过全局 12s receiveTimeout，被映射成
    // 「Relay 暂时不可用」误报（服务端实际 200）。本回归锁定：
    // ① capabilities 请求携带 60s 单请求覆盖；② 普通请求不受影响（沿用全局值）。
    test('能力矩阵请求携带 60s 接收超时覆盖，普通请求沿用全局超时', () async {
      final capturedReceiveTimeouts = <String, Duration?>{};
      final adapter = _FixtureHttpAdapter((options) {
        capturedReceiveTimeouts[options.uri.path] = options.receiveTimeout;
        if (options.uri.path == '/v1/capabilities') {
          return _jsonResponse({
            'providers': [
              {
                'kind': 'dsh',
                'version': 'fixture-1',
                'available': true,
                'capabilities': [
                  {'name': 'start', 'status': 'native'},
                ],
              },
            ],
          });
        }
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
            },
          ],
        });
      });
      final repository = _authenticatedRepository(adapter);

      await repository.getCapabilities();
      await repository.listTerminals();

      expect(
        capturedReceiveTimeouts['/v1/capabilities'],
        const Duration(seconds: 60),
        reason: '能力矩阵实时探测可能超过全局 12s，必须放宽到 60s',
      );
      expect(
        capturedReceiveTimeouts['/v1/terminals'],
        isNot(const Duration(seconds: 60)),
        reason: '普通请求不应被放宽（真死连接仍按全局超时快速收敛）',
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

  group('MOBILE-V07 命令链路 HTTP 状态到用户错误的稳定映射', () {
    test('409 lease 冲突映射为可操作状态已更新', () async {
      final adapter = _FixtureHttpAdapter((options) {
        expect(options.method, 'POST');
        return _jsonResponse({'error': 'lease conflict'}, statusCode: 409);
      });
      final repository = _authenticatedRepository(adapter);

      await expectLater(
        repository.submitSessionCommand(
          'session_1',
          const SessionCommandInput(
            kind: SessionCommandKind.send,
            idempotencyKey: 'idem-409',
            leaseEpoch: 7,
            deviceId: 'android-owner-fixture',
            ciphertext: {
              'fixture_payload': {'message': 'hi'},
            },
          ),
        ),
        throwsA(
          isA<RelayFailure>()
              .having((f) => f.kind, 'kind', RelayFailureKind.forbidden)
              .having((f) => f.message, 'message', '会话可操作状态已更新，请重试。'),
        ),
      );
    });

    test('403 scope 拒绝映射为权限提示且不重试', () async {
      var calls = 0;
      final adapter = _FixtureHttpAdapter((options) {
        calls += 1;
        return _jsonResponse({'error': 'scope denied'}, statusCode: 403);
      });
      final repository = _authenticatedRepository(adapter);

      await expectLater(
        repository.listDevices(),
        throwsA(
          isA<RelayFailure>()
              .having((f) => f.kind, 'kind', RelayFailureKind.forbidden)
              .having((f) => f.message, 'message', '当前设备没有执行此操作的权限。'),
        ),
      );
      expect(calls, 1);
    });
  });

  group('V085-01 content-dek 读取契约（http）', () {
    test('GET 返回本设备 wrapped 载荷字节且保持 dek_id', () async {
      final adapter = _FixtureHttpAdapter((options) {
        expect(options.method, 'GET');
        expect(options.path, '/v1/sessions/sess-dek-9/content-dek');
        // Go []byte 的标准 base64（可含 padding）。
        return _jsonResponse({
          'dek_id': 'dek-sess-dek-9',
          'wrapped_dek': 'AAAAAA==',
        });
      });
      final repository = _authenticatedRepository(adapter);
      final wrapped = await repository.fetchSessionContentDEK('sess-dek-9');
      expect(wrapped, isNotNull);
      expect(wrapped!.dekId, 'dek-sess-dek-9');
      expect(wrapped.wrappedBytes, isNotEmpty);
      expect(await repository.sessionContentKeyAvailable('sess-dek-9'), isTrue);
    });

    test('404 表示会话无 DEK → fetch 返回 null 且可用性 false（fail-closed）', () async {
      final adapter = _FixtureHttpAdapter((options) {
        return _jsonResponse({'error': 'content dek not found'}, statusCode: 404);
      });
      final repository = _authenticatedRepository(adapter);
      expect(await repository.fetchSessionContentDEK('sess-dek-9'), isNull);
      expect(await repository.sessionContentKeyAvailable('sess-dek-9'), isFalse);
    });

    test('空载荷视为无 DEK（不向 picker 放行）', () async {
      final adapter = _FixtureHttpAdapter((options) {
        return _jsonResponse({'dek_id': '', 'wrapped_dek': ''});
      });
      final repository = _authenticatedRepository(adapter);
      expect(await repository.fetchSessionContentDEK('sess-dek-9'), isNull);
    });
  });

  group('MOBILE-01 owner access token 过期的 401 自动刷新重放', () {
    test('首个请求 401 后用 refresh token 换新并重放，新令牌写回存储', () async {
      final calls = <RequestOptions>[];
      final written = <AuthTokens>[];
      var stored = AuthTokens(
        accessToken: 'access-stale',
        refreshToken: 'refresh-live',
        expiresAt: DateTime.utc(2026, 8, 14),
        deviceId: 'dev_owner',
      );
      final adapter = _FixtureHttpAdapter((options) {
        calls.add(options);
        if (options.path == '/v1/auth/refresh') {
          expect(options.data, {'refresh_token': 'refresh-live'});
          return _jsonResponse({
            'account_id': 'acct_1',
            'device_id': 'dev_owner',
            'access_token': 'access-fresh',
            'refresh_token': 'refresh-rotated',
            'expires_in': 900,
          });
        }
        final authorization = options.headers['Authorization'];
        if (authorization == 'Bearer access-stale') {
          return _jsonResponse({'error': 'unauthenticated'}, statusCode: 401);
        }
        expect(authorization, 'Bearer access-fresh');
        return _jsonResponse({'devices': []});
      });
      final repository = _refreshableRepository(
        adapter,
        readTokens: () async => stored,
        writeTokens: (tokens) async {
          written.add(tokens);
          stored = tokens;
        },
      );

      final devices = await repository.listDevices();

      expect(devices, isEmpty);
      expect(calls.map((call) => call.path).toList(), [
        '/v1/devices',
        '/v1/auth/refresh',
        '/v1/devices',
      ]);
      expect(written.single.accessToken, 'access-fresh');
      expect(written.single.refreshToken, 'refresh-rotated');
      // 存储已被更新：后续请求不会携带被轮换的旧 refresh token。
      expect(stored.refreshToken, 'refresh-rotated');
    });

    test('刷新也失败时保持未授权语义，且刷新只发生一次', () async {
      var refreshCalls = 0;
      final adapter = _FixtureHttpAdapter((options) {
        if (options.path == '/v1/auth/refresh') {
          refreshCalls += 1;
          return _jsonResponse({'error': 'token reused'}, statusCode: 401);
        }
        return _jsonResponse({'error': 'unauthenticated'}, statusCode: 401);
      });
      final repository = _refreshableRepository(
        adapter,
        readTokens: () async => AuthTokens(
          accessToken: 'access-stale',
          refreshToken: 'refresh-dead',
          expiresAt: DateTime.utc(2026, 8, 14),
        ),
        writeTokens: (_) async {},
      );

      await expectLater(
        repository.listDevices(),
        throwsA(
          isA<RelayFailure>().having(
            (failure) => failure.kind,
            'kind',
            RelayFailureKind.unauthorized,
          ),
        ),
      );
      expect(refreshCalls, 1);
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

HttpRelayRepository _refreshableRepository(
  _FixtureHttpAdapter adapter, {
  required Future<AuthTokens?> Function() readTokens,
  required Future<void> Function(AuthTokens tokens) writeTokens,
}) {
  final dio = Dio(BaseOptions(baseUrl: 'http://relay.fixture'));
  dio.httpClientAdapter = adapter;
  return HttpRelayRepository(
    dio: dio,
    readTokens: readTokens,
    writeTokens: writeTokens,
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
