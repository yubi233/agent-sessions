import 'package:agent_sessions_mobile/domain/control_models.dart';
import 'package:agent_sessions_mobile/domain/delegation_models.dart';
import 'package:agent_sessions_mobile/domain/models.dart';
import 'package:agent_sessions_mobile/domain/session_models.dart';
import 'package:agent_sessions_mobile/relay/fixture_relay_repository.dart';
import 'package:agent_sessions_mobile/state/delegation_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MOBILE-05 DELEG-04..06 父子会话控制状态机', () {
    test('拒绝 proposed 节点不会创建 child session 或产生成功副作用', () async {
      final fixture = await _newParentFixture();
      final proposal = await fixture.relay.seedDelegationProposal(
        parentSessionId: fixture.parent.id,
      );
      final controller = DelegationController(relay: fixture.relay);
      await controller.loadForParent(fixture.parent.id);

      final result = await controller.decide(
        delegation: proposal,
        decision: DelegationDecision.reject,
        capabilities: fixture.capabilities,
        canWrite: true,
        deviceId: _ownerDeviceId,
        parentLease: fixture.parentLease,
      );

      expect(result?.status, DelegationStatus.rejected);
      expect(controller.delegations.single.status, DelegationStatus.rejected);
      expect((await fixture.relay.listSessions()), hasLength(1));
      expect(result?.childSessionId, isNull);
    });

    test('批准使用 parent lease，但 child 必须通过独立 lease 才能写入', () async {
      final fixture = await _newParentFixture();
      // parent epoch 推进到 2；fixture approve 会为 child 创建独立的初始 epoch 1。
      final parentLease = await fixture.relay.acquireSessionLease(
        fixture.parent.id,
      );
      final proposal = await fixture.relay.seedDelegationProposal(
        parentSessionId: fixture.parent.id,
      );
      final controller = DelegationController(relay: fixture.relay);
      await controller.loadForParent(fixture.parent.id);

      final result = await controller.decide(
        delegation: proposal,
        decision: DelegationDecision.approve,
        capabilities: fixture.capabilities,
        canWrite: true,
        deviceId: _ownerDeviceId,
        parentLease: parentLease,
      );
      final childId = result?.childSessionId;

      expect(result?.status, DelegationStatus.running);
      expect(childId, isNotNull);
      expect(childId, isNot(fixture.parent.id));
      expect((await fixture.relay.listSessions()), hasLength(2));
      await expectLater(
        fixture.relay.submitSessionCommand(
          childId!,
          SessionCommandInput(
            kind: SessionCommandKind.abort,
            idempotencyKey: 'parent-lease-cannot-write-child',
            leaseEpoch: parentLease.epoch,
            deviceId: _ownerDeviceId,
          ),
        ),
        throwsA(isA<RelayFailure>()),
      );

      final childLease = await fixture.relay.acquireSessionLease(childId);
      final receipt = await fixture.relay.submitSessionCommand(
        childId,
        SessionCommandInput(
          kind: SessionCommandKind.abort,
          idempotencyKey: 'child-own-lease-can-write',
          leaseEpoch: childLease.epoch,
          deviceId: _ownerDeviceId,
        ),
      );
      expect(childLease.sessionId, childId);
      expect(receipt.status, 'accepted');
    });

    test('unsupported target 在客户端 fail-closed，不能创建 child', () async {
      final fixture = await _newParentFixture();
      final proposal = await fixture.relay.seedDelegationProposal(
        parentSessionId: fixture.parent.id,
        targetProvider: 'claude',
      );
      final controller = DelegationController(relay: fixture.relay);
      await controller.loadForParent(fixture.parent.id);

      final blocked = controller.decisionBlockedReason(
        delegation: proposal,
        decision: DelegationDecision.approve,
        capabilities: fixture.capabilities,
        canWrite: true,
        deviceId: _ownerDeviceId,
        parentLease: fixture.parentLease,
      );
      final result = await controller.decide(
        delegation: proposal,
        decision: DelegationDecision.approve,
        capabilities: fixture.capabilities,
        canWrite: true,
        deviceId: _ownerDeviceId,
        parentLease: fixture.parentLease,
      );

      expect(blocked, isNotNull);
      expect(result, isNull);
      expect(controller.message, blocked);
      expect((await fixture.relay.listSessions()), hasLength(1));
      expect(controller.delegations.single.status, DelegationStatus.proposed);
    });
  });
}

const _ownerDeviceId = 'android-owner-fixture';

Future<_ParentFixture> _newParentFixture() async {
  final relay = FixtureRelayRepository(
    clock: () => DateTime.utc(2026, 8, 14, 12),
  );
  await relay.register(
    const LoginCredentials(
      email: 'delegation-owner@fixture.test',
      password: 'fixture-password',
    ),
  );
  final parent = await relay.createSession(
    const CreateMobileSessionInput(
      workspaceId: 'fixture-workspace',
      provider: 'codex',
      deviceId: _ownerDeviceId,
    ),
  );
  return _ParentFixture(
    relay: relay,
    parent: parent,
    parentLease: await relay.acquireSessionLease(parent.id),
    capabilities: await relay.getCapabilities(),
  );
}

class _ParentFixture {
  const _ParentFixture({
    required this.relay,
    required this.parent,
    required this.parentLease,
    required this.capabilities,
  });

  final FixtureRelayRepository relay;
  final MobileSession parent;
  final SessionLease parentLease;
  final CapabilityMatrix capabilities;
}
