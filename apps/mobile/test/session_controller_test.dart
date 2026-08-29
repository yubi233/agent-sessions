import 'dart:math';

import 'package:agent_sessions_mobile/domain/control_models.dart';
import 'package:agent_sessions_mobile/domain/session_models.dart';
import 'package:agent_sessions_mobile/relay/fixture_relay_repository.dart';
import 'package:agent_sessions_mobile/state/session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fixture_owner.dart';

void main() {
  test('MOBILE-V06-REAL-SESSION：autoStart 在创建后自动获取 lease 并提交 start', () async {
    final relay = FixtureRelayRepository(clock: () => _now);
    await _prepareOwner(relay);
    final controller = SessionController(
      relay: relay,
      clock: () => _now,
      random: _DeterministicRandom(),
    );
    await controller.initialize();

    final created = await controller.createSession(
      workspaceId: 'fixture-workspace',
      provider: 'codex',
      deviceId: _ownerDeviceId,
      canWrite: true,
      autoStart: true,
    );

    expect(created, isNotNull);
    expect(controller.hasSelectedLease, isTrue);
    expect(controller.timeline.any((event) => event.label == '会话已启动'), isTrue);
  });

  test('MOBILE-V07 发送密文携带当前生效模型，避免服务端回退到配置默认', () async {
    final relay = _CapturingControlsRelay(clock: () => _now);
    await _prepareOwner(relay);
    final controller = SessionController(
      relay: relay,
      clock: () => _now,
      random: _DeterministicRandom(),
    );
    await controller.initialize();
    await controller.createSession(
      workspaceId: 'fixture-workspace',
      provider: 'opencode',
      deviceId: _ownerDeviceId,
      canWrite: true,
      autoStart: true,
    );

    await controller.sendMessage(
      message: '你好',
      deviceId: _ownerDeviceId,
      canWrite: true,
    );

    final send = relay.submitted
        .lastWhere((command) => command.kind == SessionCommandKind.send);
    final payload =
        send.ciphertext?['fixture_payload'] as Map<String, dynamic>;
    expect(payload['message'], '你好');
    expect(payload['model'], 'opencode/big-pickle');
  });

  test('MOBILE-V07 发送后乐观回显用户气泡，canonical 事件到达后清账', () async {
    final relay = _DelayedEchoRelay(clock: () => _now);
    await _prepareOwner(relay);
    final controller = SessionController(
      relay: relay,
      clock: () => _now,
      random: _DeterministicRandom(),
    );
    await controller.initialize();
    await controller.createSession(
      workspaceId: 'fixture-workspace',
      provider: 'opencode',
      deviceId: _ownerDeviceId,
      canWrite: true,
      autoStart: true,
    );

    // 先让用户事件迟迟不回传：发送后立即应挂出本地乐观回显气泡。
    // 文本不能与 fixture 预置演示对话（「你好」）相同，否则清账判定会撞车。
    const echoText = '测试乐观回显文本';
    relay.echoAfterCalls = 99;
    relay.echoText = echoText;
    final sending = controller.sendMessage(
      message: echoText,
      deviceId: _ownerDeviceId,
      canWrite: true,
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(controller.pendingOutgoingMessage, echoText);

    // canonical user.message 回传后，乐观条目清账，不留双气泡。
    relay.echoAfterCalls = 0;
    await sending;
    expect(controller.pendingOutgoingMessage, isNull);
  });

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

      await controller.startSelectedSession(
        deviceId: _ownerDeviceId,
        canWrite: true,
      );
      expect(
        controller.timeline.any((event) => event.label == '会话已启动'),
        isTrue,
      );

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

    test('start 后可通过 kill 结束 fixture 进程并进入 stopped', () async {
      final relay = FixtureRelayRepository(clock: () => _now);
      await _prepareOwner(relay);
      final controller = SessionController(relay: relay, clock: () => _now);
      await controller.initialize();
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
      await controller.startSelectedSession(
        deviceId: _ownerDeviceId,
        canWrite: true,
      );
      await controller.killSelectedSession(
        deviceId: _ownerDeviceId,
        canWrite: true,
      );

      expect(controller.selectedSession?.id, created!.id);
      expect(controller.selectedSession?.status, MobileSessionStatus.stopped);
      expect(
        controller.timeline.any((event) => event.label == '已结束本机进程'),
        isTrue,
      );
      expect(controller.errorMessage, isNull);
    });

    test('未声明 kill capability 时保持 fail-closed', () async {
      final relay = FixtureRelayRepository(clock: () => _now);
      await _prepareOwner(relay);
      final controller = SessionController(relay: relay, clock: () => _now);
      await controller.initialize();
      await controller.createSession(
        workspaceId: 'fixture-workspace',
        provider: 'claude',
        deviceId: _ownerDeviceId,
        canWrite: true,
      );
      await controller.acquireSelectedLease(
        deviceId: _ownerDeviceId,
        canWrite: true,
      );

      await controller.killSelectedSession(
        deviceId: _ownerDeviceId,
        canWrite: true,
      );

      expect(controller.errorMessage, 'fixture Provider 未声明此能力。');
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

    test('forkFromMessage 使用当前 lease 创建 child，并刷新 parent lineage 事件', () async {
      final relay = FixtureRelayRepository(clock: () => _now);
      await _prepareOwner(relay);
      final controller = SessionController(
        relay: relay,
        clock: () => _now,
        random: _DeterministicRandom(),
      );
      final parent = await controller.createSession(
        workspaceId: 'fixture-workspace',
        provider: 'codex',
        deviceId: _ownerDeviceId,
        canWrite: true,
      );
      await controller.acquireSelectedLease(
        deviceId: _ownerDeviceId,
        canWrite: true,
      );

      final child = await controller.forkFromMessage(
        messageId: 'assistant-message-1',
        deviceId: _ownerDeviceId,
        canWrite: true,
      );
      final retried = await controller.forkFromMessage(
        messageId: 'assistant-message-1',
        deviceId: _ownerDeviceId,
        canWrite: true,
      );

      expect(child, isNotNull);
      expect(retried?.id, child!.id);
      expect(child.parentSessionId, parent!.id);
      expect(child.forkedFromMessageId, 'assistant-message-1');
      expect(
        controller.sessions.where((session) => session.id == child.id),
        hasLength(1),
      );
      expect(
        controller.sessions.any((session) => session.id == parent.id),
        isTrue,
      );
      expect(controller.selectedSession?.id, parent.id);
      expect(
        controller.timeline.any((event) => event.label == '已创建分支'),
        isTrue,
      );
      expect(controller.errorMessage, isNull);
    });
  });

  test(
    'MOBILE-V06-TURN-COMPLETED：completed_turn 事件把 streaming 会话收敛为 idle 并刷新 controls',
    () async {
      final relay = _TurnCompletedRelay(clock: () => _now);
      await _prepareOwner(relay);
      final controller = SessionController(
        relay: relay,
        clock: () => _now,
        random: _DeterministicRandom(),
      );
      await controller.initialize();

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
      await controller.startSelectedSession(
        deviceId: _ownerDeviceId,
        canWrite: true,
      );

      // 下一次 snapshot 注入：session 仍为 streaming，但携带 completed_turn。
      relay.armNextSnapshot = true;
      await controller.sendMessage(
        message: '结束这一轮',
        deviceId: _ownerDeviceId,
        canWrite: true,
      );

      expect(controller.selectedSession?.status, MobileSessionStatus.idle);
      expect(controller.isStreaming, isFalse);
      expect(controller.timeline.any((event) => event.completedTurn), isTrue);
      // 回合结束后 controls 被主动刷新；fixture 控制项带确定性 usage。
      expect(controller.controls.usage, isNotNull);
      expect(created, isNotNull);
    },
  );

  test('归档会话从列表隐藏且保留数据，取消归档可恢复', () async {
    final relay = FixtureRelayRepository(clock: () => _now);
    await _prepareOwner(relay);
    final controller = SessionController(
      relay: relay,
      clock: () => _now,
      random: _DeterministicRandom(),
    );
    await controller.initialize();

    final created = await controller.createSession(
      workspaceId: 'fixture-workspace',
      provider: 'codex',
      deviceId: _ownerDeviceId,
      canWrite: true,
    );
    expect(created, isNotNull);
    expect(controller.sessions, hasLength(1));

    final archived = await controller.archiveSelectedSession(
      deviceId: _ownerDeviceId,
      canWrite: true,
    );
    expect(archived, isTrue);
    expect(controller.sessions, isEmpty);
    expect(controller.selectedSessionId, isNull);

    // 直接通过 fixture 快照仍能读取原会话（数据未删除）。
    final snapshot = await relay.getSessionSnapshot(created!.id);
    expect(snapshot.session.id, created.id);
    expect(snapshot.session.archivedAt, isNotNull);

    // 已归档会话不能从当前首页恢复（没有选择入口），但 Relay 恢复接口可将其取消归档。
    final restored = await relay.unarchiveSession(created.id);
    expect(restored.archivedAt, isNull);
    await controller.refreshSessions();
    expect(controller.sessions, hasLength(1));
  });
}

/// 在 sendMessage 后的首次快照中注入 completed_turn 事件，
/// 验证真实后端 turn.completed 终止路径在控制器里的状态收敛。
/// 前 `echoAfterCalls` 次 snapshot 不回传用户事件且保持 streaming，
/// 用于验证乐观回显的挂出与清账时序。
class _DelayedEchoRelay extends FixtureRelayRepository {
  _DelayedEchoRelay({required super.clock});

  int snapshotCalls = 0;
  int echoAfterCalls = 2;
  String echoText = '你好';

  @override
  Future<SessionSnapshot> getSessionSnapshot(
    String sessionId, {
    int afterSequence = 0,
  }) async {
    snapshotCalls += 1;
    final snapshot = await super.getSessionSnapshot(
      sessionId,
      afterSequence: afterSequence,
    );
    // fixture 预置时间线带未解决的 permission/question 事件；按 _snapshotCompletesTurn
    // 的设计它们会让轮询立即收敛，这里过滤掉以便演练乐观回显的完整时序。
    final events = snapshot.events
        .where(
          (event) =>
              !(event.envelope['fixture_payload'] is Map &&
                  const ['permission_request', 'question_request'].contains(
                    (event.envelope['fixture_payload'] as Map)['kind'],
                  )),
        )
        .toList();
    if (snapshotCalls <= echoAfterCalls) {
      return SessionSnapshot(
        session: snapshot.session.copyWith(
          status: MobileSessionStatus.streaming,
        ),
        events: events,
      );
    }
    // canonical 阶段：用户事件回传 + completed_turn 标记，控制器应清账乐观回显
    // 并按真实轮次收敛。
    final userEvent = RelaySessionEvent(
      sequence: snapshot.session.lastSequence + 1,
      eventType: 'user.message',
      envelope: {
        'fixture_payload': {
          'kind': 'user_message',
          'label': '你',
          'text': echoText,
          'streaming': false,
          'copy_text': echoText,
        },
      },
    );
    final completedEvent = RelaySessionEvent(
      sequence: snapshot.session.lastSequence + 2,
      eventType: 'turn.completed',
      envelope: const {
        'fixture_payload': {
          'kind': 'assistant_message',
          'label': 'Assistant',
          'text': '回合已结束。',
          'completed_turn': true,
        },
      },
    );
    return SessionSnapshot(
      session: snapshot.session.copyWith(
        status: MobileSessionStatus.streaming,
        lastSequence: completedEvent.sequence,
      ),
      events: [...events, userEvent, completedEvent],
    );
  }
}

/// 捕获提交的命令并固定 controls 的生效模型：验证发送密文把模型带给 daemon
/// （空模型会让 opencode 服务端回退到它的配置默认，可能命中付费条目）。
class _CapturingControlsRelay extends FixtureRelayRepository {
  _CapturingControlsRelay({required super.clock});

  final List<SessionCommandInput> submitted = [];

  @override
  Future<SessionCommandReceipt> submitSessionCommand(
    String sessionId,
    SessionCommandInput input,
  ) {
    submitted.add(input);
    return super.submitSessionCommand(sessionId, input);
  }

  @override
  Future<SessionControlState> getSessionControls(String sessionId) async {
    final controls = await super.getSessionControls(sessionId);
    return controls.copyWith(model: 'opencode/big-pickle');
  }
}

/// 在 sendMessage 后的首次快照中注入 completed_turn 事件，
/// 验证真实后端 turn.completed 终止路径在控制器里的状态收敛。
class _TurnCompletedRelay extends FixtureRelayRepository {
  _TurnCompletedRelay({required super.clock});

  bool armNextSnapshot = false;

  @override
  Future<SessionSnapshot> getSessionSnapshot(
    String sessionId, {
    int afterSequence = 0,
  }) async {
    final snapshot = await super.getSessionSnapshot(
      sessionId,
      afterSequence: afterSequence,
    );
    if (!armNextSnapshot) return snapshot;
    armNextSnapshot = false;
    final event = RelaySessionEvent(
      sequence: snapshot.session.lastSequence + 1,
      eventType: 'turn.completed',
      envelope: const {
        'fixture_payload': {
          'kind': 'assistant_message',
          'label': 'Assistant',
          'text': '回合已结束。',
          'completed_turn': true,
        },
      },
    );
    return SessionSnapshot(
      session: snapshot.session.copyWith(
        status: MobileSessionStatus.streaming,
        lastSequence: event.sequence,
      ),
      events: [...snapshot.events, event],
    );
  }
}

const _ownerDeviceId = 'android-owner-fixture';
final _now = DateTime.utc(2026, 8, 14, 9, 30);

Future<void> _prepareOwner(FixtureRelayRepository relay) async {
  await bootstrapFixtureOwner(relay);
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
