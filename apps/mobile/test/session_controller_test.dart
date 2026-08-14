import 'dart:math';

import 'package:agent_sessions_mobile/domain/models.dart';
import 'package:agent_sessions_mobile/domain/session_models.dart';
import 'package:agent_sessions_mobile/relay/fixture_relay_repository.dart';
import 'package:agent_sessions_mobile/state/session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MOBILE-02 SESS-01..02 CTRL-01..02 会话控制状态机', () {
    test('空列表、新会话、流式时间线、权限问题和停止共享同一 lease 链路', () async {
      final relay = FixtureRelayRepository(clock: () => _now);
      await _prepareOwner(relay);
      final controller = SessionController(
        relay: relay,
        clock: () => _now,
        random: _DeterministicRandom(),
      );

      await controller.initialize();
      expect(controller.isEmpty, isTrue);

      final created = await controller.createSession(
        workspaceId: 'fixture-workspace',
        provider: 'codex',
        deviceId: _ownerDeviceId,
        canWrite: true,
      );
      expect(created, isNotNull);
      expect(controller.selectedSession?.id, created!.id);
      expect(controller.timeline.single.kind, SessionTimelineKind.systemNotice);
      expect(controller.composerBlockedReason(canWrite: true), '等待获取会话控制权');

      await controller.acquireSelectedLease(
        deviceId: _ownerDeviceId,
        canWrite: true,
      );
      expect(controller.selectedLease?.epoch, 1);

      await controller.sendMessage(
        message: '请检查 fixture 会话',
        deviceId: _ownerDeviceId,
        canWrite: true,
      );
      expect(controller.isStreaming, isTrue);
      expect(
        controller.timeline.any(
          (event) =>
              event.kind == SessionTimelineKind.assistantMessage &&
              event.isStreaming,
        ),
        isTrue,
      );
      final permission = controller.timeline
          .firstWhere((event) => event.permission != null)
          .permission!;
      final question = controller.timeline
          .firstWhere((event) => event.question != null)
          .question!;

      await controller.resolvePermission(
        requestId: permission.requestId,
        approved: true,
        deviceId: _ownerDeviceId,
        canWrite: true,
      );
      await controller.answerQuestion(
        requestId: question.requestId,
        answer: question.options.first,
        deviceId: _ownerDeviceId,
        canWrite: true,
      );
      expect(
        controller.isRequestResolved('permission', permission.requestId),
        isTrue,
      );
      expect(
        controller.isRequestResolved('question', question.requestId),
        isTrue,
      );

      await controller.stopStreaming(deviceId: _ownerDeviceId, canWrite: true);
      expect(controller.selectedSession?.status, MobileSessionStatus.stopped);
      expect(controller.timeline.any((event) => event.label == '已停止'), isTrue);
      expect(controller.errorMessage, isNull);
    });

    test('只读状态不会创建会话或调用 fixture 写路径', () async {
      final relay = FixtureRelayRepository(clock: () => _now);
      final controller = SessionController(relay: relay, clock: () => _now);
      await controller.initialize();

      final created = await controller.createSession(
        workspaceId: 'fixture-workspace',
        provider: 'codex',
        deviceId: null,
        canWrite: false,
      );

      expect(created, isNull);
      expect(controller.sessions, isEmpty);
      expect(controller.errorMessage, contains('只读'));
    });

    test('旧 epoch 被 fixture 拒绝，控制器保留可见错误而不伪造发送成功', () async {
      final relay = FixtureRelayRepository(clock: () => _now);
      await _prepareOwner(relay);
      final controller = SessionController(relay: relay, clock: () => _now);
      final created = await controller.createSession(
        workspaceId: 'fixture-workspace',
        provider: 'codex',
        deviceId: _ownerDeviceId,
        canWrite: true,
      );
      await controller.acquireSelectedLease(
        deviceId: _ownerDeviceId,
        canWrite: true,
      );
      // 另一个显式 lease 获取会推进 epoch，模拟旧 UI 在 fencing 后继续发送。
      await relay.acquireSessionLease(created!.id);

      await controller.sendMessage(
        message: '这条旧 epoch 命令不能被接受',
        deviceId: _ownerDeviceId,
        canWrite: true,
      );

      expect(controller.errorMessage, '会话控制权已更新，请重新获取。');
      expect(controller.timeline.length, 1);
    });
  });
}

const _ownerDeviceId = 'android-owner-fixture';
final _now = DateTime.utc(2026, 8, 14, 9, 30);

Future<void> _prepareOwner(FixtureRelayRepository relay) async {
  await relay.register(
    const LoginCredentials(
      email: 'session-owner@fixture.test',
      password: 'fixture-password',
    ),
  );
}

/// 稳定随机数让幂等键的测试环境可重复，但产品默认使用 Random.secure。
class _DeterministicRandom implements Random {
  var _value = 0;

  @override
  bool nextBool() => nextInt(2) == 1;

  @override
  double nextDouble() => nextInt(1 << 20) / (1 << 20);

  @override
  int nextInt(int max) {
    _value += 1;
    return _value % max;
  }
}
