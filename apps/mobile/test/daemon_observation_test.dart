import 'package:agent_sessions_mobile/app/providers.dart';
import 'package:agent_sessions_mobile/domain/daemon_observation_models.dart';
import 'package:agent_sessions_mobile/domain/models.dart';
import 'package:agent_sessions_mobile/domain/session_models.dart';
import 'package:agent_sessions_mobile/relay/fixture_relay_repository.dart';
import 'package:agent_sessions_mobile/state/daemon_observation_controller.dart';
import 'package:agent_sessions_mobile/ui/daemon_observation_screens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('P2-F Daemon 观察状态机', () {
    test('仅按 Relay cursor 追加安全事件，并在失败时保留最后观察结果', () async {
      final relay = FixtureRelayRepository(clock: () => _now);
      final sessionId = await _prepareFixtureSession(relay);
      final controller = DaemonObservationController(
        relay: relay,
        sessionId: sessionId,
      );

      await controller.initialize();
      final first = controller.observation!;
      expect(controller.phase, DaemonObservationPhase.ready);
      expect(first.commands, isEmpty);
      expect(first.events, isNotEmpty);
      expect(first.events.single.envelope.state, CipherEnvelopeState.opaque);

      await relay.acquireSessionLease(sessionId);
      await relay.submitSessionCommand(
        sessionId,
        const SessionCommandInput(
          kind: SessionCommandKind.abort,
          idempotencyKey: 'p2f-observation-abort',
          leaseEpoch: 1,
          deviceId: _ownerDeviceId,
        ),
      );
      await controller.refresh();

      expect(controller.observation!.commands, hasLength(1));
      expect(
        controller.observation!.commands.single.kind,
        DaemonObservationCommandKind.abort,
      );
      expect(
        controller.observation!.commands.single.deliveryState,
        DaemonDeliveryState.queued,
      );
      expect(
        controller.observation!.events.length,
        greaterThan(first.events.length),
      );

      relay.setNetworkAvailable(false);
      await controller.refresh();
      expect(controller.phase, DaemonObservationPhase.ready);
      expect(controller.observation!.commands, hasLength(1));
      expect(controller.errorMessage, contains('不可用'));
    });

    test('未知命令、事件、错误码与加密算法均 fail-closed', () {
      final observation = DaemonSessionObservation.fromRelayJson({
        'session': {
          'status': 'future_state',
          'provider': 'future',
          'last_seq': 1,
        },
        'commands': [
          {
            'kind': 'future.command',
            'status': 'future_status',
            'delivery_state': 'future_delivery',
            'error_code': 'adapter free-form failure',
          },
        ],
        'events': [
          {
            'event_seq': 1,
            'event_type': 'future.event',
            'envelope': {
              'state': 'verified',
              'algorithm': 'future-crypto',
              'payload_version': 999,
            },
          },
        ],
      });

      expect(
        observation.commands.single.kind,
        DaemonObservationCommandKind.unknown,
      );
      expect(
        observation.commands.single.status,
        DaemonObservationCommandStatus.unknown,
      );
      expect(
        observation.commands.single.deliveryState,
        DaemonDeliveryState.unknown,
      );
      expect(
        observation.commands.single.errorCode,
        DaemonObservationErrorCode.daemonExecutionFailed,
      );
      expect(
        observation.events.single.eventType,
        DaemonObservationEventType.unknown,
      );
      expect(
        observation.events.single.envelope.state,
        CipherEnvelopeState.opaque,
      );
    });
  });

  group('P2-F Daemon 观察页面', () {
    testWidgets('只显示安全状态，不显示 fixture payload、ID、密文或远程写控件', (tester) async {
      final relay = FixtureRelayRepository(clock: () => _now);
      final sessionId = await _prepareFixtureSession(relay);
      await relay.acquireSessionLease(sessionId);
      await relay.submitSessionCommand(
        sessionId,
        const SessionCommandInput(
          kind: SessionCommandKind.abort,
          idempotencyKey: 'p2f-ui-abort',
          leaseEpoch: 1,
          deviceId: _ownerDeviceId,
        ),
      );
      final controller = DaemonObservationController(
        relay: relay,
        sessionId: sessionId,
      );
      await controller.initialize();

      await tester.pumpWidget(
        ProviderScope(
          key: UniqueKey(),
          overrides: [
            relayRepositoryProvider.overrideWithValue(relay),
            daemonObservationControllerProvider(
              sessionId,
            ).overrideWith((_) => controller),
          ],
          child: MaterialApp(
            home: DaemonObservationScreen(sessionId: sessionId),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('daemon-observation-list')), findsOneWidget);
      expect(
        find.byKey(const Key('daemon-observation-command-0')),
        findsOneWidget,
      );
      expect(find.text('停止会话'), findsOneWidget);
      expect(find.text('等待投递'), findsOneWidget);
      expect(find.text('加密内容不可用'), findsAtLeastNWidgets(1));
      expect(
        find.byKey(const Key('daemon-observation-boundary-note')),
        findsOneWidget,
      );
      expect(
        find.text('此会话使用本地 deterministic fixture，不会请求真实 Provider。'),
        findsNothing,
      );
      expect(find.text(sessionId), findsNothing);
      expect(find.byTooltip('获取会话控制权'), findsNothing);
      expect(find.byTooltip('发送消息'), findsNothing);
      expect(find.byTooltip('结束会话'), findsNothing);
    });

    testWidgets('首次读取失败时显示可重试错误', (tester) async {
      final relay = FixtureRelayRepository(clock: () => _now)
        ..setNetworkAvailable(false);
      final controller = DaemonObservationController(
        relay: relay,
        sessionId: 'missing-session',
      );
      await controller.initialize();

      await tester.pumpWidget(
        ProviderScope(
          key: UniqueKey(),
          overrides: [
            relayRepositoryProvider.overrideWithValue(relay),
            daemonObservationControllerProvider(
              'missing-session',
            ).overrideWith((_) => controller),
          ],
          child: const MaterialApp(
            home: DaemonObservationScreen(sessionId: 'missing-session'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('daemon-observation-error')), findsOneWidget);
      expect(
        find.byKey(const Key('daemon-observation-retry-button')),
        findsOneWidget,
      );
    });
  });
}

const _ownerDeviceId = 'android-owner-fixture';
final _now = DateTime.utc(2026, 8, 17, 12);

Future<String> _prepareFixtureSession(FixtureRelayRepository relay) async {
  await relay.register(
    const LoginCredentials(
      email: 'p2f-observation@fixture.test',
      password: 'fixture-password',
    ),
  );
  await relay.bootstrapOwner(
    const BootstrapOwnerInput(
      displayName: 'P2-F owner',
      platform: 'android',
      keys: DeviceRegistrationMaterial(
        identityPublicKey: 'p2f-identity',
        encryptionPublicKey: 'p2f-encryption',
      ),
    ),
  );
  final session = await relay.createSession(
    const CreateMobileSessionInput(
      workspaceId: 'p2f-workspace',
      provider: 'codex',
      deviceId: _ownerDeviceId,
    ),
  );
  return session.id;
}
